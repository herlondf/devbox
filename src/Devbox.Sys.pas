unit Devbox.Sys;

{ Tudo que fala com o Windows: processos de linha de comando, clipboard,
  portas em escuta, autostart. }

interface

uses
  Winapi.Windows,
  Winapi.Messages,
  System.SysUtils,
  Devbox.Model;

type
  { Avisa cada texto novo copiado em qualquer programa. Pula o que o
    gerenciador de senhas marca como sigiloso e o que o próprio Devbox escreveu. }
  TClipboardWatcher = class
  private
    FWnd: HWND;
    FOnText: TProc<string>;
    FSkipText: string;
    procedure WndProc(var Message: TMessage);
  public
    constructor Create(const AOnText: TProc<string>);
    destructor Destroy; override;
    { Põe o texto no clipboard sem ele voltar como "novo". }
    procedure SetText(const AText: string);
  end;

{ Roda e devolve a saída (stdout + stderr). -1 = não achou o programa;
  -2 = passou do tempo. Bloqueia: chamar fora da thread de UI. }
function RunCapture(const ACmdLine: string; out AOutput: string; ATimeoutMs: Cardinal = 15000): Integer;

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
  Vcl.Clipbrd;

{ TClipboardWatcher }

function AddClipboardFormatListener(hwnd: HWND): BOOL; stdcall; external user32;
function RemoveClipboardFormatListener(hwnd: HWND): BOOL; stdcall; external user32;

constructor TClipboardWatcher.Create(const AOnText: TProc<string>);
begin
  inherited Create;
  FOnText := AOnText;
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

{ Lê o texto do clipboard pela API, sem exceção. Outro programa pode estar com
  ele aberto logo depois de copiar: tenta algumas vezes. }
function ReadClipboardText(AOwner: HWND; out AText: string; out APrivate: Boolean): Boolean;
const
  CTries = 5;
  CWaitMs = 20;
var
  I: Integer;
  H: THandle;
  P: PChar;
begin
  Result := False;
  AText := '';
  APrivate := False;
  for I := 1 to CTries do
  begin
    if OpenClipboard(AOwner) then
      Break;
    if I = CTries then
      Exit;
    Sleep(CWaitMs);
  end;
  try
    APrivate := ClipboardMarkedPrivate;
    H := GetClipboardData(CF_UNICODETEXT);
    if H = 0 then
      Exit;
    P := GlobalLock(H);
    if P = nil then
      Exit;
    try
      AText := P;
    finally
      GlobalUnlock(H);
    end;
    Result := True;
  finally
    CloseClipboard;
  end;
end;

procedure TClipboardWatcher.WndProc(var Message: TMessage);
const
  WM_CLIPBOARDUPDATE = $031D;
var
  Text: string;
  Private_: Boolean;
begin
  if Message.Msg <> WM_CLIPBOARDUPDATE then
  begin
    Message.Result := DefWindowProc(FWnd, Message.Msg, Message.WParam, Message.LParam);
    Exit;
  end;
  if not IsClipboardFormatAvailable(CF_UNICODETEXT) or
    not ReadClipboardText(FWnd, Text, Private_) then
    Exit;
  if Private_ or (Text = FSkipText) or (Trim(Text) = '') then
    Exit;
  // Exceção solta numa rotina de janela derruba o app: vai para o tratador do VCL.
  try
    FOnText(Text);
  except
    if Assigned(ApplicationHandleException) then
      ApplicationHandleException(Self)
    else
      raise;
  end;
end;

procedure TClipboardWatcher.SetText(const AText: string);
begin
  FSkipText := AText;
  Clipboard.AsText := AText;
end;

{ Processos }

function DecodeOutput(const ABytes: TBytes): string;
begin
  // wsl.exe escreve UTF-16; o resto, UTF-8.
  if (Length(ABytes) >= 2) and (ABytes[1] = 0) then
    Result := TEncoding.Unicode.GetString(ABytes)
  else
    Result := TEncoding.UTF8.GetString(ABytes);
end;

function RunCapture(const ACmdLine: string; out AOutput: string; ATimeoutMs: Cardinal): Integer;
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
      if not CreateProcess(nil, PChar(Cmd), nil, nil, True, CREATE_NO_WINDOW, nil, nil, SI, PI) then
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
var
  Inputs: array[0..3] of TInput;

  procedure Key(AIndex: Integer; AVk: Word; AUp: Boolean);
  begin
    FillChar(Inputs[AIndex], SizeOf(TInput), 0);
    Inputs[AIndex].Itype := INPUT_KEYBOARD;
    Inputs[AIndex].ki.wVk := AVk;
    if AUp then
      Inputs[AIndex].ki.dwFlags := KEYEVENTF_KEYUP;
  end;

begin
  if (AWnd = 0) or not IsWindow(AWnd) then
    Exit;
  SetForegroundWindow(AWnd);
  Key(0, VK_CONTROL, False);
  Key(1, Ord('V'), False);
  Key(2, Ord('V'), True);
  Key(3, VK_CONTROL, True);
  SendInput(Length(Inputs), Inputs[0], SizeOf(TInput));
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
