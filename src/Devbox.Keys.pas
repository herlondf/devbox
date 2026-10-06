unit Devbox.Keys;

{ Só no DevboxHelper.exe: o gancho de teclado do expansor e a escrita no
  clipboard que o histórico ignora. Ficam fora do Devbox.exe de propósito:
  gancho de teclado + captura de tela + clipboard no mesmo exe fazia o
  antivírus tratar o app como keylogger e apagar o exe. }

interface

uses
  Winapi.Windows,
  Winapi.Messages,
  System.SysUtils,
  System.Classes,
  Devbox.Model;

type
  TExpandEvent = reference to procedure(const AAbbrev: string);

  { Expansor de texto: olha as teclas digitadas em qualquer programa (gancho
    WH_KEYBOARD_LL) e avisa quando o fim do que foi digitado é um atalho. A
    tecla segue para o programa; quem trata o aviso apaga o atalho e cola. }
  TKeyExpander = class
  private
    FHook: HHOOK;
    FWnd: HWND;
    FBuffer: string;
    FAbbrevs: TArray<string>;
    FPending: string;
    FOnExpand: TExpandEvent;
    procedure WndProc(var Message: TMessage);
    procedure KeyDown(AVk: Cardinal);
    function GetEnabled: Boolean;
    procedure SetEnabled(AValue: Boolean);
  public
    constructor Create(const AOnExpand: TExpandEvent);
    destructor Destroy; override;
    procedure SetAbbrevs(const AAbbrevs: TArray<string>);
    property Enabled: Boolean read GetEnabled write SetEnabled;
  end;

procedure SendBackspaces(ACount: Integer);

{ Põe texto no clipboard com a marca "não guardar no histórico" (o Devbox e o
  histórico do Windows respeitam). Serve para a cola do expansor. }
procedure SetPrivateClipboardText(const AText: string);

{ Texto do clipboard agora ('' se não for texto). }
function ClipboardTextNow: string;

implementation

uses
  Vcl.Clipbrd,
  Devbox.Sys;

{ TKeyExpander }

const
  WM_EXPAND = WM_APP + 1;
  // Mesma marca do SendKeyInputs (Devbox.Sys): o gancho pula só as teclas do
  // próprio Devbox. Teclado virtual e automação também injetam e devem expandir.
  CDevboxKeyMark = $DE7B0C;

type
  TKbdLLHookStruct = record
    vkCode, scanCode, flags, time: DWORD;
    dwExtraInfo: ULONG_PTR;
  end;
  PKbdLLHookStruct = ^TKbdLLHookStruct;

var
  GExpander: TKeyExpander;

function LowLevelKeyboardProc(nCode: Integer; wParam: WPARAM; lParam: LPARAM): LRESULT; stdcall;
var
  Kb: PKBDLLHookStruct;
begin
  if (nCode = HC_ACTION) and (GExpander <> nil) and
    ((wParam = WM_KEYDOWN) or (wParam = WM_SYSKEYDOWN)) then
  begin
    Kb := PKBDLLHookStruct(lParam);
    // Teclas que o próprio Devbox manda (backspace, Ctrl+V) não contam.
    if Kb.dwExtraInfo <> CDevboxKeyMark then
      GExpander.KeyDown(Kb.vkCode);
  end;
  Result := CallNextHookEx(0, nCode, wParam, lParam);
end;

constructor TKeyExpander.Create(const AOnExpand: TExpandEvent);
begin
  inherited Create;
  FOnExpand := AOnExpand;
  FWnd := AllocateHWnd(WndProc);
  GExpander := Self;
end;

destructor TKeyExpander.Destroy;
begin
  Enabled := False;
  GExpander := nil;
  DeallocateHWnd(FWnd);
  inherited;
end;

function TKeyExpander.GetEnabled: Boolean;
begin
  Result := FHook <> 0;
end;

procedure TKeyExpander.SetEnabled(AValue: Boolean);
begin
  if AValue = Enabled then
    Exit;
  if AValue then
    FHook := SetWindowsHookEx(WH_KEYBOARD_LL, @LowLevelKeyboardProc, HInstance, 0)
  else
  begin
    UnhookWindowsHookEx(FHook);
    FHook := 0;
  end;
  FBuffer := '';
end;

procedure TKeyExpander.SetAbbrevs(const AAbbrevs: TArray<string>);
begin
  FAbbrevs := AAbbrevs;
end;

{ Roda dentro do gancho: tem de ser rápido. Só guarda o que foi digitado e,
  quando bate com um atalho, deixa o resto para a mensagem. }
procedure TKeyExpander.KeyDown(AVk: Cardinal);
const
  MAPVK_VK_TO_CHAR = 2;
  CDeadKey = $80000000;
var
  Code: Cardinal;
  C: Char;
  Shift: Boolean;
begin
  if (AVk = VK_SHIFT) or (AVk = VK_LSHIFT) or (AVk = VK_RSHIFT) or (AVk = VK_CAPITAL) then
    Exit;
  if (GetAsyncKeyState(VK_CONTROL) < 0) or (GetAsyncKeyState(VK_MENU) < 0) or
    (GetAsyncKeyState(VK_LWIN) < 0) or (GetAsyncKeyState(VK_RWIN) < 0) then
    C := #0
  else if AVk = VK_BACK then
    C := #8
  else
  begin
    // MapVirtualKey não mexe no estado das teclas mortas (ToUnicode mexeria e
    // estragaria os acentos de quem digita). Devolve o caractere sem Shift.
    Code := MapVirtualKey(AVk, MAPVK_VK_TO_CHAR);
    Shift := GetAsyncKeyState(VK_SHIFT) < 0;
    if (Code = 0) or (Code and CDeadKey <> 0) then
      C := #0
    else
    begin
      C := Char(Code and $FFFF);
      if CharInSet(C, ['A'..'Z']) and not Shift then
        C := Char(Ord(C) + 32)
      else if Shift and not CharInSet(C, ['A'..'Z']) then
        C := #0;  // Shift+; não é ";": atalho não usa símbolo com Shift
    end;
  end;
  FPending := FeedAbbrevBuffer(FBuffer, C, FAbbrevs);
  if FPending <> '' then
    PostMessage(FWnd, WM_EXPAND, 0, 0);
end;

procedure TKeyExpander.WndProc(var Message: TMessage);
begin
  if Message.Msg <> WM_EXPAND then
  begin
    Message.Result := DefWindowProc(FWnd, Message.Msg, Message.WParam, Message.LParam);
    Exit;
  end;
  try
    FOnExpand(FPending);
  except
    if Assigned(ApplicationHandleException) then
      ApplicationHandleException(Self)
    else
      raise;
  end;
end;

procedure SendBackspaces(ACount: Integer);
var
  I: Integer;
begin
  for I := 1 to ACount do
    SendKeyInputs([VK_BACK, VK_BACK], [False, True]);
end;

procedure SetPrivateClipboardText(const AText: string);
var
  H: HGLOBAL;
  P: PChar;
  Size: NativeUInt;
  Mark: HGLOBAL;
  MarkP: PDWORD;
  I: Integer;
begin
  Size := (Length(AText) + 1) * SizeOf(Char);
  for I := 1 to 5 do
  begin
    if OpenClipboard(0) then
      Break;
    Sleep(20);
  end;
  try
    EmptyClipboard;
    H := GlobalAlloc(GMEM_MOVEABLE, Size);
    P := GlobalLock(H);
    Move(PChar(AText)^, P^, Size);
    GlobalUnlock(H);
    SetClipboardData(CF_UNICODETEXT, H);
    // Formato que gerenciadores de senha usam: o watcher do Devbox pula.
    Mark := GlobalAlloc(GMEM_MOVEABLE, SizeOf(DWORD));
    MarkP := GlobalLock(Mark);
    MarkP^ := 0;
    GlobalUnlock(Mark);
    SetClipboardData(RegisterClipboardFormat('ExcludeClipboardContentFromMonitorProcessing'), Mark);
  finally
    CloseClipboard;
  end;
end;

function ClipboardTextNow: string;
begin
  Result := '';
  try
    if Clipboard.HasFormat(CF_UNICODETEXT) then
      Result := Clipboard.AsText;
  except
    on EClipboardException do
      Result := '';
  end;
end;

end.
