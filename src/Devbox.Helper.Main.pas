unit Devbox.Helper.Main;

{ Janela escondida do DevboxHelper.exe: gancho do expansor de texto, atalho
  Win+Alt+S da captura e as mensagens do Devbox.exe. Fecha sozinho quando o
  Devbox.exe que o abriu sai. }

interface

uses
  Winapi.Windows,
  Winapi.Messages,
  System.Classes,
  System.SysUtils,
  Vcl.Forms,
  Vcl.ExtCtrls,
  Devbox.Keys;

type
  THelperForm = class(TForm)
  private
    FExpander: TKeyExpander;
    FParentPid: Cardinal;
    FParentTimer: TTimer;
    FRestoreTimer: TTimer;
    FRestoreText: string;
    procedure Reload;
    procedure Expand(const AAbbrev: string);
    procedure ParentTick(Sender: TObject);
    procedure RestoreTick(Sender: TObject);
    procedure SetCaptureHotkey(AOn: Boolean);
  protected
    procedure WndProc(var Message: TMessage); override;
    procedure DestroyWnd; override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
  end;

var
  HelperForm: THelperForm;

implementation

uses
  System.StrUtils,
  UI.Theme,
  Devbox.Model,
  Devbox.Store,
  Devbox.Sys,
  Devbox.Helper,
  Devbox.UI.DialogBase,
  Devbox.UI.Capture;

const
  CaptureHotkeyId = 1;
  PROCESS_QUERY_LIMITED_INFORMATION = $1000;
  CRestoreMs = 800;
  CParentCheckMs = 2000;

constructor THelperForm.Create(AOwner: TComponent);
var
  I: Integer;
begin
  inherited CreateNew(AOwner);
  Caption := HelperCaption;
  BorderStyle := bsNone;
  Width := 0;
  Height := 0;
  FParentPid := 0;
  for I := 1 to ParamCount - 1 do
    if SameText(ParamStr(I), '-parent') then
      FParentPid := StrToIntDef(ParamStr(I + 1), 0);
  FExpander := TKeyExpander.Create(
    procedure(const AAbbrev: string)
    begin
      Expand(AAbbrev);
    end);
  FRestoreTimer := TTimer.Create(Self);
  FRestoreTimer.Enabled := False;
  FRestoreTimer.Interval := CRestoreMs;
  FRestoreTimer.OnTimer := RestoreTick;
  FParentTimer := TTimer.Create(Self);
  FParentTimer.Interval := CParentCheckMs;
  FParentTimer.OnTimer := ParentTick;
  FParentTimer.Enabled := FParentPid <> 0;
  HandleNeeded;
  Reload;
end;

destructor THelperForm.Destroy;
begin
  FExpander.Free;
  inherited;
end;

procedure THelperForm.DestroyWnd;
begin
  UnregisterHotKey(Handle, CaptureHotkeyId);
  inherited;
end;

{ Atalhos, liga/desliga e tema vêm do mesmo banco do Devbox.exe. }
procedure THelperForm.Reload;
var
  Abbrevs: TArray<string>;
  C: TClip;
  B: string;
begin
  case IndexText(Store.GetSetting('theme'), ['light', 'dark']) of
    0: UITheme.Mode := tmLight;
    1: UITheme.Mode := tmDark;
  end;
  Abbrevs := nil;
  for C in Store.ListClips do
    if C.Pinned and (C.Abbrev <> '') then
      Abbrevs := Abbrevs + [C.Abbrev];
  for B in BuiltinAbbrevs do
    Abbrevs := Abbrevs + [B];
  FExpander.SetAbbrevs(Abbrevs);
  FExpander.Enabled := Store.GetSetting('expander_on', '1') = '1';
  SetCaptureHotkey(Store.GetSetting('hotkey_on', '1') = '1');
end;

procedure THelperForm.SetCaptureHotkey(AOn: Boolean);
const
  MOD_NOREPEAT = $4000;
begin
  UnregisterHotKey(Handle, CaptureHotkeyId);
  if AOn then
    RegisterHotKey(Handle, CaptureHotkeyId, MOD_WIN or MOD_ALT or MOD_NOREPEAT, Ord('S'));
end;

procedure THelperForm.WndProc(var Message: TMessage);
begin
  if Message.Msg = WM_HELPER_RELOAD then
    Reload
  else if (Message.Msg = WM_HELPER_CAPTURE) or
    ((Message.Msg = WM_HOTKEY) and (Message.WParam = CaptureHotkeyId)) then
    StartCapture
  else if Message.Msg = WM_HELPER_QUIT then
    Application.Terminate
  else
    inherited;
end;

{ Devbox.exe fechou (ou caiu): o ajudante não fica sozinho na memória. }
procedure THelperForm.ParentTick(Sender: TObject);
var
  H: THandle;
  Code: DWORD;
begin
  H := OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, False, FParentPid);
  if H = 0 then
  begin
    Application.Terminate;
    Exit;
  end;
  try
    if GetExitCodeProcess(H, Code) and (Code <> STILL_ACTIVE) then
      Application.Terminate;
  finally
    CloseHandle(H);
  end;
end;

{ O atalho acabou de ser digitado no programa da frente: apaga, pergunta os
  campos se houver e cola pelo clipboard (marcado para não entrar no
  histórico). O clipboard de antes volta depois. }
procedure THelperForm.Expand(const AAbbrev: string);
var
  Text, Title: string;
  C: TClip;
  Fields, Values: TArray<string>;
  Target: HWND;
begin
  Text := BuiltinExpansion(AAbbrev, Now);
  Title := AAbbrev;
  if Text = '' then
    for C in Store.ListClips do
      if C.Pinned and (C.Abbrev = AAbbrev) then
      begin
        Text := C.Text;
        Title := C.Title;
        Break;
      end;
  if Text = '' then
    Exit;
  Target := GetForegroundWindow;
  SendBackspaces(Length(AAbbrev));
  Fields := TemplateFields(Text);
  if Fields <> nil then
  begin
    if not AskFields(Title, Fields, Values) then
      Exit;
    Text := FillTemplate(Text, Fields, Values);
    SetForegroundWindow(Target);
  end;
  if not FRestoreTimer.Enabled then
    FRestoreText := ClipboardTextNow;
  SetPrivateClipboardText(Text);
  SendCtrlV;
  FRestoreTimer.Enabled := False;
  FRestoreTimer.Enabled := True;
end;

procedure THelperForm.RestoreTick(Sender: TObject);
begin
  FRestoreTimer.Enabled := False;
  if FRestoreText <> '' then
    SetPrivateClipboardText(FRestoreText);
end;

end.
