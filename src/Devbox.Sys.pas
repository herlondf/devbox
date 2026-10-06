unit Devbox.Sys;

{ Tudo que fala com o Windows: processos de linha de comando, clipboard,
  OCR, portas em escuta, autostart. }

interface

uses
  Winapi.Windows,
  Winapi.Messages,
  System.SysUtils,
  Devbox.Model;

type
  TClipEvent = reference to procedure(AKind: TClipKind; const AText: string; const AData: TBytes);

  { Avisa cada coisa nova copiada em qualquer programa: texto, imagem (vira PNG)
    ou arquivos (um caminho por linha). Pula o que o gerenciador de senhas marca
    como sigiloso e o que o próprio Devbox acabou de escrever. }
  TClipboardWatcher = class
  private
    FWnd: HWND;
    FOnClip: TClipEvent;
    FIgnoreUntil: UInt64;
    procedure WndProc(var Message: TMessage);
    procedure Wrote;
  public
    constructor Create(const AOnClip: TClipEvent);
    destructor Destroy; override;
    { Põem no clipboard sem voltar como "novo". }
    procedure SetText(const AText: string);
    procedure SetImage(const APng: TBytes);
    procedure SetFiles(const APaths: TArray<string>);
  end;

{ Ctrl+V sintético para o programa da frente. }
procedure SendCtrlV;
procedure SendKeyInputs(const AKeys: array of Word; const AUp: array of Boolean);

{ Traz a janela para a frente mesmo com o Windows barrando troca de foco
  (um Alt sintético libera o SetForegroundWindow). }
procedure ForceForeground(AWnd: HWND);

{ Texto da imagem pelo OCR do Windows (ocr.ps1 ao lado do exe). Bloqueia. }
function OcrImage(const APngPath: string; out AText: string): Boolean;

{ Roda e devolve a saída (stdout + stderr). -1 = não achou o programa;
  -2 = passou do tempo. Bloqueia: chamar fora da thread de UI. }
function RunCapture(const ACmdLine: string; out AOutput: string; ATimeoutMs: Cardinal = 15000;
  const AWorkDir: string = ''): Integer;

{ Portas TCP em escuta (IPv4 e IPv6, uma linha por porta) com o processo dono. }
function ListListenPorts: TListenPorts;

function KillProcess(APid: Cardinal): Boolean;

{ Traz AWnd para a frente e manda Ctrl+V. }
procedure PasteInto(AWnd: HWND);

procedure OpenUrl(const AUrl: string);
procedure Launch(const AExe, AParams: string);

function AutostartEnabled: Boolean;
procedure SetAutostart(AOn: Boolean);

implementation

uses
  System.Classes,
  System.Win.Registry,
  System.Generics.Collections,
  Winapi.ShellAPI,
  Winapi.TlHelp32,
  Winapi.ShlObj,
  System.StrUtils,
  System.Hash,
  Vcl.Graphics,
  Vcl.Imaging.pngimage,
  Vcl.Clipbrd;

{ TClipboardWatcher }

const
  // Escrita do próprio Devbox chega como mudança logo depois; ignora nesse intervalo.
  COwnWriteMs = 400;
  // DIB maior que isto (uma tela 8K tem ~130 MB) não vai para o histórico.
  CMaxDibBytes = 64 * 1024 * 1024;

function AddClipboardFormatListener(hwnd: HWND): BOOL; stdcall; external user32;
function RemoveClipboardFormatListener(hwnd: HWND): BOOL; stdcall; external user32;

constructor TClipboardWatcher.Create(const AOnClip: TClipEvent);
begin
  inherited Create;
  FOnClip := AOnClip;
  FWnd := AllocateHWnd(WndProc);
  AddClipboardFormatListener(FWnd);
end;

destructor TClipboardWatcher.Destroy;
begin
  RemoveClipboardFormatListener(FWnd);
  DeallocateHWnd(FWnd);
  inherited;
end;

{ Formatos que gerenciadores de senha (1Password, Bitwarden, KeePass) põem junto
  com a senha para o histórico do Windows ignorar. Valem aqui também. }
function ClipboardMarkedPrivate: Boolean;
var
  F: UINT;
  H: THandle;
  P: PDWORD;
begin
  Result := IsClipboardFormatAvailable(RegisterClipboardFormat('ExcludeClipboardContentFromMonitorProcessing')) or
    IsClipboardFormatAvailable(RegisterClipboardFormat('Clipboard Viewer Ignore'));
  if Result then
    Exit;
  F := RegisterClipboardFormat('CanIncludeInClipboardHistory');
  if not IsClipboardFormatAvailable(F) then
    Exit;
  H := GetClipboardData(F);
  if H = 0 then
    Exit;
  P := GlobalLock(H);
  if P <> nil then
    try
      Result := P^ = 0;
    finally
      GlobalUnlock(H);
    end;
end;

function OpenClipboardRetry(AOwner: HWND): Boolean;
const
  CTries = 5;
  CWaitMs = 20;
var
  I: Integer;
begin
  for I := 1 to CTries do
  begin
    if OpenClipboard(AOwner) then
      Exit(True);
    Sleep(CWaitMs);
  end;
  Result := False;
end;

function GlobalBytes(H: THandle): TBytes;
var
  P: Pointer;
begin
  Result := nil;
  P := GlobalLock(H);
  if P = nil then
    Exit;
  try
    SetLength(Result, GlobalSize(H));
    Move(P^, Result[0], Length(Result));
  finally
    GlobalUnlock(H);
  end;
end;

function DroppedFiles(H: THandle): string;
var
  I, Count: Integer;
  Buf: array[0..MAX_PATH * 4] of Char;
begin
  Result := '';
  Count := DragQueryFile(H, $FFFFFFFF, nil, 0);
  for I := 0 to Count - 1 do
  begin
    DragQueryFile(H, I, Buf, Length(Buf));
    Result := Result + IfThen(Result <> '', #13#10) + Buf;
  end;
end;

{ CF_DIB não tem o cabeçalho de arquivo: monta um BMP em memória e converte. }
function DibToPng(const ADib: TBytes; out AWidth, AHeight: Integer): TBytes;
var
  Info: PBitmapInfoHeader;
  FileHdr: TBitmapFileHeader;
  Colors, Masks: Integer;
  Bmp: TBitmap;
  Png: TPngImage;
  Src, Dst: TBytesStream;
begin
  Result := nil;
  if Length(ADib) < SizeOf(TBitmapInfoHeader) then
    Exit;
  Info := @ADib[0];
  Colors := Info.biClrUsed;
  if (Colors = 0) and (Info.biBitCount <= 8) then
    Colors := 1 shl Info.biBitCount;
  Masks := 0;
  if (Info.biCompression = BI_BITFIELDS) and (Info.biSize = SizeOf(TBitmapInfoHeader)) then
    Masks := 3 * SizeOf(DWORD);
  FillChar(FileHdr, SizeOf(FileHdr), 0);
  FileHdr.bfType := $4D42;  // 'BM'
  FileHdr.bfSize := SizeOf(FileHdr) + Length(ADib);
  FileHdr.bfOffBits := SizeOf(FileHdr) + Info.biSize + Cardinal(Masks) + Cardinal(Colors) * SizeOf(TRGBQuad);
  Src := TBytesStream.Create;
  Bmp := TBitmap.Create;
  Png := TPngImage.Create;
  Dst := TBytesStream.Create;
  try
    Src.WriteBuffer(FileHdr, SizeOf(FileHdr));
    Src.WriteBuffer(ADib[0], Length(ADib));
    Src.Position := 0;
    Bmp.LoadFromStream(Src);
    AWidth := Bmp.Width;
    AHeight := Bmp.Height;
    Png.Assign(Bmp);
    Png.SaveToStream(Dst);
    Result := Copy(Dst.Bytes, 0, Dst.Size);
  finally
    Dst.Free;
    Png.Free;
    Bmp.Free;
    Src.Free;
  end;
end;

function ShortHash(const ABytes: TBytes): string;
var
  H: THashSHA1;
begin
  H := THashSHA1.Create;
  H.Update(ABytes);
  Result := Copy(H.HashAsString, 1, 8);
end;

procedure TClipboardWatcher.WndProc(var Message: TMessage);
const
  WM_CLIPBOARDUPDATE = $031D;
var
  Kind: TClipKind;
  Text: string;
  Data: TBytes;
  W, H: Integer;
  Private_: Boolean;
begin
  if Message.Msg <> WM_CLIPBOARDUPDATE then
  begin
    Message.Result := DefWindowProc(FWnd, Message.Msg, Message.WParam, Message.LParam);
    Exit;
  end;
  if GetTickCount64 < FIgnoreUntil then
    Exit;
  // Ordem: arquivos, texto, imagem. Excel e navegadores mandam texto e imagem
  // juntos; nesse caso o texto é o que a pessoa quer.
  if IsClipboardFormatAvailable(CF_HDROP) then
    Kind := ckFiles
  else if IsClipboardFormatAvailable(CF_UNICODETEXT) then
    Kind := ckText
  else if IsClipboardFormatAvailable(CF_DIB) then
    Kind := ckImage
  else
    Exit;
  if not OpenClipboardRetry(FWnd) then
    Exit;
  Data := nil;
  try
    Private_ := ClipboardMarkedPrivate;
    case Kind of
      ckFiles: Text := DroppedFiles(GetClipboardData(CF_HDROP));
      ckText: Text := string(PChar(GlobalBytes(GetClipboardData(CF_UNICODETEXT))));
      ckImage: Data := GlobalBytes(GetClipboardData(CF_DIB));
    end;
  finally
    CloseClipboard;
  end;
  if Private_ then
    Exit;
  // Exceção solta numa rotina de janela derruba o app: vai para o tratador do VCL.
  try
    if Kind = ckImage then
    begin
      if (Data = nil) or (Length(Data) > CMaxDibBytes) then
        Exit;
      Data := DibToPng(Data, W, H);
      if Data = nil then
        Exit;
      // O hash entra no texto: duas imagens do mesmo tamanho não viram uma só.
      Text := Format('Imagem %d×%d · %s', [W, H, ShortHash(Data)]);
    end
    else if Trim(Text) = '' then
      Exit;
    FOnClip(Kind, Text, Data);
  except
    if Assigned(ApplicationHandleException) then
      ApplicationHandleException(Self)
    else
      raise;
  end;
end;

procedure TClipboardWatcher.Wrote;
begin
  FIgnoreUntil := GetTickCount64 + COwnWriteMs;
end;

procedure TClipboardWatcher.SetText(const AText: string);
begin
  Wrote;
  Clipboard.AsText := AText;
end;

procedure TClipboardWatcher.SetImage(const APng: TBytes);
var
  Png: TPngImage;
  Bmp: TBitmap;
  S: TBytesStream;
begin
  S := TBytesStream.Create(APng);
  Png := TPngImage.Create;
  Bmp := TBitmap.Create;
  try
    Png.LoadFromStream(S);
    Bmp.Assign(Png);
    Wrote;
    Clipboard.Assign(Bmp);
  finally
    Bmp.Free;
    Png.Free;
    S.Free;
  end;
end;

{ CF_HDROP: DROPFILES seguido dos caminhos, cada um com #0, e um #0 no fim. }
procedure TClipboardWatcher.SetFiles(const APaths: TArray<string>);
var
  List: string;
  Path: string;
  Size: NativeUInt;
  H: HGLOBAL;
  Drop: PDropFiles;
begin
  List := '';
  for Path in APaths do
    List := List + Path + #0;
  List := List + #0;
  Size := SizeOf(TDropFiles) + NativeUInt(Length(List)) * SizeOf(Char);
  H := GlobalAlloc(GMEM_MOVEABLE or GMEM_ZEROINIT, Size);
  if H = 0 then
    Exit;
  Drop := GlobalLock(H);
  Drop.pFiles := SizeOf(TDropFiles);
  Drop.fWide := True;
  Move(PChar(List)^, PByte(Drop)[SizeOf(TDropFiles)], Length(List) * SizeOf(Char));
  GlobalUnlock(H);
  if not OpenClipboardRetry(FWnd) then
  begin
    GlobalFree(H);
    Exit;
  end;
  try
    Wrote;
    EmptyClipboard;
    SetClipboardData(CF_HDROP, H);
  finally
    CloseClipboard;
  end;
end;

function OcrImage(const APngPath: string; out AText: string): Boolean;
var
  Script: string;
begin
  Script := ExtractFilePath(ParamStr(0)) + 'ocr.ps1';
  if not FileExists(Script) then
  begin
    AText := 'ocr.ps1 não está ao lado do Devbox.exe';
    Exit(False);
  end;
  // Windows PowerShell 5.1: o pwsh 7 não carrega os tipos WinRT do OCR.
  Result := RunCapture(Format('powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%s" -Path "%s"',
    [Script, APngPath]), AText, 30000) = 0;
  AText := Trim(AText);
end;

const
  // Marca nas teclas que o Devbox manda: o gancho do ajudante pula só essas.
  CDevboxKeyMark = $DE7B0C;

procedure SendKeyInputs(const AKeys: array of Word; const AUp: array of Boolean);
var
  Inputs: TArray<TInput>;
  I: Integer;
begin
  SetLength(Inputs, Length(AKeys));
  for I := 0 to High(AKeys) do
  begin
    FillChar(Inputs[I], SizeOf(TInput), 0);
    Inputs[I].Itype := INPUT_KEYBOARD;
    Inputs[I].ki.wVk := AKeys[I];
    Inputs[I].ki.dwExtraInfo := CDevboxKeyMark;
    if AUp[I] then
      Inputs[I].ki.dwFlags := KEYEVENTF_KEYUP;
  end;
  if Inputs <> nil then
    SendInput(Length(Inputs), Inputs[0], SizeOf(TInput));
end;

procedure SendCtrlV;
begin
  SendKeyInputs([VK_CONTROL, Ord('V'), Ord('V'), VK_CONTROL], [False, False, True, True]);
end;

procedure ForceForeground(AWnd: HWND);
begin
  SendKeyInputs([VK_MENU, VK_MENU], [False, True]);
  SetForegroundWindow(AWnd);
end;

{ Processos }

function DecodeOutput(const ABytes: TBytes): string;
var
  Oem: TEncoding;
begin
  // wsl.exe escreve UTF-16; docker e podman, UTF-8; cmd e programas antigos, a
  // página OEM do console (CP850 no Brasil). UTF-8 inválido cai na OEM.
  if (Length(ABytes) >= 2) and (ABytes[1] = 0) then
    Exit(TEncoding.Unicode.GetString(ABytes));
  try
    Result := TEncoding.UTF8.GetString(ABytes);
  except
    on EEncodingError do
    begin
      Oem := TEncoding.GetEncoding(GetOEMCP);
      try
        Result := Oem.GetString(ABytes);
      finally
        Oem.Free;
      end;
    end;
  end;
end;

function RunCapture(const ACmdLine: string; out AOutput: string; ATimeoutMs: Cardinal;
  const AWorkDir: string): Integer;
const
  CChunk = 4096;
var
  SA: TSecurityAttributes;
  ReadPipe, WritePipe, NulIn: THandle;
  SI: TStartupInfo;
  PI: TProcessInformation;
  Cmd: string;
  Buf: array[0..CChunk - 1] of Byte;
  Got, Avail, Code: DWORD;
  Data: TBytes;
  Start: UInt64;
  Done: Boolean;
  Dir: PChar;
begin
  AOutput := '';
  SA.nLength := SizeOf(SA);
  SA.bInheritHandle := True;
  SA.lpSecurityDescriptor := nil;
  if not CreatePipe(ReadPipe, WritePipe, @SA, 0) then
    Exit(-1);
  try
    SetHandleInformation(ReadPipe, HANDLE_FLAG_INHERIT, 0);
    FillChar(SI, SizeOf(SI), 0);
    SI.cb := SizeOf(SI);
    SI.dwFlags := STARTF_USESTDHANDLES or STARTF_USESHOWWINDOW;
    SI.wShowWindow := SW_HIDE;
    SI.hStdOutput := WritePipe;
    SI.hStdError := WritePipe;
    // App de janela não tem entrada padrão: o filho recebe o NUL.
    NulIn := CreateFile('NUL', GENERIC_READ, FILE_SHARE_READ or FILE_SHARE_WRITE, @SA,
      OPEN_EXISTING, 0, 0);
    SI.hStdInput := NulIn;
    Cmd := ACmdLine;
    UniqueString(Cmd);
    try
      if AWorkDir = '' then
        Dir := nil
      else
        Dir := PChar(AWorkDir);
      if not CreateProcess(nil, PChar(Cmd), nil, nil, True, CREATE_NO_WINDOW, nil, Dir, SI, PI) then
        Exit(-1);
    finally
      if NulIn <> INVALID_HANDLE_VALUE then
        CloseHandle(NulIn);
    end;
    CloseHandle(WritePipe);
    WritePipe := 0;
    try
      Data := nil;
      Start := GetTickCount64;
      Result := -2;
      repeat
        Done := WaitForSingleObject(PI.hProcess, 50) = WAIT_OBJECT_0;
        while PeekNamedPipe(ReadPipe, nil, 0, nil, @Avail, nil) and (Avail > 0) and
          ReadFile(ReadPipe, Buf, CChunk, Got, nil) and (Got > 0) do
          Data := Data + BytesOf(@Buf[0], Got);
        if Done then
        begin
          GetExitCodeProcess(PI.hProcess, Code);
          Result := Integer(Code);
          Break;
        end;
      until GetTickCount64 - Start > ATimeoutMs;
      if Result = -2 then
        TerminateProcess(PI.hProcess, 1);
      AOutput := DecodeOutput(Data);
    finally
      CloseHandle(PI.hThread);
      CloseHandle(PI.hProcess);
    end;
  finally
    CloseHandle(ReadPipe);
    if WritePipe <> 0 then
      CloseHandle(WritePipe);
  end;
end;

{ Portas }

const
  TCP_TABLE_OWNER_PID_LISTENER = 3;
  AF_INET = 2;
  AF_INET6 = 23;

type
  TTcpRow4 = record
    State, LocalAddr, LocalPort, RemoteAddr, RemotePort, OwningPid: DWORD;
  end;
  TTcpRow6 = record
    LocalAddr: array[0..15] of Byte;
    LocalScopeId, LocalPort: DWORD;
    RemoteAddr: array[0..15] of Byte;
    RemoteScopeId, RemotePort, State, OwningPid: DWORD;
  end;

function GetExtendedTcpTable(pTcpTable: Pointer; var pdwSize: DWORD; bOrder: BOOL;
  ulAf: ULONG; TableClass: Integer; Reserved: ULONG): DWORD; stdcall; external 'iphlpapi.dll';

function TcpTable(AFamily: ULONG): TBytes;
var
  Size: DWORD;
begin
  Size := 0;
  GetExtendedTcpTable(nil, Size, True, AFamily, TCP_TABLE_OWNER_PID_LISTENER, 0);
  SetLength(Result, Size);
  if (Size = 0) or (GetExtendedTcpTable(@Result[0], Size, True, AFamily,
    TCP_TABLE_OWNER_PID_LISTENER, 0) <> NO_ERROR) then
    Result := nil;
end;

function ProcessNames: TDictionary<Cardinal, string>;
var
  Snap: THandle;
  E: TProcessEntry32;
begin
  Result := TDictionary<Cardinal, string>.Create;
  Snap := CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  if Snap = INVALID_HANDLE_VALUE then
    Exit;
  try
    E.dwSize := SizeOf(E);
    if Process32First(Snap, E) then
      repeat
        Result.AddOrSetValue(E.th32ProcessID, E.szExeFile);
      until not Process32Next(Snap, E);
  finally
    CloseHandle(Snap);
  end;
end;

function NetPort(AValue: DWORD): Integer;
begin
  Result := Swap(Word(AValue));
end;

function ListListenPorts: TListenPorts;
var
  Names: TDictionary<Cardinal, string>;
  Seen: TDictionary<Integer, Boolean>;
  T: TBytes;
  I, Count: Integer;
  R4: ^TTcpRow4;
  R6: ^TTcpRow6;
  P: TListenPort;

  procedure Add(APort: Integer; const AAddr: string; APid: Cardinal);
  begin
    if Seen.ContainsKey(APort) then
      Exit;
    Seen.Add(APort, True);
    P.Port := APort;
    P.Address := AAddr;
    P.Pid := APid;
    if not Names.TryGetValue(APid, P.Process) then
      P.Process := '';
    P.Container := '';
    Result := Result + [P];
  end;

begin
  Result := nil;
  Names := ProcessNames;
  Seen := TDictionary<Integer, Boolean>.Create;
  try
    T := TcpTable(AF_INET);
    if T <> nil then
    begin
      Count := PInteger(@T[0])^;
      R4 := @T[SizeOf(DWORD)];
      for I := 0 to Count - 1 do
      begin
        Add(NetPort(R4.LocalPort), Format('%d.%d.%d.%d', [R4.LocalAddr and $FF,
          (R4.LocalAddr shr 8) and $FF, (R4.LocalAddr shr 16) and $FF, R4.LocalAddr shr 24]), R4.OwningPid);
        Inc(R4);
      end;
    end;
    T := TcpTable(AF_INET6);
    if T <> nil then
    begin
      Count := PInteger(@T[0])^;
      R6 := @T[SizeOf(DWORD)];
      for I := 0 to Count - 1 do
      begin
        Add(NetPort(R6.LocalPort), '[::]', R6.OwningPid);
        Inc(R6);
      end;
    end;
  finally
    Seen.Free;
    Names.Free;
  end;
end;

function KillProcess(APid: Cardinal): Boolean;
var
  H: THandle;
begin
  H := OpenProcess(PROCESS_TERMINATE, False, APid);
  Result := (H <> 0) and TerminateProcess(H, 1);
  if H <> 0 then
    CloseHandle(H);
end;

procedure PasteInto(AWnd: HWND);
begin
  if (AWnd = 0) or not IsWindow(AWnd) then
    Exit;
  SetForegroundWindow(AWnd);
  SendCtrlV;
end;

procedure OpenUrl(const AUrl: string);
begin
  ShellExecute(0, 'open', PChar(AUrl), nil, nil, SW_SHOWNORMAL);
end;

procedure Launch(const AExe, AParams: string);
begin
  ShellExecute(0, 'open', PChar(AExe), PChar(AParams), nil, SW_SHOWNORMAL);
end;

const
  RunKey = 'Software\Microsoft\Windows\CurrentVersion\Run';
  RunValue = 'Devbox';

function AutostartEnabled: Boolean;
var
  R: TRegistry;
begin
  R := TRegistry.Create(KEY_READ);
  try
    R.RootKey := HKEY_CURRENT_USER;
    Result := R.OpenKeyReadOnly(RunKey) and R.ValueExists(RunValue);
  finally
    R.Free;
  end;
end;

procedure SetAutostart(AOn: Boolean);
var
  R: TRegistry;
begin
  R := TRegistry.Create;
  try
    R.RootKey := HKEY_CURRENT_USER;
    if R.OpenKey(RunKey, True) then
      if AOn then
        R.WriteString(RunValue, '"' + ParamStr(0) + '"')
      else if R.ValueExists(RunValue) then
        R.DeleteValue(RunValue);
  finally
    R.Free;
  end;
end;

end.
