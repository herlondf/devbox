unit Devbox.Issues.UI.Main;

interface

uses
  System.Classes,
  System.SysUtils,
  System.JSON,
  System.Types,
  System.Generics.Collections,
  System.Notification,
  System.Skia,
  Winapi.Messages,
  Vcl.Controls,
  Vcl.Forms,
  Vcl.Menus,
  Vcl.ExtCtrls,
  Devbox.UI.Kit,
  UI.Theme,
  UI.Tokens,
  UI.Button,
  UI.Input,
  UI.Select,
  UI.Swap,
  UI.Status,
  UI.Dropdown,
  UI.Kbd,
  UI.Labels,
  UI.Alert,
  UI.FilterChip,
  UI.EmptyState,
  UI.Skeleton,
  UI.ProgressBar,
  UI.Tabs,
  UI.Toggle,
  UI.NumberInput,
  UI.ContextMenu,
  UI.CommandPalette,
  UI.VirtualList,
  UI.ScrollArea,
  UI.Assistant,
  UI.Animations,
  UI.PageTransition,
  UI.CommandSearch,
  UI.Assistant.Types,
  UI.RadialProgress,
  UI.TimePicker,
  UI.Stat,
  UI.Sparkline,
  Devbox.Issues.AI,
  Devbox.Issues.Model,
  Devbox.Issues.UI.Common,
  Devbox.Issues.UI.Views,
  Devbox.Issues.UI.Detail,
  Devbox.Issues.UI.Mini,
  Devbox.Issues.Update,
  Devbox.UI.SidePeek;

type
  TItemFilter = (ifNow, ifMine, ifOverdue, ifReview, ifManual, ifFlagged, ifMyPrs, ifSprint);
  TPage = (pgDashboard, pgIssues, pgAccounts, pgSettings);

  TIssueCountsProc = reference to procedure(AUnread: Integer; AOverdue: Boolean);

  TIssuesPage = class(TDevPage)
  private
    FTray: TTrayIcon;
    FTrayMenu: TPopupMenu;
    FAutostartItem: TMenuItem;
    FMiniItem: TMenuItem;
    FMini: TMiniForm;                // janela mini (sempre por cima)
    FHotkeyToggle: TUIToggle;
    FUpdateItem: TMenuItem;          // "Atualizar para x.y.z", só com versão nova
    FUpdate: TUpdateInfo;            // última release mais nova encontrada
    FUpdateBusy: Boolean;
    FUpdateMode: TUISelect;
    FUpdateBtn: TUIButton;
    FNotifier: TNotificationCenter;
    // Shell
    FTabs: TUITabs;
    FStatusDot: TUIStatus;
    FFooter: TPanel;               // atalhos; igual em todas as abas (FAB não pula)
    FHoursLabel: TUILabel;         // Jira: horas lançadas hoje e na semana
    FHoursToday, FHoursWeek: Double;
    FTabBadges: string;            // contadores com que as abas foram montadas
    FFetchingRate: Boolean;        // cotação do dólar em andamento
    FAccountBtn: TUIButton;
    FRepoBtn: TUIButton;            // filtro de repositório (GitHub), vale para Issues e Dashboard
    FRepoMenu: TUIDropdown;
    FRepoFilter: string;            // 'dono/repo'; vazio = todos
    FAccountMenu: TUIDropdown;
    FAccountFilter: Integer;  // 0 = todas as contas
    FPollMs: Integer;         // cache do intervalo de busca
    FNextRing: TUIRadialProgress;
    FTransition: TUIPageTransition;
    FDetailAnim: TUIAnimation;
    FFlashAnim: TUIAnimation;
    FFlashValue: Single;
    FFlashKeys: TDictionary<string, Boolean>;  // 'conta|CHAVE' mudou nesta busca
    FNewKeys: TDictionary<string, Boolean>;    // 'conta|CHAVE' apareceu nesta busca
    FMuted: TDictionary<string, Boolean>;
    FAccountsBox: TUIScrollArea;
    FPending: TArray<TIssueEvent>;                  // avisos segurados pelo "não perturbe"
    FLastMinuteCheck: Integer;
    FSummaryToggle: TUIToggle;
    // IA automática (tudo desligado por padrão)
    FAiCap: TUINumberInput;
    FAiCheap: TUIInput;
    FAiAuto: array[0..4] of TUIToggle;  // resumo, risco, rascunho de horas, causa do CI, triagem
    FSummaryTime: TUITimePicker;
    FDndToggle: TUIToggle;
    FDndStart: TUITimePicker;
    FDndEnd: TUITimePicker;
    FAiProvider: TUISelect;
    FAiBaseUrl: TUIInput;
    FAiModel: TUIInput;
    FAiModelsBtn: TUIButton;
    FAiModelsMenu: TUIDropdown;
    FAiPriceIn: TUINumberInput;
    FAiPriceOut: TUINumberInput;
    FAiStats: array[0..3] of TUIStat;
    FAiCostSpark: TUISparkline;
    FAiLoading: Boolean;
    FThemeSwap: TUISwap;
    FProgress: TUIProgressBar;
    FPalette: TUICommandPalette;
    FAssistant: TUIAssistant;
    FAiCards: TArray<TControl>;
    FAssistantHost: TWinControl;    // posto pela janela principal (canto do rodapé): PlaceAssistant não mexe
    FOnScreenContext: TFunc<string>;
    FOnPaletteCommands: TProc<TUICommandPalette>;
    FDetached: Boolean;              // painel, contas e preferências foram para outras telas
    FOnNavigate: TProc<Integer>;     // 0 painel, 2 contas, 3 preferências: a principal mostra onde estão
    FPages: array[TPage] of TPanel;
    FContent: TPanel;
    FPage: TPage;
    // Issues
    FAlert: TUIAlert;
    FChips: array[TItemFilter] of TUIFilterChip;
    FTags: TTags;
    FTagBar: TPanel;
    FTagChips: TArray<TUIFilterChip>;   // um por tag, na ordem de FTags
    FTagHint: TUILabel;
    FTagMenu: TUIContextMenu;           // submenu "Tag": gerenciar + uma linha por tag
    FActionMenu: TUIContextMenu;        // submenu "Ações": escrita no Jira/GitHub
    FItemsList: TUIVirtualList;
    FItemsEmpty: TUIEmptyState;
    FSkeleton: TPanel;
    FItemMenu: TUIContextMenu;
    FDetail: TDetailPanel;
    FDetailPeek: TSidePeek;          // o detalhe abre ao lado da janela, como o e-mail
    // Outras visões
    FDashboard: TDashboardView;
    FDrill: TDrill;                 // filtro vindo de um card do Dashboard
    FDrillChip: TUIFilterChip;      // mostra o FDrill; clicar remove
    FAutostartToggle: TUIToggle;
    FPollMinutes: TUINumberInput;
    FThemeSelect: TUISelect;
    FLangSelect: TUISelect;
    FNotifyStyle: TUISelect;
    FSettingsScroll: TUIScrollArea;
    FSettingsColumn: TPanel;
    FNotifySeconds: TUINumberInput;
    FAccountsList: TUIVirtualList;
    FAccountsEmpty: TUIEmptyState;
    FApiKey: TUIInput;
    // Estado
    FAccounts: TArray<TAccount>;
    FAccountErrors: TDictionary<Integer, string>;
    FAll: TItems;
    FShown: TItems;
    FGroupChip: TUIFilterChip;      // agrupar a lista por repositório/projeto
    FCollapsed: TDictionary<string, Boolean>;  // grupos recolhidos
    FShownTone: TArray<Integer>;
    FShownBadges: TArray<TBadges>;
    FShownTag: TArray<string>;
    FManual: TDictionary<string, Boolean>;
    FTimer: TTimer;
    FClock: TTimer;
    FNextPoll: TDateTime;
    FLastPoll: TDateTime;
    FPolling: Boolean;
    FPollAll: Boolean;              // próxima busca ignora o intervalo de cada conta
    FOnCounts: TIssueCountsProc;
    FOnShowRequest, FOnHideRequest, FOnAutostartChanged, FOnExitRequest: TNotifyEvent;
    FStatusText: string;
    FQuietCheck: TFunc<Boolean>;
    FToastSeq: Integer;
    FToastUrls: TDictionary<string, string>;
    FLastUrl: string;
    FUnread: Integer;
    FOverdue: Boolean;
    FDueSoon: Boolean;
    FNewsUntil: TDateTime;          // até quando o mascote comemora novidade
    FMascotFile: string;
    FApplyingSize: Boolean;
    FUndoAccount: Integer;
    FUndoKey: string;
    // Montagem
    procedure BuildTray;
    procedure BuildShell;
    procedure BuildItemsPage;
    procedure BuildAccountsPage;
    procedure BuildSettingsPage;
    procedure BuildAssistant;
    procedure AssistantStateChange(Sender: TObject; AState: TUIAssistantState);
    function NewPanel(AParent: TWinControl; AAlign: TAlign; AHeight: Integer = 0): TPanel;
    function NewList(AParent: TWinControl; ARowHeight: Integer): TUIVirtualList;
    procedure ApplyThemeColors;
    procedure ApplyCompactSize;
    // Navegação
    procedure ShowPage(APage: TPage);
    procedure TabChange(Sender: TObject; AIndex: Integer);
    procedure LoadAiSettings;
    procedure AiSettingChange(Sender: TObject);
    procedure AiAutoChange(Sender: TObject);
    procedure RegisterAiTools;
    procedure ToolItem(const AArgs: TJSONObject; out AItem: TItem; out AAccount: TAccount);
    function FindItem(const AKey: string; out AItem: TItem; out AAccount: TAccount): Boolean;
    function BuildAiContext: string;
    procedure ExplainCiFailure(const AItem: TItem);
    procedure RunAutoAi;
    procedure TriageItems(const AItems: TItems; AManual: Boolean);
    procedure ApplyTriage(const AItem: TItem);
    procedure AiListModelsClick(Sender: TObject);
    procedure AiModelPicked(Sender: TObject; const AID: string);
    procedure UpdateAiUsage;
    procedure RefreshUsdBrl;
    procedure UpdateMascotMood;
    procedure DetailChanged(Sender: TObject);
    procedure SetDetailVisible(AShow: Boolean);
    function DetailOpen: Boolean;
    procedure EnsureDetailPeek;
    procedure FlashChanges(const AKeys: TArray<string>);
    procedure AccountCardClick(Sender: TObject);
    procedure ItemsMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
    procedure CheckSchedules;
    procedure CheckForUpdate(AManual: Boolean);
    procedure StartUpdate(AShow: Boolean);
    procedure UpdateMenuClick(Sender: TObject);
    procedure MiniMenuClick(Sender: TObject);
    procedure MiniClosed(Sender: TObject);
    procedure UpdateMini;
    procedure SetHotkey(AOn: Boolean);
    procedure NotifyMute(const AKey: string; AAccountId: Integer);
    procedure NotifyReply(const AKey: string; AAccountId: Integer; const AText: string);
    procedure UpdateBtnClick(Sender: TObject);
    procedure ExportClick(Sender: TObject);
    procedure ImportClick(Sender: TObject);
    function InQuietHours: Boolean;
    function KeyOf(const AItem: TItem): string;
    procedure AccountMenuClick(Sender: TObject; const AID: string);
    procedure AccountBtnClick(Sender: TObject);
    procedure RebuildAccountMenu;
    function InFilter(AAccountId: Integer): Boolean;
    function ItemInView(const AItem: TItem): Boolean;
    procedure RebuildRepoMenu;
    procedure RepoBtnClick(Sender: TObject);
    procedure RepoMenuClick(Sender: TObject; const AID: string);
    procedure SetRepoFilter(const ARepo: string);
    procedure ReloadTags;
    function FilteredItems: TItems;
    procedure PlaceAssistant;
    procedure ClipAssistant;
    procedure SettingsResize(Sender: TObject);
    procedure TestNotifyClick(Sender: TObject);
    procedure GeneralSettingChange(Sender: TObject);
    function PollIntervalMs: Integer;
    procedure RebuildPalette;
    procedure PaletteSelect(Sender: TObject; const AID: string);
    // Dados na tela
    procedure ReloadAccounts;
    procedure LoadItems;
    procedure ApplyFilters;
    procedure UpdateViews;
    procedure UpdateHeader;
    procedure UpdateBadges;
    procedure UpdateTrayIcon;
    procedure UpdateAssistantContext;
    function AccountById(AId: Integer; out AAccount: TAccount): Boolean;
    function IsManual(const AItem: TItem): Boolean;
    function SelectedItem(out AItem: TItem): Boolean;
    procedure OpenDetail(const AItem: TItem);
    // Eventos
    procedure FilterChanged(Sender: TObject);
    procedure RegroupShown;
    procedure ClearFiltersClick(Sender: TObject);
    function IsGroupRow(AIndex: Integer): Boolean;
    procedure DrawGroupRow(AIndex: Integer; const ACanvas: ISkCanvas; const ARowRect: TRectF);
    procedure RebuildTagChips;
    procedure TagMenuClick(Sender: TObject; const AID: string);
    procedure FillTagMenu(const AItem: TItem);
    function NewRowLabel(AParent: TWinControl; const ACaption: string): TUILabel;
    procedure ItemsDraw(Sender: TObject; AIndex: Integer; const AItem: TUIVListItem;
      const ACanvas: ISkCanvas; const ARowRect: TRectF);
    procedure ItemsClick(Sender: TObject; AIndex: Integer; const AItem: TUIVListItem);
    procedure ItemsDblClick(Sender: TObject; AIndex: Integer; const AItem: TUIVListItem);
    procedure ItemsMouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
    procedure ItemMenuClick(Sender: TObject; const AID: string);
    procedure ViewOpenItem(Sender: TObject; const AItem: TItem);
    procedure DashboardDrill(Sender: TObject; const ADrill: TDrill);
    procedure DrillChipToggle(Sender: TObject);
    function DrillPass(const AItem: TItem): Boolean;
    procedure NotifyOpenDetail(const AKey: string; AAccountId: Integer);
    procedure DetailClose(Sender: TObject);
    procedure CopyKey(const AItem: TItem);
    procedure RunAction(const AItem: TItem; const ADone: string; const AWork: TProc<TAccount, string>);
    procedure FillActionMenu(const AItem: TItem);
    procedure Unwatch(const AItem: TItem);
    procedure UndoUnwatch(Sender: TObject);
    procedure WatchKey(const AText: string);
    procedure BuildFooter;
    procedure FormKeyDownEsc;
    procedure NewAccountClick(Sender: TObject);
    procedure RefreshClick(Sender: TObject);
    procedure SaveApiKeyClick(Sender: TObject);
    procedure AlertDismiss(Sender: TObject);
    procedure AutostartClick(Sender: TObject);
    procedure ThemeSwapToggle(Sender: TObject);
    procedure FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    // Busca e avisos
    procedure Poll(AManual: Boolean);
    procedure TimerTick(Sender: TObject);
    procedure ClockTick(Sender: TObject);
    procedure ToastClicked(Sender: TObject; ANotification: TNotification);
    procedure BalloonClick(Sender: TObject);
    // Janela e tray
    procedure TrayDblClick(Sender: TObject);
    procedure MenuOpenClick(Sender: TObject);
    procedure ThemeChanged(Sender: TObject; AMode: TUIThemeMode);
    procedure MigrateVigiaApp;
  protected
    procedure CreateWnd; override;
    procedure WndProc(var Message: TMessage); override;
    procedure DestroyWnd; override;
  public
    function PageKey(var AKey: Word; AShift: TShiftState): Boolean; override;
    procedure PageRefresh; override;
    procedure PageHidden; override;
    function PageShortcuts: TArray<TDevShortcut>; override;
    { Cartões da config de IA (provedor, IA automática, uso): a janela principal
      leva para Configuração › IA. Os eventos continuam aqui. }
    function TakeAiSettings: TArray<TControl>;
    { Comandos da janela principal (telas, foco, pomodoro...): entram na paleta a cada reconstrução. }
    property OnPaletteCommands: TProc<TUICommandPalette> read FOnPaletteCommands write FOnPaletteCommands;
    procedure RefreshPalette;
    procedure OpenPalette;
    { Números do cartão de uso da IA (ele mora em Configuração › IA › Custos). }
    procedure RefreshAiUsage;
    { Assistente da janela inteira: a principal registra ferramentas nele. }
    property Assistant: TUIAssistant read FAssistant;
    { Entrega o painel (Dashboard), as contas e as preferências para outras telas. A tela Issues
      fica só com a lista; pedir uma das outras chama OnNavigate (0 painel, 2 contas, 3 preferências). }
    procedure DetachPages(out ADashboard, AAccounts, ASettings: TControl);
    { Abre a issue na lista (clique no Hoje). }
    procedure OpenIssue(const AItem: TItem);
    property OnNavigate: TProc<Integer> read FOnNavigate write FOnNavigate;
    { Tela da frente no Devbox (nome e o que está aberto): entra no prompt do assistente. }
    property OnScreenContext: TFunc<string> read FOnScreenContext write FOnScreenContext;
    { Issues abertas das contas ligadas, do último retrato (para a voz). Thread de UI. }
    function OpenItems: TItems;
    { O FAB do assistente fica na tela da frente (AHost); nas Issues, a própria tela posiciona. }
    procedure AttachAssistant(AHost: TWinControl; ARight, ABottom: Integer);
    { "Procurar agora" de Configuração › Geral: procura (ou instala a que já achou). }
    procedure CheckUpdatesNow;
    { Ícone da bandeja do Devbox (balão quando o toast do Windows falha). }
    property Tray: TTrayIcon read FTray write FTray;
    { Não lidos e se há algo vencido: a janela principal desenha o contador na bandeja. }
    property OnCounts: TIssueCountsProc read FOnCounts write FOnCounts;
    { Win+Alt+V e "Abrir" pedem a janela principal com esta tela na frente. }
    property OnShowRequest: TNotifyEvent read FOnShowRequest write FOnShowRequest;
    property OnHideRequest: TNotifyEvent read FOnHideRequest write FOnHideRequest;
    property OnAutostartChanged: TNotifyEvent read FOnAutostartChanged write FOnAutostartChanged;
    { True = segurar avisos agora (modo foco do Devbox). }
    property QuietCheck: TFunc<Boolean> read FQuietCheck write FQuietCheck;
    { O atualizador abriu o instalador: a janela principal sai. }
    property OnExitRequest: TNotifyEvent read FOnExitRequest write FOnExitRequest;
    { Itens, hora da última busca e erro, para a dica da bandeja. }
    property StatusText: string read FStatusText;
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure Notify(const ATitle, ABody: string; const AUrl: string = '';
      ATone: TUISemanticTone = stInfo; const AKey: string = ''; AAccountId: Integer = 0);
  end;

var
  MainForm: TIssuesPage;

implementation

uses
  Devbox.Model,
  Devbox.Sys,
  Devbox.I18n,
  Winapi.Windows,
  Winapi.ShellAPI,
  System.StrUtils,
  System.Math,
  System.DateUtils,
  System.Threading,
  System.Generics.Defaults,
  System.Win.Registry,
  Vcl.Dialogs,
  UI.Assistant.Tools,
  Vcl.Clipbrd,
  UI.Fonts,
  UI.Painter,
  UI.Painter.Vcl,
  UI.Toast,
  UI.Card,
  UI.NumberTween,
  UI.Avatar,
  UI.PageTransition.Vcl,
  UI.Icons.Heroicons,
  Devbox.Issues.Store,
  System.IOUtils,
  Devbox.Secrets,
  Devbox.Issues.Providers,
  Devbox.Issues.Diff,
  Devbox.Issues.TrayIcon,
  Devbox.Issues.UI.Account,
  Devbox.Issues.UI.Status,
  Devbox.Issues.UI.Tags,
  Devbox.Issues.UI.Notify,
  Devbox.Issues.Backup;

const
  AiAutoKeys: array[0..4] of string = ('ai_daily', 'ai_risk', 'ai_eod', 'ai_ci', 'ai_triage');
  // ponytail: intervalo fixo e sem backoff; virar config por conta se o rate limit apertar.
  DefaultPollMinutes = 5;
  DefaultNotifySeconds = 8;
  FirstPollMs = 3 * 1000;
  MaxToastsPerPoll = 4;
  RunKey = 'Software\Microsoft\Windows\CurrentVersion\Run';
  AssistantSecret = 'Vigia:anthropic';
  AssistantModel = 'claude-sonnet-5-5';
  DetailWidth = 380;
  FilterNames: array[TItemFilter] of string = ('Agora', 'Comigo', 'Atrasadas', 'Review', 'Manuais', 'Impedidas', 'Meus PRs', 'Sprint');
  FilterTones: array[TItemFilter] of TUIBadgeTone = (btError, btPrimary, btError, btInfo, btWarning, btError, btSuccess, btInfo);
  PageTitles: array[TPage] of string = ('Dashboard', 'Issues', 'Contas', 'Configurações');

type
  // FirstVisible/RowRect/OnMouseDown são protected.
  TListAccess = class(TUIVirtualList);
  // OnClick é protected no TControl.
  TClickAccess = class(TControl);

  { Ctrl+K: texto com cara de chave (PROJ-123, dono/repo#12) vira "Acompanhar". }
  TWatchProvider = class(TInterfacedObject, IUICommandSearchProvider)
    function GroupName: string;
    function GroupIconSvg: string;
    function Search(const AQuery: string; AMaxResults: Integer): TUISearchHits;
  end;

function TWatchProvider.GroupName: string;
begin
  Result := Tr('Acompanhar');
end;

function TWatchProvider.GroupIconSvg: string;
begin
  Result := HeroIcon('squares-plus');
end;

function TWatchProvider.Search(const AQuery: string; AMaxResults: Integer): TUISearchHits;
const
  Kinds: array[TKeyFamily] of string = ('', 'Issue/PR do GitHub ou GitLab', 'Issue do Jira',
    'Work item do Azure DevOps');
var
  Key: string;
  Family: TKeyFamily;
  H: TUISearchHit;
begin
  Result := nil;
  Key := NormalizeManualKey(AQuery, Family);
  if Key = '' then
    Exit;
  H := Default(TUISearchHit);
  H.ID := 'watch:' + Key;
  H.Title := Tr('Acompanhar ') + Key;
  H.Subtitle := Kinds[Family] + Tr(' · entra na lista mesmo sem ser sua');
  H.IconSvg := HeroIcon('squares-plus');
  H.Score := 1000;
  Result := [H];
end;

type
  TPollResult = record
    Account: TAccount;
    ManualKeys: TArray<string>;
    Items: TItems;
    Me: TIdentity;
    Error: string;
  end;

var
  ExitRequested: Boolean;

procedure OpenUrl(const AUrl: string);
begin
  if AUrl <> '' then
    ShellExecute(0, 'open', PChar(AUrl), nil, nil, SW_SHOWNORMAL);
end;

function Sp(AValue: Single): Integer;
begin
  Result := Round(AValue);
end;

{ Horário 'hh:nn' guardado nas preferências. }
function TimeSetting(const AName, ADefault: string): TDateTime;
begin
  Result := StrToTimeDef(IssueStore.GetSetting(AName, ADefault), StrToTime(ADefault));
end;

function IsOverdue(const AItem: TItem): Boolean;
begin
  Result := (AItem.DueDate > 0) and (DateOf(AItem.DueDate) < Date);
end;

{ Pede ação hoje: vence hoje ou venceu, menção, review pedido, PR meu com CI
  vermelho ou mudanças pedidas, ou issue minha impedida. }
function NeedsActionNow(const AItem: TItem): Boolean;
begin
  Result := ((AItem.DueDate > 0) and (DateOf(AItem.DueDate) <= Date)) or AItem.MentionsMe or
    (isReview in AItem.Sources) or
    ((isMine in AItem.Sources) and (MatchText(AItem.CiState, ['FAILURE', 'ERROR']) or
      SameText(AItem.ReviewState, 'CHANGES_REQUESTED'))) or
    (AItem.Flagged and (isAssigned in AItem.Sources));
end;

{ ── Criação ─────────────────────────────────────────────────────────────── }

constructor TIssuesPage.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FRefreshable := True;
  // O código do Vigia monta a tela precisando de janela (assistente, atalho): já nasce dentro
  // da janela principal; o AddPage do Devbox move para a área das telas depois.
  if AOwner is TWinControl then
    Parent := TWinControl(AOwner);
  // Idioma da tela de Issues (vale para o que for criado depois).
  SetLanguage(IssueStore.GetSetting('lang'));
  Caption := Tr('Issues');
  MigrateVigiaApp;
  Hint := Tr('GitHub, Jira, GitLab e Azure DevOps: o que é seu, o que mudou e o que vence');
  DoubleBuffered := True;
  RegisterVigiaAiProvider;
  FAccountFilter := StrToIntDef(IssueStore.GetSetting('account_filter'), 0);

  FToastUrls := TDictionary<string, string>.Create;
  FManual := TDictionary<string, Boolean>.Create;
  FAccountErrors := TDictionary<Integer, string>.Create;
  FFlashKeys := TDictionary<string, Boolean>.Create;
  FNewKeys := TDictionary<string, Boolean>.Create;
  FMuted := TDictionary<string, Boolean>.Create;
  FTransition := TUIPageTransition.Create;
  FTransition.Style := ttSlide;
  FNotifier := TNotificationCenter.Create(Self);
  FNotifier.OnReceiveLocalNotification := ToastClicked;
  TUIToastManager.Position := tpBottomRight;
  TNotifyManager.OnOpenDetail := NotifyOpenDetail;
  TNotifyManager.OnMute := NotifyMute;
  TNotifyManager.OnReply := NotifyReply;
  // Janela mini aberta da última vez volta aberta.
  if IssueStore.GetSetting('mini_on') = '1' then
    ForceQueueUI( procedure begin MiniMenuClick(nil); end);

  BuildTray;
  BuildShell;
  BuildItemsPage;
  BuildAccountsPage;
  BuildSettingsPage;
  BuildAssistant;
  ApplyThemeColors;
  ReloadAccounts;
  LoadItems;
  ShowPage(pgDashboard);

  UITheme.AddChangeListener(ThemeChanged);

  FTimer := TTimer.Create(Self);
  FTimer.Interval := FirstPollMs;
  FPollAll := True;
  FTimer.OnTimer := TimerTick;
  FNextPoll := Now + FirstPollMs / MSecsPerDay;
  FTimer.Enabled := True;

  FClock := TTimer.Create(Self);
  FClock.Interval := 1000;
  FClock.OnTimer := ClockTick;
  FClock.Enabled := True;
end;

destructor TIssuesPage.Destroy;
begin
  UITheme.RemoveChangeListener(ThemeChanged);
  FToastUrls.Free;
  FManual.Free;
  FAccountErrors.Free;
  FFlashKeys.Free;
  FNewKeys.Free;
  FMuted.Free;
  FTransition.Free;
  FDetailAnim.Free;
  FFlashAnim.Free;
  inherited;
end;

const
  HotkeyId = 1;

procedure TIssuesPage.WndProc(var Message: TMessage);
begin
  if (Message.Msg = WM_HOTKEY) and (Message.WParam = HotkeyId) then
  begin
    // Atalho global alterna: na frente, esconde; senão, traz.
    if Visible and (GetForegroundWindow = GetAncestor(Handle, GA_ROOT)) then
    begin
      if Assigned(FOnHideRequest) then
        FOnHideRequest(Self);
    end
    else
      MenuOpenClick(nil);
  end
  else
    inherited;
end;

procedure TIssuesPage.DestroyWnd;
begin
  UnregisterHotKey(Handle, HotkeyId);
  inherited;
end;

{ Win+Alt+V em qualquer lugar abre ou esconde o Vigia. Outro programa já com
  a combinação: fica sem atalho e a opção avisa. }
procedure TIssuesPage.SetHotkey(AOn: Boolean);
const
  MOD_NOREPEAT = $4000;
begin
  if not HandleAllocated then
    Exit;
  UnregisterHotKey(Handle, HotkeyId);
  if AOn and not RegisterHotKey(Handle, HotkeyId, MOD_WIN or MOD_ALT or MOD_NOREPEAT, Ord('V')) then
    TUIToastManager.Show(Tr('Win+Alt+V já está em uso por outro programa'), ttWarning, 6000);
end;

procedure TIssuesPage.CreateWnd;
begin
  inherited;
  SetHotkey(IssueStore.GetSetting('hotkey_on', '1') = '1');
end;

function TIssuesPage.NewPanel(AParent: TWinControl; AAlign: TAlign; AHeight: Integer): TPanel;
begin
  Result := TPanel.Create(Self);
  Result.BevelOuter := bvNone;
  Result.ParentBackground := False;
  Result.DoubleBuffered := True;
  if AHeight > 0 then
    Result.Height := ScaleValue(AHeight);
  Result.Align := AAlign;
  Result.Parent := AParent;
end;

function TIssuesPage.NewList(AParent: TWinControl; ARowHeight: Integer): TUIVirtualList;
begin
  Result := TUIVirtualList.Create(Self);
  Result.RowHeight := ARowHeight;
  Result.AlignWithMargins := True;
  Result.Margins.SetBounds(Sp(UITheme.Tokens.Spacing.S2), 0, Sp(UITheme.Tokens.Spacing.S2),
    Sp(UITheme.Tokens.Spacing.S2));
  Result.Align := alClient;
  Result.Parent := AParent;
end;

{ Os TPanel VCL não ouvem o tema; a cor vem daqui. }
procedure TIssuesPage.ApplyThemeColors;

  procedure Paint(AControl: TWinControl);
  var
    I: Integer;
  begin
    if (AControl is TPanel) and (AControl.Tag = 1) then
      TPanel(AControl).Color := UIAlphaToVclColor(UITheme.Tokens.Color.Border)
    else if (AControl is TPanel) and not TPanel(AControl).ParentBackground then
      TPanel(AControl).Color := UIThemeVclBackground;
    for I := 0 to AControl.ControlCount - 1 do
      if AControl.Controls[I] is TWinControl then
        Paint(TWinControl(AControl.Controls[I]));
  end;

begin
  Color := UIThemeVclBackground;
  Paint(Self);
end;

{ Campos, seleção e botões com 36 px (o preset da suíte é 50). A troca de tema
  reconstrói os tokens a partir do preset, então reaplica depois de cada troca. }
procedure TIssuesPage.ApplyCompactSize;
begin
  // Dentro do Devbox os campos têm o tamanho do Devbox: o Vigia mudava o tema global.
end;

procedure TIssuesPage.BuildTray;

  function AddItem(const ACaption: string; AOnClick: TNotifyEvent): TMenuItem;
  begin
    Result := TMenuItem.Create(FTrayMenu);
    Result.Caption := ACaption;
    Result.OnClick := AOnClick;
    FTrayMenu.Items.Add(Result);
  end;

begin
  FTrayMenu := TPopupMenu.Create(Self);
  AddItem(Tr('Abrir'), MenuOpenClick).Default := True;
  AddItem(Tr('Atualizar agora'), RefreshClick);
  FAutostartItem := AddItem(Tr('Iniciar com o Windows'), AutostartClick);
  FAutostartItem.Checked := AutostartEnabled;
  FMiniItem := AddItem(Tr('Janela mini'), MiniMenuClick);
  FUpdateItem := AddItem(Tr('Atualizar o Devbox'), UpdateMenuClick);
  FUpdateItem.Visible := False;

  // O ícone da bandeja é o do Devbox (Tray, atribuído pela janela principal).
end;

{ Menu lateral + cabeçalho + barra de progresso + uma página por item do menu. }
procedure TIssuesPage.BuildShell;
var
  S: TUISpacingTokens;
  Bar: TPanel;
  P: TPage;
begin
  S := UITheme.Tokens.Spacing;

  FContent := NewPanel(Self, alClient);

  Bar := NewPanel(FContent, alTop, 60);
  Bar.Padding.SetBounds(0, 0, Sp(S.S4), 0);

  // Direita: buscar (Ctrl+K), conta, tema. Esquerda: estado + contagem.
  FThemeSwap := TUISwap.Create(Self);
  FThemeSwap.SvgOff := HeroIcon(hiSun);
  FThemeSwap.SvgOn := HeroIcon(hiMoon);
  FThemeSwap.SwapType := stRotate;
  FThemeSwap.Size := 36;
  FThemeSwap.Checked := UITheme.IsDark;
  FThemeSwap.Hint := Tr('Tema claro/escuro');
  FThemeSwap.TabStop := False;  // o anel de foco pontilhado parecia falha no desenho
  FThemeSwap.ShowHint := True;
  FThemeSwap.OnToggle := ThemeSwapToggle;
  FThemeSwap.AlignWithMargins := True;
  FThemeSwap.Margins.SetBounds(Sp(S.S2), 12, 0, 12);
  FThemeSwap.Left := 3000;  // alRight: maior Left fica mais à direita
  FThemeSwap.Align := alRight;
  FThemeSwap.Parent := Bar;
  FThemeSwap.Visible := False;   // o tema é do Devbox

  // Seletor de conta discreto: botão fantasma + menu da suíte.
  FAccountBtn := TUIButton.Create(Self);
  FAccountBtn.Variant := bvGhost;
  // Largura fixa: com AutoWidth a troca de conta mudava a largura e o VCL
  // reordenava os controles alRight do cabeçalho.
  FAccountBtn.Width := ScaleValue(200);
  FAccountBtn.Hint := Tr('Conta exibida em todas as telas e no Ctrl+K');
  FAccountBtn.ShowHint := True;
  FAccountBtn.OnClick := AccountBtnClick;
  FAccountBtn.AlignWithMargins := True;
  FAccountBtn.Margins.SetBounds(Sp(S.S2), 12, 0, 12);
  FAccountBtn.Left := 2000;
  FAccountBtn.Align := alRight;
  FAccountBtn.Parent := Bar;
  FRepoBtn := TUIButton.Create(Self);
  FRepoBtn.Variant := bvGhost;
  FRepoBtn.Width := ScaleValue(240);
  FRepoBtn.Hint := Tr('Repositório exibido em Issues e no Dashboard');
  FRepoBtn.ShowHint := True;
  FRepoBtn.OnClick := RepoBtnClick;
  FRepoBtn.AlignWithMargins := True;
  FRepoBtn.Margins.SetBounds(Sp(S.S2), 12, 0, 12);
  FRepoBtn.Left := 1500;
  FRepoBtn.Align := alRight;
  FRepoBtn.Visible := False;
  FRepoBtn.Parent := Bar;
  FRepoMenu := TUIDropdown.Create(Self);
  FRepoMenu.AnchorControl := FRepoBtn;
  FRepoMenu.AnchorPos := dapBottomRight;
  FRepoMenu.MaxHeight := 420;
  FRepoMenu.PopupWidth := 360;
  FRepoMenu.OnItemClick := RepoMenuClick;
  FRepoFilter := IssueStore.GetSetting('repo_filter');
  FAccountMenu := TUIDropdown.Create(Self);
  FAccountMenu.AnchorControl := FAccountBtn;
  FAccountMenu.AnchorPos := dapBottomRight;
  FAccountMenu.OnItemClick := AccountMenuClick;

  // Anel fino que esvazia até a próxima busca, com a bolinha de estado dentro.
  FNextRing := TUIRadialProgress.Create(Self);
  FNextRing.RingSize := 22;
  FNextRing.StrokeWidth := 2;
  FNextRing.ShowPercent := False;
  FNextRing.AnimateValue := False;
  FNextRing.Max := 100;
  FNextRing.Width := ScaleValue(26);
  FNextRing.AlignWithMargins := True;
  FNextRing.Margins.SetBounds(Sp(S.S4), 17, Sp(S.S2), 17);
  FNextRing.Align := alLeft;
  FNextRing.Parent := Bar;
  FStatusDot := TUIStatus.Create(Self);
  FStatusDot.Status := sdOnline;
  FStatusDot.Size := sdsSM;
  FStatusDot.Parent := FNextRing;
  FStatusDot.SetBounds(ScaleValue(7), ScaleValue(7), ScaleValue(12), ScaleValue(12));

  // Detalhe (itens, última e próxima busca) fica na dica do anel.
  FNextRing.ShowHint := True;

  FTabs := TUITabs.Create(Self);
  FTabs.AlignWithMargins := True;
  FTabs.Margins.SetBounds(Sp(S.S4), 0, Sp(S.S4), 0);
  FTabs.Parent := FContent;
  FTabs.Top := Bar.Top + Bar.Height + 1;
  FTabs.Align := alTop;
  UpdateBadges;

  // Linha fina animada só enquanto busca.
  FProgress := TUIProgressBar.Create(Self);
  FProgress.Indeterminate := True;
  FProgress.TrackHeight := 3;
  FProgress.Height := 3;
  FProgress.Visible := False;
  FProgress.Parent := FContent;
  FProgress.Top := FTabs.Top + FTabs.Height + 1;
  FProgress.Align := alTop;

  for P := Low(TPage) to High(TPage) do
  begin
    FPages[P] := NewPanel(FContent, alClient);
    FPages[P].Visible := False;
  end;
  BuildFooter;
  FFooter.Height := ScaleValue(43);
  FProgress.Parent := FFooter;
  FProgress.Align := alBottom;

  FDashboard := TDashboardView.Create(Self);
  FDashboard.OnOpenItem := ViewOpenItem;
  FDashboard.OnDrill := DashboardDrill;
  FDashboard.OnAddAccount := NewAccountClick;
  FDashboard.Parent := FPages[pgDashboard];

  FPalette := TUICommandPalette.Create(Self);
  FPalette.Shortcut := Tr('Ctrl+K');
  FPalette.Placeholder := Tr('Buscar tela, comando ou issue...');
  FPalette.OnItemSelect := PaletteSelect;
  FPalette.AddProvider(TWatchProvider.Create);
end;

procedure TIssuesPage.BuildItemsPage;
var
  S: TUISpacingTokens;
  Page, Bar: TPanel;
  F: TItemFilter;
  I: Integer;
  Sk: TUISkeletonLoader;
  SkRow: TPanel;
begin
  S := UITheme.Tokens.Spacing;
  Page := FPages[pgIssues];

  FDetail := TDetailPanel.Create(Self);
  // Mora no painel lateral (SetDetailVisible cria na primeira vez).
  FDetail.Width := ScaleValue(DetailWidth);
  FDetail.OnClose := DetailClose;
  FDetail.OnChanged := DetailChanged;
  FDetail.Align := alClient;

  FAlert := TUIAlert.Create(Self);
  FAlert.Tone := atError;
  FAlert.Style_ := asSoft;
  FAlert.Dismissible := True;
  FAlert.OnDismiss := AlertDismiss;
  FAlert.Visible := False;
  FAlert.AlignWithMargins := True;
  FAlert.Margins.SetBounds(Sp(S.S4), Sp(S.S3), Sp(S.S4), 0);
  FAlert.Align := alTop;
  FAlert.Parent := Page;

  // Filtros rápidos (situação) e tags (projeto do usuário), cada um na sua linha.
  Bar := NewPanel(Page, alTop, 44);
  Bar.Top := Page.ControlCount * 1000;
  Bar.Padding.SetBounds(Sp(S.S4), Sp(S.S2), Sp(S.S4), Sp(S.S1));
  NewRowLabel(Bar, Tr('Filtros'));
  for F := Low(TItemFilter) to High(TItemFilter) do
  begin
    FChips[F] := TUIFilterChip.Create(Self);
    FChips[F].Caption := Tr(FilterNames[F]);
    FChips[F].Count := 0;
    FChips[F].Tone := FilterTones[F];
    FChips[F].OnToggle := FilterChanged;
    FChips[F].Left := (Ord(F) + 1) * 1000;
    FChips[F].AlignWithMargins := True;
    FChips[F].Margins.SetBounds(0, 0, Sp(S.S2), 0);
    FChips[F].Align := alLeft;
    FChips[F].Parent := Bar;
  end;
  FGroupChip := TUIFilterChip.Create(Self);
  FGroupChip.Caption := Tr('Agrupar');
  FGroupChip.Hint := Tr('Agrupa a lista por repositório (GitHub) ou projeto (Jira)');
  FGroupChip.ShowHint := True;
  FGroupChip.Active := IssueStore.GetSetting('group_list') = '1';
  FGroupChip.OnToggle := FilterChanged;
  FGroupChip.AlignWithMargins := True;
  FGroupChip.Margins.SetBounds(Sp(S.S2), 0, 0, 0);
  FGroupChip.Left := 900000;
  FGroupChip.Align := alRight;  // vai para a linha das tags: a dos filtros encheu
  FCollapsed := TDictionary<string, Boolean>.Create;
  FDrillChip := TUIFilterChip.Create(Self);
  FDrillChip.Tone := btPrimary;
  FDrillChip.Active := True;
  FDrillChip.Visible := False;
  FDrillChip.OnToggle := DrillChipToggle;
  FDrillChip.AlignWithMargins := True;
  FDrillChip.Margins.SetBounds(Sp(S.S2), 0, 0, 0);
  FDrillChip.Left := 800000;
  FDrillChip.Align := alRight;

  FTagBar := NewPanel(Page, alTop, 40);
  FTagBar.Top := Page.ControlCount * 1000;
  FTagBar.Padding.SetBounds(Sp(S.S4), 0, Sp(S.S4), Sp(S.S1));
  NewRowLabel(FTagBar, Tr('Tags'));
  FTagHint := TUILabel.Create(Self);
  FTagHint.Caption := Tr('Botão direito numa issue › Tag › Gerenciar para criar (ex.: #Bug, #Feature)');
  FTagHint.Variant := lvMuted;
  FTagHint.FontSize := HintFontSize;
  FTagHint.Italic := True;
  FTagHint.AutoSize := False;
  FTagHint.Width := ScaleValue(600);
  FTagHint.Left := 900000;
  FTagHint.Align := alLeft;
  FTagHint.Parent := FTagBar;
  FDrillChip.Parent := FTagBar;
  FGroupChip.Parent := FTagBar;
  FTagMenu := TUIContextMenu.Create(Self);
  FTagMenu.OnItemClick := TagMenuClick;
  FActionMenu := TUIContextMenu.Create(Self);
  FActionMenu.OnItemClick := TagMenuClick;

  FItemsList := NewList(Page, 76);
  FItemsList.OnCustomDraw := ItemsDraw;
  FItemsList.OnItemClick := ItemsClick;
  FItemsList.OnItemDblClick := ItemsDblClick;
  TListAccess(FItemsList).OnMouseDown := ItemsMouseDown;
  TListAccess(FItemsList).OnMouseMove := ItemsMouseMove;
  FItemsList.ShowHint := True;

  // Menu da suíte; os itens são montados no botão direito (o "parar" depende da linha).
  FItemMenu := TUIContextMenu.Create(Self);
  FItemMenu.OnItemClick := ItemMenuClick;
  FItemMenu.AttachTo(FItemsList);

  FItemsEmpty := TUIEmptyState.Create(Self);
  FItemsEmpty.Visible := False;
  FItemsEmpty.Align := alClient;
  FItemsEmpty.Parent := Page;

  FSkeleton := NewPanel(Page, alClient);
  FSkeleton.Padding.SetBounds(Sp(S.S4), Sp(S.S2), Sp(S.S4), 0);
  FSkeleton.Visible := False;
  for I := 1 to 6 do
  begin
    // Mesmo desenho da linha real: chave curta, título longo, dois selos.
    SkRow := NewPanel(FSkeleton, alNone, 76);
    SkRow.Top := I * 1000;
    SkRow.Align := alTop;
    Sk := TUISkeletonLoader.Create(Self);
    Sk.Shape := ssText;
    Sk.SetBounds(ScaleValue(14), ScaleValue(10), ScaleValue(110), ScaleValue(12));
    Sk.Parent := SkRow;
    Sk := TUISkeletonLoader.Create(Self);
    Sk.Shape := ssText;
    Sk.SetBounds(ScaleValue(14), ScaleValue(30), ScaleValue(380 - I * 25), ScaleValue(14));
    Sk.Parent := SkRow;
    Sk := TUISkeletonLoader.Create(Self);
    Sk.SetBounds(ScaleValue(14), ScaleValue(52), ScaleValue(80), ScaleValue(16));
    Sk.Parent := SkRow;
    Sk := TUISkeletonLoader.Create(Self);
    Sk.SetBounds(ScaleValue(100), ScaleValue(52), ScaleValue(64), ScaleValue(16));
    Sk.Parent := SkRow;
  end;
end;

procedure TIssuesPage.BuildAccountsPage;
var
  S: TUISpacingTokens;
  Page, Bar: TPanel;
  Btn: TUIButton;
begin
  S := UITheme.Tokens.Spacing;
  Page := FPages[pgAccounts];

  Bar := NewPanel(Page, alTop, 60);
  Bar.Padding.SetBounds(Sp(S.S4), Sp(S.S3), Sp(S.S4), Sp(S.S2));
  Btn := TUIButton.Create(Self);
  Btn.Caption := Tr('Nova conta');
  Btn.AutoWidth := True;
  Btn.OnClick := NewAccountClick;
  Btn.Align := alRight;
  Btn.Parent := Bar;

  FAccountsList := NewList(Page, 64);  // ponytail: fica escondida; cartões no lugar
  FAccountsList.Visible := False;
  FAccountsBox := TUIScrollArea.Create(Self);
  FAccountsBox.Align := alClient;
  FAccountsBox.Parent := Page;

  FAccountsEmpty := TUIEmptyState.Create(Self);
  FAccountsEmpty.Title := Tr('Nenhuma conta ainda');
  FAccountsEmpty.Description := Tr('Adicione uma conta do GitHub ou do Jira para o Devbox começar a acompanhar.');
  FAccountsEmpty.ActionLabel := Tr('Nova conta');
  FAccountsEmpty.OnAction := NewAccountClick;
  FAccountsEmpty.Visible := False;
  FAccountsEmpty.Align := alClient;
  FAccountsEmpty.Parent := Page;
end;

{ Configurações em seções (cartões). Cada linha: título e descrição à
  esquerda, controle à direita, com a mesma altura de 36 px dos campos. }
procedure TIssuesPage.BuildSettingsPage;
const
  ColumnW = 760;
  RowH = 80;     // campos têm até 40 px; 20 de respiro em cima e embaixo
  FieldH = 40;
var
  S: TUISpacingTokens;
  Page, Column: TPanel;
  Card: TUICard;

  function NewSection(const ATitle: string; ARows: Integer): TUICard;
  var
    Lbl: TUILabel;
  begin
    Result := TUICard.Create(Self);
    Result.Variant := cvOutlined;
    Result.CardPad := cpNone;
    Result.Padding.SetBounds(Sp(S.S4), Sp(S.S3), Sp(S.S4), Sp(S.S2));
    Result.Height := ScaleValue(44 + ARows * RowH + 8);
    Result.AlignWithMargins := True;
    Result.Margins.SetBounds(0, Sp(S.S4), 0, 0);
    Result.Parent := Column;
    Result.Top := Column.ControlCount * 1000;
    Result.Align := alTop;
    Lbl := TUILabel.Create(Self);
    Lbl.Caption := ATitle;
    Lbl.Bold := True;
    Lbl.FontSize := 15;
    Lbl.AutoSize := False;
    Lbl.Height := ScaleValue(28);
    Lbl.Parent := Result;
    Lbl.Top := 0;
    Lbl.Align := alTop;
  end;

  { Linha com título/descrição; devolve o painel da direita para o controle. }
  function NewRow(ACard: TUICard; const ATitle, ADesc: string; AControlW: Integer): TPanel;
  var
    Row, Text, Line: TPanel;
    Lbl: TUILabel;
    VPad: Integer;
  begin
    Row := NewPanel(ACard, alNone, RowH);
    Row.Top := ACard.ControlCount * 1000;
    Row.Align := alTop;
    Line := NewPanel(Row, alTop, 1);
    Line.Tag := 1;  // divisória: cor de borda, não de fundo
    Line.Color := UIAlphaToVclColor(UITheme.Tokens.Color.Border);
    VPad := (ScaleValue(RowH) - ScaleValue(FieldH)) div 2;
    Result := NewPanel(Row, alRight);
    Result.Width := ScaleValue(AControlW);
    Result.Padding.SetBounds(0, VPad, 0, VPad);
    Text := NewPanel(Row, alClient);
    Text.Padding.SetBounds(0, Sp(S.S3), Sp(S.S4), 0);
    Lbl := TUILabel.Create(Self);
    Lbl.Caption := ATitle;
    Lbl.AutoSize := False;
    Lbl.Height := ScaleValue(20);
    Lbl.Parent := Text;
    Lbl.Top := 0;
    Lbl.Align := alTop;
    Lbl := TUILabel.Create(Self);
    Lbl.Caption := ADesc;
    Lbl.Variant := lvMuted;
    Lbl.FontSize := HintFontSize;
    Lbl.Italic := True;
    Lbl.AutoSize := False;
    Lbl.WordWrap := True;
    Lbl.Parent := Text;
    Lbl.Top := 1000;
    Lbl.Align := alClient;
  end;

var
  Host, Row: TPanel;
  Btn: TUIButton;
  AK: TAiProviderKind;
  UK: Integer;
begin
  S := UITheme.Tokens.Spacing;
  Page := FPages[pgSettings];
  // Coluna centralizada de largura fixa (linhas largas demais cansam a leitura),
  // dentro de uma área de rolagem.
  FSettingsScroll := TUIScrollArea.Create(Self);
  FSettingsScroll.Align := alClient;
  FSettingsScroll.AutoHideScrollbar := False;  // mostra onde a tela está mesmo parada
  FSettingsScroll.Parent := Page;
  Column := NewPanel(FSettingsScroll.InnerPanel, alNone);
  Column.Width := ScaleValue(ColumnW);
  Column.Height := ScaleValue(2000);
  FSettingsColumn := Column;
  Page.OnResize := SettingsResize;

  Card := NewSection(Tr('Busca e atalho'), 2);
  Host := NewRow(Card, Tr('Iniciar com o Windows'),
    Tr('Abre o Vigia na bandeja quando você entra no Windows. Vale só para este usuário.'), 60);
  FAutostartToggle := TUIToggle.Create(Self);
  FAutostartToggle.Checked := AutostartEnabled;
  FAutostartToggle.OnChange := GeneralSettingChange;
  FAutostartToggle.Align := alClient;
  FAutostartToggle.Parent := Host;
  Host.Parent.Visible := False;   // iniciar com o Windows: Configuração › Geral do Devbox

  Host := NewRow(Card, Tr('Buscar a cada'), Tr('Intervalo entre as consultas ao GitHub e ao Jira.'), 150);
  FPollMinutes := TUINumberInput.Create(Self);
  FPollMinutes.SuffixText := Tr('min');
  FPollMinutes.Min := 1;
  FPollMinutes.Max := 120;
  FPollMinutes.Value := StrToIntDef(IssueStore.GetSetting('poll_minutes'), DefaultPollMinutes);
  FPollMinutes.OnChange := GeneralSettingChange;
  FPollMinutes.Align := alClient;
  FPollMinutes.Parent := Host;

  Host := NewRow(Card, Tr('Tema'), Tr('Seguir o Windows ou fixar claro ou escuro.'), 220);
  FThemeSelect := TUISelect.Create(Self);
  FThemeSelect.Items.Add(Tr('Seguir o Windows'));
  FThemeSelect.Items.Add(Tr('Claro'));
  FThemeSelect.Items.Add(Tr('Escuro'));
  FThemeSelect.ItemIndex := IndexText(IssueStore.GetSetting('theme'), ['', 'light', 'dark']);
  FThemeSelect.OnChange := GeneralSettingChange;
  FThemeSelect.Align := alClient;
  FThemeSelect.Parent := Host;
  Host.Parent.Visible := False;   // o tema é do Devbox

  Host := NewRow(Card, Tr('Idioma'), Tr('Português ou inglês. Vale ao reabrir o Devbox.'), 220);
  FLangSelect := TUISelect.Create(Self);
  FLangSelect.Items.Add(Tr('Automático (Windows)'));
  FLangSelect.Items.Add('Português');
  FLangSelect.Items.Add('English');
  FLangSelect.ItemIndex := Max(0, IndexText(IssueStore.GetSetting('lang'), ['', 'pt', 'en']));
  FLangSelect.OnChange := GeneralSettingChange;
  FLangSelect.Align := alClient;
  FLangSelect.Parent := Host;
  Host.Parent.Visible := False;   // idioma: Configuração › Geral do Devbox

  Host := NewRow(Card, Tr('Atalho global'),
    Tr('Win+Alt+V abre as Issues do Devbox de qualquer programa; de novo, esconde.'), 60);
  FHotkeyToggle := TUIToggle.Create(Self);
  FHotkeyToggle.Checked := IssueStore.GetSetting('hotkey_on', '1') = '1';
  FHotkeyToggle.OnChange := GeneralSettingChange;
  FHotkeyToggle.Width := ScaleValue(60);
  FHotkeyToggle.Align := alLeft;
  FHotkeyToggle.Parent := Host;

  Host := NewRow(Card, Tr('Atualizações'), Tr('Versão ') + AppVersion + Tr('. Procura release nova uma vez por dia ' +
    '(só na versão instalada).'), 340);
  FUpdateBtn := TUIButton.Create(Self);
  FUpdateBtn.Caption := Tr('Procurar agora');
  FUpdateBtn.Variant := bvOutline;
  FUpdateBtn.AutoWidth := True;
  FUpdateBtn.OnClick := UpdateBtnClick;
  FUpdateBtn.AlignWithMargins := True;
  FUpdateBtn.Margins.SetBounds(Sp(S.S2), 0, 0, 0);
  FUpdateBtn.Align := alRight;
  FUpdateBtn.Parent := Host;
  FUpdateMode := TUISelect.Create(Self);
  FUpdateMode.Items.Add(Tr('Só avisar'));
  FUpdateMode.Items.Add(Tr('Instalar sozinho'));
  FUpdateMode.Items.Add(Tr('Não procurar'));
  FUpdateMode.ItemIndex := Max(0, IndexText(IssueStore.GetSetting('update_mode'), ['notify', 'auto', 'off']));
  FUpdateMode.OnChange := GeneralSettingChange;
  FUpdateMode.Align := alClient;
  FUpdateMode.Parent := Host;
  Host.Parent.Visible := False;   // atualizações: Configuração › Geral do Devbox

  Card := NewSection(Tr('Notificações'), 5);
  Host := NewRow(Card, Tr('Estilo do aviso'),
    Tr('Popup do Devbox no canto da tela, ou a notificação padrão do Windows.'), 220);
  FNotifyStyle := TUISelect.Create(Self);
  FNotifyStyle.Items.Add(Tr('Popup do Devbox'));
  FNotifyStyle.Items.Add(Tr('Windows'));
  FNotifyStyle.ItemIndex := IfThen(IssueStore.GetSetting('notify_style', 'vigia') = 'vigia', 0, 1);
  FNotifyStyle.OnChange := GeneralSettingChange;
  FNotifyStyle.Align := alClient;
  FNotifyStyle.Parent := Host;

  Host := NewRow(Card, Tr('Tempo na tela'),
    Tr('Quanto o popup fica visível. Com o mouse em cima ele espera.'), 150);
  FNotifySeconds := TUINumberInput.Create(Self);
  FNotifySeconds.SuffixText := 's';
  FNotifySeconds.Min := 3;
  FNotifySeconds.Max := 60;
  FNotifySeconds.Value := StrToIntDef(IssueStore.GetSetting('notify_seconds'), DefaultNotifySeconds);
  FNotifySeconds.OnChange := GeneralSettingChange;
  FNotifySeconds.Align := alClient;
  FNotifySeconds.Parent := Host;

  Host := NewRow(Card, Tr('Resumo do dia'),
    Tr('Um aviso por dia com o que vence, o que está impedido e os comentários novos.'), 200);
  FSummaryTime := TUITimePicker.Create(Self);
  FSummaryTime.Hour := HourOf(TimeSetting('summary_time', '09:00'));
  FSummaryTime.Minute := MinuteOf(TimeSetting('summary_time', '09:00'));
  FSummaryTime.OnChange := GeneralSettingChange;
  FSummaryTime.Align := alClient;
  FSummaryTime.Parent := Host;
  FSummaryToggle := TUIToggle.Create(Self);
  FSummaryToggle.Checked := IssueStore.GetSetting('summary_on', '1') = '1';
  FSummaryToggle.OnChange := GeneralSettingChange;
  FSummaryToggle.Width := ScaleValue(60);
  FSummaryToggle.Align := alLeft;
  FSummaryToggle.Parent := Host;

  Host := NewRow(Card, Tr('Não perturbe'),
    Tr('Nesse horário os avisos esperam e chegam juntos quando o silêncio acaba.'), 300);
  FDndToggle := TUIToggle.Create(Self);
  FDndToggle.Checked := IssueStore.GetSetting('dnd_on', '0') = '1';
  FDndToggle.OnChange := GeneralSettingChange;
  FDndToggle.Width := ScaleValue(60);
  FDndToggle.Align := alLeft;
  FDndToggle.Parent := Host;
  FDndStart := TUITimePicker.Create(Self);
  FDndStart.Hour := HourOf(TimeSetting('dnd_start', '19:00'));
  FDndStart.Minute := MinuteOf(TimeSetting('dnd_start', '19:00'));
  FDndStart.OnChange := GeneralSettingChange;
  FDndStart.Width := ScaleValue(116);
  FDndStart.Left := 1000;
  FDndStart.Align := alLeft;
  FDndStart.Parent := Host;
  FDndEnd := TUITimePicker.Create(Self);
  FDndEnd.Hour := HourOf(TimeSetting('dnd_end', '08:00'));
  FDndEnd.Minute := MinuteOf(TimeSetting('dnd_end', '08:00'));
  FDndEnd.OnChange := GeneralSettingChange;
  FDndEnd.AlignWithMargins := True;
  FDndEnd.Margins.SetBounds(ScaleValue(8), 0, 0, 0);
  FDndEnd.Left := 2000;
  FDndEnd.Align := alClient;
  FDndEnd.Parent := Host;

  Host := NewRow(Card, Tr('Testar'), Tr('Mostra um aviso de exemplo com o estilo escolhido.'), 150);
  Btn := TUIButton.Create(Self);
  Btn.Caption := Tr('Mostrar aviso');
  Btn.Variant := bvOutline;
  Btn.OnClick := TestNotifyClick;
  Btn.Align := alClient;
  Btn.Parent := Host;

  Card := NewSection(Tr('Assistente de IA'), 5);
  FAiCards := FAiCards + [Card];
  Host := NewRow(Card, Tr('Provedor'), Tr('Anthropic usa o assistente completo da suíte; os outros, a API ' +
    'compatível com OpenAI.'), 260);
  FAiProvider := TUISelect.Create(Self);
  for AK := Low(TAiProviderKind) to High(TAiProviderKind) do
    FAiProvider.Items.Add(AiProviderNames[AK]);
  FAiProvider.ItemIndex := Ord(CurrentAiConfig.Kind);
  FAiProvider.OnChange := AiSettingChange;
  FAiProvider.Align := alClient;
  FAiProvider.Parent := Host;

  Host := NewRow(Card, Tr('Endereço da API'), Tr('Já vem preenchido; troque para um gateway próprio ou Ollama remoto.'), 340);
  FAiBaseUrl := TUIInput.Create(Self);
  FAiBaseUrl.ReserveHintSpace := False;
  FAiBaseUrl.OnBlur := AiSettingChange;
  FAiBaseUrl.Align := alClient;
  FAiBaseUrl.Parent := Host;

  Host := NewRow(Card, Tr('Chave'), Tr('Uma por provedor, no Credential Manager deste usuário.'), 340);
  Btn := TUIButton.Create(Self);
  Btn.Caption := Tr('Salvar');
  Btn.AutoWidth := True;
  Btn.OnClick := SaveApiKeyClick;
  Btn.AlignWithMargins := True;
  Btn.Margins.SetBounds(Sp(S.S2), 0, 0, 0);
  Btn.Align := alRight;
  Btn.Parent := Host;
  FApiKey := TUIInput.Create(Self);
  FApiKey.PasswordChar := '*';
  FApiKey.PasswordToggle := True;
  FApiKey.ReserveHintSpace := False;
  FApiKey.Align := alClient;
  FApiKey.Parent := Host;

  Host := NewRow(Card, Tr('Modelo'), Tr('Digite ou escolha da lista que o provedor devolve.'), 340);
  FAiModelsBtn := TUIButton.Create(Self);
  FAiModelsBtn.Caption := Tr('Listar');
  FAiModelsBtn.Variant := bvOutline;
  FAiModelsBtn.AutoWidth := True;
  FAiModelsBtn.OnClick := AiListModelsClick;
  FAiModelsBtn.AlignWithMargins := True;
  FAiModelsBtn.Margins.SetBounds(Sp(S.S2), 0, 0, 0);
  FAiModelsBtn.Align := alRight;
  FAiModelsBtn.Parent := Host;
  FAiModel := TUIInput.Create(Self);
  FAiModel.ReserveHintSpace := False;
  FAiModel.OnBlur := AiSettingChange;
  FAiModel.Align := alClient;
  FAiModel.Parent := Host;
  FAiModelsMenu := TUIDropdown.Create(Self);
  FAiModelsMenu.AnchorControl := FAiModel;
  FAiModelsMenu.AnchorPos := dapBottomLeft;
  FAiModelsMenu.MaxHeight := ScaleValue(320);
  FAiModelsMenu.OnItemClick := AiModelPicked;

  Host := NewRow(Card, Tr('Preço (US$ por milhão de tokens)'),
    Tr('Entrada e saída. Claude já vem com o preço público; nos outros, preencha para ver o custo.'), 320);
  FAiPriceOut := TUINumberInput.Create(Self);
  FAiPriceOut.PrefixText := Tr('saída');
  FAiPriceOut.DecimalPlaces := 2;
  FAiPriceOut.Step := 0.1;
  FAiPriceOut.Max := 1000;
  FAiPriceOut.OnChange := AiSettingChange;
  FAiPriceOut.AlignWithMargins := True;
  FAiPriceOut.Margins.SetBounds(Sp(S.S2), 0, 0, 0);
  FAiPriceOut.Align := alClient;
  FAiPriceOut.Parent := Host;
  FAiPriceIn := TUINumberInput.Create(Self);
  FAiPriceIn.PrefixText := 'entrada';
  FAiPriceIn.DecimalPlaces := 2;
  FAiPriceIn.Step := 0.1;
  FAiPriceIn.Max := 1000;
  FAiPriceIn.OnChange := AiSettingChange;
  FAiPriceIn.Width := ScaleValue(156);
  FAiPriceIn.Align := alLeft;
  FAiPriceIn.Parent := Host;

  Card := NewSection(Tr('Backup'), 1);
  Host := NewRow(Card, Tr('Contas e configurações'), Tr('Arquivo com contas, tags, issues acompanhadas e ' +
    'preferências. Os tokens vão cifrados e só voltam neste usuário do Windows.'), 260);
  Btn := TUIButton.Create(Self);
  Btn.Caption := Tr('Importar...');
  Btn.Variant := bvOutline;
  Btn.AutoWidth := True;
  Btn.OnClick := ImportClick;
  Btn.AlignWithMargins := True;
  Btn.Margins.SetBounds(Sp(S.S2), 0, 0, 0);
  Btn.Align := alRight;
  Btn.Parent := Host;
  Btn := TUIButton.Create(Self);
  Btn.Caption := Tr('Exportar...');
  Btn.Variant := bvOutline;
  Btn.AutoWidth := True;
  Btn.OnClick := ExportClick;
  Btn.Align := alRight;
  Btn.Parent := Host;

  Card := NewSection(Tr('IA automática'), 7);
  FAiCards := FAiCards + [Card];
  Host := NewRow(Card, Tr('Limite por mês (US$)'), Tr('Chegou no limite, o chat e as tarefas automáticas param ' +
    'até o mês virar. 0 = sem limite.'), 160);
  FAiCap := TUINumberInput.Create(Self);
  FAiCap.DecimalPlaces := 2;
  FAiCap.Step := 1;
  FAiCap.Max := 10000;
  FAiCap.Value := AiMonthCap;
  FAiCap.OnChange := AiAutoChange;
  FAiCap.Align := alClient;
  FAiCap.Parent := Host;
  Host := NewRow(Card, Tr('Modelo das tarefas automáticas'), Tr('Mais barato que o do chat. Vazio = o mesmo do chat.'), 300);
  FAiCheap := TUIInput.Create(Self);
  FAiCheap.ReserveHintSpace := False;
  FAiCheap.Value := AiCheapModel;
  FAiCheap.OnBlur := AiAutoChange;
  FAiCheap.Align := alClient;
  FAiCheap.Parent := Host;
  for UK := 0 to 4 do
  begin
    case UK of
      0: Host := NewRow(Card, Tr('Resumo do dia escrito pela IA'), Tr('No horário do resumo. Sem IA, vai o resumo em números.'), 60);
      1: Host := NewRow(Card, Tr('Alerta de risco'), Tr('Uma vez por dia: até 3 issues com chance de atrasar ou travar.'), 60);
      2: Host := NewRow(Card, Tr('Rascunho de horas no fim do dia'), Tr('Às 17:30, em dias úteis. O assistente lança se você pedir.'), 60);
      3: Host := NewRow(Card, Tr('Causa da falha do CI'), Tr('Quando um PR seu fica vermelho, lê o log do job e explica.'), 60);
      4: Host := NewRow(Card, Tr('Triagem de issues novas'), Tr('Sugere tag e prioridade para até 3 issues novas por busca. ' +
        'Aplicar fica no botão direito › Ações.'), 60);
    end;
    FAiAuto[UK] := TUIToggle.Create(Self);
    FAiAuto[UK].Checked := IssueStore.GetSetting(AiAutoKeys[UK]) = '1';
    FAiAuto[UK].OnChange := AiAutoChange;
    FAiAuto[UK].Width := ScaleValue(60);
    FAiAuto[UK].Align := alLeft;
    FAiAuto[UK].Parent := Host;
  end;

  // Uso: números do mês e custo por dia.
  Card := NewSection(Tr('Assistente e IA automática das Issues: este mês'), 0);
  FAiCards := FAiCards + [Card];
  Card.Height := ScaleValue(44 + 120 + 70 + 16);
  Row := NewPanel(Card, alNone, 120);
  Row.Top := 1000;
  Row.Align := alTop;
  for UK := 0 to 3 do
  begin
    FAiStats[UK] := TUIStat.Create(Self);
    FAiStats[UK].AlignWithMargins := True;
    FAiStats[UK].Margins.SetBounds(0, 0, Sp(S.S2), 0);
    FAiStats[UK].Width := ScaleValue(176);
    FAiStats[UK].Left := (UK + 1) * 1000;
    FAiStats[UK].Align := alLeft;
    FAiStats[UK].Parent := Row;
  end;
  FAiStats[0].CardLabel := Tr('Perguntas no mês');
  FAiStats[1].CardLabel := Tr('Tokens por pergunta');
  FAiStats[1].SubText := Tr('média, entrada + saída');
  FAiStats[2].CardLabel := Tr('Custo no mês');
  FAiStats[2].ValueFormat := nfDecimal;
  FAiStats[2].ValueDecimals := 2;
  FAiStats[2].ValuePrefix := Tr('US$ ');
  FAiStats[3].CardLabel := Tr('Custo por pergunta');
  FAiStats[3].ValueFormat := nfDecimal;
  FAiStats[3].ValueDecimals := 4;
  FAiStats[3].ValuePrefix := Tr('US$ ');
  FAiCostSpark := TUISparkline.Create(Self);
  FAiCostSpark.Kind := skBar;
  FAiCostSpark.Color := UITheme.Tokens.Color.Primary;
  FAiCostSpark.Hint := Tr('Custo por dia, últimos 30 dias');
  FAiCostSpark.ShowHint := True;
  FAiCostSpark.AlignWithMargins := True;
  FAiCostSpark.Margins.SetBounds(0, Sp(S.S3), 0, 0);
  FAiCostSpark.Height := ScaleValue(56);
  FAiCostSpark.Parent := Card;
  FAiCostSpark.Top := 2000;
  FAiCostSpark.Align := alTop;
  LoadAiSettings;
  UpdateAiUsage;
end;

procedure TIssuesPage.SettingsResize(Sender: TObject);
var
  I, H: Integer;
  C: TControl;
begin
  if FSettingsColumn = nil then
    Exit;
  // Altura = soma dos cartões (alTop com altura fixa) + respiro no fim.
  H := ScaleValue(16);
  for I := 0 to FSettingsColumn.ControlCount - 1 do
  begin
    C := FSettingsColumn.Controls[I];
    Inc(H, C.Height + C.Margins.Top);
  end;
  FSettingsColumn.SetBounds(Max(0, (FSettingsScroll.ClientWidth - FSettingsColumn.Width) div 2), 0,
    FSettingsColumn.Width, H);
  FSettingsScroll.ContentHeight := H;
end;

{ Campos do assistente para o provedor escolhido. }
procedure TIssuesPage.LoadAiSettings;
var
  Cfg: TAiConfig;
  PIn, POut: Double;
begin
  FAiLoading := True;
  try
    Cfg := CurrentAiConfig;
    FAiProvider.ItemIndex := Ord(Cfg.Kind);
    FAiBaseUrl.Value := Cfg.BaseUrl;
    FAiBaseUrl.LabelText := IfThen(Cfg.Kind = apAnthropic, Tr('Padrão da Anthropic'), 'https://...');
    FAiModel.Value := Cfg.Model;
    FAiModel.LabelText := Tr('ex.: ') + IfThen(Cfg.Kind = apAnthropic, AiDefaultModel, Tr('nome do modelo'));
    FApiKey.LabelText := IfThen(Cfg.ApiKey <> '', Tr('Chave salva (digite para trocar)'),
      IfThen(Cfg.Kind = apOllama, Tr('Ollama local não precisa de chave'), Tr('Cole a chave aqui')));
    AiPriceFor(Cfg.Model, PIn, POut);
    FAiPriceIn.Value := PIn;
    FAiPriceOut.Value := POut;
  finally
    FAiLoading := False;
  end;
end;

procedure TIssuesPage.AiSettingChange(Sender: TObject);
var
  Id: string;
begin
  if FAiLoading then
    Exit;
  if Sender = FAiProvider then
  begin
    IssueStore.SetSetting('ai_provider', AiProviderIds[TAiProviderKind(FAiProvider.ItemIndex)]);
    LoadAiSettings;
    Exit;
  end;
  Id := AiProviderIds[CurrentAiConfig.Kind];
  if Sender = FAiBaseUrl then
    IssueStore.SetSetting('ai_base_' + Id, FAiBaseUrl.Value.Trim)
  else if Sender = FAiModel then
  begin
    IssueStore.SetSetting('ai_model_' + Id, FAiModel.Value.Trim);
    LoadAiSettings;  // preço do modelo novo
  end
  else if ((Sender = FAiPriceIn) or (Sender = FAiPriceOut)) and (FAiModel.Value.Trim <> '') then
    SetAiPrice(FAiModel.Value.Trim, FAiPriceIn.Value, FAiPriceOut.Value);
end;

procedure TIssuesPage.AiListModelsClick(Sender: TObject);
var
  Cfg: TAiConfig;
begin
  Cfg := CurrentAiConfig;
  FAiModelsBtn.Loading := True;
  RunTask(
    procedure
    var
      Models: TArray<string>;
      Err: string;
    begin
      try
        Models := ListAiModels(Cfg);
      except
        on E: Exception do
          Err := E.Message;
      end;
      QueueUI(
        procedure
        var
          M: string;
        begin
          FAiModelsBtn.Loading := False;
          if Err <> '' then
          begin
            TUIToastManager.Show(Tr('Não listou: ') + Err, TUIToastTone(2), 6000);
            Exit;
          end;
          FAiModelsMenu.ClearItems;
          for M in Models do
            FAiModelsMenu.AddItem(M, M);
          if Models = nil then
            TUIToastManager.Show(Tr('O provedor não devolveu modelos'), TUIToastTone(3))
          else
            FAiModelsMenu.Open;
        end);
    end);
end;

procedure TIssuesPage.AiModelPicked(Sender: TObject; const AID: string);
begin
  FAiModel.Value := AID;
  AiSettingChange(FAiModel);
end;

{ Painel de uso: mês corrente e custo por dia (30 dias). }
{ Uma vez por dia busca a cotação (em segundo plano) e redesenha o card. }
procedure TIssuesPage.RefreshUsdBrl;
var
  Today: string;
  LProbe: TProc;
begin
  Today := FormatDateTime('yyyy-mm-dd', Date);
  if (IssueStore.GetSetting('usd_brl_date') = Today) or FFetchingRate then
    Exit;
  FFetchingRate := True;
  LProbe := (
    procedure
    var
      Rate: Double;
    begin
      try
        Rate := FetchUsdBrl;
      except
        Rate := 0;  // sem rede: tenta de novo na próxima vez que abrir o card
      end;
      Devbox.UI.Kit.QueueUI(
        procedure
        begin
          FFetchingRate := False;
          if Rate <= 0 then
            Exit;
          IssueStore.SetSetting('usd_brl', FloatToStr(Rate, TFormatSettings.Invariant));
          IssueStore.SetSetting('usd_brl_date', Today);
          UpdateAiUsage;
        end);
    end);
end;

procedure TIssuesPage.UpdateAiUsage;
var
  Count, TIn, TOut, I: Integer;
  Cost, Rate: Double;
  PerDay: TArray<Double>;
  Points: string;
  Fmt: TFormatSettings;
begin
  if FAiStats[0] = nil then
    Exit;
  IssueStore.AiTotals(StartOfTheMonth(Now), Count, TIn, TOut, Cost);
  FAiStats[0].NumericValue := Count;
  FAiStats[1].NumericValue := IfThen(Count > 0, (TIn + TOut) / Max(Count, 1), 0);
  FAiStats[2].NumericValue := Cost;
  FAiStats[3].NumericValue := IfThen(Count > 0, Cost / Max(Count, 1), 0);
  FAiStats[0].SubText := Format(Tr('%d entrada · %d saída'), [TIn, TOut]);
  Fmt := TFormatSettings.Invariant;
  // Fica em dólar; o real vai pequeno embaixo, pela cotação do dia.
  Rate := StrToFloatDef(IssueStore.GetSetting('usd_brl'), 0, Fmt);
  if Rate > 0 then
  begin
    FAiStats[2].SubText := Format(Tr('≈ R$ %s · dólar a R$ %s'), [FormatFloat('#,##0.00', Cost * Rate),
      FormatFloat('0.00', Rate)]);
    FAiStats[3].SubText := '≈ R$ ' + FormatFloat('#,##0.0000', IfThen(Count > 0, Cost / Max(Count, 1), 0) * Rate);
  end;
  RefreshUsdBrl;
  PerDay := IssueStore.AiCostPerDay(30);
  Points := '';
  for I := 0 to High(PerDay) do
    Points := Points + IfThen(I > 0, ',') + FloatToStr(PerDay[I], Fmt);
  FAiCostSpark.DataPoints := Points;
end;

procedure TIssuesPage.TestNotifyClick(Sender: TObject);
begin
  Notify(Tr('Acme · APP-123 · Novo comentário'),
    Tr('Maria: pode validar o ajuste no checkout antes de subir?'), '', stInfo, '*teste');
end;

{ Assistente da suíte: botão flutuante no canto, painel de conversa. As issues
  vão como contexto no prompt de sistema a cada busca. }
procedure TIssuesPage.BuildAssistant;
begin
  FAssistant := TUIAssistant.Create(Self);
  // FAB à direita, acima do rodapé da lista, por cima de todas as telas.
  FAssistant.Parent := Self;
  FAssistant.Anchors := [akRight, akBottom];
  FAssistant.SetBounds(ClientWidth - ScaleValue(96), ClientHeight - ScaleValue(150),
    ScaleValue(74), ScaleValue(74));
  FAssistant.Config.ApiKey := LoadSecret(AssistantSecret);
  FAssistant.Config.ApiKeyEnvVar := 'ANTHROPIC_API_KEY';
  FAssistant.Config.Model := AssistantModel;
  // Mascote animado (Lottie) por estado: ocioso, ouvindo, pensando, falando, dormindo.
  FAssistant.Behaviors.ApplyDefaults(ExtractFilePath(ParamStr(0)) + 'assets\assistant');
  FAssistant.Greeting := Tr('Posso resumir suas issues, registrar horas, comentar, mudar status e filtrar ' +
    'a tela. Toda escrita pede sua confirmação. Ex.: "o que vence esta semana?" ou "lance 2h na PROJ-1".');
  RegisterAiTools;
  FAssistant.OnStateChange := AssistantStateChange;
  FAssistant.BringToFront;
end;

{ ── Navegação ───────────────────────────────────────────────────────────── }

procedure TIssuesPage.ShowPage(APage: TPage);
var
  P, Old: TPage;
  Dir: TUIPageTransitionDirection;
begin
  if FDetached and (APage <> pgIssues) then
  begin
    if APage = pgSettings then
    begin
      FApiKey.Value := '';
      UpdateAiUsage;
      SettingsResize(nil);
    end;
    if Assigned(FOnNavigate) then
      FOnNavigate(Ord(APage));
    Exit;
  end;
  Old := FPage;
  FPage := APage;
  // Prepara a página antes da transição: consulta ao banco e layout no meio do
  // deslize travavam os primeiros quadros, e a captura já sai com o conteúdo certo.
  if APage = pgSettings then
  begin
    FApiKey.Value := '';
    UpdateAiUsage;
    SettingsResize(nil);
  end;
  if (Old <> APage) and Visible and FContent.HandleAllocated then
  begin
    // Desliza para a direita indo para uma aba à direita, e o contrário.
    if Ord(APage) > Ord(Old) then
      Dir := tdForward
    else
      Dir := tdBackward;
    FTransition.Run(FContent, Dir,
      procedure
      var
        Q: TPage;
      begin
        for Q := Low(TPage) to High(TPage) do
          FPages[Q].Visible := Q = APage;
      end);
  end
  else
    for P := Low(TPage) to High(TPage) do
      FPages[P].Visible := P = APage;
  if FTabs.ActiveIndex <> Ord(APage) then
  begin
    FTabs.OnChange := nil;
    FTabs.ActiveIndex := Ord(APage);
    FTabs.OnChange := TabChange;
  end;
  PlaceAssistant;
end;

function TIssuesPage.PollIntervalMs: Integer;
begin
  // Em memória: o cabeçalho pergunta a cada segundo e ir ao banco toda vez é desperdício.
  if FPollMs = 0 then
  begin
    FPollMs := StrToIntDef(IssueStore.GetSetting('poll_minutes'), DefaultPollMinutes) * 60 * 1000;
    // O relógio anda no menor intervalo; cada conta só busca quando chega a vez dela.
    for var Acc in IssueStore.ListAccounts do
      if Acc.Enabled and (Acc.PollMinutes > 0) then
        FPollMs := Min(FPollMs, Acc.PollMinutes * 60 * 1000);
  end;
  Result := FPollMs;
end;

procedure TIssuesPage.GeneralSettingChange(Sender: TObject);
const
  Themes: array[0..2] of string = ('', 'light', 'dark');
begin
  if Sender = FAutostartToggle then
  begin
    SetAutostart(FAutostartToggle.Checked);
    FAutostartItem.Checked := AutostartEnabled;
    if Assigned(FOnAutostartChanged) then
      FOnAutostartChanged(Self);
  end
  else if Sender = FPollMinutes then
  begin
    IssueStore.SetSetting('poll_minutes', IntToStr(Round(FPollMinutes.Value)));
    FPollMs := 0;
    FTimer.Interval := PollIntervalMs;
    FNextPoll := Now + PollIntervalMs / MSecsPerDay;
  end
  else if Sender = FNotifyStyle then
    IssueStore.SetSetting('notify_style', IfThen(FNotifyStyle.ItemIndex = 1, 'windows', 'vigia'))
  else if Sender = FSummaryToggle then
    IssueStore.SetSetting('summary_on', IfThen(FSummaryToggle.Checked, '1', '0'))
  else if Sender = FSummaryTime then
    IssueStore.SetSetting('summary_time', Format('%.2d:%.2d', [FSummaryTime.Hour, FSummaryTime.Minute]))
  else if Sender = FDndToggle then
    IssueStore.SetSetting('dnd_on', IfThen(FDndToggle.Checked, '1', '0'))
  else if Sender = FDndStart then
    IssueStore.SetSetting('dnd_start', Format('%.2d:%.2d', [FDndStart.Hour, FDndStart.Minute]))
  else if Sender = FDndEnd then
    IssueStore.SetSetting('dnd_end', Format('%.2d:%.2d', [FDndEnd.Hour, FDndEnd.Minute]))
  else if (Sender = FLangSelect) and (FLangSelect.ItemIndex >= 0) then
  begin
    IssueStore.SetSetting('lang', IfThen(FLangSelect.ItemIndex = 1, 'pt', IfThen(FLangSelect.ItemIndex = 2, 'en', '')));
    TUIToastManager.Show(Tr('O idioma muda ao reabrir o Devbox'), ttInfo);
  end
  else if Sender = FHotkeyToggle then
  begin
    IssueStore.SetSetting('hotkey_on', IfThen(FHotkeyToggle.Checked, '1', '0'));
    SetHotkey(FHotkeyToggle.Checked);
  end
  else if (Sender = FUpdateMode) and (FUpdateMode.ItemIndex >= 0) then
    IssueStore.SetSetting('update_mode', IfThen(FUpdateMode.ItemIndex = 1, 'auto',
      IfThen(FUpdateMode.ItemIndex = 2, 'off', 'notify')))
  else if Sender = FNotifySeconds then
    IssueStore.SetSetting('notify_seconds', IntToStr(Round(FNotifySeconds.Value)))
  else if (Sender = FThemeSelect) and (FThemeSelect.ItemIndex >= 0) then
  begin
    IssueStore.SetSetting('theme', Themes[FThemeSelect.ItemIndex]);
    case FThemeSelect.ItemIndex of
      0: UITheme.Mode := tmSystem;
      1: UITheme.Mode := tmLight;
      2: UITheme.Mode := tmDark;
    end;
  end;
end;

{ O FAB da suíte recorta a janela no quadrado inteiro (74 px, com sombra), e
  os cantos mostravam o fundo liso por cima da lista. Recorta um círculo só um
  maior (1 px) que o desenhado (CFabInset = 8): a borda dura do recorte cai no
  fundo da mesma cor e não aparece; a borda do círculo continua com antialias. }
procedure TIssuesPage.ClipAssistant;
const
  FabInset = 8;
  Slack = 1;
var
  M: Integer;
begin
  if not FAssistant.HandleAllocated then
    Exit;
  M := ScaleValue(FabInset - Slack);
  SetWindowRgn(FAssistant.Handle, CreateEllipticRgn(M, M, FAssistant.Width - M + 1,
    FAssistant.Height - M + 1), True);
end;

{ O FAB vira filho do controle principal da tela: a suíte pinta nos cantos o
  que o pai desenha, então o círculo fica suave sobre a lista ou o painel
  (com o form de pai, os cantos mostravam o fundo do form por cima da lista). }
procedure TIssuesPage.PlaceAssistant;
var
  Host: TWinControl;
begin
  if FAssistantHost <> nil then
    Exit;
  // Sempre a página: na lista de Issues a margem dela subia o FAB.
  Host := FPages[FPage];
  if FAssistant.Parent <> Host then
  begin
    FAssistant.Parent := Host;
    ClipAssistant;
  end;
  // Painel da issue aberto: o FAB vai para a esquerda dele e não cobre o enviar.
  if False then  // o detalhe agora abre fora da janela
    FAssistant.SetBounds(FDetail.Left - FAssistant.Width - ScaleValue(16),
      Host.ClientHeight - FAssistant.Height - ScaleValue(16), FAssistant.Width, FAssistant.Height)
  else
    FAssistant.SetBounds(Host.ClientWidth - FAssistant.Width - ScaleValue(16),
      Host.ClientHeight - FAssistant.Height - ScaleValue(16), FAssistant.Width, FAssistant.Height);
  FAssistant.BringToFront;
end;

function TIssuesPage.OpenItems: TItems;
var
  LAccount: TAccount;
  LItem: TItem;
begin
  Result := nil;
  for LAccount in IssueStore.ListAccounts do
    if LAccount.Enabled then
      for LItem in IssueStore.LoadSnapshot(LAccount.Id) do
        if not SameText(LItem.StatusCategory, 'done') then
          Result := Result + [LItem];
end;

procedure TIssuesPage.RefreshPalette;
begin
  RebuildPalette;
end;

procedure TIssuesPage.RefreshAiUsage;
begin
  UpdateAiUsage;
end;

procedure TIssuesPage.OpenPalette;
begin
  FPalette.Open;
end;

procedure TIssuesPage.OpenIssue(const AItem: TItem);
begin
  if Assigned(FOnShowRequest) then
    FOnShowRequest(Self);
  OpenDetail(AItem);
end;

procedure TIssuesPage.DetachPages(out ADashboard, AAccounts, ASettings: TControl);
var
  P: TPage;
begin
  ShowPage(pgIssues);
  FDetached := True;
  FTabs.Visible := False;
  ADashboard := FPages[pgDashboard];
  AAccounts := FPages[pgAccounts];
  ASettings := FPages[pgSettings];
  for P in [pgDashboard, pgAccounts, pgSettings] do
    FPages[P].Visible := True;
end;

function TIssuesPage.TakeAiSettings: TArray<TControl>;
begin
  Result := FAiCards;
end;

procedure TIssuesPage.AttachAssistant(AHost: TWinControl; ARight, ABottom: Integer);
begin
  FAssistantHost := AHost;
  if FAssistant.Parent <> AHost then
  begin
    FAssistant.Parent := AHost;
    ClipAssistant;
  end;
  FAssistant.SetBounds(AHost.ClientWidth - FAssistant.Width - ARight, AHost.ClientHeight - FAssistant.Height - ABottom,
    FAssistant.Width, FAssistant.Height);
  FAssistant.BringToFront;
end;

procedure TIssuesPage.TabChange(Sender: TObject; AIndex: Integer);
begin
  ShowPage(TPage(AIndex));
end;

procedure TIssuesPage.RebuildPalette;
var
  P: TPage;
  I: Integer;
  It: TItem;
begin
  FPalette.ClearItems;
  if Assigned(FOnPaletteCommands) then
    FOnPaletteCommands(FPalette);
  FPalette.AddCommand(Tr('Issues / Atualizar agora'), procedure begin Poll(True); end, HeroIcon('arrow-path'));
  FPalette.AddCommand(Tr('Ações / Alternar tema claro e escuro'),
    procedure
    begin
      FThemeSwap.Checked := not FThemeSwap.Checked;
      ThemeSwapToggle(nil);
    end, HeroIcon('sun'));
  FPalette.AddCommand(Tr('Issues / Nova conta'), procedure begin NewAccountClick(nil); end, HeroIcon('squares-plus'));
  FPalette.AddCommand(Tr('Ações / Assistente IA'), procedure begin FAssistant.Open; end, HeroIcon('fire'));
  for P := Low(TPage) to High(TPage) do
    FPalette.AddItem('page:' + IntToStr(Ord(P)), Tr('Ir para ') + Tr(PageTitles[P]), '', Tr('Navegar'));
  for I := 0 to High(FAll) do
  begin
    It := FAll[I];
    if not ItemInView(It) then
      Continue;
    FPalette.AddItem('issue:' + It.Key + '|' + IntToStr(It.AccountId),
      It.Key + '  ' + It.Title, '', Tr('Issues'));
  end;
end;

procedure TIssuesPage.PaletteSelect(Sender: TObject; const AID: string);
var
  Parts: TArray<string>;
  I: Integer;
begin
  // Escolhido de outra tela: as Issues vêm para a frente antes.
  if (AID.StartsWith('page:') or AID.StartsWith('issue:')) and Assigned(FOnShowRequest) then
    FOnShowRequest(Self);
  if AID.StartsWith('watch:') then
    WatchKey(AID.Substring(6))
  else if AID.StartsWith('page:') then
    ShowPage(TPage(StrToIntDef(AID.Substring(5), 0)))
  else if AID.StartsWith('issue:') then
  begin
    Parts := AID.Substring(6).Split(['|']);
    for I := 0 to High(FAll) do
      if SameText(FAll[I].Key, Parts[0]) and (IntToStr(FAll[I].AccountId) = Parts[1]) then
      begin
        OpenDetail(FAll[I]);
        Break;
      end;
  end;
end;

{ ── Contas ──────────────────────────────────────────────────────────────── }

function TIssuesPage.AccountById(AId: Integer; out AAccount: TAccount): Boolean;
var
  A: TAccount;
begin
  for A in FAccounts do
    if A.Id = AId then
    begin
      AAccount := A;
      Exit(True);
    end;
  Result := False;
end;

procedure TIssuesPage.ReloadAccounts;
var
  A: TAccount;
  State, Points: string;
  Card: TUICard;
  Av: TUIAvatar;
  Lbl: TUILabel;
  Spark: TUISparkline;
  PerDay: TArray<Integer>;
  Last: TDateTime;
  I, J, Y: Integer;
begin
  // Conta nova/editada: intervalo pode ter mudado e ela busca já.
  FPollMs := 0;
  FPollAll := True;
  FAccounts := IssueStore.ListAccounts;

  // Um cartão por conta: avatar, estado, atividade de 14 dias e última busca.
  for I := FAccountsBox.InnerPanel.ControlCount - 1 downto 0 do
    FAccountsBox.InnerPanel.Controls[I].Free;
  Y := ScaleValue(4);
  for A in FAccounts do
  begin
    if not A.Enabled then
      State := Tr('desligada')
    else if FAccountErrors.ContainsKey(A.Id) then
      State := Tr('com erro na última busca')
    else
      State := Tr('ligada');
    Card := TUICard.Create(Self);
    Card.Variant := cvOutlined;
    Card.Clickable := True;
    Card.Hoverable := True;
    Card.Tag := A.Id;
    Card.OnClick := AccountCardClick;
    Card.Cursor := crHandPoint;
    Card.Parent := FAccountsBox.InnerPanel;
    Card.SetBounds(ScaleValue(16), Y, FAccountsBox.ClientWidth - ScaleValue(32), ScaleValue(96));
    Card.Anchors := [akLeft, akTop, akRight];

    Av := TUIAvatar.Create(Self);
    Av.Initials := Initials(A.Name);
    Av.Size := asLG;
    if not A.Enabled then
      Av.StatusColor := UITheme.Tokens.Color.FGMuted
    else if FAccountErrors.ContainsKey(A.Id) then
      Av.StatusColor := UITheme.Tokens.Color.Error
    else
      Av.StatusColor := UITheme.Tokens.Color.Success;
    Av.Parent := Card;
    Av.SetBounds(ScaleValue(16), ScaleValue(22), ScaleValue(52), ScaleValue(52));

    Lbl := TUILabel.Create(Self);
    Lbl.Caption := A.Name;
    Lbl.Bold := True;
    Lbl.FontSize := 15;
    Lbl.Parent := Card;
    Lbl.SetBounds(ScaleValue(84), ScaleValue(18), ScaleValue(360), ScaleValue(22));
    Lbl := TUILabel.Create(Self);
    Lbl.Caption := Tr(ProviderNames[A.Kind]) + '  ·  ' + A.BaseUrl;
    Lbl.Variant := lvMuted;
    Lbl.Parent := Card;
    Lbl.SetBounds(ScaleValue(84), ScaleValue(42), ScaleValue(360), ScaleValue(18));
    Last := IssueStore.LastPoll(A.Id);
    Lbl := TUILabel.Create(Self);
    if Last > 0 then
      Lbl.Caption := State + Tr('  ·  última busca ') + FormatDateTime('dd/mm hh:nn', Last)
    else
      Lbl.Caption := State + Tr('  ·  ainda não buscou');
    Lbl.Variant := lvMuted;
    Lbl.Parent := Card;
    Lbl.SetBounds(ScaleValue(84), ScaleValue(62), ScaleValue(360), ScaleValue(18));

    PerDay := IssueStore.EventsPerDay(14, A.Id);
    Points := '';
    for J := 0 to High(PerDay) do
      Points := Points + IfThen(J > 0, ',') + IntToStr(PerDay[J]);
    Spark := TUISparkline.Create(Self);
    Spark.Kind := skArea;
    Spark.DataPoints := Points;
    Spark.Color := UITheme.Tokens.Color.Primary;
    Spark.Parent := Card;
    Spark.Anchors := [akTop, akRight];
    Spark.SetBounds(Card.Width - ScaleValue(200), ScaleValue(24), ScaleValue(176), ScaleValue(48));
    Spark.Hint := Tr('Avisos por dia, últimos 14 dias');
    Spark.ShowHint := True;

    // Os filhos não repassam o clique ao cartão: liga o mesmo handler neles.
    for J := 0 to Card.ControlCount - 1 do
    begin
      Card.Controls[J].Tag := A.Id;
      TClickAccess(Card.Controls[J]).OnClick := AccountCardClick;
      Card.Controls[J].Cursor := crHandPoint;
    end;
    Inc(Y, ScaleValue(108));
  end;
  FAccountsBox.ContentHeight := Y;
  FAccountsEmpty.Visible := FAccounts = nil;
  FAccountsBox.Visible := FAccounts <> nil;

  RebuildAccountMenu;
end;

{ Menu do seletor de conta. A escolha vale por usuário e filtra lista,
  Dashboard e Ctrl+K. Conta que sumiu volta para "Todas". }
procedure TIssuesPage.RebuildAccountMenu;
var
  A: TAccount;
  Found: Boolean;
begin
  Found := FAccountFilter = 0;
  FAccountMenu.ClearItems;
  FAccountMenu.AddItem('0', Tr('Todas as contas'), HeroIcon('squares-2x2'));
  if FAccounts <> nil then
    FAccountMenu.AddSeparator;
  for A in FAccounts do
  begin
    FAccountMenu.AddItem(IntToStr(A.Id), A.Name, HeroIcon('signal'));
    FAccountMenu.SetItemDetail(IntToStr(A.Id), Tr(ShortProviderNames[A.Kind]));
    Found := Found or (A.Id = FAccountFilter);
  end;
  if not Found then
    FAccountFilter := 0;
  FAccountBtn.Caption := Tr('Todas as contas  ▾');
  for A in FAccounts do
    if A.Id = FAccountFilter then
      FAccountBtn.Caption := A.Name + '  ▾';
end;

procedure TIssuesPage.AccountBtnClick(Sender: TObject);
begin
  FAccountMenu.Open;
end;

procedure TIssuesPage.AccountMenuClick(Sender: TObject; const AID: string);
begin
  FAccountFilter := StrToIntDef(AID, 0);
  IssueStore.SetSetting('account_filter', IntToStr(FAccountFilter));
  RebuildAccountMenu;
  SetDetailVisible(False);
  ReloadTags;
  RebuildRepoMenu;
  ApplyFilters;
  UpdateViews;
  RebuildPalette;
  UpdateHeader;
end;
function TIssuesPage.InFilter(AAccountId: Integer): Boolean;
begin
  Result := (FAccountFilter = 0) or (FAccountFilter = AAccountId);
end;

function TIssuesPage.ItemInView(const AItem: TItem): Boolean;
begin
  Result := InFilter(AItem.AccountId) and
    ((FRepoFilter = '') or SameText(RepoOf(AItem.Key), FRepoFilter));
end;

{ Repositórios das issues do GitHub na conta escolhida, com a quantidade.
  O botão só aparece quando há GitHub na tela. }
procedure TIssuesPage.RebuildRepoMenu;
var
  It: TItem;
  Counts: TDictionary<string, Integer>;
  Repos: TArray<string>;
  R: string;
  N: Integer;
begin
  Counts := TDictionary<string, Integer>.Create;
  try
    for It in FAll do
      if InFilter(It.AccountId) and (RepoOf(It.Key) <> '') then
      begin
        R := RepoOf(It.Key);
        if not Counts.TryGetValue(R, N) then
          N := 0;
        Counts.AddOrSetValue(R, N + 1);
      end;
    Repos := Counts.Keys.ToArray;
    TArray.Sort<string>(Repos, TComparer<string>.Construct(
      function(const L, Rr: string): Integer
      begin
        Result := CompareText(L, Rr);
      end));
    if (FRepoFilter <> '') and not Counts.ContainsKey(FRepoFilter) then
      FRepoFilter := '';
    FRepoMenu.ClearItems;
    FRepoMenu.AddItem('', Tr('Todos os repositórios'), HeroIcon('squares-2x2'));
    FRepoMenu.SetItemDetail('', IntToStr(Length(Repos)));
    if Repos <> nil then
      FRepoMenu.AddSeparator;
    for R in Repos do
    begin
      FRepoMenu.AddItem(R, R);
      FRepoMenu.SetItemDetail(R, IntToStr(Counts[R]));
    end;
    if (Repos <> nil) and not FRepoBtn.Visible then
      // alRight decide pela posição: logo à esquerda da conta, senão ia para a ponta.
      FRepoBtn.Left := FAccountBtn.Left - 1;
    FRepoBtn.Visible := Repos <> nil;
    if FRepoFilter = '' then
      FRepoBtn.Caption := Tr('Todos os repositórios  ▾')
    else
      FRepoBtn.Caption := FRepoFilter.Substring(FRepoFilter.IndexOf('/') + 1) + '  ▾';
  finally
    Counts.Free;
  end;
end;

procedure TIssuesPage.RepoBtnClick(Sender: TObject);
begin
  FRepoMenu.Open;
end;

procedure TIssuesPage.RepoMenuClick(Sender: TObject; const AID: string);
begin
  SetRepoFilter(AID);
end;

procedure TIssuesPage.SetRepoFilter(const ARepo: string);
begin
  FRepoFilter := ARepo;
  IssueStore.SetSetting('repo_filter', FRepoFilter);
  RebuildRepoMenu;
  SetDetailVisible(False);
  ApplyFilters;
  UpdateViews;
  RebuildPalette;
  UpdateHeader;
end;

{ Tags da conta escolhida (todas com "Todas as contas"). }
procedure TIssuesPage.ReloadTags;
var
  T: TTag;
begin
  FTags := nil;
  for T in IssueStore.ListTags do
    if (FAccountFilter = 0) or (T.AccountId = FAccountFilter) then
      FTags := FTags + [T];
  RebuildTagChips;
end;

function TIssuesPage.FilteredItems: TItems;
var
  It: TItem;
begin
  Result := nil;
  for It in FAll do
    if ItemInView(It) then
      Result := Result + [It];
end;
procedure TIssuesPage.AccountCardClick(Sender: TObject);
var
  A: TAccount;
begin
  if AccountById(TComponent(Sender).Tag, A) and EditAccount(Self, A) then
  begin
    ReloadAccounts;
    LoadItems;
    Poll(False);
  end;
end;
procedure TIssuesPage.NewAccountClick(Sender: TObject);
begin
  if EditAccount(Self, NewAccount(pkGitHub)) then
  begin
    ReloadAccounts;
    Poll(False);
  end;
end;

procedure TIssuesPage.SaveApiKeyClick(Sender: TObject);
begin
  if FApiKey.Value.Trim = '' then
  begin
    TUIToastManager.Show(Tr('Informe a chave'), ttWarning);
    Exit;
  end;
  SaveSecret(AiSecretTarget(CurrentAiConfig.Kind), '', FApiKey.Value.Trim);
  FApiKey.Value := '';
  FApiKey.LabelText := Tr('Chave salva (digite para trocar)');
  TUIToastManager.Show(Tr('Chave de ') + AiProviderNames[CurrentAiConfig.Kind] + Tr(' salva.'), ttSuccess);
end;

{ ── Issues ──────────────────────────────────────────────────────────────── }

function TIssuesPage.KeyOf(const AItem: TItem): string;
begin
  Result := IntToStr(AItem.AccountId) + '|' + AItem.Key.ToUpper;
end;

{ Linhas que mudaram brilham por ~1,4 s; as novas também entram deslizando. }
procedure TIssuesPage.FlashChanges(const AKeys: TArray<string>);
var
  K: string;
begin
  FFlashKeys.Clear;
  for K in AKeys do
    FFlashKeys.AddOrSetValue(K, True);
  if (FFlashKeys.Count = 0) and (FNewKeys.Count = 0) then
    Exit;
  FreeAndNil(FFlashAnim);
  FFlashAnim := TUIAnimation.Create(0, 1, 1400, aeLinear);
  FFlashAnim.OnUpdate :=
    procedure(const AValue: Single)
    begin
      FFlashValue := AValue;
      FItemsList.Invalidate;
    end;
  FFlashAnim.OnComplete :=
    procedure
    begin
      FFlashKeys.Clear;
      FNewKeys.Clear;
      FFlashValue := 1;
      FItemsList.Invalidate;
    end;
  FFlashValue := 0;
  FFlashAnim.Start;
end;

function TIssuesPage.IsManual(const AItem: TItem): Boolean;
begin
  Result := FManual.ContainsKey(IntToStr(AItem.AccountId) + '|' + AItem.Key.ToUpper);
end;

{ Lê o snapshot do banco (uma vez por busca) e reaplica os filtros em memória. }
procedure TIssuesPage.LoadItems;
var
  A: TAccount;
  K: string;
  It: TItem;
  MutedRules: TDictionary<string, TMuteRule>;
  Rule: TMuteRule;
begin
  FAll := nil;
  FManual.Clear;
  FOverdue := False;
  for A in FAccounts do
    if A.Enabled then
    begin
      FAll := FAll + IssueStore.LoadSnapshot(A.Id);
      for K in IssueStore.ListManualKeys(A.Id) do
        FManual.AddOrSetValue(IntToStr(A.Id) + '|' + K.ToUpper, True);
    end;
  ReloadTags;
  RebuildRepoMenu;
  FMuted.Clear;
  MutedRules := IssueStore.LoadMuted;
  FDueSoon := False;
  for It in FAll do
  begin
    if IsOverdue(It) then
      FOverdue := True;
    if (It.DueDate > 0) and AccountById(It.AccountId, A) and (DueTone(It.DueDate, A) <> btSuccess) then
      FDueSoon := True;
    if MutedRules.TryGetValue(KeyOf(It), Rule) then
      if Rule.Active(It.Status) then
        FMuted.AddOrSetValue(KeyOf(It), True)
      else
        IssueStore.Unmute(It.AccountId, It.Key);  // prazo ou status passou: solta
  end;
  MutedRules.Free;

  // Com prazo primeiro (mais perto em cima), depois associadas, depois mais recentes.
  TArray.Sort<TItem>(FAll, TComparer<TItem>.Construct(
    function(const L, R: TItem): Integer
    begin
      Result := Ord(R.DueDate > 0) - Ord(L.DueDate > 0);
      if (Result = 0) and (L.DueDate > 0) then
        Result := CompareValue(L.DueDate, R.DueDate);
      if Result = 0 then
        Result := Ord(isAssigned in R.Sources) - Ord(isAssigned in L.Sources);
      if Result = 0 then
        Result := CompareValue(R.UpdatedAt, L.UpdatedAt);
    end));
  ApplyFilters;
  UpdateViews;
  RebuildPalette;
  UpdateAssistantContext;
  UpdateHeader;
  UpdateTrayIcon;
  UpdateMini;
end;

procedure TIssuesPage.UpdateViews;
begin
  FDashboard.AccountFilter := FAccountFilter;
  FDashboard.Update(FilteredItems, FAccounts);
end;

{ Tudo o que o Vigia sabe vai no prompt de sistema: contas, issues (com o
  último comentário) e avisos recentes. O assistente responde sobre qualquer
  tela sem precisar navegar. Tokens nunca entram aqui. }
procedure TIssuesPage.UpdateAssistantContext;
var
  LScreen: string;
begin
  LScreen := '';
  if Assigned(FOnScreenContext) then
    LScreen := FOnScreenContext();
  FAssistant.Config.SystemPrompt := BuildAiContext + sLineBreak +
    Tr('Você também é o assistente do Devbox inteiro, não só das issues. O usuário pode pedir sobre o que está na ' +
    'tela ("isso", "esse texto", "esse log", "esse e-mail"): o conteúdo vem abaixo em "Tela aberta" (e a ferramenta ' +
    'devbox_tela_atual lê de novo). Traduzir, resumir, explicar, melhorar texto, mensagem de commit: responda e, ' +
    'quando o resultado for um texto para usar, ofereça devbox_copiar. Comando de terminal: devbox_rodar_comando ' +
    '(o usuário confirma antes).') + sLineBreak + sLineBreak + LScreen;
end;

{ Antes de cada pergunta (o usuário começou a digitar): o prompt leva a tela de agora. }
procedure TIssuesPage.AssistantStateChange(Sender: TObject; AState: TUIAssistantState);
begin
  if AState = asListening then
    UpdateAssistantContext;
end;

function TIssuesPage.BuildAiContext: string;
const
  MaxEvents = 40;
  MaxCommentChars = 300;
var
  Sb: TStringBuilder;
  It: TItem;
  A: TAccount;
  E: TIssueEvent;
  Err: string;
begin
  Sb := TStringBuilder.Create;
  try
    Sb.AppendLine(Tr('Você é o assistente de issues do Devbox, um app de bandeja que acompanha issues do GitHub e do Jira ' +
      'para o usuário ') + GetEnvironmentVariable('USERNAME') + '.');
    Sb.AppendLine(Tr('Responda em português do Brasil, curto e direto, citando as chaves das issues. ' +
      'Hoje é ') + FormatDateTime('dddd, dd/mm/yyyy hh:nn', Now) + '.');
    Sb.AppendLine(Tr('Você tem ferramentas para agir: registrar horas, comentar, mudar status, marcar impedimento, ' +
      'atribuir, criar issue, abrir uma issue na tela, acompanhar, criar tag e filtrar a lista. Toda escrita no ' +
      'Jira/GitHub pede confirmação do usuário na própria conversa. Use vigia_issue_details para ler descrição ' +
      'e comentários antes de responder sobre o conteúdo de uma issue.'));
    if FHoursWeek > 0 then
      Sb.AppendLine(Format(Tr('Horas lançadas no Jira: %.1fh hoje, %.1fh na semana.'), [FHoursToday, FHoursWeek]));
    if IssueStore.GetSetting('ai_eod_draft') <> '' then
    begin
      Sb.AppendLine(Tr('Rascunho de horas de hoje (feito por você no fim do dia; o usuário pode pedir para lançar):'));
      Sb.AppendLine(IssueStore.GetSetting('ai_eod_draft'));
    end;
    Sb.AppendLine;
    Sb.AppendLine(Tr('## Contas'));
    for A in FAccounts do
    begin
      if not FAccountErrors.TryGetValue(A.Id, Err) then
        Err := '';
      Sb.AppendFormat(Tr('- %s (%s, %s): %s; prazo laranja até %d dias, vermelho até %d dias%s'),
        [A.Name, Tr(ProviderNames[A.Kind]), A.BaseUrl, IfThen(A.Enabled, Tr('ligada'), Tr('desligada')),
         A.WarnDays, A.CriticalDays, IfThen(Err <> '', Tr('; ERRO na última busca: ') + Err, '')]);
      Sb.AppendLine;
    end;
    Sb.AppendLine;
    Sb.AppendLine(Tr('## Issues acompanhadas'));
    Sb.AppendLine(Tr('chave | título | status | conta | vínculo | impedida | entrega | responsável | ' +
      'atualizada | comentários | último comentário'));
    for It in FAll do
    begin
      if not AccountById(It.AccountId, A) then
        Continue;
      Sb.AppendFormat('%s | %s | %s | %s | %s | %s | %s | %s | %s | %d | %s%s', [It.Key, It.Title,
        It.Status, A.Name,
        IfThen(isAssigned in It.Sources, Tr('comigo'), IfThen(IsManual(It), Tr('manual'),
          IfThen(isReview in It.Sources, Tr('review'), Tr('observando')))),
        IfThen(It.Flagged, 'sim', Tr('não')),
        IfThen(It.DueDate > 0, FormatDateTime('dd/mm/yyyy', It.DueDate), '-'),
        IfThen(It.Assignee <> '', It.Assignee, '-'),
        IfThen(It.UpdatedAt > 0, FormatDateTime('dd/mm hh:nn', TTimeZone.Local.ToLocalTime(It.UpdatedAt)), '-'),
        It.CommentCount,
        IfThen(It.LastCommentText <> '', It.LastCommentBy + ': ' +
          Copy(It.LastCommentText.Replace(#13, ' ').Replace(#10, ' '), 1, MaxCommentChars), '-'),
        IfThen(It.CiState <> '', Tr(' | CI ') + It.CiState + IfThen(It.CiDetail <> '', ' (' + It.CiDetail + ')', ''), '') +
        IfThen(It.Reviewers <> '', ' | ' + It.Reviewers, '') +
        IfThen(isSprint in It.Sources, Tr(' | sprint ativa'), '')]);
      Sb.AppendLine;
    end;
    Sb.AppendLine;
    Sb.AppendLine(Tr('## Avisos recentes (mais novos primeiro)'));
    for E in IssueStore.ListRecentEvents(MaxEvents) do
    begin
      Sb.AppendFormat('%s | %s | %s | %s', [FormatDateTime('dd/mm hh:nn', E.At), E.Key,
        Tr(EventNames[E.Kind]), E.Body]);
      Sb.AppendLine;
    end;
    Result := Sb.ToString;
  finally
    Sb.Free;
  end;
end;

function TIssuesPage.FindItem(const AKey: string; out AItem: TItem; out AAccount: TAccount): Boolean;
var
  It: TItem;
begin
  for It in FAll do
    if SameText(It.Key, AKey.Trim) and AccountById(It.AccountId, AAccount) then
    begin
      AItem := It;
      Exit(True);
    end;
  Result := False;
end;

procedure TIssuesPage.ToolItem(const AArgs: TJSONObject; out AItem: TItem; out AAccount: TAccount);
var
  Key: string;
begin
  Key := AArgs.GetValue<string>('key', '').Trim;
  if not FindItem(Key, AItem, AAccount) then
    raise Exception.CreateFmt(Tr('Issue %s não está entre as acompanhadas'), [Key]);
end;

{ Ferramentas do assistente (só com Anthropic; o provedor compatível com OpenAI
  é só texto). Escrita = RequiresConfirm: o chat pede Permitir/Negar antes. }
procedure TIssuesPage.RegisterAiTools;
var
  D: TUIAssistantToolDef;

begin
  D := FAssistant.Tools.Register('vigia_issue_details',
    Tr('Lê descrição, anexos, ligações e os últimos comentários de uma issue.'),
    function(const AArgs: TJSONObject): string
    var
      It: TItem;
      A: TAccount;
      Info: TIssueInfo;
      C: TComment;
      L: TIssueLink;
    begin
      ToolItem(AArgs, It, A);
      Info := FetchIssueInfo(A, LoadSecret(A.SecretTarget), It.Key);
      Result := Tr('Descrição: ') + Copy(Info.Description, 1, 4000) + sLineBreak;
      for L in Info.Links do
        Result := Result + Format(Tr('Ligação: %s %s (%s)'), [L.Kind, L.Key, L.Summary]) + sLineBreak;
      for C in FetchComments(A, LoadSecret(A.SecretTarget), It.Key, 10) do
        Result := Result + Format(Tr('Comentário de %s em %s: %s'), [C.Author,
          FormatDateTime('dd/mm hh:nn', TTimeZone.Local.ToLocalTime(C.At)), Copy(C.Text, 1, 1500)]) + sLineBreak;
    end);
  D.AddParam('key', pkString, Tr('Chave da issue, ex.: PROJ-123 ou dono/repo#12'), True);

  D := FAssistant.Tools.Register('vigia_log_hours', Tr('Registra horas trabalhadas numa issue do Jira.'),
    function(const AArgs: TJSONObject): string
    var
      It: TItem;
      A: TAccount;
      Day: TDateTime;
      Start: string;
    begin
      ToolItem(AArgs, It, A);
      if not (A.Kind in WorklogKinds) then
        raise Exception.Create(ShortProviderNames[A.Kind] + Tr(' não tem registro de horas pelo Devbox'));
      Day := Date;
      if AArgs.GetValue<string>('date', '') <> '' then
        Day := ISO8601ToDate(AArgs.GetValue<string>('date') + 'T00:00:00', False);
      Start := AArgs.GetValue<string>('start', '09:00');
      AddWorklog(A, LoadSecret(A.SecretTarget), It.Key, AArgs.GetValue<Double>('hours'),
        Day + EncodeTime(StrToIntDef(Copy(Start, 1, 2), 9), StrToIntDef(Copy(Start, 4, 2), 0), 0, 0),
        AArgs.GetValue<string>('note', ''));
      Poll(False);
      Result := Tr('Horas registradas');
    end, True);
  D.AddParam('key', pkString, Tr('Chave da issue'), True);
  D.AddParam('hours', pkNumber, Tr('Horas, ex.: 1.5'), True);
  D.AddParam('date', pkString, 'Dia no formato yyyy-mm-dd; vazio = hoje');
  D.AddParam('start', pkString, Tr('Hora de início HH:MM; vazio = 09:00'));
  D.AddParam('note', pkString, Tr('O que foi feito'));

  D := FAssistant.Tools.Register('vigia_comment', Tr('Publica um comentário na issue.'),
    function(const AArgs: TJSONObject): string
    var
      It: TItem;
      A: TAccount;
    begin
      ToolItem(AArgs, It, A);
      PostComment(A, LoadSecret(A.SecretTarget), It.Key, AArgs.GetValue<string>('text'));
      Result := Tr('Comentário publicado');
    end, True);
  D.AddParam('key', pkString, Tr('Chave da issue'), True);
  D.AddParam('text', pkString, Tr('Texto do comentário'), True);

  D := FAssistant.Tools.Register('vigia_list_transitions', Tr('Lista os status para onde a issue pode ir agora.'),
    function(const AArgs: TJSONObject): string
    var
      It: TItem;
      A: TAccount;
      T: TTransition;
    begin
      ToolItem(AArgs, It, A);
      Result := '';
      for T in FetchTransitions(A, LoadSecret(A.SecretTarget), It.Key) do
        Result := Result + T.ToStatus + IfThen(T.Fields <> nil, Tr(' (pede campos na tela)'), '') + sLineBreak;
    end);
  D.AddParam('key', pkString, Tr('Chave da issue'), True);

  D := FAssistant.Tools.Register('vigia_change_status', Tr('Muda o status da issue (use um nome de vigia_list_transitions).'),
    function(const AArgs: TJSONObject): string
    var
      It: TItem;
      A: TAccount;
      T: TTransition;
      Want: string;
    begin
      ToolItem(AArgs, It, A);
      Want := AArgs.GetValue<string>('status', '');
      for T in FetchTransitions(A, LoadSecret(A.SecretTarget), It.Key) do
        if SameText(T.ToStatus, Want) or SameText(T.Name, Want) then
        begin
          if T.Fields <> nil then
            raise Exception.Create(Tr('Essa transição pede campos. Peça ao usuário para usar botão direito > Mudar status'));
          ApplyTransition(A, LoadSecret(A.SecretTarget), It.Key, T);
          Poll(False);
          Exit(Tr('Status alterado para ') + T.ToStatus);
        end;
      raise Exception.CreateFmt(Tr('Status "%s" não disponível agora'), [Want]);
    end, True);
  D.AddParam('key', pkString, Tr('Chave da issue'), True);
  D.AddParam('status', pkString, Tr('Status de destino'), True);

  D := FAssistant.Tools.Register('vigia_set_impediment', Tr('Jira: marca ou tira impedimento (Flagged) e comenta o motivo.'),
    function(const AArgs: TJSONObject): string
    var
      It: TItem;
      A: TAccount;
    begin
      ToolItem(AArgs, It, A);
      SetImpediment(A, LoadSecret(A.SecretTarget), It.Key, AArgs.GetValue<Boolean>('on', True), AArgs.GetValue<string>('reason', ''));
      Poll(False);
      Result := Tr('Feito');
    end, True);
  D.AddParam('key', pkString, Tr('Chave da issue'), True);
  D.AddParam('on', pkBoolean, Tr('true marca, false tira'), True);
  D.AddParam('reason', pkString, Tr('Motivo (vira comentário)'));

  D := FAssistant.Tools.Register('vigia_assign_me', Tr('Atribui a issue ao usuário.'),
    function(const AArgs: TJSONObject): string
    var
      It: TItem;
      A: TAccount;
    begin
      ToolItem(AArgs, It, A);
      AssignToMe(A, LoadSecret(A.SecretTarget), It.Key);
      Poll(False);
      Result := Tr('Atribuída');
    end, True);
  D.AddParam('key', pkString, Tr('Chave da issue'), True);

  D := FAssistant.Tools.Register('vigia_create_issue', Tr('Cria uma issue no Jira (projeto) ou GitHub (dono/repo).'),
    function(const AArgs: TJSONObject): string
    var
      A: TAccount;
      Found: Boolean;
    begin
      Found := False;
      for A in FAccounts do
        if SameText(A.Name, AArgs.GetValue<string>('account', '')) then
        begin
          Found := True;
          Result := Tr('Criada: ') + CreateIssue(A, LoadSecret(A.SecretTarget), AArgs.GetValue<string>('where'),
            AArgs.GetValue<string>('title'), AArgs.GetValue<string>('body', ''));
          Break;
        end;
      if not Found then
        raise Exception.Create(Tr('Conta não encontrada; use o nome que aparece em Contas'));
    end, True);
  D.AddParam('account', pkString, Tr('Nome da conta no Devbox'), True);
  D.AddParam('where', pkString, Tr('Chave do projeto Jira ou dono/repo do GitHub'), True);
  D.AddParam('title', pkString, Tr('Título'), True);
  D.AddParam('body', pkString, Tr('Descrição'));

  D := FAssistant.Tools.Register('vigia_open_issue', Tr('Abre o painel da issue na tela de Issues do Devbox.'),
    function(const AArgs: TJSONObject): string
    var
      It: TItem;
      A: TAccount;
    begin
      ToolItem(AArgs, It, A);
      OpenDetail(It);
      Result := Tr('Aberta');
    end);
  D.AddParam('key', pkString, Tr('Chave da issue'), True);

  D := FAssistant.Tools.Register('vigia_watch', Tr('Passa a acompanhar uma issue pela chave (PROJ-123 ou dono/repo#12).'),
    function(const AArgs: TJSONObject): string
    begin
      WatchKey(AArgs.GetValue<string>('key'));
      Result := Tr('Acompanhando');
    end);
  D.AddParam('key', pkString, Tr('Chave da issue'), True);

  D := FAssistant.Tools.Register('vigia_create_tag', Tr('Cria uma #tag local que agrupa issues por palavras do título.'),
    function(const AArgs: TJSONObject): string
    var
      T: TTag;
      A: TAccount;
    begin
      T := Default(TTag);
      T.Name := AArgs.GetValue<string>('name').Trim.TrimLeft(['#']);
      T.Keywords := AArgs.GetValue<string>('keywords', '');
      T.AccountId := 0;
      for A in FAccounts do
        if SameText(A.Name, AArgs.GetValue<string>('account', '')) or (T.AccountId = 0) then
          T.AccountId := A.Id;
      IssueStore.SaveTag(T);
      ReloadTags;
      LoadItems;
      Result := Tr('Tag #') + T.Name + Tr(' criada');
    end);
  D.AddParam('name', pkString, Tr('Nome sem #'), True);
  D.AddParam('keywords', pkString, Tr('Palavras do título separadas por vírgula'), True);
  D.AddParam('account', pkString, Tr('Nome da conta; vazio = primeira'));

  D := FAssistant.Tools.Register('vigia_filter', Tr('Filtra a lista de Issues na tela.'),
    function(const AArgs: TJSONObject): string
    var
      F: TItemFilter;
      Chips: string;
      I: Integer;
    begin
      ClearFiltersClick(nil);
      Chips := AArgs.GetValue<string>('chips', '');
      for F := Low(TItemFilter) to High(TItemFilter) do
        if ContainsText(Chips, Tr(FilterNames[F])) then
          FChips[F].Active := True;
      for I := 0 to High(FTags) do
        if SameText('#' + FTags[I].Name, AArgs.GetValue<string>('tag', '')) or
          SameText(FTags[I].Name, AArgs.GetValue<string>('tag', '')) then
          FTagChips[I].Active := True;
      if AArgs.GetValue<string>('repo', '') <> '' then
        SetRepoFilter(AArgs.GetValue<string>('repo'));
      ShowPage(pgIssues);
      ApplyFilters;
      Result := Format(Tr('%d issues na lista'), [Length(FShown)]);
    end);
  D.AddParam('chips', pkString, Tr('Filtros separados por vírgula: Comigo, Atrasadas, Review, Manuais, ' +
    'Impedidas, Meus PRs, Sprint'));
  D.AddParam('tag', pkString, Tr('Nome de uma tag'));
  D.AddParam('repo', pkString, Tr('dono/repo do GitHub'));
end;

{ ── IA automática (opt-in) ── }

procedure TIssuesPage.AiAutoChange(Sender: TObject);
var
  I: Integer;
begin
  if Sender = FAiCap then
    IssueStore.SetSetting('ai_month_cap', FloatToStr(FAiCap.Value, TFormatSettings.Invariant))
  else if Sender = FAiCheap then
    IssueStore.SetSetting('ai_cheap_model_' + AiProviderIds[CurrentAiConfig.Kind], FAiCheap.Value.Trim)
  else
    for I := 0 to High(FAiAuto) do
      if Sender = FAiAuto[I] then
        IssueStore.SetSetting(AiAutoKeys[I], IfThen(FAiAuto[I].Checked, '1', '0'));
end;

{ Triagem: a IA sugere uma das tags da conta e a prioridade. A sugestão fica
  guardada por issue; aplicar é decisão do usuário (botão direito › Ações). }
procedure TIssuesPage.TriageItems(const AItems: TItems; AManual: Boolean);
const
  MaxAuto = 3;
var
  It: TItem;
  T: TTag;
  A: TAccount;
  TagList, Prompt: string;
  N: Integer;
begin
  N := 0;
  for It in AItems do
  begin
    if not AManual and (N >= MaxAuto) then
      Break;
    if not AccountById(It.AccountId, A) then
      Continue;
    TagList := '';
    for T in FTags do
      if T.AccountId = It.AccountId then
        TagList := TagList + Format(Tr('- %s (palavras: %s)'), [T.Name, T.Keywords]) + sLineBreak;
    Prompt := Format(Tr('Issue %s no %s: "%s". Status: %s. Prazo: %s. Responsável: %s.'), [It.Key,
      Tr(ShortProviderNames[A.Kind]), It.Title, It.Status, IfThen(It.DueDate > 0,
      FormatDateTime('dd/mm/yyyy', It.DueDate), Tr('sem')), IfThen(It.Assignee <> '', It.Assignee, Tr('ninguém'))]) +
      sLineBreak + Tr('Tags do usuário:') + sLineBreak + IfThen(TagList <> '', TagList, Tr('(nenhuma)') + sLineBreak) +
      'Responda só um JSON: {"tag": "nome de uma das tags ou vazio", "prioridade": "Alta, Média ou Baixa", ' +
      '"motivo": "até 15 palavras"}';
    Inc(N);
    AiAsk(Tr('Você faz triagem de issues para um desenvolvedor. Seja direto. Responda só o JSON pedido.'),
      Prompt, True,
      procedure(AText: string)
      var
        J: TJSONValue;
        Json, Tag, Prio, Why: string;
      begin
        // O modelo às vezes cerca o JSON com texto: pega do primeiro { ao último }.
        Json := Copy(AText, Pos('{', AText), LastDelimiter('}', AText) - Pos('{', AText) + 1);
        J := TJSONObject.ParseJSONValue(Json);
        try
          if not (J is TJSONObject) then
          begin
            if AManual then
              TUIToastManager.Show(Tr('A IA não devolveu uma sugestão válida'), ttWarning);
            Exit;
          end;
          Tag := J.GetValue<string>('tag', '').TrimLeft(['#']).Trim;
          Prio := J.GetValue<string>('prioridade', '').Trim;
          Why := J.GetValue<string>('motivo', '').Trim;
        finally
          J.Free;
        end;
        IssueStore.SetSetting(TriageSettingName(It.AccountId, It.Key), Json);
        if AManual then
          TUIToastManager.Show(Format('%s: %s%s · %s', [It.Key, IfThen(Tag <> '', '#' + Tag + ' · ', ''),
            Prio, Why]), ttInfo, 8000)
        else
          Notify(Tr('Triagem · ') + It.Key, Format('%s%s · %s', [IfThen(Tag <> '', '#' + Tag + ' · ', ''), Prio,
            Why]), '', stInfo, It.Key, It.AccountId);
        if DetailOpen and SameText(FDetail.Item.Key, It.Key) and AccountById(It.AccountId, A) then
          FDetail.ShowItem(FDetail.Item, A);
      end,
      procedure(AErr: string)
      begin
        if AManual then
          TUIToastManager.Show(Tr('Triagem: ') + AErr, ttError, 6000);
      end);
  end;
end;

{ Aplica a sugestão: marca a tag local e, no Jira, muda a prioridade (com confirmação). }
procedure TIssuesPage.ApplyTriage(const AItem: TItem);
var
  J: TJSONValue;
  Tag, Prio, Pick: string;
  T: TTag;
  A: TAccount;
  It: TItem;
  Found: Boolean;
begin
  J := TJSONObject.ParseJSONValue(IssueStore.GetSetting(TriageSettingName(AItem.AccountId, AItem.Key)));
  try
    if J = nil then
      Exit;
    Tag := J.GetValue<string>('tag', '').TrimLeft(['#']).Trim;
    Prio := J.GetValue<string>('prioridade', '').Trim;
  finally
    J.Free;
  end;
  It := AItem;
  Found := False;
  if Tag <> '' then
    for T in FTags do
      if (T.AccountId = AItem.AccountId) and SameText(T.Name, Tag) then
      begin
        IssueStore.SetItemTag(T.Id, AItem.AccountId, AItem.Key, True);
        Found := True;
      end;
  if Found then
    TUIToastManager.Show(AItem.Key + Tr(' marcada com #') + Tag, ttSuccess);
  LoadItems;
  if (Prio = '') or not AccountById(AItem.AccountId, A) or not (A.Kind in JiraKinds) then
    Exit;
  if not AskConfirm(Self, Tr('Prioridade'), Format(Tr('Mudar a prioridade de %s para "%s" no Jira?'),
    [AItem.Key, Prio]), Tr('Mudar')) then
    Exit;
  RunAction(It, Tr('Prioridade de ') + AItem.Key + Tr(' alterada'),
    procedure(AAcc: TAccount; AToken: string)
    var
      Names: TArray<string>;
      N: string;
    begin
      // Nome do Jira pode estar em inglês: casa "Alta" com "High" pela posição usual.
      Names := FetchPriorities(AAcc, AToken);
      Pick := '';
      for N in Names do
        if ContainsText(N, Prio) or
          (SameText(Prio, 'Alta') and ContainsText(N, 'High')) or
          ((Prio.StartsWith('M', True)) and ContainsText(N, 'Medium')) or
          (SameText(Prio, 'Baixa') and ContainsText(N, 'Low')) then
        begin
          Pick := N;
          Break;
        end;
      if Pick = '' then
        raise Exception.Create(Tr('Prioridade "') + Prio + Tr('" não existe neste Jira'));
      SetPriority(AAcc, AToken, AItem.Key, Pick);
    end);
end;

{ PR com CI vermelho: lê o fim do log do job e pede a causa provável. }
procedure TIssuesPage.ExplainCiFailure(const AItem: TItem);
var
  A: TAccount;
  It: TItem;
begin
  if (IssueStore.GetSetting('ai_ci') <> '1') or (AItem.CiUrl = '') or not AccountById(AItem.AccountId, A) then
    Exit;
  It := AItem;
  RunTask(
    procedure
    var
      Log: string;
    begin
      try
        Log := FetchJobLog(A, LoadSecret(A.SecretTarget), It.CiUrl);
      except
        on E: Exception do
          Log := '';
      end;
      if Log = '' then
        Exit;
      QueueUI(
        procedure
        begin
          AiAsk(Tr('Você analisa falhas de CI. Responda em português, em até 3 frases curtas: causa provável e ' +
            'o que fazer. Sem markdown.'), Tr('Job "') + It.CiDetail + Tr('" do PR ') + It.Key + Tr(' falhou. Fim do log:') +
            sLineBreak + Log, True,
            procedure(AText: string)
            begin
              IssueStore.SetSetting('ai_ci_' + It.Key, AText);
              Notify(Tr('CI de ') + It.Key + Tr(' · causa provável'), AText, It.CiUrl, stError, It.Key, It.AccountId);
            end);
        end);
    end);
end;

{ Uma vez por dia cada: resumo (no horário do resumo), risco (após a 1ª busca)
  e rascunho de horas (a partir das 17:30). }
procedure TIssuesPage.RunAutoAi;
const
  EodTime = 17.5 / 24;
var
  Today: string;
begin
  if FLastPoll = 0 then
    Exit;
  Today := FormatDateTime('yyyy-mm-dd', Date);
  if (IssueStore.GetSetting('ai_risk') = '1') and (IssueStore.GetSetting('ai_risk_last') <> Today) then
  begin
    IssueStore.SetSetting('ai_risk_last', Today);
    AiAsk(BuildAiContext, Tr('Aponte até 3 issues com maior risco de atrasar ou travar (prazo perto, impedida, ' +
      'parada há dias, CI falhando). Uma linha por issue: chave e motivo. Se não houver risco real, ' +
      'responda só NADA.'), True,
      procedure(AText: string)
      begin
        if not SameText(AText, 'NADA') then
          Notify(Tr('Issues · riscos de hoje'), AText, '', stWarning, '*dashboard');
      end);
  end;
  if (IssueStore.GetSetting('ai_eod') = '1') and (Frac(Now) >= EodTime) and
    (IssueStore.GetSetting('ai_eod_last') <> Today) and (DayOfTheWeek(Date) <= 5) then
  begin
    IssueStore.SetSetting('ai_eod_last', Today);
    AiAsk(BuildAiContext, Format(Tr('Fim do dia. Já lancei %.1fh hoje. Pelos avisos e issues de hoje, rascunhe ' +
      'lançamentos de horas que faltam: uma linha por issue no formato "CHAVE · horas · o que foi feito". ' +
      'Se não houver o que lançar, responda só NADA.'), [FHoursToday]), True,
      procedure(AText: string)
      begin
        if SameText(AText, 'NADA') then
          Exit;
        IssueStore.SetSetting('ai_eod_draft', AText);
        Notify(Tr('Issues · rascunho de horas'), AText + sLineBreak +
          Tr('Peça ao assistente: "lance o rascunho de horas".'), '', stInfo, '*dashboard');
      end);
  end;
end;

procedure TIssuesPage.ApplyFilters;
var
  It: TItem;
  A: TAccount;
  F: TItemFilter;
  AnyChip, Pass: Boolean;
  Tag, KeepKey: string;
  Tone: TUIBadgeTone;
  V: TUIVListItem;
  I, First: Integer;
  Sel: TItem;
  Badges: TBadges;
  Counts: array[TItemFilter] of Integer;
  TagCounts: TArray<Integer>;
  AnyTag, TagPass: Boolean;
  Active: string;
  T: Integer;
begin
  SetLength(TagCounts, Length(FTags));
  AnyTag := False;
  for T := 0 to High(FTagChips) do
    AnyTag := AnyTag or FTagChips[T].Active;
  AnyChip := False;
  for F := Low(TItemFilter) to High(TItemFilter) do
  begin
    AnyChip := AnyChip or FChips[F].Active;
    Counts[F] := 0;
  end;

  KeepKey := '';
  if SelectedItem(Sel) then
    KeepKey := Sel.Key;
  First := TListAccess(FItemsList).FirstVisible;

  FShown := nil;
  FShownTone := nil;
  FShownBadges := nil;
  FShownTag := nil;
  FItemsList.ClearItems;
  for It in FAll do
  begin
    if not ItemInView(It) then
      Continue;

    // Contador de cada chip antes de aplicar os chips.
    if isAssigned in It.Sources then Inc(Counts[ifMine]);
    if IsOverdue(It) then Inc(Counts[ifOverdue]);
    if isReview in It.Sources then Inc(Counts[ifReview]);
    if IsManual(It) then Inc(Counts[ifManual]);
    if It.Flagged then Inc(Counts[ifFlagged]);
    if isMine in It.Sources then Inc(Counts[ifMyPrs]);
    if isSprint in It.Sources then Inc(Counts[ifSprint]);
    if NeedsActionNow(It) then Inc(Counts[ifNow]);
    for T := 0 to High(FTags) do
      if FTags[T].Matches(It) then
        Inc(TagCounts[T]);

    if not DrillPass(It) then
      Continue;

    // Tags somam entre si (OU) e filtram junto com os chips de cima (E).
    if AnyTag then
    begin
      TagPass := False;
      for T := 0 to High(FTags) do
        TagPass := TagPass or (FTagChips[T].Active and FTags[T].Matches(It));
      if not TagPass then
        Continue;
    end;

    if AnyChip then
    begin
      // Chips somam (OU): "Comigo" + "Atrasadas" mostra as duas coisas.
      Pass := (FChips[ifMine].Active and (isAssigned in It.Sources)) or
        (FChips[ifOverdue].Active and IsOverdue(It)) or
        (FChips[ifReview].Active and (isReview in It.Sources)) or
        (FChips[ifManual].Active and IsManual(It)) or
        (FChips[ifFlagged].Active and It.Flagged) or
        (FChips[ifMyPrs].Active and (isMine in It.Sources)) or
        (FChips[ifSprint].Active and (isSprint in It.Sources)) or
        (FChips[ifNow].Active and NeedsActionNow(It));
      if not Pass then
        Continue;
    end;

    if IsOverdue(It) then
    begin
      Tag := Tr('atrasada');
      Tone := btError;
    end
    else if isAssigned in It.Sources then
    begin
      Tag := Tr('comigo');
      Tone := btPrimary;
    end
    else if isReview in It.Sources then
    begin
      Tag := Tr('review');
      Tone := btInfo;
    end
    else if isMine in It.Sources then
    begin
      Tag := Tr('meu PR');
      Tone := btSuccess;
    end
    else if isMention in It.Sources then
    begin
      Tag := Tr('mencionado');
      Tone := btWarning;
    end
    else if isQuery in It.Sources then
    begin
      Tag := Tr('busca');
      Tone := btNeutral;
    end
    else if isOwnRepo in It.Sources then
    begin
      Tag := Tr('meu repo');
      Tone := btNeutral;
    end
    else if IsManual(It) then
    begin
      Tag := Tr('manual');
      Tone := btWarning;
    end
    else
    begin
      Tag := Tr('observando');
      Tone := btNeutral;
    end;

    Badges := nil;
    if (FAccountFilter = 0) and (Length(FAccounts) > 1) and AccountById(It.AccountId, A) then
      Badges := Badges + [Badge(A.Name, btNeutral)];
    for T := 0 to High(FTags) do
      if FTags[T].Matches(It) then
        Badges := Badges + [Badge('#' + FTags[T].Name, btSuccess)];
    if It.Status <> '' then
      Badges := Badges + [Badge(It.Status, StatusTone(It.StatusCategory))];
    if It.Flagged then
      Badges := Badges + [Badge(Tr('Impedida'), btError)];
    if SameText(It.ReviewState, 'APPROVED') then
      Badges := Badges + [Badge(Tr('Aprovado'), btSuccess)]
    else if SameText(It.ReviewState, 'CHANGES_REQUESTED') then
      Badges := Badges + [Badge(Tr('Mudanças pedidas'), btWarning)];
    if MatchText(It.CiState, ['FAILURE', 'ERROR']) then
      Badges := Badges + [Badge(Tr('CI falhou'), btError)]
    else if MatchText(It.CiState, ['PENDING', 'EXPECTED']) then
      Badges := Badges + [Badge(Tr('CI rodando'), btInfo)]
    else if SameText(It.CiState, 'SUCCESS') then
      Badges := Badges + [Badge(Tr('CI ok'), btSuccess)];
    if (It.DueDate > 0) and AccountById(It.AccountId, A) then
      Badges := Badges + [Badge(IfThen(A.DueField <> '', Tr('Entrega '), Tr('Prazo ')) +
        FormatDateTime('dd/mm', It.DueDate), DueTone(It.DueDate, A))];
    if FMuted.ContainsKey(KeyOf(It)) then
      Badges := Badges + [Badge(Tr('silenciada'), btGhost)];

    // A lista só desenha fundo, hover e seleção; as 3 linhas vêm do OnCustomDraw.
    V := Default(TUIVListItem);
    V.ID := It.Key;
    FItemsList.AddItem(V);
    FShown := FShown + [It];
    FShownTone := FShownTone + [Ord(Tone)];
    FShownBadges := FShownBadges + [Badges];
    FShownTag := FShownTag + [Tag];
  end;

  IssueStore.SetSetting('group_list', IfThen(FGroupChip.Active, '1', ''));
  if FGroupChip.Active then
    RegroupShown;

  // Mantém a posição e a seleção entre recargas.
  for I := 0 to High(FShown) do
    if SameText(FShown[I].Key, KeepKey) then
      FItemsList.SelectIndex(I);
  if (First > 0) and (FShown <> nil) then
    TListAccess(FItemsList).ScrollTo(Min(First, High(FShown)) * FItemsList.RowHeight);

  for F := Low(TItemFilter) to High(TItemFilter) do
    FChips[F].Count := Counts[F];
  // Sprint só existe no Jira com Agile: sem itens, o chip some.
  if (Counts[ifSprint] > 0) or FChips[ifSprint].Active then
  begin
    FChips[ifSprint].Left := FChips[ifMyPrs].Left + FChips[ifMyPrs].Width + 1;
    FChips[ifSprint].Visible := True;
  end
  else
    FChips[ifSprint].Visible := False;
  for T := 0 to High(FTagChips) do
    FTagChips[T].Count := TagCounts[T];

  // Lista, esqueleto (primeira busca) ou vazio.
  FSkeleton.Visible := (FShown = nil) and (FAll = nil) and FPolling;
  FItemsEmpty.Visible := (FShown = nil) and not FSkeleton.Visible;
  FItemsList.Visible := FShown <> nil;
  if FItemsEmpty.Visible then
  begin
    if FAccounts = nil then
    begin
      FItemsEmpty.Title := Tr('Nenhuma conta ainda');
      FItemsEmpty.Description := Tr('Cadastre uma conta do GitHub ou do Jira em Configuração › Issues.');
      FItemsEmpty.ActionLabel := Tr('Nova conta');
      FItemsEmpty.OnAction := NewAccountClick;
    end
    else if FAll = nil then
    begin
      FItemsEmpty.Title := Tr('Nada acompanhado ainda');
      FItemsEmpty.Description := Tr('A lista enche depois da primeira busca.');
      FItemsEmpty.ActionLabel := Tr('Atualizar agora');
      FItemsEmpty.OnAction := RefreshClick;
    end
    else
    begin
      // Diz o que está filtrando, para não parecer que sumiu tudo.
      Active := '';
      for F := Low(TItemFilter) to High(TItemFilter) do
        if FChips[F].Active then
          Active := Active + IfThen(Active <> '', ', ') + Tr(FilterNames[F]);
      for T := 0 to High(FTagChips) do
        if FTagChips[T].Active then
          Active := Active + IfThen(Active <> '', ', ') + '#' + FTags[T].Name;
      if FDrill.Kind <> dkNone then
        Active := Active + IfThen(Active <> '', ', ') + FDrill.Caption;
      if FRepoFilter <> '' then
        Active := Active + IfThen(Active <> '', ', ') + FRepoFilter;
      FItemsEmpty.Title := Tr('Nada com esse filtro');
      FItemsEmpty.Description := IfThen(Active <> '', Tr('Filtrando por: ') + Active + '.',
        Tr('Nenhuma issue nesta conta.'));
      FItemsEmpty.ActionLabel := IfThen(Active <> '', Tr('Limpar filtros'), '');
      FItemsEmpty.OnAction := ClearFiltersClick;
    end;
  end;
end;

procedure TIssuesPage.FilterChanged(Sender: TObject);
begin
  ApplyFilters;
end;

procedure TIssuesPage.ClearFiltersClick(Sender: TObject);
var
  F: TItemFilter;
  C: TUIFilterChip;
begin
  for F := Low(TItemFilter) to High(TItemFilter) do
    FChips[F].Active := False;
  for C in FTagChips do
    C.Active := False;
  FDrill := Default(TDrill);
  FDrillChip.Visible := False;
  if FRepoFilter <> '' then
    SetRepoFilter('')
  else
    ApplyFilters;
end;

{ Linha de cabeçalho: AccountId = -1, Key = nome do grupo; CommentCount = itens,
  DueAlert = atrasadas, Flagged por contagem em LastCommentText. }
function TIssuesPage.IsGroupRow(AIndex: Integer): Boolean;
begin
  Result := (AIndex >= 0) and (AIndex <= High(FShown)) and (FShown[AIndex].AccountId = -1);
end;

{ Reordena FShown em grupos (repositório no GitHub, projeto no Jira), do maior
  para o menor, com um cabeçalho por grupo. Grupo recolhido mostra só o cabeçalho. }
procedure TIssuesPage.RegroupShown;
var
  Names: TArray<string>;
  Idx: TDictionary<string, TList<Integer>>;
  G: string;
  I, J: Integer;
  H: TItem;
  L: TList<Integer>;
  Items: TItems;
  Tones: TArray<Integer>;
  Bdg: TArray<TBadges>;
  Tags: TArray<string>;
  V: TUIVListItem;
  Overdue, Flagged: Integer;

  function GroupOf(const AItem: TItem): string;
  begin
    Result := RepoOf(AItem.Key);
    if Result = '' then
      Result := AItem.Key.Substring(0, AItem.Key.IndexOf('-'));
  end;

begin
  Idx := TObjectDictionary<string, TList<Integer>>.Create([doOwnsValues]);
  try
    for I := 0 to High(FShown) do
    begin
      G := GroupOf(FShown[I]);
      if not Idx.TryGetValue(G, L) then
      begin
        L := TList<Integer>.Create;
        Idx.Add(G, L);
      end;
      L.Add(I);
    end;
    Names := Idx.Keys.ToArray;
    TArray.Sort<string>(Names, TComparer<string>.Construct(
      function(const A, B: string): Integer
      begin
        Result := Idx[B].Count - Idx[A].Count;
        if Result = 0 then
          Result := CompareText(A, B);
      end));
    FItemsList.ClearItems;
    for G in Names do
    begin
      L := Idx[G];
      Overdue := 0;
      Flagged := 0;
      for J in L do
      begin
        if IsOverdue(FShown[J]) then Inc(Overdue);
        if FShown[J].Flagged then Inc(Flagged);
      end;
      H := Default(TItem);
      H.AccountId := -1;
      H.Key := G;
      H.CommentCount := L.Count;
      H.DueAlert := Overdue;
      H.LastCommentText := IntToStr(Flagged);
      Items := Items + [H];
      Tones := Tones + [0];
      Bdg := Bdg + [nil];
      Tags := Tags + [''];
      V := Default(TUIVListItem);
      V.ID := '#grupo:' + G;
      FItemsList.AddItem(V);
      if FCollapsed.ContainsKey(G) then
        Continue;
      for J in L do
      begin
        Items := Items + [FShown[J]];
        Tones := Tones + [FShownTone[J]];
        Bdg := Bdg + [FShownBadges[J]];
        Tags := Tags + [FShownTag[J]];
        V := Default(TUIVListItem);
        V.ID := FShown[J].Key;
        FItemsList.AddItem(V);
      end;
    end;
    FShown := Items;
    FShownTone := Tones;
    FShownBadges := Bdg;
    FShownTag := Tags;
  finally
    Idx.Free;
  end;
end;

procedure TIssuesPage.DrawGroupRow(AIndex: Integer; const ACanvas: ISkCanvas; const ARowRect: TRectF);
var
  T: TUITokens;
  H: TItem;
  L, Cy, X: Single;
  NameFont, SubFont: ISkFont;
  Sub: string;
  Badges: TBadges;
begin
  T := UITheme.Tokens;
  H := FShown[AIndex];
  UIDrawRRectFill(ACanvas, ARowRect, 0, UIColorWithAlpha(T.Color.FG, 0.035));
  L := ARowRect.Left + 14;
  Cy := ARowRect.CenterPoint.Y;
  NameFont := TUIFontManager.GetFont(T.Typography.FamilyPrimary, 14, T.Typography.WeightSemiBold);
  SubFont := TUIFontManager.GetFont(T.Typography.FamilyPrimary, 12, T.Typography.WeightRegular);
  UIDrawText(ACanvas, IfThen(FCollapsed.ContainsKey(H.Key), '▸', '▾'),
    TRectF.Create(L, Cy - 12, L + 16, Cy + 12), NameFont, T.Color.FGMuted);
  X := L + 22;
  UIDrawText(ACanvas, H.Key, TRectF.Create(X, Cy - 12, ARowRect.Right - 200, Cy + 12), NameFont, T.Color.FG);
  Badges := [Badge(Format('%d', [H.CommentCount]), btNeutral)];
  if H.DueAlert > 0 then
    Badges := Badges + [Badge(Format(Tr('%d atrasada(s)'), [H.DueAlert]), btError)];
  if StrToIntDef(H.LastCommentText, 0) > 0 then
    Badges := Badges + [Badge(H.LastCommentText + Tr(' impedida(s)'), btWarning)];
  DrawBadgeRow(ACanvas, X + UITextWidth(H.Key, NameFont) + 12, Cy, Badges, ARowRect.Right - 14);
  Sub := IfThen(FCollapsed.ContainsKey(H.Key), Tr('recolhido · clique para abrir'), '');
  if Sub <> '' then
    UIDrawText(ACanvas, Sub, TRectF.Create(ARowRect.Right - 220, Cy - 10, ARowRect.Right - 14, Cy + 10),
      SubFont, T.Color.FGMuted, UI.Painter.taRight);
end;

{ Recria os chips de tag mantendo os que estavam ligados (por nome). }
procedure TIssuesPage.RebuildTagChips;
var
  Was: TArray<string>;
  C: TUIFilterChip;
  I: Integer;
begin
  Was := nil;
  for C in FTagChips do
  begin
    if C.Active then
      Was := Was + [C.Hint];
    C.Free;
  end;
  FTagChips := nil;
  for I := 0 to High(FTags) do
  begin
    C := TUIFilterChip.Create(Self);
    C.Caption := '#' + FTags[I].Name;
    C.Count := 0;
    C.Hint := FTags[I].Name;
    C.Tone := btSuccess;
    C.Active := IndexText(FTags[I].Name, Was) >= 0;
    C.OnToggle := FilterChanged;
    C.AlignWithMargins := True;
    C.Margins.SetBounds(0, 0, 8, 0);
    C.Left := (I + 1) * 1000;
    C.Align := alLeft;
    C.Parent := FTagBar;
    FTagChips := FTagChips + [C];
  end;
  FTagHint.Visible := FTags = nil;
end;

{ Rótulo fixo à esquerda da linha, para os chips das duas linhas alinharem. }
function TIssuesPage.NewRowLabel(AParent: TWinControl; const ACaption: string): TUILabel;
begin
  Result := TUILabel.Create(Self);
  Result.Caption := ACaption;
  Result.Variant := lvMuted;
  Result.AutoSize := False;
  Result.Width := ScaleValue(56);
  Result.Left := 0;
  Result.Align := alLeft;
  Result.Parent := AParent;
end;

{ Submenu "Tag" do menu da issue: Gerenciar e uma linha por tag (✓ nas da issue).
  ponytail: menu não rola; com muitas tags ele cresce até a borda da janela. }
procedure TIssuesPage.FillTagMenu(const AItem: TItem);
const
  Check = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" ' +
    'stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="M5 12l5 5L20 7"/></svg>';
var
  T: TTag;
begin
  FTagMenu.ClearItems;
  FTagMenu.AddItem('tag-manage', Tr('Gerenciar tags...'), HeroIcon('squares-plus'));
  if FTags <> nil then
    FTagMenu.AddSeparator;
  for T in FTags do
    if T.AccountId <> AItem.AccountId then
      Continue
    else if T.HasManual(AItem.AccountId, AItem.Key) then
      FTagMenu.AddItem('tag:' + IntToStr(T.Id), '#' + T.Name, Check)
    else if T.ByKeyword(AItem.Title) then
      FTagMenu.AddItem('tag:' + IntToStr(T.Id), '#' + T.Name + Tr('  (pelo título)'), Check)
    else
      FTagMenu.AddItem('tag:' + IntToStr(T.Id), '#' + T.Name);
end;

procedure TIssuesPage.FillActionMenu(const AItem: TItem);
var
  A: TAccount;
begin
  FActionMenu.ClearItems;
  if not AccountById(AItem.AccountId, A) then
    Exit;
  FActionMenu.AddItem('act-assign', Tr('Atribuir a mim'), HeroIcon('arrow-down-tray'));
  FActionMenu.AddItem('act-triage', Tr('Triar com IA'), HeroIcon('bolt'));
  if IssueStore.GetSetting(TriageSettingName(AItem.AccountId, AItem.Key)) <> '' then
    FActionMenu.AddItem('act-triage-apply', Tr('Aplicar sugestão da IA'), HeroIcon('check-circle'));
  if A.Kind in WorklogKinds then
    FActionMenu.AddItem('act-log', Tr('Registrar horas...'), HeroIcon('clock'));
  if not (A.Kind in JiraKinds) then
  begin
    FActionMenu.AddItem('act-label', IfThen(A.Kind = pkAzure, Tr('Adicionar tag...'), Tr('Adicionar label...')),
      HeroIcon('squares-plus'));
    // PR do GitHub (/pull/) ou MR do GitLab (chave com '!').
    if (Pos('/pull/', AItem.Url) > 0) or (Pos('!', AItem.Key) > 0) then
      FActionMenu.AddItem('act-approve', IfThen(A.Kind = pkGitLab, Tr('Aprovar MR'), Tr('Aprovar PR')),
        HeroIcon('check-circle'));
    if AItem.CiUrl <> '' then
      FActionMenu.AddItem('act-ci', Tr('Abrir job que falhou'), HeroIcon('x-circle'));
  end
  else
  begin
    FActionMenu.AddItem('act-priority', Tr('Mudar prioridade...'), HeroIcon('arrow-trending-up'));
    FActionMenu.AddItem('act-label', Tr('Adicionar label...'), HeroIcon('squares-plus'));
    if AItem.Flagged then
      FActionMenu.AddItem('act-unflag', Tr('Tirar impedimento...'), HeroIcon('check-circle'))
    else
      FActionMenu.AddItem('act-flag', Tr('Marcar impedimento...'), HeroIcon('exclamation-triangle'));
  end;
end;

{ Roda a escrita fora da UI; no fim avisa e busca de novo. A confirmação já
  aconteceu antes de chegar aqui. }
procedure TIssuesPage.RunAction(const AItem: TItem; const ADone: string; const AWork: TProc<TAccount, string>);
var
  A: TAccount;
begin
  if not AccountById(AItem.AccountId, A) then
    Exit;
  RunTask(
    procedure
    var
      Err: string;
    begin
      try
        AWork(A, LoadSecret(A.SecretTarget));
      except
        on E: Exception do
          Err := E.Message;
      end;
      QueueUI(
        procedure
        begin
          if Err = '' then
          begin
            TUIToastManager.Show(ADone, ttSuccess);
            Poll(False);
          end
          else
            TUIToastManager.Show(Tr('Não deu certo: ') + Err, ttError, 6000);
        end);
    end);
end;

procedure TIssuesPage.TagMenuClick(Sender: TObject; const AID: string);
begin
  ItemMenuClick(Sender, AID);
end;

{ Linha da issue em 3 linhas: chave, título, selos. À direita: vínculo e
  data/hora da última atualização. }
procedure TIssuesPage.ItemsDraw(Sender: TObject; AIndex: Integer; const AItem: TUIVListItem;
  const ACanvas: ISkCanvas; const ARowRect: TRectF);
const
  PadX = 14;
var
  T: TUITokens;
  It: TItem;
  L, R, Cy1, Cy2, Cy3, TitleMax: Single;
  KeyFont, TitleFont: ISkFont;
  Stamp: TBadge;
begin
  if AIndex > High(FShown) then
    Exit;
  if IsGroupRow(AIndex) then
  begin
    DrawGroupRow(AIndex, ACanvas, ARowRect);
    Exit;
  end;
  T := UITheme.Tokens;
  It := FShown[AIndex];
  // Brilho de "mudou" sumindo; linha nova entra deslizando 24 px.
  if FFlashKeys.ContainsKey(KeyOf(It)) or FNewKeys.ContainsKey(KeyOf(It)) then
    UIDrawRRectFill(ACanvas, ARowRect, 0, UIColorWithAlpha(T.Color.Primary, (1 - FFlashValue) * 0.22));
  L := ARowRect.Left + PadX;
  if FNewKeys.ContainsKey(KeyOf(It)) then
    L := L + 24 * (1 - TUIEasingFunctions.Apply(FFlashValue, aeEaseOutCubic));
  R := ARowRect.Right - PadX;
  Cy1 := ARowRect.Top + 17;
  Cy2 := ARowRect.Top + 38;
  Cy3 := ARowRect.Top + 59;

  KeyFont := TUIFontManager.GetFont(T.Typography.FamilyPrimary, 11.5, T.Typography.WeightSemiBold);
  TitleFont := TUIFontManager.GetFont(T.Typography.FamilyPrimary, 13, T.Typography.WeightMedium);

  DrawPillRight(ACanvas, R, Cy1, Badge(FShownTag[AIndex], TUIBadgeTone(FShownTone[AIndex])));
  Stamp := Badge('', btNeutral);
  if It.UpdatedAt > 0 then
  begin
    Stamp.Text := FormatDateTime('dd/mm hh:nn', TTimeZone.Local.ToLocalTime(It.UpdatedAt));
    DrawPillRight(ACanvas, R, Cy2, Stamp);
  end;

  UIDrawText(ACanvas, It.Key, TRectF.Create(L, Cy1 - 9, R - 110, Cy1 + 9), KeyFont, T.Color.Primary);
  TitleMax := R - L - IfThen(Stamp.Text <> '', UITextWidth(Stamp.Text, KeyFont) + 30, 0);
  UIDrawText(ACanvas, FitText(It.Title, TitleFont, TitleMax),
    TRectF.Create(L, Cy2 - 10, L + TitleMax, Cy2 + 10), TitleFont, T.Color.FG);
  DrawBadgeRow(ACanvas, L, Cy3, FShownBadges[AIndex], R);
end;

function TIssuesPage.SelectedItem(out AItem: TItem): Boolean;
var
  Sel: TArray<Integer>;
begin
  Sel := FItemsList.GetSelectedIndices;
  Result := (Sel <> nil) and (Sel[0] >= 0) and (Sel[0] <= High(FShown)) and not IsGroupRow(Sel[0]);
  if Result then
    AItem := FShown[Sel[0]];
end;

procedure TIssuesPage.OpenDetail(const AItem: TItem);
var
  A: TAccount;
  I: Integer;
begin
  if not AccountById(AItem.AccountId, A) then
    Exit;
  ShowPage(pgIssues);
  for I := 0 to High(FShown) do
    if SameText(FShown[I].Key, AItem.Key) and (FShown[I].AccountId = AItem.AccountId) then
    begin
      FItemsList.SelectIndex(I);
      FItemsList.ScrollToIndex(I);
    end;
  // O detalhe precisa de pai (o painel lateral) antes de montar o conteúdo.
  EnsureDetailPeek;
  FDetail.ShowItem(AItem, A);
  SetDetailVisible(True);
  if AItem.ThreadId <> '' then
    RunTask(
      procedure
      begin
        try
          MarkNotificationRead(A, LoadSecret(A.SecretTarget), AItem.ThreadId);
        except
          on E: Exception do
            OutputDebugString(PChar('Devbox issues: não marcou como lida (' + E.Message + ')'));
        end;
      end);
end;

{ Detalhe da issue no painel lateral fora da janela (o mesmo do e-mail). }
procedure TIssuesPage.EnsureDetailPeek;
begin
  if FDetailPeek <> nil then
    Exit;
  FDetailPeek := TSidePeek.CreatePeek(GetParentForm(Self), DetailWidth + 140);
  FDetailPeek.Title := Tr('Issue');
  FDetail.Parent := FDetailPeek.Body;
end;

procedure TIssuesPage.SetDetailVisible(AShow: Boolean);
begin
  if AShow then
  begin
    EnsureDetailPeek;
    if FDetail.Item.Key <> '' then
      FDetailPeek.Title := FDetail.Item.Key;
    FDetailPeek.Open;
  end
  else if FDetailPeek <> nil then
    FDetailPeek.Close_;
end;

function TIssuesPage.DetailOpen: Boolean;
begin
  Result := (FDetailPeek <> nil) and FDetailPeek.IsOpen;
end;

procedure TIssuesPage.PageHidden;
begin
  SetDetailVisible(False);
  inherited;
end;

procedure TIssuesPage.ItemsClick(Sender: TObject; AIndex: Integer; const AItem: TUIVListItem);
begin
  // Cabeçalho de grupo: recolhe ou abre.
  if IsGroupRow(AIndex) then
  begin
    if FCollapsed.ContainsKey(FShown[AIndex].Key) then
      FCollapsed.Remove(FShown[AIndex].Key)
    else
      FCollapsed.AddOrSetValue(FShown[AIndex].Key, True);
    ForceQueueUI( procedure begin ApplyFilters; end);
    Exit;
  end;
  // Painel aberto acompanha a seleção; fechado, o clique só seleciona.
  if DetailOpen and (AIndex >= 0) and (AIndex <= High(FShown)) then
    OpenDetail(FShown[AIndex]);
end;

procedure TIssuesPage.ItemsDblClick(Sender: TObject; AIndex: Integer; const AItem: TUIVListItem);
begin
  if (AIndex >= 0) and (AIndex <= High(FShown)) and not IsGroupRow(AIndex) then
    OpenDetail(FShown[AIndex]);
end;

{ Botão direito seleciona a linha e monta o menu dela antes do WM_CONTEXTMENU. }
procedure TIssuesPage.ItemsMouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
var
  L: TListAccess;
  I: Integer;
  It: TItem;
begin
  if Button <> mbRight then
    Exit;
  L := TListAccess(FItemsList);
  for I := L.FirstVisible to Min(L.LastVisible, High(FShown)) do
    if L.RowRect(I).Contains(PointF(X, Y)) then
    begin
      FItemsList.SelectIndex(I);
      Break;
    end;
  FItemMenu.ClearItems;
  if not SelectedItem(It) then
    Exit;
  FItemMenu.AddItem('detail', Tr('Ver detalhes'), HeroIcon('information-circle'));
  FItemMenu.AddItem('status', Tr('Mudar status...'), HeroIcon('arrow-path'));
  FItemMenu.AddItem('open', Tr('Abrir no navegador'), HeroIcon('arrow-trending-up'));
  FItemMenu.AddItem('copy', Tr('Copiar chave'), HeroIcon('squares-plus'));
  FillActionMenu(It);
  FItemMenu.AddSubmenu('act-sub', Tr('Ações'), FActionMenu, HeroIcon('bolt'));
  FItemMenu.AddSeparator;
  if FMuted.ContainsKey(KeyOf(It)) then
    FItemMenu.AddItem('unmute', Tr('Reativar avisos'), HeroIcon('bolt'))
  else
  begin
    FItemMenu.AddItem('mute-day', Tr('Silenciar até amanhã'), HeroIcon('clock'));
    FItemMenu.AddItem('mute-status', Tr('Silenciar até mudar status'), HeroIcon('signal'));
  end;
  FItemMenu.AddSeparator;
  FillTagMenu(It);
  FItemMenu.AddSubmenu('tag-sub', Tr('Tag'), FTagMenu, HeroIcon('squares-2x2'));
  if IsManual(It) then
  begin
    FItemMenu.AddSeparator;
    FItemMenu.AddItem('unwatch', Tr('Parar de acompanhar'), HeroIcon('x-circle'), True);
  end;
end;

procedure TIssuesPage.ItemsMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
var
  L: TListAccess;
  I, B: Integer;
  A: TAccount;
  Tip, Txt: string;
begin
  L := TListAccess(FItemsList);
  Tip := '';
  for I := L.FirstVisible to Min(L.LastVisible, High(FShown)) do
    if L.RowRect(I).Contains(PointF(X, Y)) then
    begin
      // Selos ficam na 3ª linha (Cy3 = topo + 59, 18 px de altura).
      if (Y >= L.RowRect(I).Top + 50) and (Y <= L.RowRect(I).Top + 68) then
      begin
        B := BadgeIndexAt(X, FShownBadges[I], L.RowRect(I).Left + 14);
        if B >= 0 then
        begin
          Txt := FShownBadges[I][B].Text;
          if Txt = Tr('Impedida') then
            Tip := Tr('Marcada com Flagged no Jira: alguém sinalizou um impedimento.')
          else if (Txt.StartsWith('Entrega') or Txt.StartsWith('Prazo')) and
            AccountById(FShown[I].AccountId, A) then
            Tip := Format(Tr('Faltam %d dia(s). Laranja com %d, vermelho com %d.'),
              [Trunc(DateOf(FShown[I].DueDate) - Date), A.WarnDays, A.CriticalDays])
          else if Txt = Tr('silenciada') then
            Tip := Tr('Sem avisos desta issue até o prazo do silêncio. Botão direito para reativar.')
          else if SameText(Txt, FShown[I].Status) then
            Tip := Tr('Status no ') + IfThen(AccountById(FShown[I].AccountId, A), Tr(ShortProviderNames[A.Kind]), '') +
              ': ' + Txt;
        end;
      end;
      Break;
    end;
  if FItemsList.Hint <> Tip then
  begin
    FItemsList.Hint := Tip;
    Application.CancelHint;
  end;
end;

procedure TIssuesPage.ItemMenuClick(Sender: TObject; const AID: string);
var
  It: TItem;
  A: TAccount;
  T: TTag;
  Lbl: string;
  Names: TArray<string>;
  Idx: Integer;
  On_: Boolean;
begin
  if not SelectedItem(It) then
    Exit;
  if AID = 'detail' then
    OpenDetail(It)
  else if AID = 'open' then
    OpenUrl(It.Url)
  else if AID = 'copy' then
    CopyKey(It)
  else if AID = 'status' then
  begin
    if AccountById(It.AccountId, A) and ChangeStatus(Self, A, It) then
    begin
      TUIToastManager.Show(Tr('Status de ') + It.Key + Tr(' alterado'), ttSuccess);
      Poll(False);
    end;
  end
  else if AID = 'act-assign' then
  begin
    if AccountById(It.AccountId, A) and AskConfirm(Self, Tr('Atribuir a mim'), Format(Tr('Atribuir %s a você no %s?'),
      [It.Key, Tr(ShortProviderNames[A.Kind])]), Tr('Atribuir')) then
      RunAction(It, It.Key + Tr(' atribuída a você'),
        procedure(AAcc: TAccount; AToken: string)
        begin
          AssignToMe(AAcc, AToken, It.Key);
        end);
  end
  else if AID = 'act-label' then
  begin
    Lbl := '';
    if AskText(Self, Tr('Adicionar label'), Tr('A label entra em ') + It.Key + '.', Tr('Label'), Lbl) then
      RunAction(It, Format(Tr('Label "%s" adicionada em %s'), [Lbl, It.Key]),
        procedure(AAcc: TAccount; AToken: string)
        begin
          AddLabel(AAcc, AToken, It.Key, Lbl);
        end);
  end
  else if AID = 'act-approve' then
  begin
    if AskConfirm(Self, Tr('Aprovar PR'), Tr('Enviar aprovação para ') + It.Key + '?', Tr('Aprovar')) then
      RunAction(It, It.Key + Tr(' aprovado'),
        procedure(AAcc: TAccount; AToken: string)
        begin
          ApprovePr(AAcc, AToken, It.Key);
        end);
  end
  else if AID = 'act-ci' then
    OpenUrl(It.CiUrl)
  else if AID = 'act-triage' then
    TriageItems([It], True)
  else if AID = 'act-triage-apply' then
    ApplyTriage(It)
  else if AID = 'act-log' then
  begin
    if AccountById(It.AccountId, A) and LogTime(Self, A, It) then
      Poll(False);
  end
  else if AID = 'act-priority' then
  begin
    if not AccountById(It.AccountId, A) then
      Exit;
    try
      Names := FetchPriorities(A, LoadSecret(A.SecretTarget));
    except
      on E: Exception do
      begin
        TUIToastManager.Show(Tr('Não carregou as prioridades: ') + E.Message, ttError, 6000);
        Exit;
      end;
    end;
    Idx := -1;
    if AskChoice(Self, Tr('Mudar prioridade'), Tr('Nova prioridade de ') + It.Key + '.', Tr('Prioridade'), Names, Idx) then
    begin
      Lbl := Names[Idx];
      RunAction(It, Format(Tr('Prioridade de %s: %s'), [It.Key, Lbl]),
        procedure(AAcc: TAccount; AToken: string)
        begin
          SetPriority(AAcc, AToken, It.Key, Lbl);
        end);
    end;
  end
  else if (AID = 'act-flag') or (AID = 'act-unflag') then
  begin
    Lbl := '';
    On_ := AID = 'act-flag';
    if AskText(Self, IfThen(On_, Tr('Marcar impedimento'), Tr('Tirar impedimento')),
      IfThen(On_, Tr('Marca Flagged em '), Tr('Tira o Flagged de ')) + It.Key +
      Tr(' e comenta o motivo na issue.'), Tr('Motivo'), Lbl) then
      RunAction(It, IfThen(On_, It.Key + Tr(' marcada como impedida'), Tr('Impedimento de ') + It.Key + Tr(' removido')),
        procedure(AAcc: TAccount; AToken: string)
        begin
          SetImpediment(AAcc, AToken, It.Key, On_, Lbl);
        end);
  end
  else if AID = 'unwatch' then
    Unwatch(It)
  else if AID = 'tag-manage' then
  begin
    if ManageTags(Self, It, False) then
      LoadItems;
  end
  else if AID.StartsWith('tag:') then
  begin
    for T in FTags do
      if T.Id = StrToIntDef(AID.Substring(4), 0) then
      begin
        if T.ByKeyword(It.Title) and not T.HasManual(It.AccountId, It.Key) then
          TUIToastManager.Show(Format(Tr('%s entra em "%s" pelo título. Mude as palavras em Gerenciar tags.'),
            [It.Key, T.Name]), ttInfo, 5000)
        else
          IssueStore.SetItemTag(T.Id, It.AccountId, It.Key, not T.HasManual(It.AccountId, It.Key));
      end;
    LoadItems;
  end
  else if AID = 'mute-day' then
  begin
    // Amanhã às 8h: o silêncio cobre o resto do dia e a noite.
    IssueStore.Mute(It.AccountId, It.Key, Trunc(Now) + 1 + 8 / 24, '');
    TUIToastManager.Show(It.Key + Tr(' silenciada até amanhã às 8h'), ttInfo);
    LoadItems;
  end
  else if AID = 'mute-status' then
  begin
    IssueStore.Mute(It.AccountId, It.Key, 0, It.Status);
    TUIToastManager.Show(It.Key + Tr(' silenciada até sair de "') + It.Status + '"', ttInfo);
    LoadItems;
  end
  else if AID = 'unmute' then
  begin
    IssueStore.Unmute(It.AccountId, It.Key);
    TUIToastManager.Show(Tr('Avisos de ') + It.Key + Tr(' reativados'), ttSuccess);
    LoadItems;
  end;
end;

procedure TIssuesPage.NotifyOpenDetail(const AKey: string; AAccountId: Integer);
var
  It: TItem;
begin
  MenuOpenClick(nil);
  if AKey = '*dashboard' then
  begin
    ShowPage(pgDashboard);
    Exit;
  end;
  if AKey = '*teste' then
    Exit;
  if AKey = '*update' then
  begin
    StartUpdate(True);
    Exit;
  end;
  for It in FAll do
    if SameText(It.Key, AKey) and (It.AccountId = AAccountId) then
    begin
      OpenDetail(It);
      Exit;
    end;
end;

{ Clique num card do Dashboard: limpa os filtros, aplica o do card e abre Issues. }
procedure TIssuesPage.DashboardDrill(Sender: TObject; const ADrill: TDrill);
var
  F: TItemFilter;
  C: TUIFilterChip;
begin
  for F := Low(TItemFilter) to High(TItemFilter) do
    FChips[F].Active := False;
  for C in FTagChips do
    C.Active := False;
  FDrill := Default(TDrill);
  if FDetached and not Showing and Assigned(FOnShowRequest) then
    FOnShowRequest(Self);
  case ADrill.Kind of
    dkMine: FChips[ifMine].Active := True;
    dkFlagged: FChips[ifFlagged].Active := True;
    dkMyPrs: FChips[ifMyPrs].Active := True;
    dkTag:
      for C in FTagChips do
        C.Active := SameText(C.Hint, ADrill.Value);
    dkDueSoon, dkWithDue, dkCategory, dkStatus, dkPrState, dkKind:
      FDrill := ADrill;
    dkRepo:
      begin
        SetRepoFilter(ADrill.Value);
        ShowPage(pgIssues);
        Exit;
      end;
  end;
  FDrillChip.Visible := FDrill.Kind <> dkNone;
  FDrillChip.Caption := FDrill.Caption + '  ✕';
  FDrillChip.Active := True;
  ApplyFilters;
  ShowPage(pgIssues);
end;

procedure TIssuesPage.DrillChipToggle(Sender: TObject);
begin
  FDrill := Default(TDrill);
  FDrillChip.Visible := False;
  ApplyFilters;
end;

function TIssuesPage.DrillPass(const AItem: TItem): Boolean;
var
  A: TAccount;
begin
  case FDrill.Kind of
    dkDueSoon:
      Result := (AItem.DueDate > 0) and AccountById(AItem.AccountId, A) and
        (DueTone(AItem.DueDate, A) <> btSuccess);
    dkWithDue: Result := AItem.DueDate > 0;
    dkCategory: Result := CategoryOf(AItem) = FDrill.Value;
    dkStatus: Result := SameText(AItem.Status, FDrill.Value);
    dkKind: Result := (AItem.Url.Contains('/pull/')) = (FDrill.Value = 'pr');
    dkPrState:
      if FDrill.Value = 'CI' then
        Result := MatchText(AItem.CiState, ['FAILURE', 'ERROR'])
      else if FDrill.Value = 'WAITING' then
        Result := (isMine in AItem.Sources) and
          not MatchText(AItem.ReviewState, ['APPROVED', 'CHANGES_REQUESTED'])
      else
        Result := SameText(AItem.ReviewState, FDrill.Value);
  else
    Result := True;
  end;
end;

procedure TIssuesPage.ViewOpenItem(Sender: TObject; const AItem: TItem);
begin
  // Clique no painel (que mora em Hoje): a lista vem para a frente.
  if FDetached and not Showing and Assigned(FOnShowRequest) then
    FOnShowRequest(Self);
  OpenDetail(AItem);
end;

procedure TIssuesPage.DetailClose(Sender: TObject);
begin
  SetDetailVisible(False);
end;

procedure TIssuesPage.DetailChanged(Sender: TObject);
begin
  Poll(False);
end;

procedure TIssuesPage.CopyKey(const AItem: TItem);
begin
  Clipboard.AsText := AItem.Key;
  TUIToastManager.Show(AItem.Key + Tr(' copiada'), ttSuccess, 1500);
end;

procedure TIssuesPage.Unwatch(const AItem: TItem);
begin
  IssueStore.RemoveManualKey(AItem.AccountId, AItem.Key);
  FUndoAccount := AItem.AccountId;
  FUndoKey := AItem.Key;
  TUIToastManager.Show(Tr('Parei de acompanhar ') + AItem.Key, ttInfo, 6000, Tr('Desfazer'), UndoUnwatch);
  Poll(False);
end;

procedure TIssuesPage.UndoUnwatch(Sender: TObject);
begin
  if FUndoKey = '' then
    Exit;
  IssueStore.AddManualKey(FUndoAccount, FUndoKey);
  FUndoKey := '';
  Poll(False);
end;

{ Descobre a conta pela forma da chave; se houver mais de uma do mesmo tipo,
  usa a conta do filtro. Confere a issue na API antes de salvar. }
procedure TIssuesPage.WatchKey(const AText: string);
const
  FamilyNames: array[TKeyFamily] of string = ('', 'GitHub ou GitLab', 'Jira', 'Azure DevOps');
var
  Key: string;
  Family: TKeyFamily;
  A, Target: TAccount;
  Count: Integer;
  Token: string;
begin
  Key := NormalizeManualKey(AText, Family);
  if Key = '' then
  begin
    TUIToastManager.Show(Tr('Use PROJ-123 (Jira), dono/repo#12 (GitHub, GitLab) ou Projeto#123 (Azure)'),
      ttError, 6000);
    Exit;
  end;
  Count := 0;
  for A in FAccounts do
    if KeyFamilies[A.Kind] = Family then
    begin
      Inc(Count);
      Target := A;
    end;
  if (Count > 1) and (FAccountFilter <> 0) and AccountById(FAccountFilter, A) and
    (KeyFamilies[A.Kind] = Family) then
  begin
    Target := A;
    Count := 1;
  end;
  if Count = 0 then
  begin
    TUIToastManager.Show(Tr('Nenhuma conta ') + Tr(FamilyNames[Family]) + Tr(' cadastrada'), ttError, 5000);
    Exit;
  end;
  if Count > 1 then
  begin
    TUIToastManager.Show(Tr('Escolha a conta no seletor do topo'), ttError, 5000);
    Exit;
  end;

  Token := LoadSecret(Target.SecretTarget);
  TUIToastManager.Show(Tr('Conferindo ') + Key + '...', ttInfo, 2000);
  RunTask(
    procedure
    var
      Title, Err: string;
    begin
      try
        Title := CheckItem(Target, Token, Key);
      except
        on E: Exception do
          Err := E.Message;
      end;
      QueueUI(
        procedure
        begin
          // Tom por valor: dentro desta closure o compilador (22.0) deixa de
          // resolver ttError/ttSuccess depois de UI.TimePicker/UI.PageTransition
          // no uses e acusa "no overloaded version of Queue". 1 = sucesso, 2 = erro.
          if Err <> '' then
          begin
            TUIToastManager.Show(Key + Tr(' não encontrada em ') + Target.Name + ' (' + Err + ')', TUIToastTone(2), 5000);
            Exit;
          end;
          IssueStore.AddManualKey(Target.Id, Key);
          TUIToastManager.Show(Tr('Acompanhando ') + Key + ': ' + Title, TUIToastTone(1));
          Poll(False);
        end);
    end);
end;

{ ── Cabeçalho, tray e atalhos ───────────────────────────────────────────── }

{ Rodapé: barra de progresso e horas do Jira. Os atalhos ficam no rodapé da janela
  principal (PageShortcuts). Mesma altura em todas as abas: o FAB fica no mesmo lugar. }
procedure TIssuesPage.BuildFooter;
begin
  FFooter := NewPanel(FContent, alBottom, 40);
  FFooter.Padding.SetBounds(Sp(UITheme.Tokens.Spacing.S4), 0, Sp(UITheme.Tokens.Spacing.S4), 0);
  FHoursLabel := TUILabel.Create(Self);
  FHoursLabel.Variant := lvMuted;
  FHoursLabel.AutoSize := True;
  FHoursLabel.Hint := Tr('Horas que você lançou no Jira (worklog)');
  FHoursLabel.ShowHint := True;
  FHoursLabel.Align := alRight;
  FHoursLabel.Parent := FFooter;
end;

procedure TIssuesPage.PageRefresh;
begin
  Poll(True);
end;

function TIssuesPage.PageShortcuts: TArray<TDevShortcut>;
begin
  Result := nil;
end;

{ Primeira abertura depois da unificação: a inicialização com o Windows do Vigia
  vira a do Devbox (se estava ligada lá, liga aqui) e a chave Run 'Vigia' sai. }
procedure TIssuesPage.MigrateVigiaApp;
const
  CRunKey = 'Software\Microsoft\Windows\CurrentVersion\Run';
var
  LReg: TRegistry;
  LHad: Boolean;
begin
  // Só com dados de um Vigia de verdade nesta pasta de dados (a instância de teste usa outra e
  // não pode mexer na chave Run do usuário).
  if (IssueStore.GetSetting('migr_vigia_app') <> '') or
    not FileExists(TPath.Combine(VigiaDataDir, 'vigia.db')) then
    Exit;
  LReg := TRegistry.Create;
  try
    LReg.RootKey := HKEY_CURRENT_USER;
    LHad := LReg.OpenKey(CRunKey, False) and LReg.ValueExists('Vigia');
    if LHad then
      LReg.DeleteValue('Vigia');
  finally
    LReg.Free;
  end;
  if LHad and not AutostartEnabled then
    SetAutostart(True);
  IssueStore.SetSetting('migr_vigia_app', '1');
end;

function TIssuesPage.PageKey(var AKey: Word; AShift: TShiftState): Boolean;
begin
  FormKeyDown(Self, AKey, AShift);
  Result := AKey = 0;
end;

procedure TIssuesPage.FormKeyDownEsc;
var
  Key: Word;
begin
  Key := VK_ESCAPE;
  FormKeyDown(Self, Key, []);
end;

procedure TIssuesPage.UpdateHeader;
var
  Secs: Integer;
  S: string;
begin
  S := Format(Tr('%d itens'), [Length(FShown)]);
  if FPolling then
    S := S + Tr('  ·  atualizando...')
  else
  begin
    if FLastPoll > 0 then
      S := S + Tr('  ·  atualizado ') + FormatDateTime('hh:nn', FLastPoll);
    Secs := Max(0, SecondsBetween(FNextPoll, Now));
    S := S + Format(Tr('  ·  próxima em %d:%.2d'), [Secs div 60, Secs mod 60]);
  end;
  FNextRing.Hint := S;
  // Verde ok, pulsando enquanto busca, vermelho se alguma conta falhou.
  if FPolling then
    FStatusDot.Status := sdBusy
  else if FAccountErrors.Count > 0 then
    FStatusDot.Status := sdError
  else
    FStatusDot.Status := sdOnline;
  FStatusDot.Pulsing := FPolling;
  FNextRing.Indeterminate := FPolling;
  if not FPolling then
    FNextRing.Value := EnsureRange(SecondsBetween(FNextPoll, Now) * 100000 / PollIntervalMs, 0, 100);
  FProgress.Visible := FPolling;
end;

{ Contadores nas abas: não lidos em Issues, contas com erro em Contas.
  ponytail: TUITabs não troca o badge depois de criado; recria as abas. }
procedure TIssuesPage.UpdateBadges;
var
  Keep: Integer;
begin
  if FTabs = nil then
    Exit;
  // Recriar as abas reinicia a animação do sublinhado: só quando o número muda.
  if Format('%d|%d', [FUnread, FAccountErrors.Count]) = FTabBadges then
    Exit;
  FTabBadges := Format('%d|%d', [FUnread, FAccountErrors.Count]);
  if FDetached then
    Exit;
  Keep := Ord(FPage);  // a busca recria as abas; a aba aberta continua
  FTabs.OnChange := nil;
  FTabs.RemoveTab(3);  // índice inexistente é ignorado
  FTabs.RemoveTab(2);
  FTabs.RemoveTab(1);
  FTabs.RemoveTab(0);
  FTabs.AddTab(Tr(PageTitles[pgDashboard]));
  FTabs.AddTab(Tr(PageTitles[pgIssues]), FUnread);
  FTabs.AddTab(Tr(PageTitles[pgAccounts]), FAccountErrors.Count);
  FTabs.AddTab(Tr(PageTitles[pgSettings]));
  FTabs.ActiveIndex := Keep;
  FTabs.OnChange := TabChange;
end;

{ Cena do mascote parado conforme a situação: novidade > atrasada > prazo
  perto > normal. Só troca o Lottie quando a cena muda. }
procedure TIssuesPage.UpdateMascotMood;
var
  F, Tip: string;
begin
  if Now < FNewsUntil then
  begin
    F := 'assistant-news.json';
    Tip := Tr('Novidade nas issues!');
  end
  else if FOverdue then
  begin
    F := 'assistant-idle-overdue.json';
    Tip := Tr('Tem issue atrasada');
  end
  else if FDueSoon then
  begin
    F := 'assistant-idle-duesoon.json';
    Tip := Tr('Prazo chegando');
  end
  else
  begin
    F := 'assistant-idle.json';
    Tip := Tr('Como posso ajudar?');
  end;
  if F = FMascotFile then
    Exit;
  FMascotFile := F;
  FAssistant.Behaviors.SetBehavior(asIdle, F, 1.0, True, Tip);
end;

procedure TIssuesPage.ClockTick(Sender: TObject);
begin
  if Visible then
    UpdateHeader;
  UpdateMascotMood;
  // Agendas de minuto em minuto (resumo do dia, fim do "não perturbe").
  if MinuteOf(Now) <> FLastMinuteCheck then
  begin
    FLastMinuteCheck := MinuteOf(Now);
    CheckSchedules;
  end;
end;

function TIssuesPage.InQuietHours: Boolean;
var
  T, A, B: TDateTime;
begin
  // Modo foco do Devbox também segura os avisos (entregues no fim, como o "não perturbe").
  Result := Assigned(FQuietCheck) and FQuietCheck();
  if Result or (IssueStore.GetSetting('dnd_on', '0') <> '1') then
    Exit;
  T := Frac(Now);
  A := TimeSetting('dnd_start', '19:00');
  B := TimeSetting('dnd_end', '08:00');
  if A <= B then
    Result := (T >= A) and (T < B)
  else
    Result := (T >= A) or (T < B);  // atravessa a meia-noite
end;

{ Release nova no GitHub. Automático: uma vez por dia, só na cópia instalada.
  Manual (botão): sempre, e diz o resultado. }
procedure TIssuesPage.CheckForUpdate(AManual: Boolean);
begin
  if FUpdateBusy then
    Exit;
  if not AManual then
  begin
    if not IsInstalledCopy or (IssueStore.GetSetting('update_mode') = 'off') or
      (IssueStore.GetSetting('update_last') = FormatDateTime('yyyy-mm-dd', Date)) then
      Exit;
    IssueStore.SetSetting('update_last', FormatDateTime('yyyy-mm-dd', Date));
  end;
  FUpdateBusy := True;
  RunTask(
    procedure
    var
      Info: TUpdateInfo;
      Found: Boolean;
      Err: string;
    begin
      Found := False;
      try
        Found := FetchLatest(Info);
      except
        on E: Exception do
          Err := E.Message;
      end;
      QueueUI(
        procedure
        begin
          FUpdateBusy := False;
          if Err <> '' then
          begin
            if AManual then
              TUIToastManager.Show(Tr('Não deu para procurar: ') + Err, ttError, 6000);
            Exit;
          end;
          if not Found then
          begin
            if AManual then
              TUIToastManager.Show(Tr('Você já está na versão mais nova (') + AppVersion + ')', ttSuccess);
            Exit;
          end;
          FUpdate := Info;
          FUpdateItem.Caption := Tr('Atualizar para ') + Info.Version;
          FUpdateItem.Visible := True;
          FUpdateBtn.Caption := Tr('Atualizar para ') + Info.Version;
          if (IssueStore.GetSetting('update_mode') = 'auto') and not AManual and not Visible then
            StartUpdate(False)
          else
            Notify(Tr('Devbox ') + Info.Version + Tr(' disponível'), Tr('Você está na ') + AppVersion +
              Tr('. Clique para atualizar; o Devbox fecha e volta sozinho.'), '', stInfo, '*update');
        end);
    end);
end;

{ Baixa, confere o hash, roda o instalador e sai. O instalador reabre o Vigia. }
procedure TIssuesPage.StartUpdate(AShow: Boolean);
var
  Info: TUpdateInfo;
begin
  if FUpdateBusy or (FUpdate.Version = '') then
    Exit;
  if not IsInstalledCopy then
  begin
    TUIToastManager.Show(Tr('Esta cópia não foi instalada pelo instalador. Baixe a ') + FUpdate.Version +
      Tr(' na página de releases.'), ttWarning, 6000);
    Exit;
  end;
  Info := FUpdate;
  FUpdateBusy := True;
  TUIToastManager.Show(Tr('Baixando o Devbox ') + Info.Version + '...', ttInfo);
  RunTask(
    procedure
    var
      Path, Err: string;
    begin
      try
        Path := DownloadUpdate(Info);
      except
        on E: Exception do
          Err := E.Message;
      end;
      QueueUI(
        procedure
        begin
          FUpdateBusy := False;
          if Err <> '' then
          begin
            TUIToastManager.Show(Tr('Atualização falhou: ') + Err, ttError, 8000);
            Exit;
          end;
          try
            RunInstaller(Path, AShow);
          except
            on E: Exception do
            begin
              TUIToastManager.Show(Tr('Não abriu o instalador: ') + E.Message, ttError, 8000);
              Exit;
            end;
          end;
          // Instalador aberto: o Devbox sai para ser trocado.
          if Assigned(FOnExitRequest) then
            FOnExitRequest(Self);
        end);
    end);
end;

procedure TIssuesPage.ExportClick(Sender: TObject);
var
  D: TSaveDialog;
  Targets: TArray<string>;
  AK: TAiProviderKind;
begin
  D := TSaveDialog.Create(nil);
  try
    D.Title := Tr('Exportar contas e configurações');
    D.Filter := Tr('Backup das issues (*.json)|*.json');
    D.DefaultExt := 'json';
    D.FileName := Tr('Devbox-issues-backup-') + FormatDateTime('yyyy-mm-dd', Date) + '.json';
    D.Options := D.Options + [ofOverwritePrompt];
    if not D.Execute(Handle) then
      Exit;
    Targets := [AssistantSecret];
    for AK := Low(TAiProviderKind) to High(TAiProviderKind) do
      Targets := Targets + [AiSecretTarget(AK)];
    ExportBackup(IssueStore, D.FileName, True, Targets);
    TUIToastManager.Show(Tr('Backup salvo em ') + ExtractFileName(D.FileName), ttSuccess);
  finally
    D.Free;
  end;
end;

procedure TIssuesPage.ImportClick(Sender: TObject);
var
  D: TOpenDialog;
  R: TBackupResult;
begin
  D := TOpenDialog.Create(nil);
  try
    D.Title := Tr('Importar contas e configurações');
    D.Filter := Tr('Backup das issues (*.json)|*.json');
    if not D.Execute(Handle) then
      Exit;
    if not AskConfirm(Self, Tr('Importar backup'), Tr('Conta com o mesmo nome e provedor é atualizada; ' +
      'as outras entram. Tags, issues acompanhadas e preferências também.'), Tr('Importar')) then
      Exit;
    try
      R := ImportBackup(IssueStore, D.FileName);
    except
      on E: Exception do
      begin
        TUIToastManager.Show(Tr('Não importou: ') + E.Message, ttError, 8000);
        Exit;
      end;
    end;
    ReloadAccounts;
    LoadItems;
    LoadAiSettings;
    FPollAll := True;
    Poll(False);
    TUIToastManager.Show(Tr('Importado: ') + R.Summary + Tr(' Tema e intervalos valem ao reabrir o Devbox.'),
      ttSuccess, 10000);
  finally
    D.Free;
  end;
end;

procedure TIssuesPage.MiniMenuClick(Sender: TObject);
begin
  if (FMini <> nil) and FMini.Visible then
  begin
    FMini.Close;
    Exit;
  end;
  if FMini = nil then
  begin
    FMini := TMiniForm.Create(Self);
    FMini.OnOpen := NotifyOpenDetail;
    FMini.OnClosed := MiniClosed;
  end;
  IssueStore.SetSetting('mini_on', '1');
  FMiniItem.Checked := True;
  UpdateMini;
  ShowWindow(FMini.Handle, SW_SHOWNOACTIVATE);
  FMini.Visible := True;
end;

procedure TIssuesPage.MiniClosed(Sender: TObject);
begin
  IssueStore.SetSetting('mini_on', '0');
  FMiniItem.Checked := False;
end;

procedure TIssuesPage.UpdateMini;
var
  It: TItem;
  NowItems: TItems;
  Overdue, Mine: Integer;
begin
  if FMini = nil then
    Exit;
  NowItems := nil;
  Overdue := 0;
  Mine := 0;
  for It in FAll do
  begin
    if NeedsActionNow(It) then
      NowItems := NowItems + [It];
    if IsOverdue(It) then
      Inc(Overdue);
    if isAssigned in It.Sources then
      Inc(Mine);
  end;
  FMini.ShowData(NowItems, Overdue, Mine, Length(FAll));
end;

procedure TIssuesPage.NotifyMute(const AKey: string; AAccountId: Integer);
begin
  IssueStore.Mute(AAccountId, AKey, Trunc(Now) + 1 + 8 / 24, '');
  TUIToastManager.Show(AKey + Tr(' silenciada até amanhã às 8h'), ttInfo);
  LoadItems;
end;

{ Resposta escrita no próprio aviso: comenta na issue sem abrir o Vigia. }
procedure TIssuesPage.NotifyReply(const AKey: string; AAccountId: Integer; const AText: string);
var
  A: TAccount;
begin
  if not AccountById(AAccountId, A) then
    Exit;
  RunTask(
    procedure
    var
      Err: string;
    begin
      try
        PostComment(A, LoadSecret(A.SecretTarget), AKey, AText);
      except
        on E: Exception do
          Err := E.Message;
      end;
      QueueUI(
        procedure
        begin
          if Err = '' then
            Notify(Tr('Comentário enviado'), AKey + ': ' + AText, '', stSuccess)
          else
            Notify(Tr('Comentário não foi'), AKey + ': ' + Err, '', stError);
        end);
    end);
end;

procedure TIssuesPage.UpdateMenuClick(Sender: TObject);
begin
  StartUpdate(True);
end;

procedure TIssuesPage.CheckUpdatesNow;
begin
  UpdateBtnClick(nil);
end;

procedure TIssuesPage.UpdateBtnClick(Sender: TObject);
begin
  if FUpdate.Version <> '' then
    StartUpdate(True)
  else
    CheckForUpdate(True);
end;

procedure TIssuesPage.CheckSchedules;
var
  It: TItem;
  A: TAccount;
  Red, Orange, Flagged, Comments: Integer;
  E: TIssueEvent;
  Keys: string;
begin
  // Fim do silêncio: entrega o que ficou guardado.
  if (FPending <> nil) and not InQuietHours then
  begin
    if Length(FPending) <= 3 then
      for E in FPending do
        Notify(E.Title, E.Body, E.Url, EventTone(E.Kind), E.Key, E.AccountId)
    else
    begin
      Keys := '';
      for E in FPending do
        if not ContainsText(Keys, E.Key) then
          Keys := Keys + IfThen(Keys <> '', ', ') + E.Key;
      Notify(Format(Tr('Issues · %d avisos durante o silêncio'), [Length(FPending)]), Keys, '', stPrimary,
        '*dashboard');
    end;
    FPending := nil;
  end;

  if not InQuietHours then
    RunAutoAi;
  if FLastPoll > 0 then
    CheckForUpdate(False);

  // Resumo do dia, uma vez por dia a partir do horário escolhido.
  if (IssueStore.GetSetting('summary_on', '1') = '1') and (FLastPoll > 0) and
    (Frac(Now) >= TimeSetting('summary_time', '09:00')) and
    (IssueStore.GetSetting('summary_last') <> FormatDateTime('yyyy-mm-dd', Date)) and not InQuietHours then
  begin
    IssueStore.SetSetting('summary_last', FormatDateTime('yyyy-mm-dd', Date));
    Red := 0;
    Orange := 0;
    Flagged := 0;
    for It in FAll do
    begin
      if It.Flagged then
        Inc(Flagged);
      if (It.DueDate > 0) and AccountById(It.AccountId, A) then
        case DueTone(It.DueDate, A) of
          btError: Inc(Red);
          btWarning: Inc(Orange);
        end;
    end;
    Comments := IssueStore.CountEvents(ekComment, 24) + IssueStore.CountEvents(ekMention, 24);
    if IssueStore.GetSetting('ai_daily') = '1' then
    begin
      AiAsk(BuildAiContext, Tr('Escreva o resumo de bom dia em até 4 frases curtas: o que vence, o que está ' +
        'impedido, o que mudou desde ontem e por onde começar. Cite as chaves. Sem markdown.'), True,
        procedure(AText: string)
        begin
          Notify(Tr('Bom dia · resumo das issues'), AText, '', stPrimary, '*dashboard');
        end,
        procedure(AErr: string)
        begin
          Notify(Tr('Bom dia · resumo das issues'), Format(Tr('%d vencendo ou vencidas, %d chegando, %d impedidas. ' +
            '(IA indisponível: %s)'), [Red, Orange, Flagged, AErr]), '', stPrimary, '*dashboard');
        end);
      Exit;
    end;
    Notify(Tr('Bom dia · resumo das issues'), Format(Tr('%d vencendo ou vencidas, %d chegando, %d impedidas, ' +
      '%d comentário(s) nas últimas 24 h.'), [Red, Orange, Flagged, Comments]), '', stPrimary, '*dashboard');
  end;
end;

procedure TIssuesPage.UpdateTrayIcon;
begin
  // A janela principal desenha o contador sobre o ícone do Devbox.
  if Assigned(FOnCounts) then
    FOnCounts(FUnread, FOverdue);
end;

procedure TIssuesPage.AutostartClick(Sender: TObject);
begin
  SetAutostart(not FAutostartItem.Checked);
  FAutostartItem.Checked := AutostartEnabled;
  FAutostartToggle.Checked := FAutostartItem.Checked;
end;

procedure TIssuesPage.AlertDismiss(Sender: TObject);
begin
  FAlert.Visible := False;
end;

procedure TIssuesPage.FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
var
  It: TItem;
begin
  case Key of
    VK_F5:
      Poll(True);
    VK_ESCAPE:
      if DetailOpen then
        SetDetailVisible(False)
      else
        Exit;   // Esc sem detalhe: a janela principal esconde
    Ord('F'):
      if ssCtrl in Shift then
        FPalette.Open
      else
        Exit;
    Ord('C'):
      if (ssCtrl in Shift) and FItemsList.Focused and SelectedItem(It) then
        CopyKey(It)
      else
        Exit;
    VK_RETURN:
      if FItemsList.Focused and SelectedItem(It) then
        OpenDetail(It)
      else
        Exit;
    Ord('1')..Ord('4'):
      if ssCtrl in Shift then
        ShowPage(TPage(Key - Ord('1')))
      else
        Exit;
  else
    Exit;
  end;
  Key := 0;
end;

{ ── Busca e avisos ──────────────────────────────────────────────────────── }

procedure TIssuesPage.Notify(const ATitle, ABody: string; const AUrl: string;
  ATone: TUISemanticTone; const AKey: string; AAccountId: Integer);
var
  N: TNotification;
  E: TIssueEvent;
begin
  FLastUrl := AUrl;
  // "Não perturbe": guarda e entrega no fim do silêncio (CheckSchedules).
  if InQuietHours and (AKey <> '*teste') then
  begin
    E := Default(TIssueEvent);
    E.Title := ATitle;
    E.Body := ABody;
    E.Url := AUrl;
    E.Key := AKey;
    E.AccountId := AAccountId;
    E.Kind := ekComment;
    FPending := FPending + [E];
    Exit;
  end;
  // Padrão: aviso da ComponentesUI no canto da tela. 'windows' usa o toast do sistema.
  if IssueStore.GetSetting('notify_style', 'vigia') = 'vigia' then
  begin
    TNotifyManager.Show(ATitle, ABody, AUrl, ATone, AKey, AAccountId,
      StrToIntDef(IssueStore.GetSetting('notify_seconds'), DefaultNotifySeconds) * 1000);
    Exit;
  end;
  Inc(FToastSeq);
  // Toast do Windows. Se a plataforma recusar, cai no balão da tray.
  try
    N := FNotifier.CreateNotification;
    try
      N.Name := 'vigia-' + IntToStr(FToastSeq);
      N.Title := ATitle;
      N.AlertBody := ABody;
      if AUrl <> '' then
        FToastUrls.AddOrSetValue(N.Name, AUrl);
      FNotifier.PresentNotification(N);
    finally
      N.Free;
    end;
  except
    if FTray <> nil then
    begin
      FTray.BalloonTitle := ATitle;
      FTray.BalloonHint := ABody;
      FTray.ShowBalloonHint;
    end;
  end;
end;

procedure TIssuesPage.ToastClicked(Sender: TObject; ANotification: TNotification);
var
  Url: string;
begin
  if FToastUrls.TryGetValue(ANotification.Name, Url) then
    OpenUrl(Url);
end;

procedure TIssuesPage.BalloonClick(Sender: TObject);
begin
  OpenUrl(FLastUrl);
end;

procedure TIssuesPage.RefreshClick(Sender: TObject);
begin
  Poll(True);
end;

procedure TIssuesPage.TimerTick(Sender: TObject);
begin
  FTimer.Interval := PollIntervalMs;
  Poll(False);
end;

{ Rede numa task; diff, snapshot e toast de volta na thread de UI (FireDAC não é
  compartilhado entre threads). AManual = veio do usuário: mostra "nada novo". }
procedure TIssuesPage.Poll(AManual: Boolean);
var
  Jobs: TArray<TPollResult>;
  Job: TPollResult;
  A: TAccount;
  Global: Integer;
begin
  if FPolling then
    Exit;
  Jobs := nil;
  Global := StrToIntDef(IssueStore.GetSetting('poll_minutes'), DefaultPollMinutes);
  for A in IssueStore.ListAccounts do
    if A.Enabled and (AManual or FPollAll or
      (Now - IssueStore.LastPoll(A.Id) >= (IfThen(A.PollMinutes > 0, A.PollMinutes, Global) - 0.5) / MinsPerDay)) then
    begin
      Job := Default(TPollResult);
      Job.Account := A;
      Job.ManualKeys := IssueStore.ListManualKeys(A.Id);
      Jobs := Jobs + [Job];
    end;
  FPollAll := False;
  if Jobs = nil then
  begin
    if AManual then
      TUIToastManager.Show(Tr('Nenhuma conta ligada'), ttWarning);
    LoadItems;
    // Nenhuma conta na vez: o relógio segue.
    FTimer.Enabled := False;
    FTimer.Interval := PollIntervalMs;
    FTimer.Enabled := True;
    FNextPoll := Now + PollIntervalMs / MSecsPerDay;
    Exit;
  end;
  FPolling := True;
  // Reinicia o relógio: a busca manual empurra a automática.
  FTimer.Enabled := False;
  FTimer.Interval := PollIntervalMs;
  FTimer.Enabled := True;
  FNextPoll := Now + PollIntervalMs / MSecsPerDay;
  // (a dica da bandeja é do Devbox)
  ApplyFilters;
  UpdateHeader;

  RunTask(
    procedure
    var
      I: Integer;
      HToday, HWeek, T, W: Double;
      HasJira: Boolean;
    begin
      HToday := 0;
      HWeek := 0;
      HasJira := False;
      for I := 0 to High(Jobs) do
      begin
        try
          Jobs[I].Items := FetchItems(Jobs[I].Account, LoadSecret(Jobs[I].Account.SecretTarget),
            Jobs[I].ManualKeys, Jobs[I].Me);
        except
          on E: Exception do
            Jobs[I].Error := E.Message;
        end;
        // ponytail: soma só as contas Jira desta rodada; com várias contas Jira em
        // intervalos diferentes o total fica parcial até a próxima busca de todas.
        if (Jobs[I].Account.Kind in JiraKinds) and (Jobs[I].Error = '') then
          try
            FetchWeekHours(Jobs[I].Account, LoadSecret(Jobs[I].Account.SecretTarget), T, W);
            HToday := HToday + T;
            HWeek := HWeek + W;
            HasJira := True;
          except
            on E: Exception do
              OutputDebugString(PChar('Devbox issues: horas da semana (' + E.Message + ')'));
          end;
      end;

      QueueUI(
        procedure
        var
          PR: TPollResult;
          Events, All: TIssueEvents;
          E: TIssueEvent;
          Items: TItems;
          Baseline: Boolean;
          Errors, Keys, Status: string;
          Kept: TIssueEvents;
          It: TItem;
          Changed: TArray<string>;
          Before: TDictionary<string, Boolean>;
        begin
          All := nil;
          Changed := nil;
          if HasJira then
          begin
            FHoursToday := HToday;
            FHoursWeek := HWeek;
            FHoursLabel.Caption := Format(Tr('Lançado: %.1fh hoje · %.1fh na semana'), [HToday, HWeek]);
          end;
          // Chaves antes da busca: o que não estava aqui entra deslizando.
          Before := TDictionary<string, Boolean>.Create;
          for It in FAll do
            Before.AddOrSetValue(KeyOf(It), True);
          Errors := '';
          try
            for PR in Jobs do
            begin
              if PR.Error <> '' then
              begin
                FAccountErrors.AddOrSetValue(PR.Account.Id, PR.Error);
                Errors := Errors + PR.Account.Name + ': ' + PR.Error + sLineBreak;
                Continue;
              end;
              FAccountErrors.Remove(PR.Account.Id);
              Items := PR.Items;
              Baseline := not IssueStore.HasSnapshot(PR.Account.Id);
              Events := DiffItems(IssueStore.LoadSnapshot(PR.Account.Id), Items, PR.Account,
                PR.Me, Date, Baseline);
              IssueStore.SaveSnapshot(PR.Account.Id, Items);
              IssueStore.AddEvents(Events);
              if Baseline then
                Notify(Tr('Issues · ') + PR.Account.Name,
                  Format(Tr('Acompanhando %d itens. Aviso o que mudar daqui pra frente.'), [Length(Items)]));
              All := All + FilterEvents(Events, PR.Account.Events);
            end;

            // Silenciadas não avisam (o histórico continua gravando).
            Kept := nil;
            for E in All do
            begin
              Status := '';
              for PR in Jobs do
                for It in PR.Items do
                  if (It.AccountId = E.AccountId) and SameText(It.Key, E.Key) then
                    Status := It.Status;
              if not IssueStore.IsMuted(E.AccountId, E.Key, Status) then
                Kept := Kept + [E];
            end;
            All := Kept;
            Changed := nil;
            for E in All do
              Changed := Changed + [IntToStr(E.AccountId) + '|' + E.Key.ToUpper];

            if All <> nil then
            begin
              // Novidade: o mascote comemora uns segundos.
              FNewsUntil := Now + 5 / SecsPerDay;
              UpdateMascotMood;
            end;
            for E in All do
              if E.Kind = ekCiFailed then
                for PR in Jobs do
                  for It in PR.Items do
                    if (It.AccountId = E.AccountId) and SameText(It.Key, E.Key) then
                      ExplainCiFailure(It);
            if Length(All) <= MaxToastsPerPoll then
              for E in All do
                Notify(E.Title, E.Body, E.Url, EventTone(E.Kind), E.Key, E.AccountId)
            else
            begin
              Keys := '';
              for E in All do
                if not ContainsText(Keys, E.Key) then
                  Keys := Keys + IfThen(Keys <> '', ', ') + E.Key;
              Notify(Format(Tr('Issues · %d novidades'), [Length(All)]), Keys, '', stPrimary);
            end;

            // Janela aberta e ativa: o usuário já está vendo, não conta como não lido.
            if not (Visible and Application.Active) then
              Inc(FUnread, Length(All));

            FAlert.Title := Tr('Falha na busca');
            FAlert.Message_ := Errors.Trim;
            FAlert.Visible := Errors <> '';
            if AManual and (All = nil) and (Errors = '') then
              TUIToastManager.Show(Tr('Nada novo'), ttInfo, 2000);

            FLastPoll := Now;
          finally
            FPolling := False;
            ReloadAccounts;
            LoadItems;
            FNewKeys.Clear;
            if Before.Count > 0 then
              for It in FAll do
                if not Before.ContainsKey(KeyOf(It)) then
                  FNewKeys.AddOrSetValue(KeyOf(It), True);
            Before.Free;
            if (IssueStore.GetSetting('ai_triage') = '1') and (FNewKeys.Count > 0) then
            begin
              Items := nil;
              for It in FAll do
                if FNewKeys.ContainsKey(KeyOf(It)) then
                  Items := Items + [It];
              TriageItems(Items, False);
            end;
            FlashChanges(Changed);
            UpdateBadges;
            FStatusText := Format(Tr('%d itens · %s%s'), [Length(FAll),
              FormatDateTime('hh:nn', FLastPoll), IfThen(Errors <> '', Tr(' · com erro'), '')]);
          end;
        end);
    end);
end;

{ ── Janela e tray ───────────────────────────────────────────────────────── }

procedure TIssuesPage.TrayDblClick(Sender: TObject);
begin
  MenuOpenClick(Sender);
end;

procedure TIssuesPage.MenuOpenClick(Sender: TObject);
begin
  FUnread := 0;
  UpdateTrayIcon;
  UpdateBadges;
  UpdateHeader;
  if Assigned(FOnShowRequest) then
    FOnShowRequest(Self);
end;


procedure TIssuesPage.ThemeSwapToggle(Sender: TObject);
var
  Theme: string;
begin
  Theme := IfThen(FThemeSwap.Checked, 'dark', 'light');
  // Escolha explícita vale para este usuário; sem ela, segue o Windows.
  IssueStore.SetSetting('theme', Theme);
  // O círculo do reveal sai do centro do sol/lua, não do cursor.
  UITheme.SetThemeReveal(Theme, TPointF.Create(FThemeSwap.ClientToScreen(
    Point(FThemeSwap.Width div 2, FThemeSwap.Height div 2))), Self);
end;

procedure TIssuesPage.ThemeChanged(Sender: TObject; AMode: TUIThemeMode);
begin
  if FApplyingSize then
    Exit;
  ApplyCompactSize;
  FThemeSwap.Checked := UITheme.IsDark;
  FThemeSelect.OnChange := nil;
  FThemeSelect.ItemIndex := IndexText(IssueStore.GetSetting('theme'), ['', 'light', 'dark']);
  FThemeSelect.OnChange := GeneralSettingChange;
  ApplyThemeColors;
  FDetail.ApplyTheme;
  // Quadro e gráficos guardam cores do tema na criação.
  UpdateViews;
end;

initialization

end.
