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
  Devbox.UI.Wsl,
  Devbox.UI.Git,
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
    FEnvsPage: TEnvsPage;
    FJobsPage: TJobsPage;
    FNetworkPage: TNetworkPage;
    FCleanupPage: TCleanupPage;
    FGitPage: TGitPage;
    FIssuesConfig: THostPage;
    FHealthTimer: TTimer;
    FHealthRunning: Boolean;
    FPomodoroText: string;
    FBalloonExplain: Boolean;      // clique no aviso explica o erro copiado
    FExplainText: string;
    FExplainOfferedAt: UInt64;
    FBalloonPage: string;          // tela que o clique no aviso abre (manutenção: Limpeza)
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
    procedure RegisterMailTools;
    procedure RegisterAppTools;
    procedure RegisterSearch;
    procedure RegisterMemoryTools;
    function CopyClipProc(const AText: string): TProc;
    function OpenMailProc(const AId: string): TProc;
    function RunEnvProc(const AName: string): TProc;
    procedure OfferExplain(const AText: string);
    procedure ExplainClick(Sender: TObject);
    procedure HealthTick(Sender: TObject);
    procedure UpdateMiniStatus;
    procedure MiniMenuClick(Sender: TObject);
    procedure HealthNow(Sender: TObject);
    procedure RunHealth(AManual: Boolean; const AOnDone: TProc<string> = nil);
    procedure TrayBalloonClick(Sender: TObject);
    procedure BuildShell;
    procedure FillFooter;
    procedure FooterClick(Sender: TObject);
    procedure ApplyThemeColors;
    procedure ApplyCompactSize;
    procedure ThemeChanged(Sender: TObject; AMode: TUIThemeMode);
    procedure ApplyThemeSetting;
    procedure ApplyTableDensity(AParent: TWinControl);
    procedure LookChanged(Sender: TObject);
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
  UI.CommandSearch,
  UI.DataTable,
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
  Devbox.Health,
  Devbox.Jobs,
  Devbox.Wsl,
  Devbox.Git,
  Devbox.Cleanup,
  Devbox.Store;

const
  HotkeyId = 1;
  CToastInset = 64;

type
  TFooterLabel = class(TControl);

function MemoryContext: string; forward;

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

  ApplyThemeSetting;
  ApplyCompactSize;
  TUIToastManager.Position := tpBottomRight;
  // Acima do rodapé de atalhos e do botão do assistente, que ficam no canto de baixo.
  TUIToastManager.EdgeInset := CToastInset;
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
  FGitPage := TGitPage.Create(Self);
  AddPage('git', 'Ferramentas', IconGit, FGitPage);
  // Expansor e captura moram no DevboxHelper.exe (ver Devbox.Keys).
  StartHelper;
  Services := TServicesPage.Create(Self);
  AddPage('services', 'Ambiente', IconServer, Services);
  AddPage('wsl', 'Ambiente', IconTerminal, TWslPage.Create(Self));
  FCleanupPage := TCleanupPage.Create(Self);
  AddPage('cleanup', 'Ambiente', IconBroom, FCleanupPage);
  FNetworkPage := TNetworkPage.Create(Self);
  AddPage('network', 'Ambiente', IconGlobe, FNetworkPage);
  AddPage('system', 'Ambiente', IconCpu, TSystemPage.Create(Self));
  FEnvsPage := TEnvsPage.Create(Self);
  AddPage('envs', 'Automação', IconPlay, FEnvsPage);
  FJobsPage := TJobsPage.Create(Self);
  AddPage('jobs', 'Automação', IconClock, FJobsPage);
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
  Settings.OnLookChanged := LookChanged;
  Settings.OnHistoryCleared := HistoryCleared;
  Settings.OnHealthNow := HealthNow;
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
  AskAssistant :=
    procedure(AText: string)
    begin
      FIssuesPage.Assistant.Open;
      FIssuesPage.Assistant.Ask(AText);
    end;
  ErrorCopied :=
    procedure(AText: string)
    begin
      OfferExplain(AText);
    end;
  FIssuesPage.OnScreenContext :=
    function: string
    begin
      Result := MemoryContext + ScreenContext;
    end;
  RegisterDevboxTools;
  RegisterMailTools;
  RegisterAppTools;
  RegisterSearch;
  RegisterMemoryTools;
  // Manutenção do Windows: confere a agenda a cada minuto (Configuração › Geral).
  FHealthTimer := TTimer.Create(Self);
  FHealthTimer.Interval := 60 * 1000;
  FHealthTimer.OnTimer := HealthTick;
  FHealthTimer.Enabled := True;
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
      // Teste: DEVBOX_PALETTE abre o Ctrl+K já buscando.
      if GetEnvironmentVariable('DEVBOX_PALETTE') <> '' then
        FIssuesPage.OpenPaletteWith(GetEnvironmentVariable('DEVBOX_PALETTE'));
    end);

  ApplyThemeColors;
  UITheme.AddChangeListener(ThemeChanged);
  // Devbox.exe -show -page settings: abre direto numa tela (atalho e teste de tela).
  if not FindCmdLineSwitch('page', LStartPage, True, [clstValueNextParam]) or not PageExists(LStartPage) then
    LStartPage := 'home';
  ApplyTableDensity(Self);
  ShowPage(LStartPage);
end;

destructor TMainForm.Destroy;
begin
  AppClosing := True;
  NotifyHandler := nil;
  ShortcutsChanged := nil;
  AskAssistant := nil;
  ErrorCopied := nil;
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
  FSubtitle.Caption := Page.Hint;  // a tela pode trocar a linha ao aparecer (Hoje muda com a hora)
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
  AddItem('Janela mini (sempre por cima)', MiniMenuClick);
  AddItem('-', nil);
  AddItem('Sair', MenuExitClick);
  FTray := TTrayIcon.Create(Self);
  FTray.Icon.Handle := MakeTrayIcon;
  FTray.Hint := 'Devbox  ·  Win+Alt+B abre o clipboard';
  FTray.PopupMenu := FTrayMenu;
  FTray.OnDblClick := MenuOpenClick;
  FTray.OnBalloonClick := TrayBalloonClick;
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
{ Densidade (Configuração › Geral): tamanho de campo e seletor do tema e linhas das tabelas. }
procedure TMainForm.ApplyCompactSize;
const
  CFieldCompact = 36;
  CSelectorCompact = 22;
  CFieldComfortable = 42;
  CSelectorComfortable = 24;
var
  LComfortable: Boolean;
  LField: Integer;
begin
  LComfortable := Store.GetSetting('density') = 'comfortable';
  LField := IfThen(LComfortable, CFieldComfortable, CFieldCompact);
  if FApplyingSize or (UITheme.Tokens.Size.FieldBase = LField) then
    Exit;
  FApplyingSize := True;
  try
    UITheme.SetCustomSize(LField, IfThen(LComfortable, CSelectorComfortable, CSelectorCompact), 1);
  finally
    FApplyingSize := False;
  end;
end;

procedure TMainForm.ApplyThemeSetting;
begin
  case IndexText(Store.GetSetting('theme'), ['light', 'dark']) of
    0: UITheme.Mode := tmLight;
    1: UITheme.Mode := tmDark;
  else
    UITheme.Mode := tmSystem;
  end;
end;

{ Linhas das tabelas seguem a densidade (as telas criam compactas). }
procedure TMainForm.ApplyTableDensity(AParent: TWinControl);
var
  I: Integer;
begin
  for I := 0 to AParent.ControlCount - 1 do
    if AParent.Controls[I] is TUIDataTable then
      TUIDataTable(AParent.Controls[I]).Density := TUITableDensity(IfThen(
        Store.GetSetting('density') = 'comfortable', Ord(tdStandard), Ord(tdCompact)))
    else if AParent.Controls[I] is TWinControl then
      ApplyTableDensity(TWinControl(AParent.Controls[I]));
end;

procedure TMainForm.LookChanged(Sender: TObject);
begin
  ApplyThemeSetting;
  ApplyCompactSize;
  ApplyTableDensity(Self);
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
  LPalette.AddCommand('Devbox / Janela mini (sempre por cima)', procedure begin FIssuesPage.ToggleMini; end);
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
      FPomodoroText := AText;
      UpdateMiniStatus;
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
  FBalloonPage := '';
  FBalloonExplain := False;
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

procedure TMainForm.TrayBalloonClick(Sender: TObject);
begin
  if FBalloonExplain then
  begin
    ExplainClick(nil);
    Exit;
  end;
  if FBalloonPage = '' then
    Exit;
  ShowPage(FBalloonPage);
  ShowWindow_;
end;

{ Erro copiado: na janela, aviso com "Explicar"; com ela escondida, balão da bandeja.
  No máximo um convite por minuto, para não insistir enquanto a pessoa copia o log. }
procedure TMainForm.OfferExplain(const AText: string);
const
  CCooldownMs = 60000;
begin
  if (FExplainOfferedAt <> 0) and (GetTickCount64 - FExplainOfferedAt < CCooldownMs) then
    Exit;
  FExplainOfferedAt := GetTickCount64;
  FExplainText := AText;
  if Visible and not IsIconic(Handle) then
    TUIToastManager.Show('Parece um erro. Quer a explicação do assistente?', ttInfo, 8000, 'Explicar', ExplainClick)
  else
  begin
    ShowNotify('Erro copiado', 'Clique para o assistente explicar.', False);
    FBalloonExplain := True;
  end;
end;

procedure TMainForm.ExplainClick(Sender: TObject);
const
  CMaxChars = 6000;
begin
  FBalloonExplain := False;
  ShowWindow_;
  AskAssistant('Explique este erro que copiei. Diga a causa provável, onde olhar e como corrigir. Seja curto.' +
    sLineBreak + sLineBreak + '```' + sLineBreak + HideSecrets(Copy(FExplainText, 1, CMaxChars)) + sLineBreak + '```');
end;

procedure TMainForm.MiniMenuClick(Sender: TObject);
begin
  FIssuesPage.ToggleMini;
  UpdateMiniStatus;
end;

{ Linha da janela mini: Pomodoro e a reunião de agora ou a próxima de hoje. }
procedure TMainForm.UpdateMiniStatus;
var
  LParts: TArray<string>;
  LEvent, LNext: TCalEvent;
  LFound: Boolean;
begin
  if not FIssuesPage.MiniVisible then
    Exit;
  LParts := nil;
  if FPomodoroText <> '' then
    LParts := [FPomodoroText];
  LFound := False;
  for LEvent in FAgendaPage.TodayEvents do
    if not LEvent.AllDay and (LEvent.Finish > Now) and (not LFound or (LEvent.Start < LNext.Start)) then
    begin
      LNext := LEvent;
      LFound := True;
    end;
  if LFound and (LNext.Start <= Now) then
    LParts := LParts + ['Agora: ' + LNext.Title]
  else if LFound then
    LParts := LParts + ['Próxima ' + FormatDateTime('hh:nn', LNext.Start) + ' ' + LNext.Title];
  FIssuesPage.SetMiniStatus(string.Join('  ·  ', LParts));
end;

procedure TMainForm.HealthTick(Sender: TObject);
var
  LSchedule: THealthSchedule;
  LHour: Integer;
  LKey: string;
begin
  UpdateMiniStatus;
  if FHealthRunning or (Store.GetSetting('health_on', '1') <> '1') then
    Exit;
  LSchedule := THealthSchedule(EnsureRange(StrToIntDef(Store.GetSetting('health_schedule', '0'), 0), 0,
    Ord(High(THealthSchedule))));
  LHour := HealthDueHour(LSchedule, Now);
  if LHour < 0 then
    Exit;
  LKey := FormatDateTime('yyyy-mm-dd', Date) + ' ' + IntToStr(LHour);
  if Store.GetSetting('health_last') = LKey then
    Exit;
  Store.SetSetting('health_last', LKey);
  RunHealth(False);
end;

procedure TMainForm.HealthNow(Sender: TObject);
begin
  TUIToastManager.Show('Procurando o que dá para limpar e ajustar...', ttLoading, 4000);
  RunHealth(True);
end;

{ Varredura em segundo plano. Automático: só avisa se achou algo. Manual: sempre diz o resultado.
  AOnDone (assistente) recebe o texto em vez do aviso. }
procedure TMainForm.RunHealth(AManual: Boolean; const AOnDone: TProc<string>);
const
  CJunkIdleDays = 30;
var
  LRoots: TArray<string>;
begin
  if FHealthRunning then
  begin
    if Assigned(AOnDone) then
      AOnDone('A manutenção já está rodando; tente de novo em um minuto.');
    Exit;
  end;
  FHealthRunning := True;
  // Mesmas pastas da Limpeza › Lixo de build (o banco só na thread da tela).
  LRoots := Store.GetSetting('junk_roots', GetEnvironmentVariable('USERPROFILE')).Split([';'],
    TStringSplitOptions.ExcludeEmpty);
  RunTask(
    procedure
    var
      LReport: THealthReport;
      LError: string;
    begin
      LError := '';
      try
        LReport := RunHealthScan(LRoots, CJunkIdleDays);
      except
        on E: Exception do
          LError := E.Message;
      end;
      QueueUI(
        procedure
        begin
          FHealthRunning := False;
          if Assigned(AOnDone) then
          begin
            if LError <> '' then
              AOnDone('A varredura falhou: ' + LError)
            else
              AOnDone(LReport.Title + '. ' + LReport.Text);
            Exit;
          end;
          if LError <> '' then
          begin
            if AManual then
              TUIToastManager.Show('A manutenção falhou: ' + LError, ttError, 6000);
            Exit;
          end;
          if LReport.Findings = 0 then
          begin
            if AManual then
              TUIToastManager.Show('Tudo em ordem: nada para limpar ou ajustar agora.', ttSuccess, 4000);
            Exit;
          end;
          ShowNotify(LReport.Title, LReport.Text, False);
          FBalloonPage := 'cleanup';
        end);
    end);
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

{ Espera uma ação assíncrona da tela terminar sem travar a janela (as ferramentas do
  assistente rodam na thread da tela e precisam devolver o resultado). }
procedure WaitUntil(const ADone: TFunc<Boolean>; ATimeoutMs: Cardinal);
var
  LStart: UInt64;
begin
  LStart := GetTickCount64;
  while not ADone() and (GetTickCount64 - LStart < ATimeoutMs) do
  begin
    Application.ProcessMessages;
    Sleep(20);
  end;
end;

{ Organizar e aplicar sugestões do e-mail: o que eram botões da tela E-mail. }
procedure TMainForm.RegisterMailTools;
const
  CMailTimeoutMs = 180000;
var
  LDef: TUIAssistantToolDef;
begin
  FIssuesPage.Assistant.Tools.Register('devbox_email_organizar',
    'Lê os e-mails da caixa de entrada e sugere o que fazer com cada um (rótulo, arquivar, marcar lido). ' +
    'Não muda nada na caixa: devolve as sugestões numeradas para o usuário revisar.',
    function(const AArgs: TJSONObject): string
    var
      LDone: Boolean;
      LText: string;
    begin
      ShowPage('mail');
      LDone := False;
      FMailPage.Organize(
        procedure(AOk: Boolean; AText: string)
        begin
          LText := AText;
          LDone := True;
        end);
      WaitUntil(
        function: Boolean
        begin
          Result := LDone;
        end, CMailTimeoutMs);
      if not LDone then
        LText := 'Demorou demais; as sugestões aparecem na tela E-mail quando ficarem prontas.';
      Result := LText;
    end);

  FIssuesPage.Assistant.Tools.Register('devbox_email_sugestoes',
    'Sugestões pendentes para os e-mails, numeradas.',
    function(const AArgs: TJSONObject): string
    begin
      Result := FMailPage.SuggestionsText;
    end);

  LDef := FIssuesPage.Assistant.Tools.Register('devbox_email_descartar',
    'Descarta uma sugestão (o e-mail fica como está). Use o número da lista de sugestões.',
    function(const AArgs: TJSONObject): string
    begin
      if FMailPage.DiscardSuggestion(AArgs.GetValue<Integer>('numero', 0)) then
        Result := 'Descartada. ' + sLineBreak + FMailPage.SuggestionsText
      else
        Result := 'Não achei a sugestão com esse número.';
    end);
  LDef.AddParam('numero', pkInteger, 'Número da sugestão', True);

  FIssuesPage.Assistant.Tools.Register('devbox_email_aplicar',
    'Aplica na caixa de entrada todas as sugestões pendentes (arquiva, marca lido, põe rótulo). O usuário confirma.',
    function(const AArgs: TJSONObject): string
    var
      LDone: Boolean;
      LText: string;
    begin
      LDone := False;
      FMailPage.ApplySuggestions(
        procedure(AText: string)
        begin
          LText := AText;
          LDone := True;
        end);
      WaitUntil(
        function: Boolean
        begin
          Result := LDone;
        end, CMailTimeoutMs);
      if not LDone then
        LText := 'Ainda aplicando; a tela E-mail mostra quando terminar.';
      Result := LText;
    end, True);
  FIssuesPage.Assistant.Tools.Register('devbox_manutencao',
    'Varredura de manutenção do Windows: quanto dá para liberar (temporários, lixo de build), disco com pouco ' +
    'espaço, PATH quebrado e programas na inicialização. Só lê; limpar é na tela Limpeza.',
    function(const AArgs: TJSONObject): string
    var
      LDone: Boolean;
      LText: string;
    begin
      LDone := False;
      RunHealth(False,
        procedure(AText: string)
        begin
          LText := AText;
          LDone := True;
        end);
      WaitUntil(
        function: Boolean
        begin
          Result := LDone;
        end, 300000);
      Result := LText;
    end);
end;

function FindEnv(const AName: string; out AEnv: TEnv): Boolean;
var
  LEnv: TEnv;
begin
  for LEnv in Store.ListEnvs do
    if SameText(LEnv.Name, AName) then
    begin
      AEnv := LEnv;
      Exit(True);
    end;
  Result := False;
end;

function FindJob(const AName: string; out AJob: TJob): Boolean;
var
  LJob: TJob;
begin
  for LJob in Store.ListJobs do
    if SameText(LJob.Name, AName) then
    begin
      AJob := LJob;
      Exit(True);
    end;
  Result := False;
end;

{ O que se faz à mão no Devbox, o assistente faz também: telas, foco, pomodoro, ambientes,
  agendador, avisos de fim, snippets, monitor de URL, limpeza e WSL. O que muda algo fora do
  Devbox (roda comando, liga containers, agenda tarefa) pede confirmação. }
procedure TMainForm.RegisterAppTools;
const
  CCleanupTimeoutMs = 600000;
  CCleanupTabs: array[0..5] of string = ('lixo_build', 'temporarios', 'arquivos_grandes', 'pastas_vazias',
    'containers', 'inicializacao');
var
  LTools: TUIAssistantToolRegistry;
  LDef: TUIAssistantToolDef;
  LPages: string;
  LId: string;

begin
  LTools := FIssuesPage.Assistant.Tools;
  LPages := '';
  for LId in FPageOrder do
    LPages := LPages + IfThen(LPages <> '', ', ') + LId;

  LDef := LTools.Register('devbox_abrir_tela', 'Abre uma tela do Devbox: ' + LPages + ', clipboard, expander.',
    function(const AArgs: TJSONObject): string
    begin
      if not PageExists(AArgs.GetValue<string>('tela', '')) then
        Exit('Tela desconhecida. Use uma destas: ' + LPages);
      ShowPage(AArgs.GetValue<string>('tela', ''));
      Result := 'Aberta.';
    end);
  LDef.AddParam('tela', pkString, 'Id da tela', True);

  LDef := LTools.Register('devbox_foco', 'Liga ou desliga o modo foco (pausa o clipboard e guarda os avisos).',
    function(const AArgs: TJSONObject): string
    begin
      if AArgs.GetValue<Boolean>('ligar', True) <> FocusActive then
        FFocusPage.Toggle;
      Result := IfThen(FocusActive, 'Foco ligado.', 'Foco desligado.');
    end);
  LDef.AddParam('ligar', pkBoolean, 'true liga, false desliga', True);

  LTools.Register('devbox_pomodoro', 'Começa ou pausa o Pomodoro (trabalho e pausa em ciclos).',
    function(const AArgs: TJSONObject): string
    begin
      FPomodoro.Toggle;
      Result := 'Pomodoro alternado (começou ou pausou).';
    end);

  LTools.Register('devbox_ambientes', 'Lista os ambientes de projeto e os passos de cada um.',
    function(const AArgs: TJSONObject): string
    var
      LEnv: TEnv;
    begin
      Result := '';
      for LEnv in Store.ListEnvs do
        Result := Result + '## ' + LEnv.Name + sLineBreak + LEnv.Script + sLineBreak;
      if Result = '' then
        Result := 'Nenhum ambiente.';
    end);

  LDef := LTools.Register('devbox_ambiente_criar',
    'Cria ou troca um ambiente de projeto. Passos, um por linha: "distro: Ubuntu", "container: nome @Distro", ' +
    '"esperar: localhost:5432" ou "esperar: 5", "terminal: C:\pasta | comando", "editor: C:\pasta", ' +
    '"abrir: http://localhost:3000". Linha com # é comentário.',
    function(const AArgs: TJSONObject): string
    var
      LEnv: TEnv;
    begin
      if not FindEnv(AArgs.GetValue<string>('nome', ''), LEnv) then
        LEnv := Default(TEnv);
      LEnv.Name := AArgs.GetValue<string>('nome', '');
      LEnv.Script := AArgs.GetValue<string>('passos', '').Replace(#10, sLineBreak);
      Store.SaveEnv(LEnv);
      FEnvsPage.Reload;
      Result := 'Ambiente salvo: ' + LEnv.Name;
    end);
  LDef.AddParam('nome', pkString, 'Nome do ambiente', True);
  LDef.AddParam('passos', pkString, 'Passos, um por linha', True);

  LDef := LTools.Register('devbox_ambiente_ligar', 'Liga (ou desliga) um ambiente de projeto: sobe distro, ' +
    'containers, terminal, editor e navegador.',
    function(const AArgs: TJSONObject): string
    var
      LEnv: TEnv;
    begin
      if not FindEnv(AArgs.GetValue<string>('nome', ''), LEnv) then
        Exit('Ambiente não encontrado.');
      ShowPage('envs');
      FEnvsPage.Run(LEnv, AArgs.GetValue<Boolean>('desligar', False));
      Result := 'Rodando os passos de ' + LEnv.Name + '; o resultado aparece na tela Ambientes e num aviso.';
    end, True);
  LDef.AddParam('nome', pkString, 'Nome do ambiente', True);
  LDef.AddParam('desligar', pkBoolean, 'true para desligar', False);

  LTools.Register('devbox_tarefas', 'Lista as tarefas do agendador (quando rodam, ligadas, último resultado).',
    function(const AArgs: TJSONObject): string
    var
      LJob: TJob;
    begin
      Result := '';
      for LJob in Store.ListJobs do
        Result := Result + Format('- %s: %s, %s, %s, comando: %s', [LJob.Name, LJob.WhenText,
          IfThen(LJob.Enabled, 'ligada', 'desligada'), IfThen(LJob.LastExit < 0, 'nunca rodou',
          'última saída ' + IntToStr(LJob.LastExit)), LJob.Command]) + sLineBreak;
      if Result = '' then
        Result := 'Nenhuma tarefa.';
    end);

  LDef := LTools.Register('devbox_tarefa_criar', 'Cria uma rotina no agendador: roda um comando (cmd.exe /c) ou ' +
    'só lembra (lembrete) a cada N minutos, todo dia ou em dias da semana num horário. Use para pedidos como ' +
    '"toda sexta às 17h me lembra de lançar horas" ou "todo dia às 9h limpa o lixo de build".',
    function(const AArgs: TJSONObject): string
    var
      LJob: TJob;
      LTime, LDays, LDay: string;
      LHour, LMin, I: Integer;
    begin
      LJob := Default(TJob);
      LJob.Name := AArgs.GetValue<string>('nome', '');
      LJob.Command := AArgs.GetValue<string>('comando', '');
      // Lembrete: o "comando" só ecoa a mensagem e o aviso sai mesmo dando certo.
      if AArgs.GetValue<string>('lembrete', '') <> '' then
      begin
        LJob.Command := 'echo ' + AArgs.GetValue<string>('lembrete', '');
        LJob.NotifyOk := True;
      end;
      if LJob.Command = '' then
        Exit('Faltou o comando ou o lembrete.');
      LJob.WorkDir := AArgs.GetValue<string>('pasta', '');
      LJob.Enabled := True;
      LJob.LastExit := -1;
      LJob.Weekdays := $7F;
      LTime := AArgs.GetValue<string>('as', AArgs.GetValue<string>('todo_dia_as', ''));
      LDays := AArgs.GetValue<string>('dias_semana', '');
      if (LTime <> '') and TryStrToInt(Copy(LTime, 1, 2), LHour) and TryStrToInt(Copy(LTime, 4, 2), LMin) then
      begin
        LJob.Kind := jkDaily;
        LJob.AtMin := LHour * 60 + LMin;
        if LDays <> '' then
        begin
          LJob.Kind := jkWeekly;
          LJob.Weekdays := 0;
          for LDay in LDays.Split([',', ' ', ';'], TStringSplitOptions.ExcludeEmpty) do
            for I := 0 to 6 do
              // "sexta", "sex", "sábado", "sabado": basta começar pelo nome curto.
              if StartsText(StringReplace(WeekdayNames[I], 'á', 'a', []), StringReplace(LDay, 'á', 'a', [])) then
                LJob.Weekdays := LJob.Weekdays or (1 shl I);
          if LJob.Weekdays = 0 then
            Exit('Não entendi os dias. Use dom, seg, ter, qua, qui, sex, sáb.');
        end;
      end
      else
      begin
        LJob.Kind := jkInterval;
        LJob.EveryMin := Max(1, AArgs.GetValue<Integer>('a_cada_minutos', 60));
      end;
      LJob.NextRun := NextRunAfter(LJob, Now);
      Store.SaveJob(LJob);
      FJobsPage.Reload;
      Result := Format('Tarefa criada: %s, %s.', [LJob.Name, LJob.WhenText]);
    end, True);
  LDef.AddParam('nome', pkString, 'Nome da tarefa', True);
  LDef.AddParam('comando', pkString, 'Comando (roda com cmd.exe /c). Vazio se for lembrete.', False);
  LDef.AddParam('lembrete', pkString, 'Mensagem do lembrete (em vez do comando)', False);
  LDef.AddParam('pasta', pkString, 'Pasta onde roda', False);
  LDef.AddParam('a_cada_minutos', pkInteger, 'Intervalo em minutos (quando não tem horário)', False);
  LDef.AddParam('as', pkString, 'Horário hh:mm (todo dia, ou nos dias da semana)', False);
  LDef.AddParam('dias_semana', pkString, 'Dias, ex.: "seg,qua,sex" (com o horário)', False);

  LDef := LTools.Register('devbox_tarefa_rodar', 'Roda agora uma tarefa do agendador.',
    function(const AArgs: TJSONObject): string
    var
      LJob: TJob;
    begin
      if not FindJob(AArgs.GetValue<string>('nome', ''), LJob) then
        Exit('Tarefa não encontrada.');
      FJobsPage.RunJob(LJob);
      Result := 'Rodando ' + LJob.Name + '; o resultado aparece no Agendador e num aviso.';
    end, True);
  LDef.AddParam('nome', pkString, 'Nome da tarefa', True);

  LDef := LTools.Register('devbox_tarefa_ligar', 'Liga ou desliga uma tarefa do agendador.',
    function(const AArgs: TJSONObject): string
    var
      LJob: TJob;
    begin
      if not FindJob(AArgs.GetValue<string>('nome', ''), LJob) then
        Exit('Tarefa não encontrada.');
      LJob.Enabled := AArgs.GetValue<Boolean>('ligar', True);
      LJob.NextRun := NextRunAfter(LJob, Now);
      Store.SaveJob(LJob);
      FJobsPage.Reload;
      Result := LJob.Name + IfThen(LJob.Enabled, ' ligada.', ' desligada.');
    end);
  LDef.AddParam('nome', pkString, 'Nome da tarefa', True);
  LDef.AddParam('ligar', pkBoolean, 'true liga, false desliga', True);

  LDef := LTools.Register('devbox_aviso_fim', 'Avisa na bandeja quando um processo termina ou uma porta fecha.',
    function(const AArgs: TJSONObject): string
    var
      LTarget: string;
    begin
      LTarget := AArgs.GetValue<string>('alvo', '');
      if SameText(AArgs.GetValue<string>('tipo', 'processo'), 'porta') then
        FWatchesPage.AddWatch(wkPort, LTarget, '', 'Porta ' + LTarget)
      else
        FWatchesPage.AddWatch(wkProcess, LTarget, '', 'Processo ' + LTarget);
      Result := 'Aviso criado para ' + LTarget + '.';
    end);
  LDef.AddParam('tipo', pkString, 'processo ou porta', True);
  LDef.AddParam('alvo', pkString, 'Nome do processo (ou pid:123) ou número da porta', True);

  LDef := LTools.Register('devbox_snippet_criar', 'Cria um snippet do expansor: digitar o atalho (ex.: ;sql) em ' +
    'qualquer programa vira o texto. Campos {{nome}} são perguntados antes de colar.',
    function(const AArgs: TJSONObject): string
    var
      LAbbrev: string;
    begin
      LAbbrev := AArgs.GetValue<string>('atalho', '');
      if not LAbbrev.StartsWith(';') then
        LAbbrev := ';' + LAbbrev;
      Store.SaveSnippet(0, AArgs.GetValue<string>('texto', '').Replace(#10, sLineBreak), LAbbrev);
      ExpanderChanged(nil);
      FExpanderPage.Reload;
      Result := 'Snippet ' + LAbbrev + ' criado.';
    end);
  LDef.AddParam('atalho', pkString, 'Atalho, ex.: ;sql', True);
  LDef.AddParam('texto', pkString, 'Texto que entra no lugar do atalho', True);

  LDef := LTools.Register('devbox_url_monitorar', 'Monitora uma URL: avisa quando cai ou volta e quando o ' +
    'certificado vai vencer.',
    function(const AArgs: TJSONObject): string
    var
      LCheck: TUrlCheck;
    begin
      LCheck := Default(TUrlCheck);
      LCheck.Name := AArgs.GetValue<string>('nome', '');
      LCheck.Url := AArgs.GetValue<string>('url', '');
      LCheck.IntervalSec := Max(30, AArgs.GetValue<Integer>('intervalo_segundos', 60));
      LCheck.Enabled := True;
      Store.SaveUrlCheck(LCheck);
      FNetworkPage.ReloadUrls;
      Result := 'Monitorando ' + LCheck.Url + '.';
    end);
  LDef.AddParam('nome', pkString, 'Nome', True);
  LDef.AddParam('url', pkString, 'Endereço', True);
  LDef.AddParam('intervalo_segundos', pkInteger, 'De quanto em quanto tempo (padrão 60)', False);

  LDef := LTools.Register('devbox_limpeza_analisar', 'Analisa uma aba da Limpeza e devolve o que achou (só lê; ' +
    'apagar é o usuário quem faz, na tela). Abas: ' + string.Join(', ', CCleanupTabs) + '.',
    function(const AArgs: TJSONObject): string
    var
      LTab: Integer;
    begin
      LTab := IndexText(AArgs.GetValue<string>('aba', 'temporarios'), CCleanupTabs);
      if LTab < 0 then
        Exit('Aba desconhecida.');
      ShowPage('cleanup');
      FCleanupPage.AnalyzeTab(LTab);
      WaitUntil(
        function: Boolean
        begin
          Result := not FCleanupPage.Busy;
        end, CCleanupTimeoutMs);
      Result := FCleanupPage.PageContext;
    end);
  LDef.AddParam('aba', pkString, 'Uma das abas', True);

  LDef := LTools.Register('devbox_wsl', 'WSL: listar as distros (com o tamanho do disco), desligar tudo ou ' +
    'liberar a memória das distros ligadas.',
    function(const AArgs: TJSONObject): string
    var
      LAction, LError: string;
      LDistro: TWslDistro;
    begin
      LAction := AArgs.GetValue<string>('acao', 'listar');
      if SameText(LAction, 'desligar') then
        Exit(IfThen(WslShutdown(LError), 'WSL desligado.', 'Não deu: ' + LError));
      if SameText(LAction, 'liberar_memoria') then
        Exit(WslRunAsRootInRunning('sync; echo 3 > /proc/sys/vm/drop_caches'));
      Result := '';
      for LDistro in ListWslDistros do
        Result := Result + Format('- %s: %s, disco %s', [LDistro.Name, IfThen(LDistro.Running, 'ligada',
          'desligada'), SizeText(LDistro.VhdxSize)]) + sLineBreak;
    end, True);
  LDef.AddParam('acao', pkString, 'listar, desligar ou liberar_memoria', True);

  LTools.Register('devbox_git', 'Repositórios Git locais: branch, arquivos sem commit e o que falta enviar ou ' +
    'puxar. Responde "o que ficou sem commit?".',
    function(const AArgs: TJSONObject): string
    begin
      ShowPage('git');
      WaitUntil(
        function: Boolean
        begin
          Result := not FGitPage.Busy;
        end, 120000);
      Result := FGitPage.ReposText;
    end);

  LDef := LTools.Register('devbox_git_diff', 'Diff de um repositório (o stage; sem stage, tudo que mudou) para ' +
    'escrever a mensagem de commit ou a descrição do PR. Só lê.',
    function(const AArgs: TJSONObject): string
    var
      LRepo: TGitRepo;
    begin
      if not FGitPage.RepoByName(AArgs.GetValue<string>('repositorio', ''), LRepo) then
        Exit('Repositório não encontrado. Use devbox_git para ver os nomes.');
      Result := HideSecrets(GitDiffText(LRepo.Path));
    end);
  LDef.AddParam('repositorio', pkString, 'Nome ou pasta do repositório', True);

  LDef := LTools.Register('devbox_email_buscar', 'Busca e-mails carregados por assunto, remetente ou trecho. ' +
    'Vazio: os não lidos. Devolve id, remetente, assunto e trecho.',
    function(const AArgs: TJSONObject): string
    const
      CMax = 15;
    var
      LMsgs: TMailMsgs;
      LMsg: TMailMsg;
    begin
      if Trim(AArgs.GetValue<string>('texto', '')) = '' then
        LMsgs := Copy(FMailPage.UnreadMails, 0, CMax)
      else
        LMsgs := FMailPage.SearchMails(Trim(AArgs.GetValue<string>('texto', '')), CMax);
      Result := '';
      for LMsg in LMsgs do
        Result := Result + Format('- id %s | %s <%s> | %s | %s', [LMsg.Id, LMsg.FromName, LMsg.FromEmail,
          LMsg.Subject, LMsg.Snippet]) + sLineBreak;
      if Result = '' then
        Result := 'Nenhum e-mail encontrado.';
    end);
  LDef.AddParam('texto', pkString, 'O que buscar (vazio = não lidos)', False);

  LDef := LTools.Register('devbox_email_ler', 'Lê o e-mail inteiro pelo id (para entender o pedido antes de ' +
    'responder).',
    function(const AArgs: TJSONObject): string
    var
      LMsg: TMailMsg;
      LAccount, LSel: TMailAccount;
      LFound, LDone: Boolean;
      LError: string;
    begin
      if not FMailPage.FindMail(AArgs.GetValue<string>('id', ''), LMsg) then
        Exit('E-mail não encontrado. Use devbox_email_buscar.');
      if LMsg.Body = '' then
      begin
        LFound := False;
        for LAccount in LoadMailAccounts do
          if SameText(LAccount.Email, LMsg.Account) then
          begin
            LSel := LAccount;
            LFound := True;
          end;
        if LFound then
        begin
          LDone := False;
          RunTask(
            procedure
            begin
              SrcGetMail(LSel, LMsg.Id, LMsg, LError);
              LDone := True;
            end);
          WaitUntil(
            function: Boolean
            begin
              Result := LDone;
            end, 30000);
        end;
      end;
      Result := HideSecrets(Format('De: %s <%s>%sAssunto: %s%sData: %s%s%s', [LMsg.FromName, LMsg.FromEmail,
        sLineBreak, LMsg.Subject, sLineBreak, FormatDateTime('dd/mm/yyyy hh:nn', LMsg.Date), sLineBreak + sLineBreak,
        Copy(IfThen(LMsg.Body <> '', LMsg.Body, LMsg.Snippet), 1, 8000)]));
    end);
  LDef.AddParam('id', pkString, 'Id do e-mail', True);

  LDef := LTools.Register('devbox_email_rascunho', 'Cria o rascunho da resposta (não envia). Gmail: fica nos ' +
    'Rascunhos, na conversa. Conta IMAP: o texto vai para o clipboard.',
    function(const AArgs: TJSONObject): string
    var
      LMsg: TMailMsg;
      LAccount: TMailAccount;
      LIsGmail, LDone, LOk: Boolean;
      LText, LError: string;
    begin
      if not FMailPage.FindMail(AArgs.GetValue<string>('id', ''), LMsg) then
        Exit('E-mail não encontrado. Use devbox_email_buscar.');
      LText := AArgs.GetValue<string>('texto', '');
      LIsGmail := False;
      for LAccount in LoadMailAccounts do
        if SameText(LAccount.Email, LMsg.Account) then
          LIsGmail := not LAccount.IsImap;
      if not LIsGmail then
      begin
        Clipboard.AsText := LText;
        Exit('Conta IMAP: o rascunho foi para o clipboard. Cole no seu programa de e-mail.');
      end;
      LDone := False;
      LOk := False;
      RunTask(
        procedure
        begin
          LOk := CreateReplyDraft(LMsg.Account, LMsg.ThreadId, LMsg.FromEmail, LMsg.Subject, LText, LError);
          LDone := True;
        end);
      WaitUntil(
        function: Boolean
        begin
          Result := LDone;
        end, 30000);
      Result := IfThen(LOk, 'Rascunho criado nos Rascunhos do Gmail, na conversa. Revise e envie de lá.',
        'Não deu para criar o rascunho: ' + LError);
    end, True);
  LDef.AddParam('id', pkString, 'Id do e-mail', True);
  LDef.AddParam('texto', pkString, 'Texto da resposta', True);
end;

type
  { Um grupo do Ctrl+K a partir de uma função: clipboard, e-mail, ambientes. }
  TFuncSearchProvider = class(TInterfacedObject, IUICommandSearchProvider)
  private
    FName, FIcon: string;
    FSearch: TFunc<string, Integer, TUISearchHits>;
  public
    constructor Create(const AName, AIcon: string; const ASearch: TFunc<string, Integer, TUISearchHits>);
    function GroupName: string;
    function GroupIconSvg: string;
    function Search(const AQuery: string; AMaxResults: Integer): TUISearchHits;
  end;

constructor TFuncSearchProvider.Create(const AName, AIcon: string;
  const ASearch: TFunc<string, Integer, TUISearchHits>);
begin
  inherited Create;
  FName := AName;
  FIcon := AIcon;
  FSearch := ASearch;
end;

function TFuncSearchProvider.GroupName: string;
begin
  Result := FName;
end;

function TFuncSearchProvider.GroupIconSvg: string;
begin
  Result := FIcon;
end;

function TFuncSearchProvider.Search(const AQuery: string; AMaxResults: Integer): TUISearchHits;
const
  CMinChars = 2;
begin
  if Length(Trim(AQuery)) < CMinChars then
    Exit(nil);
  Result := FSearch(Trim(AQuery), AMaxResults);
end;

function SearchHit(const AId, ATitle, ASubtitle, AIcon: string; const AAction: TProc): TUISearchHit;
begin
  Result := Default(TUISearchHit);
  Result.ID := AId;
  Result.Title := ATitle;
  Result.Subtitle := ASubtitle;
  Result.IconSvg := AIcon;
  Result.Action := AAction;
  Result.Score := 100;
end;

const
  CMemoryKey = 'assistant_memory';
  CMaxMemories = 30;
  CMaxMemoryChars = 300;

function Memories: TArray<string>;
begin
  Result := Store.GetSetting(CMemoryKey, '').Split([#10], TStringSplitOptions.ExcludeEmpty);
end;

{ O que o usuário ensinou ao assistente ("meu projeto principal é X"): vai no começo do
  contexto de toda conversa. }
function MemoryContext: string;
var
  LItems: TArray<string>;
  I: Integer;
begin
  LItems := Memories;
  if LItems = nil then
    Exit('');
  Result := 'O que o usuário pediu para você lembrar (use sem perguntar de novo):' + sLineBreak;
  for I := 0 to High(LItems) do
    Result := Result + Format('%d. %s', [I + 1, LItems[I]]) + sLineBreak;
  Result := Result + sLineBreak;
end;

procedure TMainForm.RegisterMemoryTools;
var
  LDef: TUIAssistantToolDef;
begin
  LDef := FIssuesPage.Assistant.Tools.Register('devbox_lembrar', 'Guarda um fato que o usuário quer que você ' +
    'lembre nas próximas conversas ("meu projeto principal é X", "lanço horas na PROJ-7"). Use quando ele ' +
    'pedir para lembrar ou disser uma preferência duradoura.',
    function(const AArgs: TJSONObject): string
    var
      LItems: TArray<string>;
      LText: string;
    begin
      LText := Copy(Trim(AArgs.GetValue<string>('fato', '').Replace(#13, ' ').Replace(#10, ' ')), 1,
        CMaxMemoryChars);
      if LText = '' then
        Exit('Faltou o fato.');
      LItems := Memories;
      if Length(LItems) >= CMaxMemories then
        Exit(Format('Já guardo %d coisas. Peça para esquecer alguma antes.', [CMaxMemories]));
      Store.SetSetting(CMemoryKey, string.Join(#10, LItems + [LText]));
      Result := 'Guardado.';
    end);
  LDef.AddParam('fato', pkString, 'O que lembrar, numa frase', True);

  LDef := FIssuesPage.Assistant.Tools.Register('devbox_esquecer', 'Apaga um item da memória pelo número ' +
    '(a lista numerada vem no começo do contexto).',
    function(const AArgs: TJSONObject): string
    var
      LItems: TArray<string>;
      LIndex: Integer;
    begin
      LItems := Memories;
      LIndex := AArgs.GetValue<Integer>('numero', 0) - 1;
      if (LIndex < 0) or (LIndex > High(LItems)) then
        Exit('Número fora da lista.');
      Delete(LItems, LIndex, 1);
      Store.SetSetting(CMemoryKey, string.Join(#10, LItems));
      Result := 'Esquecido.';
    end);
  LDef.AddParam('numero', pkInteger, 'Número do item', True);
end;

{ Ctrl+K busca também no conteúdo: clipboard e snippets, e-mails carregados e ambientes. }
procedure TMainForm.RegisterSearch;
begin
  FIssuesPage.AddSearchProvider(TFuncSearchProvider.Create('Clipboard e snippets', LineIcon(IconClipboard),
    function(AQuery: string; AMax: Integer): TUISearchHits
    var
      LClip: TClip;
    begin
      Result := nil;
      for LClip in Store.ListClips do
        if (LClip.Kind <> ckImage) and (ContainsText(LClip.Text, AQuery) or ContainsText(LClip.Abbrev, AQuery)) then
        begin
          Result := Result + [SearchHit('clip:' + IntToStr(LClip.Id), LClip.Title,
            IfThen(LClip.Pinned, 'Snippet ' + LClip.Abbrev, 'Copiado em ' + FormatDateTime('dd/mm hh:nn',
            LClip.CreatedAt)) + ' · Enter copia', LineIcon(IconClipboard),
            CopyClipProc(LClip.Text))];
          if Length(Result) >= AMax then
            Exit;
        end;
    end));
  FIssuesPage.AddSearchProvider(TFuncSearchProvider.Create('E-mail', LineIcon(IconMail),
    function(AQuery: string; AMax: Integer): TUISearchHits
    var
      LMsg: TMailMsg;
    begin
      Result := nil;
      for LMsg in FMailPage.SearchMails(AQuery, AMax) do
        Result := Result + [SearchHit('mail:' + LMsg.Id, LMsg.Subject, LMsg.FromName + ' · ' +
          FormatDateTime('dd/mm hh:nn', LMsg.Date), LineIcon(IconMail), OpenMailProc(LMsg.Id))];
    end));
  FIssuesPage.AddSearchProvider(TFuncSearchProvider.Create('Ambientes', LineIcon(IconPlay),
    function(AQuery: string; AMax: Integer): TUISearchHits
    var
      LEnv: TEnv;
    begin
      Result := nil;
      for LEnv in Store.ListEnvs do
        if ContainsText(LEnv.Name, AQuery) then
          Result := Result + [SearchHit('env:' + IntToStr(LEnv.Id), 'Ligar ' + LEnv.Name, 'Ambiente de projeto',
            LineIcon(IconPlay), RunEnvProc(LEnv.Name))];
    end));
end;

{ Cada uma num método próprio: a ação guarda o valor da volta do laço, não a variável. }
function TMainForm.CopyClipProc(const AText: string): TProc;
begin
  Result :=
    procedure
    begin
      Clipboard.AsText := AText;
      TUIToastManager.Show('Copiado', ttSuccess, 2000);
    end;
end;

function TMainForm.OpenMailProc(const AId: string): TProc;
begin
  Result :=
    procedure
    begin
      ShowPage('mail');
      FMailPage.OpenMessage(AId);
    end;
end;

function TMainForm.RunEnvProc(const AName: string): TProc;
begin
  Result :=
    procedure
    var
      LEnv: TEnv;
    begin
      ShowPage('envs');
      if FindEnv(AName, LEnv) then
        FEnvsPage.Run(LEnv, False);
    end;
end;

function TMainForm.ScreenContext: string;
begin
  if FActive = nil then
    Exit('');
  Result := 'Tela aberta no Devbox: ' + FActive.Caption + '.';
  if FActive.PageContext <> '' then
    Result := Result + sLineBreak + HideSecrets(FActive.PageContext);
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
