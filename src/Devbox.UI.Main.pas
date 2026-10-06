unit Devbox.UI.Main;

{ Janela única: menu lateral com as telas (TDevPage), cabeçalho com título e
  tema, ícone da bandeja e atalho global Win+Alt+B. }

interface

uses
  Winapi.Windows,
  Winapi.Messages,
  System.Classes,
  System.SysUtils,
  System.Types,
  System.Generics.Collections,
  Vcl.Controls,
  Vcl.Forms,
  Vcl.Menus,
  Vcl.ExtCtrls,
  UI.Theme,
  UI.Swap,
  UI.Labels,
  UI.Sidebar,
  Devbox.UI.Kit,
  Devbox.Helper,
  Devbox.UI.Clipboard,
  Devbox.UI.Expander,
  Devbox.UI.Services,
  Devbox.UI.Cleanup,
  Devbox.UI.Network,
  Devbox.UI.Jobs,
  Devbox.UI.Watches,
  Devbox.UI.Envs,
  Devbox.UI.Focus,
  Devbox.UI.Tools,
  Devbox.UI.AICommand,
  Devbox.UI.System,
  Devbox.UI.Settings;

type
  TMainForm = class(TForm)
  private
    FTray: TTrayIcon;
    FTrayMenu: TPopupMenu;
    FSidebar: TUISidebar;
    FTitle, FSubtitle: TUILabel;
    FThemeSwap: TUISwap;
    FContent: TPanel;
    FPages: TDictionary<string, TDevPage>;
    FPageOrder: TList<string>;
    FActive: TDevPage;
    FClipboard: TClipboardPage;
    FExpanderPage: TExpanderPage;
    FWatchesPage: TWatchesPage;
    FFocusPage: TFocusPage;
    FFocusItem: TMenuItem;
    FApplyingSize: Boolean;
    FExitRequested: Boolean;
    procedure AddPage(const AID, AGroup, AIconPath: string; APage: TDevPage);
    procedure ShowPage(const AID: string);
    procedure SidebarChange(Sender: TObject);
    procedure BuildTray;
    procedure BuildShell;
    procedure ApplyThemeColors;
    procedure ApplyCompactSize;
    procedure ThemeChanged(Sender: TObject; AMode: TUIThemeMode);
    procedure ThemeSwapToggle(Sender: TObject);
    procedure SetHotkey(AOn: Boolean);
    procedure HotkeySettingChanged(Sender: TObject);
    procedure HistoryCleared(Sender: TObject);
    procedure ExpanderChanged(Sender: TObject);
    procedure EditSnippet(AId: Integer);
    procedure ShowNotify(const ATitle, AText: string; AError: Boolean);
    procedure FocusMenuClick(Sender: TObject);
    procedure FocusChanged(Sender: TObject);
    procedure ShowWindow_;
    procedure MenuOpenClick(Sender: TObject);
    procedure MenuExitClick(Sender: TObject);
    procedure FormCloseQuery(Sender: TObject; var CanClose: Boolean);
    procedure FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
  protected
    procedure CreateWnd; override;
    procedure DestroyWnd; override;
    procedure WndProc(var Message: TMessage); override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
  end;

var
  MainForm: TMainForm;

implementation

uses
  System.StrUtils,
  System.Math,
  Winapi.Dwmapi,
  Vcl.Graphics,
  UI.Tokens,
  UI.Painter.Vcl,
  UI.Toast,
  UI.Icons.Heroicons,
  Devbox.UI.Dialogs,
  Devbox.Notify,
  Devbox.Focus,
  Devbox.Model,
  Devbox.Store;

const
  HotkeyId = 1;

var
  WM_DEVBOX_SHOW: Cardinal;

{ Ícone da bandeja: quadrado arredondado roxo com "D". }
function MakeTrayIcon: HICON;
var
  Size: Integer;
  Color, Mask: TBitmap;
  Info: TIconInfo;
begin
  Size := GetSystemMetrics(SM_CXSMICON);
  Color := TBitmap.Create;
  Mask := TBitmap.Create;
  try
    Color.SetSize(Size, Size);
    Color.PixelFormat := pf24bit;
    Mask.Monochrome := True;
    Mask.SetSize(Size, Size);
    Mask.Canvas.Brush.Color := clWhite;
    Mask.Canvas.FillRect(Rect(0, 0, Size, Size));
    Mask.Canvas.Brush.Color := clBlack;
    Mask.Canvas.Pen.Color := clBlack;
    Mask.Canvas.RoundRect(0, 0, Size, Size, Size div 2, Size div 2);
    Color.Canvas.Brush.Color := clBlack;
    Color.Canvas.FillRect(Rect(0, 0, Size, Size));
    Color.Canvas.Brush.Color := RGB(79, 70, 229);
    Color.Canvas.Pen.Color := Color.Canvas.Brush.Color;
    Color.Canvas.RoundRect(0, 0, Size, Size, Size div 2, Size div 2);
    Color.Canvas.Font.Name := 'Segoe UI';
    Color.Canvas.Font.Style := [fsBold];
    Color.Canvas.Font.Quality := fqAntialiased;
    Color.Canvas.Font.Color := clWhite;
    Color.Canvas.Font.Height := -Round(Size * 0.7);
    Color.Canvas.Brush.Style := bsClear;
    Color.Canvas.TextOut((Size - Color.Canvas.TextWidth('D')) div 2,
      (Size - Color.Canvas.TextHeight('D')) div 2, 'D');
    Info.fIcon := True;
    Info.xHotspot := 0;
    Info.yHotspot := 0;
    Info.hbmMask := Mask.Handle;
    Info.hbmColor := Color.Handle;
    Result := CreateIconIndirect(Info);
  finally
    Color.Free;
    Mask.Free;
  end;
end;

{ TMainForm }

constructor TMainForm.Create(AOwner: TComponent);
var
  Settings: TSettingsPage;
  Services: TServicesPage;
begin
  inherited CreateNew(AOwner);
  Caption := 'Devbox ' + AppVersion;
  ClientWidth := ScaleValue(1180);
  // Cabe o menu inteiro sem rolar; tela baixa fica com a área útil.
  ClientHeight := Min(ScaleValue(840), Screen.WorkAreaHeight - ScaleValue(60));
  Constraints.MinWidth := ScaleValue(860);
  Constraints.MinHeight := ScaleValue(520);
  Position := poScreenCenter;
  DoubleBuffered := True;
  KeyPreview := True;
  OnKeyDown := FormKeyDown;
  OnCloseQuery := FormCloseQuery;

  case IndexText(Store.GetSetting('theme'), ['light', 'dark']) of
    0: UITheme.Mode := tmLight;
    1: UITheme.Mode := tmDark;
  end;
  ApplyCompactSize;
  TUIToastManager.Position := tpBottomRight;
  FPages := TDictionary<string, TDevPage>.Create;
  FPageOrder := TList<string>.Create;

  BuildTray;
  BuildShell;
  FClipboard := TClipboardPage.Create(Self);
  AddPage('clipboard', 'Dia a dia', IconClipboard, FClipboard);
  FExpanderPage := TExpanderPage.Create(Self);
  FExpanderPage.OnChanged := ExpanderChanged;
  AddPage('expander', 'Dia a dia', IconKeyboard, FExpanderPage);
  FFocusPage := TFocusPage.Create(Self);
  FFocusPage.OnChanged := FocusChanged;
  AddPage('focus', 'Dia a dia', IconTarget, FFocusPage);
  AddPage('tools', 'Dia a dia', IconWrench, TToolsPage.Create(Self));
  FClipboard.OnEditSnippet := EditSnippet;
  // Expansor e captura moram no DevboxHelper.exe (ver Devbox.Keys).
  StartHelper;
  Services := TServicesPage.Create(Self);
  AddPage('services', 'Ambiente', IconServer, Services);
  AddPage('cleanup', 'Ambiente', IconBroom, TCleanupPage.Create(Self));
  AddPage('network', 'Ambiente', IconGlobe, TNetworkPage.Create(Self));
  AddPage('system', 'Ambiente', IconCpu, TSystemPage.Create(Self));
  AddPage('envs', 'Automação', IconPlay, TEnvsPage.Create(Self));
  AddPage('aicmd', 'Automação', IconSparkles, TAICommandPage.Create(Self));
  AddPage('jobs', 'Automação', IconClock, TJobsPage.Create(Self));
  FWatchesPage := TWatchesPage.Create(Self);
  AddPage('watches', 'Automação', IconBell, FWatchesPage);
  Services.OnWatchRequest := FWatchesPage.AddWatch;
  NotifyHandler :=
    procedure(const ATitle, AText: string; AError: Boolean)
    begin
      ShowNotify(ATitle, AText, AError);
    end;
  Settings := TSettingsPage.Create(Self);
  Settings.OnHotkeyChanged := HotkeySettingChanged;
  Settings.OnHistoryCleared := HistoryCleared;
  AddPage('settings', 'Devbox', IconSettings, Settings);

  ApplyThemeColors;
  UITheme.AddChangeListener(ThemeChanged);
  ShowPage('clipboard');
end;

destructor TMainForm.Destroy;
begin
  NotifyHandler := nil;
  UITheme.RemoveChangeListener(ThemeChanged);
  FPages.Free;
  FPageOrder.Free;
  inherited;
end;

procedure TMainForm.AddPage(const AID, AGroup, AIconPath: string; APage: TDevPage);
var
  Last: TDevPage;
begin
  // Grupo novo só quando muda em relação à tela anterior.
  if (FPageOrder.Count = 0) or not FPages.TryGetValue(FPageOrder.Last, Last) or
    (Last.HelpKeyword <> AGroup) then
    FSidebar.AddGroup(AGroup);
  APage.HelpKeyword := AGroup;
  FSidebar.AddItem(AID, APage.Caption, LineIcon(AIconPath));
  APage.Parent := FContent;
  FPages.Add(AID, APage);
  FPageOrder.Add(AID);
end;

procedure TMainForm.ShowPage(const AID: string);
var
  Page: TDevPage;
begin
  if not FPages.TryGetValue(AID, Page) or (Page = FActive) then
    Exit;
  if FActive <> nil then
  begin
    FActive.PageHidden;
    FActive.Visible := False;
  end;
  FActive := Page;
  FTitle.Caption := Page.Caption;
  FSubtitle.Caption := Page.Hint;
  Page.Visible := True;
  if FSidebar.ActiveItemID <> AID then
    FSidebar.ActiveItemID := AID;
  Page.PageShown;
end;

procedure TMainForm.SidebarChange(Sender: TObject);
begin
  ShowPage(FSidebar.ActiveItemID);
end;

procedure TMainForm.BuildShell;
var
  Right, Header, Texts: TPanel;
begin
  FSidebar := TUISidebar.Create(Self);
  FSidebar.Title := 'Devbox';
  FSidebar.Subtitle := 'versão ' + AppVersion;
  FSidebar.AvatarInitials := 'D';
  FSidebar.Width := FSidebar.ExpandedWidth;
  FSidebar.Align := alLeft;
  FSidebar.TabStop := False;  // sem isto o anel de foco contornava o menu todo
  FSidebar.Parent := Self;
  FSidebar.OnChange := SidebarChange;

  Right := TPanel.Create(Self);
  Right.BevelOuter := bvNone;
  Right.ParentBackground := False;
  Right.Align := alClient;
  Right.Parent := Self;

  Header := TPanel.Create(Self);
  Header.BevelOuter := bvNone;
  Header.ParentBackground := False;
  Header.Height := ScaleValue(72);
  Header.Padding.SetBounds(ScaleValue(20), ScaleValue(12), ScaleValue(16), ScaleValue(4));
  Header.Align := alTop;
  Header.Parent := Right;

  FThemeSwap := TUISwap.Create(Self);
  FThemeSwap.SvgOff := HeroIcon(hiSun);
  FThemeSwap.SvgOn := HeroIcon(hiMoon);
  FThemeSwap.SwapType := stRotate;
  FThemeSwap.Size := 36;
  FThemeSwap.Checked := UITheme.IsDark;
  FThemeSwap.Hint := 'Tema claro/escuro';
  FThemeSwap.ShowHint := True;
  FThemeSwap.TabStop := False;
  FThemeSwap.OnToggle := ThemeSwapToggle;
  FThemeSwap.AlignWithMargins := True;
  FThemeSwap.Margins.SetBounds(0, ScaleValue(8), 0, ScaleValue(12));
  FThemeSwap.Align := alRight;
  FThemeSwap.Parent := Header;

  Texts := TPanel.Create(Self);
  Texts.BevelOuter := bvNone;
  Texts.ParentBackground := False;
  Texts.Align := alClient;
  Texts.Parent := Header;
  FTitle := TUILabel.Create(Self);
  FTitle.Bold := True;
  FTitle.FontSize := 20;
  FTitle.AutoSize := False;
  FTitle.Height := ScaleValue(30);
  FTitle.Align := alTop;
  FTitle.Parent := Texts;
  FSubtitle := TUILabel.Create(Self);
  FSubtitle.Variant := lvMuted;
  FSubtitle.AutoSize := False;
  FSubtitle.Height := ScaleValue(22);
  FSubtitle.Top := 1000;
  FSubtitle.Align := alTop;
  FSubtitle.Parent := Texts;

  FContent := TPanel.Create(Self);
  FContent.BevelOuter := bvNone;
  FContent.ParentBackground := False;
  FContent.Padding.SetBounds(ScaleValue(20), ScaleValue(8), ScaleValue(20), ScaleValue(14));
  FContent.Align := alClient;
  FContent.Parent := Right;
end;

procedure TMainForm.BuildTray;

  procedure AddItem(const ACaption: string; AOnClick: TNotifyEvent; ADefault: Boolean = False);
  var
    M: TMenuItem;
  begin
    M := TMenuItem.Create(FTrayMenu);
    M.Caption := ACaption;
    M.OnClick := AOnClick;
    M.Default := ADefault;
    FTrayMenu.Items.Add(M);
  end;

begin
  FTrayMenu := TPopupMenu.Create(Self);
  AddItem('Abrir', MenuOpenClick, True);
  AddItem('Modo foco', FocusMenuClick);
  FFocusItem := FTrayMenu.Items[FTrayMenu.Items.Count - 1];
  AddItem('-', nil);
  AddItem('Sair', MenuExitClick);
  FTray := TTrayIcon.Create(Self);
  FTray.Icon.Handle := MakeTrayIcon;
  Icon.Handle := MakeTrayIcon;
  FTray.Hint := 'Devbox  ·  Win+Alt+B abre o clipboard';
  FTray.PopupMenu := FTrayMenu;
  FTray.OnDblClick := MenuOpenClick;
  FTray.Visible := True;
end;

procedure TMainForm.ApplyThemeColors;
const
  DWMWA_USE_IMMERSIVE_DARK_MODE = 20;
var
  Dark: BOOL;
begin
  Color := UIThemeVclBackground;
  PaintPanels(Self);
  if HandleAllocated then
  begin
    Dark := UITheme.IsDark;
    DwmSetWindowAttribute(Handle, DWMWA_USE_IMMERSIVE_DARK_MODE, @Dark, SizeOf(Dark));
  end;
end;

{ Campos e botões com 36 px (o preset da suíte é 50). }
procedure TMainForm.ApplyCompactSize;
begin
  if FApplyingSize or (UITheme.Tokens.Size.FieldBase = 36) then
    Exit;
  FApplyingSize := True;
  try
    UITheme.SetCustomSize(36, 22, 1);
  finally
    FApplyingSize := False;
  end;
end;

procedure TMainForm.ThemeChanged(Sender: TObject; AMode: TUIThemeMode);
begin
  if FApplyingSize then
    Exit;
  ApplyCompactSize;
  FThemeSwap.Checked := UITheme.IsDark;
  ApplyThemeColors;
end;

procedure TMainForm.ThemeSwapToggle(Sender: TObject);
var
  Theme: string;
begin
  Theme := IfThen(FThemeSwap.Checked, 'dark', 'light');
  Store.SetSetting('theme', Theme);
  UITheme.SetThemeReveal(Theme, TPointF.Create(FThemeSwap.ClientToScreen(
    Point(FThemeSwap.Width div 2, FThemeSwap.Height div 2))), Self);
end;

procedure TMainForm.CreateWnd;
begin
  inherited;
  SetHotkey(Store.GetSetting('hotkey_on', '1') = '1');
  ApplyThemeColors;
end;

procedure TMainForm.DestroyWnd;
begin
  UnregisterHotKey(Handle, HotkeyId);
  inherited;
end;

procedure TMainForm.WndProc(var Message: TMessage);
var
  Prev: HWND;
begin
  if (WM_DEVBOX_SHOW <> 0) and (Message.Msg = WM_DEVBOX_SHOW) then
    MenuOpenClick(nil)
  else if (Message.Msg = WM_HOTKEY) and (Message.WParam = HotkeyId) then
  begin
    if Visible and (GetForegroundWindow = Handle) then
      Hide
    else
    begin
      Prev := GetForegroundWindow;
      ShowPage('clipboard');
      ShowWindow_;
      FClipboard.OpenFromHotkey(Prev);
    end;
  end
  else
    inherited;
end;

procedure TMainForm.SetHotkey(AOn: Boolean);
const
  MOD_NOREPEAT = $4000;
begin
  if not HandleAllocated then
    Exit;
  UnregisterHotKey(Handle, HotkeyId);
  if AOn and not RegisterHotKey(Handle, HotkeyId, MOD_WIN or MOD_ALT or MOD_NOREPEAT, Ord('B')) then
    TUIToastManager.Show('Win+Alt+B já está em uso por outro programa', ttWarning, 6000);
end;

procedure TMainForm.HotkeySettingChanged(Sender: TObject);
begin
  SetHotkey(Store.GetSetting('hotkey_on', '1') = '1');
  // Win+Alt+S é do ajudante.
  PostToHelper(WM_HELPER_RELOAD);
end;

procedure TMainForm.HistoryCleared(Sender: TObject);
begin
  FClipboard.ReloadClips;
end;

procedure TMainForm.ExpanderChanged(Sender: TObject);
begin
  PostToHelper(WM_HELPER_RELOAD);
  FClipboard.ReloadClips;
end;

procedure TMainForm.EditSnippet(AId: Integer);
begin
  FExpanderPage.EditSnippetById(AId);
end;

{ Balão da bandeja (vira notificação do Windows) e, com a janela na frente,
  também o aviso da própria tela. }
procedure TMainForm.ShowNotify(const ATitle, AText: string; AError: Boolean);
begin
  FTray.BalloonTitle := ATitle;
  FTray.BalloonHint := AText;
  if AError then
    FTray.BalloonFlags := bfError
  else
    FTray.BalloonFlags := bfInfo;
  FTray.ShowBalloonHint;
  if Visible and AError then
    TUIToastManager.Show(ATitle + ': ' + AText, ttError, 6000)
  else if Visible then
    TUIToastManager.Show(ATitle + ': ' + AText, ttSuccess, 5000);
end;

procedure TMainForm.FocusMenuClick(Sender: TObject);
begin
  FFocusPage.Toggle;
end;

procedure TMainForm.FocusChanged(Sender: TObject);
begin
  FFocusItem.Checked := FocusActive;
  if FocusActive then
    FTray.Hint := 'Devbox  ·  modo foco ligado'
  else
    FTray.Hint := 'Devbox  ·  Win+Alt+B abre o clipboard';
end;

procedure TMainForm.ShowWindow_;
begin
  if not Visible then
    Show;
  if IsIconic(Handle) then
    ShowWindow(Handle, SW_RESTORE);
  SetForegroundWindow(Handle);
end;

procedure TMainForm.MenuOpenClick(Sender: TObject);
begin
  FClipboard.OpenFromHotkey(0);
  ShowWindow_;
end;

procedure TMainForm.MenuExitClick(Sender: TObject);
begin
  FExitRequested := True;
  PostToHelper(WM_HELPER_QUIT);
  Close;
end;

procedure TMainForm.FormCloseQuery(Sender: TObject; var CanClose: Boolean);
begin
  // Fechar a janela só esconde; sair é pelo menu da bandeja.
  CanClose := FExitRequested;
  if not CanClose then
    Hide;
end;

procedure TMainForm.FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if Key = VK_ESCAPE then
  begin
    Hide;
    Key := 0;
  end
  else if (FActive <> nil) and FActive.PageKey(Key, Shift) then
    Key := 0;
end;

initialization
  WM_DEVBOX_SHOW := RegisterWindowMessage(ShowMessageName);

end.
