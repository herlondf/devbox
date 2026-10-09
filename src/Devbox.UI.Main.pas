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
  Devbox.UI.SidePeek,
  Devbox.UI.HostPage,
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
  Devbox.UI.Pomodoro,
  Devbox.UI.Tools,
  Devbox.UI.System,
  Devbox.UI.Settings,
  Devbox.UI.AISettings,
  Devbox.Issues.UI.Main,
  Devbox.Issues.TrayIcon,
  Devbox.UI.Google,
  Devbox.UI.Mail,
  Devbox.UI.Agenda,
  Devbox.UI.Digest,
  Devbox.UI.Voice;

type
  TMainForm = class(TForm)
  private
    FTray: TTrayIcon;
    FTrayMenu: TPopupMenu;
    FSidebar: TUISidebar;
    FTitle, FSubtitle: TUILabel;
    FThemeSwap: TUISwap;
    FContent: TPanel;
    FFooter: TPanel;
    FFooterActions: TArray<TProc>;
    FPages: TDictionary<string, TDevPage>;
    FPageOrder: TList<string>;
    FActive: TDevPage;
    FClipboard: TClipboardPage;
    FExpanderPage: TExpanderPage;
    FWatchesPage: TWatchesPage;
    FFocusPage: TFocusPage;
    FToolsPage: TToolsPage;
    FPomodoro: TPomodoroPage;
    FIssuesConfig: THostPage;
    FFocusItem: TMenuItem;
    FGooglePage: TGooglePage;
    FMailPage: TMailPage;
    FAgendaPage: TAgendaPage;
    FDigestPage: TDigestPage;
    FSettingsPage: TAISettingsPage;
    FIssuesPage: TIssuesPage;
    FGeneralPage: TSettingsPage;
    FVoice: TVoiceAssistant;
    FApplyingSize: Boolean;
    FExitRequested: Boolean;
    procedure PaletteCommands(APalette: TObject);
    procedure PomodoroMenuClick(Sender: TObject);
    function PageCommand(const AId: string): TProc;
    procedure GoogleAccountsChanged(Sender: TObject);
    function NewPomodoro: TPomodoroPage;
    procedure AddPage(const AID, AGroup, AIconPath: string; APage: TDevPage);
    procedure ShowPage(AID: string);
    function PageExists(const AID: string): Boolean;
    procedure SidebarChange(Sender: TObject);
    procedure BuildTray;
    procedure IssuesCounts(AUnread: Integer; AOverdue: Boolean);
    procedure IssuesShowRequest(Sender: TObject);
    procedure IssuesHideRequest(Sender: TObject);
    procedure IssuesCheckUpdates(Sender: TObject);
    procedure IssuesAiUsage(Sender: TObject);
    procedure RegisterDevboxTools;
    function ScreenContext: string;
    function MyDayText: string;
    procedure BuildShell;
    procedure FillFooter;
    procedure FooterClick(Sender: TObject);
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
    procedure VoiceMenuClick(Sender: TObject);
    procedure VoiceSettingChanged(Sender: TObject);
    procedure ApplyVoiceSetting(AShowErrors: Boolean);
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
  Devbox.Google,
  Devbox.AI,
  Devbox.MailSource,
  Devbox.Voice,
  Devbox.Voice.Agent,
  Vcl.Graphics,
  UI.Tokens,
  UI.Painter.Vcl,
  UI.Toast,
  UI.Kbd,
  UI.Assistant.Tools,
  System.JSON,
  System.Threading,
  Vcl.Clipbrd,
  Devbox.Sys,
  UI.CommandPalette,
  Devbox.Issues.Model,
  UI.Icons.Heroicons,
  Devbox.UI.Dialogs,
  Devbox.Notify,
  Devbox.Focus,
  Devbox.Model,
  Devbox.Secrets,
  Devbox.Whisper,
  Devbox.Realtime,
  Devbox.Speech,
  UI.Audio.Capture,
  Devbox.Store;

const
  HotkeyId = 1;

type
  TFooterLabel = class(TControl);

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
  LStartPage: string;
  LDashboard, LAccounts, LIssueSettings: TControl;
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
  ShortcutsChanged :=
    procedure
    begin
      if FActive <> nil then
        FillFooter;
    end;
  FMailPage := TMailPage.Create(Self);
  FAgendaPage := TAgendaPage.Create(Self);
  FDigestPage := TDigestPage.Create(Self);
  FDigestPage.OnTodayEvents :=
    function: TCalEvents
    begin
      Result := FAgendaPage.TodayEvents;
    end;
  FDigestPage.OnOpenIssues :=
    function: TItems
    begin
      Result := FIssuesPage.OpenItems;
    end;
  AddPage('home', 'Início', IconHome, FDigestPage);
  // Issues e PRs (o antigo Vigia): GitHub, Jira, GitLab, Azure DevOps.
  FIssuesPage := TIssuesPage.Create(Self);
  FIssuesPage.Tray := FTray;
  FIssuesPage.OnCounts := IssuesCounts;
  FIssuesPage.OnShowRequest := IssuesShowRequest;
  FIssuesPage.OnHideRequest := IssuesHideRequest;
  FIssuesPage.OnExitRequest := MenuExitClick;
  FIssuesPage.QuietCheck :=
    function: Boolean
    begin
      Result := FocusActive;
    end;
  AddPage('issues', 'Início', IconIssues, FIssuesPage);
  AddPage('mail', 'E-mail e agenda', IconMail, FMailPage);
  AddPage('agenda', 'E-mail e agenda', IconCalendar, FAgendaPage);
  FFocusPage := TFocusPage.Create(Self);
  FFocusPage.OnChanged := FocusChanged;
  AddPage('focus', 'Produtividade', IconTarget, FFocusPage);
  FPomodoro := NewPomodoro;
  AddPage('pomodoro', 'Produtividade', IconTimer, FPomodoro);
  FClipboard := TClipboardPage.Create(Self);
  FClipboard.OnEditSnippet := EditSnippet;
  FExpanderPage := TExpanderPage.Create(Self);
  FExpanderPage.OnChanged := ExpanderChanged;
  FToolsPage := TToolsPage.Create(Self, FClipboard, FExpanderPage);
  AddPage('tools', 'Ferramentas', IconWrench, FToolsPage);
  // Expansor e captura moram no DevboxHelper.exe (ver Devbox.Keys).
  StartHelper;
  Services := TServicesPage.Create(Self);
  AddPage('services', 'Ambiente', IconServer, Services);
  AddPage('cleanup', 'Ambiente', IconBroom, TCleanupPage.Create(Self));
  AddPage('network', 'Ambiente', IconGlobe, TNetworkPage.Create(Self));
  AddPage('system', 'Ambiente', IconCpu, TSystemPage.Create(Self));
  AddPage('envs', 'Automação', IconPlay, TEnvsPage.Create(Self));
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
  FGeneralPage := Settings;
  // "Procurar agora" da tela Geral usa o atualizador da tela Issues (criada antes).
  FGeneralPage.OnCheckUpdates := IssuesCheckUpdates;
  AddPage('settings', 'Configuração', IconSettings, Settings);
  FGooglePage := TGooglePage.Create(Self);
  FGooglePage.OnAccountsChanged := GoogleAccountsChanged;
  AddPage('google', 'Configuração', IconUser, FGooglePage);
  // Contas e preferências das Issues numa tela de Configuração; o painel delas vai para Hoje.
  FIssuesConfig := THostPage.Create(Self);
  FIssuesConfig.Caption := 'Issues';
  FIssuesConfig.Hint := 'Contas do GitHub, Jira, GitLab e Azure DevOps e as preferências de busca e aviso.';
  AddPage('issues-config', 'Configuração', IconIssues, FIssuesConfig);
  FIssuesPage.DetachPages(LDashboard, LAccounts, LIssueSettings);
  FIssuesConfig.AddView('Contas', LAccounts);
  FIssuesConfig.AddView('Preferências', LIssueSettings);
  // O painel antigo das Issues sai de cena: o Hoje tem o próprio, com e-mail e agenda juntos.
  LDashboard.Visible := False;
  LDashboard.Parent := FDigestPage;
  FDigestPage.OnImportantMails :=
    function: TMailMsgs
    begin
      Result := FMailPage.UnreadMails;
    end;
  FDigestPage.OnOpenMail :=
    procedure(AId: string)
    begin
      ShowPage('mail');
      FMailPage.OpenMessage(AId);
    end;
  FDigestPage.OnOpenIssue :=
    procedure(AItem: TItem)
    begin
      FIssuesPage.OpenIssue(AItem);
    end;
  FDigestPage.OnNavigate :=
    procedure(AId: string)
    begin
      ShowPage(AId);
    end;
  FIssuesPage.OnNavigate :=
    procedure(APage: Integer)
    begin
      case APage of
        0: ShowPage('home');
        2, 3:
          begin
            ShowPage('issues-config');
            FIssuesConfig.ShowTab(APage - 2);
          end;
      end;
      ShowWindow_;
    end;
  FSettingsPage := TAISettingsPage.Create(Self);
  FSettingsPage.OnVoiceChanged := VoiceSettingChanged;
  FSettingsPage.OnVoiceTalk := VoiceMenuClick;
  AddPage('ai', 'Configuração', IconSparkles, FSettingsPage);
  FSettingsPage.HostAiCards(FIssuesPage.TakeAiSettings);
  FSettingsPage.OnCostsShown := IssuesAiUsage;
  FIssuesPage.OnScreenContext :=
    function: string
    begin
      Result := ScreenContext;
    end;
  RegisterDevboxTools;
  FIssuesPage.OnPaletteCommands :=
    procedure(APalette: TUICommandPalette)
    begin
      PaletteCommands(APalette);
    end;
  FIssuesPage.RefreshPalette;

  // Criado por último: é destruído primeiro (o microfone para antes das telas).
  FVoice := TVoiceAssistant.Create(Self);
  FVoice.OnContext :=
    function: TVoiceContext
    begin
      Result := Default(TVoiceContext);
      Result.Config := LoadAIConfig;
      LoadGoogleClient;
      Result.Accounts := LoadMailAccounts;
      Result.Today := FAgendaPage.TodayEvents;
      Result.Upcoming := FAgendaPage.AllEvents;
      Result.Issues := FIssuesPage.OpenItems;
      Result.Now := Now;
    end;
  FVoice.OnAction :=
    procedure(const AReply: TVoiceReply)
    begin
      case AReply.Action of
        vaFocoLigar:
          if not FocusActive then
            FFocusPage.Toggle;
        vaFocoDesligar:
          if FocusActive then
            FFocusPage.Toggle;
        vaAbrir:
          if PageExists(AReply.Page) then
          begin
            ShowPage(AReply.Page);
            ShowWindow_;
          end;
      end;
    end;
  System.Classes.TThread.ForceQueue(nil,
    procedure
    begin
      if not AppClosing then
        ApplyVoiceSetting(False);
      // Teste: DEVBOX_ASSISTANT_ASK abre o assistente e já pergunta (ver o chat sem clicar).
      if GetEnvironmentVariable('DEVBOX_ASSISTANT_ASK') <> '' then
      begin
        FIssuesPage.Assistant.Open;
        FIssuesPage.Assistant.Ask(GetEnvironmentVariable('DEVBOX_ASSISTANT_ASK'));
      end;
    end);

  ApplyThemeColors;
  UITheme.AddChangeListener(ThemeChanged);
  // Devbox.exe -show -page settings: abre direto numa tela (atalho e teste de tela).
  if not FindCmdLineSwitch('page', LStartPage, True, [clstValueNextParam]) or not PageExists(LStartPage) then
    LStartPage := 'home';
  ShowPage(LStartPage);
end;

destructor TMainForm.Destroy;
begin
  AppClosing := True;
  NotifyHandler := nil;
  ShortcutsChanged := nil;
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

function TMainForm.PageExists(const AID: string): Boolean;
begin
  Result := FPages.ContainsKey(AID) or MatchText(AID, ['clipboard', 'expander', 'digest']);
end;

procedure TMainForm.ShowPage(AID: string);
var
  Page: TDevPage;
begin
  // Nomes antigos (voz, -page): o clipboard virou aba de Ferramentas e o resumo virou Hoje.
  if MatchText(AID, ['clipboard', 'expander']) then
  begin
    ShowPage('tools');
    if SameText(AID, 'clipboard') then
      FToolsPage.ShowTab(ttClip)
    else
      FToolsPage.ShowTab(ttExpander);
    FillFooter;
    Exit;
  end;
  if SameText(AID, 'digest') then
    AID := 'home';
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
  // O assistente (FAB) fica no canto do rodapé, fora do conteúdo das telas.
  FIssuesPage.AttachAssistant(FFooter.Parent, ScaleValue(14), ScaleValue(0));
  FillFooter;
end;

procedure TMainForm.FillFooter;
var
  LItems: TArray<TDevShortcut>;
  LItem: TDevShortcut;
  LKbd: TUIKbd;
  LLabel: TUILabel;
  LIndex: Integer;
begin
  while FFooter.ControlCount > 0 do
    FFooter.Controls[0].Free;
  LItems := nil;
  if FActive.Refreshable then
    LItems := [DevShortcut('F5', 'Atualizar', procedure begin FActive.PageRefresh; end)];
  LItems := LItems + FActive.PageShortcuts + [
    DevShortcut('Ctrl+K', 'Comandos', procedure begin FIssuesPage.OpenPalette; end),
    DevShortcut('Win+Alt+B', 'Clipboard', procedure begin ShowPage('clipboard'); end),
    DevShortcut('Esc', 'Esconder', procedure begin Hide; end)];
  FFooterActions := nil;
  for LIndex := 0 to High(LItems) do
  begin
    LItem := LItems[LIndex];
    LKbd := TUIKbd.Create(Self);
    LKbd.Shortcut := LItem.Keys;
    LKbd.AlignWithMargins := True;
    LKbd.Margins.SetBounds(IfThen(LIndex = 0, 0, ScaleValue(18)), ScaleValue(11), ScaleValue(6), ScaleValue(11));
    LKbd.Left := (LIndex * 2 + 1) * 1000;
    LKbd.Align := alLeft;
    LKbd.Parent := FFooter;
    LLabel := TUILabel.Create(Self);
    LLabel.Caption := LItem.Caption;
    LLabel.Variant := lvMuted;
    LLabel.AutoSize := True;
    LLabel.Cursor := crHandPoint;
    LLabel.Tag := LIndex;
    LLabel.Left := (LIndex * 2 + 2) * 1000;
    LLabel.Align := alLeft;
    LLabel.Parent := FFooter;
    // Clicar no texto faz o mesmo que a tecla.
    TFooterLabel(LLabel).OnClick := FooterClick;
    FFooterActions := FFooterActions + [LItem.Action];
  end;
end;

procedure TMainForm.FooterClick(Sender: TObject);
begin
  // Na próxima volta: a ação pode trocar de tela e refazer o rodapé (o rótulo clicado some).
  ForceQueueUI(FFooterActions[TComponent(Sender).Tag]);
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

  // Rodapé com os atalhos da tela da frente (como era no Vigia).
  FFooter := TPanel.Create(Self);
  FFooter.BevelOuter := bvNone;
  FFooter.ParentBackground := False;
  FFooter.Height := ScaleValue(44);
  // Direita livre: o botão redondo do assistente fica ali.
  FFooter.Padding.SetBounds(ScaleValue(20), 0, ScaleValue(110), 0);
  FFooter.Align := alBottom;
  FFooter.Parent := Right;

  FContent := TPanel.Create(Self);
  FContent.BevelOuter := bvNone;
  FContent.ParentBackground := False;
  FContent.Padding.SetBounds(ScaleValue(20), ScaleValue(8), ScaleValue(20), ScaleValue(24));
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
  AddItem('Falar com o Devbox', VoiceMenuClick);
  AddItem('Pomodoro: começar ou pausar', PomodoroMenuClick);
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
  // O painel lateral (e-mail, logs) anda e some junto com a janela.
  if (Message.Msg = WM_WINDOWPOSCHANGED) or (Message.Msg = WM_SIZE) then
  begin
    inherited;
    SidePeekFollow(Self);
  end
  else if (WM_DEVBOX_SHOW <> 0) and (Message.Msg = WM_DEVBOX_SHOW) then
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

procedure TMainForm.GoogleAccountsChanged(Sender: TObject);
begin
  FMailPage.Reload;
  FAgendaPage.Reload;
end;

procedure TMainForm.PomodoroMenuClick(Sender: TObject);
begin
  FPomodoro.Toggle;
end;

{ Uma função por tela: o laço reaproveitaria a mesma variável em todas. }
function TMainForm.PageCommand(const AId: string): TProc;
begin
  Result :=
    procedure
    begin
      ShowPage(AId);
    end;
end;

{ Paleta (Ctrl+K, de qualquer tela): telas do Devbox e as ações mais usadas. }
procedure TMainForm.PaletteCommands(APalette: TObject);
var
  LPalette: TUICommandPalette;
  LId: string;
begin
  LPalette := TUICommandPalette(APalette);
  for LId in FPageOrder do
    LPalette.AddCommand('Telas / ' + FPages[LId].Caption, PageCommand(LId));
  LPalette.AddCommand('Telas / Clipboard', procedure begin ShowPage('clipboard'); end);
  LPalette.AddCommand('Telas / Expansor de texto', procedure begin ShowPage('expander'); end);
  LPalette.AddCommand('Devbox / Ligar ou desligar o modo foco', procedure begin FFocusPage.Toggle; end);
  LPalette.AddCommand('Devbox / Pomodoro: começar ou pausar', procedure begin FPomodoro.Toggle; end);
  LPalette.AddCommand('Devbox / Resumo do meu dia (assistente)',
    procedure
    begin
      FIssuesPage.Assistant.Open;
      FIssuesPage.Assistant.Ask('Me dê o resumo do meu dia: agenda, e-mails importantes e issues que pedem atenção.');
    end);
  LPalette.AddCommand('Devbox / Capturar região da tela', procedure begin PostToHelper(WM_HELPER_CAPTURE); end);
  LPalette.AddCommand('Devbox / Falar com o Devbox', procedure begin FVoice.Trigger; end);
  LPalette.AddCommand('Devbox / Novo snippet',
    procedure
    begin
      ShowPage('expander');
      FExpanderPage.EditSnippetById(0);
    end);
end;

function TMainForm.NewPomodoro: TPomodoroPage;
begin
  Result := TPomodoroPage.Create(Self);
  Result.OnStatus :=
    procedure(AText: string)
    begin
      if AText <> '' then
        FTray.Hint := 'Devbox  ·  ' + AText
      else
        FocusChanged(nil);  // volta a dica normal
    end;
  Result.OnWorkStart :=
    procedure(AMinutes: Integer)
    begin
      FFocusPage.StartTimed(AMinutes, 'Pomodoro');
    end;
  Result.OnWorkStop :=
    procedure
    begin
      if FocusActive then
        FFocusPage.StopBy('Pomodoro');
    end;
end;

procedure TMainForm.EditSnippet(AId: Integer);
begin
  ShowPage('expander');
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

procedure TMainForm.ApplyVoiceSetting(AShowErrors: Boolean);
const
  CSimilarity: array[0..2] of Single = (0.6, 0.72, 0.85);
var
  LError: string;
  LEngine: TSttEngine;
  LLive: Integer;
  LLiveConfig: TRealtimeConfig;
begin
  FVoice.SetPhrase(Store.GetSetting('voice_phrase', VoiceDefaultPhrase),
    CSimilarity[EnsureRange(StrToIntDef(Store.GetSetting('voice_sense', '1'), 1), 0, 2)]);
  // Aparelhos guardados pelo nome (o índice muda quando se pluga outro).
  VoiceOutputDevice := DeviceIndexByName(OutputDeviceNames, Store.GetSetting('voice_out_dev'));
  FVoice.SetInputDevice(DeviceIndexByName(TUIAudioCapture.DeviceNames, Store.GetSetting('voice_in_dev')));
  LEngine := TSttEngine(EnsureRange(StrToIntDef(Store.GetSetting('voice_stt', '0'), 0), 0, Ord(High(TSttEngine))));
  if SttIsCloud(LEngine) then
    SttConfigure(LEngine, LoadSecret(SttSecretTarget(LEngine)))
  else
    SttConfigure(LEngine, '');
  LLive := EnsureRange(StrToIntDef(Store.GetSetting('voice_live', '0'), 0), 0, 2);
  LLiveConfig := Default(TRealtimeConfig);
  if LLive > 0 then
  begin
    LLiveConfig.Provider := TRealtimeProvider(LLive - 1);
    LLiveConfig.Key := LoadSecret('Devbox:rt:' + IntToStr(LLive));
    LLiveConfig.Model := Store.GetSetting('voice_live_model_' + IntToStr(LLive), '');
  end;
  FVoice.SetLive(LLive > 0, LLiveConfig);
  if Store.GetSetting('voice_on', '0') <> '1' then
  begin
    FVoice.Enable(False, LError);
    Exit;
  end;
  if FVoice.Enable(True, LError) then
  begin
    if AShowErrors then
      TUIToastManager.Show('Ouvindo. Diga "' + Store.GetSetting('voice_phrase', VoiceDefaultPhrase) + '" e o pedido.',
        ttSuccess, 3500);
  end
  else
  begin
    // Sem microfone ou sem os arquivos de voz: desliga para não insistir a cada abertura.
    Store.SetSetting('voice_on', '0');
    FSettingsPage.SetVoiceOn(False);
    if AShowErrors then
      TUIToastManager.Show('Voz não ligou: ' + LError, ttError, 8000)
    else
      ShowNotify('Voz do Devbox', 'Não ligou: ' + LError, True);
  end;
end;

procedure TMainForm.VoiceSettingChanged(Sender: TObject);
begin
  ApplyVoiceSetting(True);
end;

procedure TMainForm.VoiceMenuClick(Sender: TObject);
begin
  FVoice.Trigger;
end;

{ Contador das issues sobre o ícone da bandeja (o desenho com número vem do Vigia). }
procedure TMainForm.IssuesCounts(AUnread: Integer; AOverdue: Boolean);
begin
  if (AUnread > 0) or AOverdue then
    FTray.Icon.Handle := Devbox.Issues.TrayIcon.MakeTrayIcon(AUnread, AOverdue)
  else
    FTray.Icon.Handle := MakeTrayIcon;
end;

procedure TMainForm.IssuesShowRequest(Sender: TObject);
begin
  ShowPage('issues');
  ShowWindow_;
end;

{ Agenda de hoje e e-mails não lidos, em texto, para o assistente resumir. }
function TMainForm.MyDayText: string;
const
  CMaxMails = 15;
var
  LEvent: TCalEvent;
  LMsg: TMailMsg;
  LMails: TMailMsgs;
  LCount: Integer;
begin
  Result := 'Agora: ' + FormatDateTime('dddd dd/mm hh:nn', Now) + sLineBreak + 'Agenda de hoje:' + sLineBreak;
  for LEvent in FAgendaPage.TodayEvents do
    if LEvent.AllDay then
      Result := Result + '- dia todo: ' + LEvent.Title + sLineBreak
    else
      Result := Result + Format('- %s-%s: %s%s', [FormatDateTime('hh:nn', LEvent.Start),
        FormatDateTime('hh:nn', LEvent.Finish), LEvent.Title, IfThen(LEvent.MeetUrl <> '', ' (Meet)', '')]) +
        sLineBreak;
  LMails := FMailPage.UnreadMails;
  Result := Result + Format('E-mails não lidos: %d', [Length(LMails)]) + sLineBreak;
  LCount := 0;
  for LMsg in LMails do
    if LMsg.Important then
    begin
      Result := Result + Format('- [importante] %s, de %s: %s', [LMsg.Subject, LMsg.FromName, LMsg.Snippet]) +
        sLineBreak;
      Inc(LCount);
      if LCount = CMaxMails then
        Break;
    end;
  for LMsg in LMails do
    if not LMsg.Important and (LCount < CMaxMails) then
    begin
      Result := Result + Format('- %s, de %s: %s', [LMsg.Subject, LMsg.FromName, LMsg.Snippet]) + sLineBreak;
      Inc(LCount);
    end;
end;

function TMainForm.ScreenContext: string;
begin
  if FActive = nil then
    Exit('');
  Result := 'Tela aberta no Devbox: ' + FActive.Caption + '.';
  if FActive.PageContext <> '' then
    Result := Result + sLineBreak + FActive.PageContext;
end;

{ O que antes eram botões de IA nas telas (Clipboard, logs, Comando por IA) o assistente faz:
  lê a tela, copia o resultado e roda comando com confirmação. }
procedure TMainForm.RegisterDevboxTools;
const
  CRunTimeoutMs = 60000;
  CMaxOutput = 8000;
var
  LDef: TUIAssistantToolDef;
begin
  FIssuesPage.Assistant.Tools.Register('devbox_tela_atual',
    'Lê o que está aberto no Devbox agora: o item escolhido no Clipboard, o e-mail aberto ou o log aberto.',
    function(const AArgs: TJSONObject): string
    var
      LText: string;
    begin
      if TThread.CurrentThread.ThreadID = MainThreadID then
        LText := ScreenContext
      else
        TThread.Synchronize(nil,
          procedure
          begin
            LText := ScreenContext;
          end);
      Result := LText;
    end);

  FIssuesPage.Assistant.Tools.Register('devbox_meu_dia',
    'Agenda de hoje e e-mails não lidos (importantes primeiro). Use para o resumo do dia, junto com as issues ' +
    'que você já conhece.',
    function(const AArgs: TJSONObject): string
    var
      LText: string;
    begin
      if TThread.CurrentThread.ThreadID = MainThreadID then
        LText := MyDayText
      else
        TThread.Synchronize(nil,
          procedure
          begin
            LText := MyDayText;
          end);
      Result := LText;
    end);

  LDef := FIssuesPage.Assistant.Tools.Register('devbox_copiar',
    'Põe um texto no Clipboard do Windows (tradução, resumo, mensagem de commit, comando...).',
    function(const AArgs: TJSONObject): string
    var
      LText: string;
    begin
      LText := AArgs.GetValue<string>('texto', '');
      TThread.Synchronize(nil,
        procedure
        begin
          Clipboard.AsText := LText;
        end);
      Result := 'copiado';
    end);
  LDef.AddParam('texto', pkString, 'O texto a copiar', True);

  LDef := FIssuesPage.Assistant.Tools.Register('devbox_rodar_comando',
    'Roda um comando no PC do usuário e devolve a saída. Use para responder perguntas sobre a máquina ou fazer o ' +
    'que ele pediu. Prefira comandos que só leem; o usuário confirma antes de rodar.',
    function(const AArgs: TJSONObject): string
    var
      LShell, LCommand, LLine, LOutput: string;
      LCode: Integer;
      LTask: ITask;
    begin
      LShell := LowerCase(AArgs.GetValue<string>('shell', 'powershell'));
      LCommand := AArgs.GetValue<string>('comando', '');
      if LShell = 'cmd' then
        LLine := 'cmd.exe /c ' + LCommand
      else if LShell = 'wsl' then
        LLine := 'wsl.exe -e sh -c "' + StringReplace(LCommand, '"', '\"', [rfReplaceAll]) + '"'
      else
        LLine := 'powershell.exe -NoProfile -Command "' + StringReplace(LCommand, '"', '\"', [rfReplaceAll]) + '"';
      LTask := TTask.Run(
        procedure
        begin
          try
            LCode := RunCapture(LLine, LOutput, CRunTimeoutMs);
          except
            on E: Exception do
            begin
              LCode := -3;
              LOutput := E.Message;
            end;
          end;
        end);
      // Na thread da tela: espera sem travar a janela.
      if TThread.CurrentThread.ThreadID = MainThreadID then
        while LTask.Status in [TTaskStatus.Created, TTaskStatus.WaitingToRun, TTaskStatus.Running] do
        begin
          Application.ProcessMessages;
          Sleep(20);
        end
      else
        LTask.Wait;
      LOutput := StringReplace(TrimRight(LOutput), #13, '', [rfReplaceAll]);
      Result := Format('código de saída %d' + sLineBreak + '%s', [LCode, Copy(LOutput, Max(1, Length(LOutput) -
        CMaxOutput), CMaxOutput)]);
    end, True);
  LDef.AddParam('shell', pkString, 'powershell, cmd ou wsl', True);
  LDef.AddParam('comando', pkString, 'O comando, numa linha', True);
end;

procedure TMainForm.IssuesAiUsage(Sender: TObject);
begin
  FIssuesPage.RefreshAiUsage;
end;

procedure TMainForm.IssuesCheckUpdates(Sender: TObject);
begin
  FIssuesPage.CheckUpdatesNow;
end;

procedure TMainForm.IssuesHideRequest(Sender: TObject);
begin
  Hide;
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
  // Janela antes do foco: SetFocus com o form escondido levanta exceção.
  // O clique duplo da bandeja não trata exceção: sem o except, o app fecha.
  try
    ShowWindow_;
    FClipboard.OpenFromHotkey(0);
  except
    Application.HandleException(Self);
  end;
end;

procedure TMainForm.MenuExitClick(Sender: TObject);
begin
  FExitRequested := True;
  AppClosing := True;
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
  // A tela tem a primeira palavra (Esc fecha o detalhe das Issues antes de esconder).
  if (FActive <> nil) and FActive.PageKey(Key, Shift) then
    Key := 0
  else if Key = VK_ESCAPE then
  begin
    // Com o painel lateral aberto, Esc fecha só ele.
    if not SidePeekCloseAny then
      Hide;
    Key := 0;
  end
  else if (Key = VK_F5) and (FActive <> nil) and FActive.Refreshable then
  begin
    FActive.PageRefresh;
    Key := 0;
  end;
end;

initialization
  WM_DEVBOX_SHOW := RegisterWindowMessage(ShowMessageName);

end.
