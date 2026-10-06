unit Devbox.UI.Main;

{ Janela única: Clipboard (histórico + snippets), Serviços (Docker, WSL, portas)
  e Configurações. Fica na bandeja; Win+Alt+B abre a busca do clipboard. }

interface

uses
  Winapi.Windows,
  Winapi.Messages,
  System.Classes,
  System.SysUtils,
  System.Types,
  Vcl.Controls,
  Vcl.Forms,
  Vcl.Menus,
  Vcl.ExtCtrls,
  UI.Theme,
  UI.Tokens,
  UI.Button,
  UI.Input,
  UI.Swap,
  UI.Labels,
  UI.FilterChip,
  UI.EmptyState,
  UI.Tabs,
  UI.Toggle,
  UI.Code,
  UI.Stat,
  UI.ScrollArea,
  UI.VirtualList,
  UI.DataTable,
  UI.ProgressBar,
  Devbox.Model,
  Devbox.Sys;

type
  TPage = (pgClipboard, pgServices, pgSettings);
  TServiceTab = (stContainers, stWsl, stPorts);

  TMainForm = class(TForm)
  private
    FTray: TTrayIcon;
    FTrayMenu: TPopupMenu;
    FTabs: TUITabs;
    FPages: array[TPage] of TPanel;
    FThemeSwap: TUISwap;
    FApplyingSize: Boolean;
    FExitRequested: Boolean;
    // Clipboard
    FWatcher: TClipboardWatcher;
    FClips: TClips;
    FShown: TClips;
    FSearch: TUIInput;
    FSnippetChip: TUIFilterChip;
    FClipList: TUIVirtualList;
    FClipEmpty: TUIEmptyState;
    FPreview: TUICode;
    FPreviewScroll: TUIScrollArea;
    FPinBtn: TUIButton;
    FPrevWnd: HWND;              // janela que estava na frente antes do atalho
    FPasteTimer: TTimer;
    // Serviços
    FStats: array[0..3] of TUIStat;
    FServiceTabs: TUITabs;
    FTables: array[TServiceTab] of TUIDataTable;
    FToolbars: array[TServiceTab] of TPanel;
    FSel: array[TServiceTab] of Integer;
    FContainers: TContainers;
    FDistros: TDistros;
    FPorts: TListenPorts;
    FEngines: TArray<string>;    // motores de container que responderam
    FBusy: Boolean;
    FProgress: TUIProgressBar;
    FRefreshTimer: TTimer;
    FLogPanel: TPanel;
    FLogTitle: TUILabel;
    FLogScroll: TUIScrollArea;
    FLog: TUICode;
    FKillPid: Cardinal;
    // Configurações
    FClipToggle, FAutostartToggle, FHotkeyToggle: TUIToggle;

    function NewPanel(AParent: TWinControl; AAlign: TAlign; AHeight: Integer = 0): TPanel;
    function NewButton(AParent: TWinControl; const ACaption: string; AOnClick: TNotifyEvent;
      AVariant: TUIButtonVariant = bvOutline; AAlign: TAlign = alLeft): TUIButton;
    function NewToggleRow(AParent: TWinControl; const ACaption, AHint: string): TUIToggle;
    procedure BuildTray;
    procedure BuildShell;
    procedure BuildClipboardPage;
    procedure BuildServicesPage;
    procedure BuildSettingsPage;
    procedure ApplyThemeColors;
    procedure ApplyCompactSize;
    procedure ThemeChanged(Sender: TObject; AMode: TUIThemeMode);
    procedure ThemeSwapToggle(Sender: TObject);
    procedure ShowPage(APage: TPage);
    procedure TabChange(Sender: TObject; AIndex: Integer);
    procedure ShowWindow_;
    procedure SetHotkey(AOn: Boolean);
    // Clipboard
    procedure ClipCopied(const AText: string);
    procedure ReloadClips;
    procedure FilterClips;
    function SelectedClip(out AClip: TClip): Boolean;
    procedure UpdatePreview;
    procedure SearchChange(Sender: TObject);
    procedure ClipClick(Sender: TObject; AIndex: Integer; const AItem: TUIVListItem);
    procedure ClipDblClick(Sender: TObject; AIndex: Integer; const AItem: TUIVListItem);
    procedure PasteClick(Sender: TObject);
    procedure CopyClick(Sender: TObject);
    procedure PinClick(Sender: TObject);
    procedure DeleteClick(Sender: TObject);
    procedure PasteTimerTick(Sender: TObject);
    procedure MoveSelection(ADelta: Integer);
    // Serviços
    procedure RefreshServices;
    procedure ServicesLoaded;
    procedure RefreshClick(Sender: TObject);
    procedure RefreshTimerTick(Sender: TObject);
    procedure ServiceTabChange(Sender: TObject; AIndex: Integer);
    procedure RowSelect(Sender: TObject; ARowIndex: Integer);
    function SelectedContainer(out AContainer: TContainer): Boolean;
    function SelectedDistro(out ADistro: TDistro): Boolean;
    function SelectedPort(out APort: TListenPort): Boolean;
    procedure RunAndRefresh(const ACmdLine, ADoneMessage: string);
    procedure ContainerStart(Sender: TObject);
    procedure ContainerStop(Sender: TObject);
    procedure ContainerRestart(Sender: TObject);
    procedure ContainerLogs(Sender: TObject);
    procedure DistroOpen(Sender: TObject);
    procedure DistroTerminate(Sender: TObject);
    procedure WslShutdown(Sender: TObject);
    procedure PortOpen(Sender: TObject);
    procedure PortKill(Sender: TObject);
    procedure PortKillConfirmed(Sender: TObject);
    procedure LogClose(Sender: TObject);
    // Configurações
    procedure SettingToggle(Sender: TObject);
    procedure ClearHistoryClick(Sender: TObject);
    // Bandeja e janela
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
  System.UITypes,
  System.StrUtils,
  System.Math,
  System.Threading,
  Winapi.Dwmapi,
  Vcl.Graphics,
  UI.Painter,
  UI.Painter.Vcl,
  UI.Toast,
  UI.Icons.Heroicons,
  Devbox.Store;

const
  HotkeyId = 1;
  CRefreshMs = 30000;  // cada volta roda ~1,5 s de wsl por distro ligada
  CPreviewWidth = 420;
  CLogLines = 200;

var
  WM_DEVBOX_SHOW: Cardinal;

function StateText(const AState: string): string;
begin
  case IndexText(AState, ['running', 'exited', 'paused', 'created', 'restarting', 'dead']) of
    0: Result := 'rodando';
    1: Result := 'parado';
    2: Result := 'pausado';
    3: Result := 'criado';
    4: Result := 'reiniciando';
    5: Result := 'morto';
  else
    Result := AState;
  end;
end;

{ Ícone da bandeja: quadrado arredondado azul com "D". }
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
begin
  inherited CreateNew(AOwner);
  Caption := 'Devbox ' + AppVersion;
  ClientWidth := ScaleValue(1000);
  ClientHeight := ScaleValue(740);
  Constraints.MinWidth := ScaleValue(720);
  Constraints.MinHeight := ScaleValue(460);
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

  FPasteTimer := TTimer.Create(Self);
  FPasteTimer.Enabled := False;
  FPasteTimer.Interval := 80;
  FPasteTimer.OnTimer := PasteTimerTick;
  FRefreshTimer := TTimer.Create(Self);
  FRefreshTimer.Interval := CRefreshMs;
  FRefreshTimer.OnTimer := RefreshTimerTick;

  BuildTray;
  BuildShell;
  BuildClipboardPage;
  BuildServicesPage;
  BuildSettingsPage;
  ApplyThemeColors;
  UITheme.AddChangeListener(ThemeChanged);
  ShowPage(pgClipboard);

  FWatcher := TClipboardWatcher.Create(
    procedure(AText: string)
    begin
      ClipCopied(AText);
    end);
  ReloadClips;

end;

destructor TMainForm.Destroy;
begin
  UITheme.RemoveChangeListener(ThemeChanged);
  FWatcher.Free;
  inherited;
end;

procedure TMainForm.CreateWnd;
begin
  inherited;
  SetHotkey(Store.GetSetting('hotkey_on', '1') = '1');
end;

procedure TMainForm.DestroyWnd;
begin
  UnregisterHotKey(Handle, HotkeyId);
  inherited;
end;

procedure TMainForm.WndProc(var Message: TMessage);
begin
  if (WM_DEVBOX_SHOW <> 0) and (Message.Msg = WM_DEVBOX_SHOW) then
    MenuOpenClick(nil)
  else if (Message.Msg = WM_HOTKEY) and (Message.WParam = HotkeyId) then
  begin
    if Visible and (GetForegroundWindow = Handle) then
      Hide
    else
    begin
      FPrevWnd := GetForegroundWindow;
      ShowPage(pgClipboard);
      FSearch.Value := '';
      ShowWindow_;
      FSearch.SetFocus;
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

function TMainForm.NewPanel(AParent: TWinControl; AAlign: TAlign; AHeight: Integer): TPanel;
begin
  Result := TPanel.Create(Self);
  Result.BevelOuter := bvNone;
  Result.ParentBackground := False;
  Result.DoubleBuffered := True;
  if AHeight > 0 then
    Result.Height := ScaleValue(AHeight);
  Result.Align := AAlign;
  Result.Top := 100000;
  Result.Parent := AParent;
end;

function TMainForm.NewButton(AParent: TWinControl; const ACaption: string;
  AOnClick: TNotifyEvent; AVariant: TUIButtonVariant; AAlign: TAlign): TUIButton;
begin
  Result := TUIButton.Create(Self);
  Result.Caption := ACaption;
  Result.Variant := AVariant;
  Result.AutoWidth := True;
  Result.OnClick := AOnClick;
  Result.AlignWithMargins := True;
  if AAlign = alRight then
    Result.Margins.SetBounds(ScaleValue(8), 0, 0, 0)
  else
    Result.Margins.SetBounds(0, 0, ScaleValue(8), 0);
  Result.Left := 100000;
  Result.Align := AAlign;
  Result.Parent := AParent;
end;

{ Switch + rótulo + dica cinza em itálico embaixo. }
function TMainForm.NewToggleRow(AParent: TWinControl; const ACaption, AHint: string): TUIToggle;
var
  Row, Text: TPanel;
  L: TUILabel;
begin
  Row := NewPanel(AParent, alTop, 56);
  Result := TUIToggle.Create(Self);
  Result.Width := ScaleValue(44);
  Result.AlignWithMargins := True;
  Result.Margins.SetBounds(0, ScaleValue(2), 0, ScaleValue(30));
  Result.Align := alLeft;
  Result.OnChange := SettingToggle;
  Result.Parent := Row;
  Text := NewPanel(Row, alClient);
  Text.Padding.SetBounds(ScaleValue(10), 0, 0, 0);
  L := TUILabel.Create(Self);
  L.Caption := ACaption;
  L.AutoSize := False;
  L.Height := ScaleValue(24);
  L.Align := alTop;
  L.Parent := Text;
  L := TUILabel.Create(Self);
  L.Caption := AHint;
  L.Variant := lvMuted;
  L.FontSize := 12;
  L.Italic := True;
  L.AutoSize := False;
  L.Height := ScaleValue(20);
  L.Top := 1000;
  L.Align := alTop;
  L.Parent := Text;
end;

procedure TMainForm.ApplyThemeColors;

  procedure Paint(AControl: TWinControl);
  var
    I: Integer;
  begin
    if (AControl is TPanel) and not TPanel(AControl).ParentBackground then
      TPanel(AControl).Color := UIThemeVclBackground;
    for I := 0 to AControl.ControlCount - 1 do
      if AControl.Controls[I] is TWinControl then
        Paint(TWinControl(AControl.Controls[I]));
  end;

const
  DWMWA_USE_IMMERSIVE_DARK_MODE = 20;
var
  Dark: BOOL;
begin
  Color := UIThemeVclBackground;
  Paint(Self);
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
  AddItem('-', nil);
  AddItem('Sair', MenuExitClick);
  FTray := TTrayIcon.Create(Self);
  FTray.Icon.Handle := MakeTrayIcon;
  FTray.Hint := 'Devbox  ·  Win+Alt+B abre o clipboard';
  FTray.PopupMenu := FTrayMenu;
  FTray.OnDblClick := MenuOpenClick;
  FTray.Visible := True;
end;

procedure TMainForm.BuildShell;
var
  Bar: TPanel;
  Title: TUILabel;
  P: TPage;
begin
  Bar := NewPanel(Self, alTop, 56);
  Bar.Padding.SetBounds(ScaleValue(16), 0, ScaleValue(16), 0);
  Title := TUILabel.Create(Self);
  Title.Caption := 'Devbox';
  Title.Bold := True;
  Title.FontSize := 18;
  Title.AutoSize := False;
  Title.Width := ScaleValue(140);
  Title.Align := alLeft;
  Title.Parent := Bar;

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
  FThemeSwap.Margins.SetBounds(0, 10, 0, 10);
  FThemeSwap.Align := alRight;
  FThemeSwap.Parent := Bar;

  FTabs := TUITabs.Create(Self);
  FTabs.AddTab('Clipboard');
  FTabs.AddTab('Serviços');
  FTabs.AddTab('Configurações');
  FTabs.AlignWithMargins := True;
  FTabs.Margins.SetBounds(ScaleValue(16), 0, ScaleValue(16), 0);
  FTabs.Top := 100000;
  FTabs.Align := alTop;
  FTabs.Parent := Self;
  FTabs.OnChange := TabChange;

  for P := Low(TPage) to High(TPage) do
  begin
    FPages[P] := NewPanel(Self, alClient);
    FPages[P].Padding.SetBounds(ScaleValue(16), ScaleValue(12), ScaleValue(16), ScaleValue(12));
    FPages[P].Visible := False;
  end;
end;

procedure TMainForm.BuildClipboardPage;
var
  Page, Bar, Right, Buttons: TPanel;
  Hint: TUILabel;
begin
  Page := FPages[pgClipboard];

  Bar := NewPanel(Page, alTop, 48);
  Bar.Padding.SetBounds(0, 0, 0, ScaleValue(8));
  FSnippetChip := TUIFilterChip.Create(Self);
  FSnippetChip.Caption := 'Snippets';
  FSnippetChip.Tone := btPrimary;
  FSnippetChip.OnToggle := SearchChange;
  FSnippetChip.AlignWithMargins := True;
  FSnippetChip.Margins.SetBounds(ScaleValue(8), ScaleValue(4), 0, ScaleValue(4));
  FSnippetChip.Align := alRight;
  FSnippetChip.Parent := Bar;
  FSearch := TUIInput.Create(Self);
  FSearch.LabelMode := ilmBorder;
  FSearch.LabelText := 'Buscar no histórico e nos snippets';
  FSearch.ReserveHintSpace := False;
  FSearch.ShowClearButton := True;
  FSearch.OnChange := SearchChange;
  FSearch.Align := alClient;
  FSearch.Parent := Bar;

  Hint := TUILabel.Create(Self);
  Hint.Caption := 'Enter cola na janela de antes  ·  ↑↓ escolhem  ·  Esc fecha  ·  ' +
    'senhas de gerenciador e textos com cara de token não entram';
  Hint.Variant := lvMuted;
  Hint.FontSize := 12;
  Hint.Italic := True;
  Hint.AutoSize := False;
  Hint.Height := ScaleValue(24);
  Hint.Align := alBottom;
  Hint.Parent := Page;

  Right := NewPanel(Page, alRight);
  Right.Width := ScaleValue(CPreviewWidth);
  Right.Padding.SetBounds(ScaleValue(12), 0, 0, 0);
  Buttons := NewPanel(Right, alBottom, 44);
  Buttons.Padding.SetBounds(0, ScaleValue(8), 0, 0);
  NewButton(Buttons, 'Colar', PasteClick, bvPrimary);
  NewButton(Buttons, 'Copiar', CopyClick);
  FPinBtn := NewButton(Buttons, 'Fixar como snippet', PinClick);
  NewButton(Buttons, 'Excluir', DeleteClick, bvGhost, alRight);
  FPreviewScroll := TUIScrollArea.Create(Self);
  FPreviewScroll.Align := alClient;
  FPreviewScroll.Parent := Right;
  FPreview := TUICode.Create(Self);
  FPreview.Align := alTop;
  FPreview.Parent := FPreviewScroll.InnerPanel;

  FClipList := TUIVirtualList.Create(Self);
  FClipList.RowHeight := 56;
  FClipList.Align := alClient;
  FClipList.OnItemClick := ClipClick;
  FClipList.OnItemDblClick := ClipDblClick;
  FClipList.Parent := Page;

  FClipEmpty := TUIEmptyState.Create(Self);
  FClipEmpty.Title := 'Nada copiado ainda';
  FClipEmpty.Description := 'Copie um texto em qualquer programa. Ele aparece aqui e fica a um Win+Alt+B de distância.';
  FClipEmpty.Visible := False;
  FClipEmpty.Align := alClient;
  FClipEmpty.Parent := Page;
end;

procedure TMainForm.BuildServicesPage;
const
  StatLabels: array[0..3] of string = ('Containers', 'Distros WSL', 'Portas em escuta', 'Motores');
  TabNames: array[TServiceTab] of string = ('Containers', 'WSL', 'Portas');
var
  Page, Cards, Bar: TPanel;
  I: Integer;
  T: TServiceTab;
  C: TUIColorTokens;

  procedure Badges(ATable: TUIDataTable; const ACol: string);
  begin
    ATable.SetColType(ACol, ctBadge);
    ATable.AddBadgeMap(ACol, 'rodando', C.SuccessSubtle, C.Success);
    ATable.AddBadgeMap(ACol, 'ligada', C.SuccessSubtle, C.Success);
    ATable.AddBadgeMap(ACol, 'parado', C.BGMuted, C.FGMuted);
    ATable.AddBadgeMap(ACol, 'desligada', C.BGMuted, C.FGMuted);
    ATable.AddBadgeMap(ACol, 'pausado', C.WarningSubtle, C.Warning);
    ATable.AddBadgeMap(ACol, 'reiniciando', C.WarningSubtle, C.Warning);
  end;

begin
  C := UITheme.Tokens.Color;
  Page := FPages[pgServices];

  Cards := NewPanel(Page, alTop, 124);
  Cards.Padding.SetBounds(0, 0, 0, ScaleValue(12));
  for I := 0 to High(FStats) do
  begin
    FStats[I] := TUIStat.Create(Self);
    FStats[I].CardLabel := StatLabels[I];
    FStats[I].Value := '–';
    FStats[I].Width := ScaleValue(220);
    FStats[I].AlignWithMargins := True;
    FStats[I].Margins.SetBounds(0, 0, ScaleValue(12), 0);
    FStats[I].Left := (I + 1) * 1000;
    FStats[I].Align := alLeft;
    FStats[I].Parent := Cards;
  end;

  FServiceTabs := TUITabs.Create(Self);
  for T := Low(TServiceTab) to High(TServiceTab) do
    FServiceTabs.AddTab(TabNames[T]);
  FServiceTabs.Top := 100000;
  FServiceTabs.Align := alTop;
  FServiceTabs.Parent := Page;
  FServiceTabs.OnChange := ServiceTabChange;

  FProgress := TUIProgressBar.Create(Self);
  FProgress.Indeterminate := True;
  FProgress.TrackHeight := 3;
  FProgress.Height := 3;
  FProgress.Visible := False;
  FProgress.Top := 100000;
  FProgress.Align := alTop;
  FProgress.Parent := Page;

  for T := Low(TServiceTab) to High(TServiceTab) do
  begin
    Bar := NewPanel(Page, alTop, 52);
    Bar.Padding.SetBounds(0, ScaleValue(8), 0, ScaleValue(8));
    Bar.Visible := False;
    NewButton(Bar, 'Atualizar', RefreshClick, bvGhost, alRight);
    FToolbars[T] := Bar;
    FSel[T] := -1;
  end;
  NewButton(FToolbars[stContainers], 'Iniciar', ContainerStart);
  NewButton(FToolbars[stContainers], 'Parar', ContainerStop);
  NewButton(FToolbars[stContainers], 'Reiniciar', ContainerRestart);
  NewButton(FToolbars[stContainers], 'Ver logs', ContainerLogs);
  NewButton(FToolbars[stWsl], 'Abrir terminal', DistroOpen);
  NewButton(FToolbars[stWsl], 'Desligar', DistroTerminate);
  NewButton(FToolbars[stWsl], 'Desligar o WSL todo', WslShutdown, bvGhost);
  NewButton(FToolbars[stPorts], 'Abrir no navegador', PortOpen);
  NewButton(FToolbars[stPorts], 'Encerrar processo', PortKill);

  // Logs do container: painel de baixo, fecha no X.
  FLogPanel := NewPanel(Page, alBottom, 260);
  FLogPanel.Padding.SetBounds(0, ScaleValue(8), 0, 0);
  FLogPanel.Visible := False;
  Bar := NewPanel(FLogPanel, alTop, 36);
  NewButton(Bar, 'Fechar', LogClose, bvGhost, alRight);
  FLogTitle := TUILabel.Create(Self);
  FLogTitle.Bold := True;
  FLogTitle.AutoSize := False;
  FLogTitle.Align := alClient;
  FLogTitle.Parent := Bar;
  FLogScroll := TUIScrollArea.Create(Self);
  FLogScroll.Align := alClient;
  FLogScroll.Parent := FLogPanel;
  FLog := TUICode.Create(Self);
  FLog.FontSize := 11;
  FLog.Align := alTop;
  FLog.Parent := FLogScroll.InnerPanel;

  for T := Low(TServiceTab) to High(TServiceTab) do
  begin
    FTables[T] := TUIDataTable.Create(Self);
    FTables[T].SelectionMode := tsmSingle;
    FTables[T].Density := tdCompact;
    FTables[T].OnRowSelect := RowSelect;
    FTables[T].Tag := Ord(T);
    FTables[T].Visible := False;
    FTables[T].Align := alClient;
    FTables[T].Parent := Page;
  end;
  with FTables[stContainers] do
  begin
    AddColumn('name', 'Nome', 'name', 200);
    AddColumn('state', 'Estado', 'state', 110);
    AddColumn('where', 'Onde', 'where', 130);
    AddColumn('image', 'Imagem', 'image', 240);
    AddColumn('status', 'Há quanto tempo', 'status', 170);
    AddColumn('ports', 'Portas', 'ports', 260);
    EmptyStateText := 'Nenhum container encontrado';
  end;
  Badges(FTables[stContainers], 'state');
  with FTables[stWsl] do
  begin
    AddColumn('name', 'Distro', 'name', 260);
    AddColumn('state', 'Estado', 'state', 120);
    AddColumn('default', 'Padrão', 'default', 100);
    EmptyStateText := 'Nenhuma distro WSL instalada';
  end;
  Badges(FTables[stWsl], 'state');
  with FTables[stPorts] do
  begin
    AddColumn('port', 'Porta', 'port', 90, True, caRight);
    AddColumn('address', 'Endereço', 'address', 130);
    AddColumn('process', 'Processo', 'process', 220);
    AddColumn('pid', 'PID', 'pid', 90, True, caRight);
    AddColumn('container', 'Container', 'container', 220);
    SetColType('port', ctNumber);
    SetColType('pid', ctNumber);
    EmptyStateText := 'Nenhuma porta em escuta';
  end;
  FServiceTabs.ActiveIndex := 0;
  ServiceTabChange(nil, 0);
end;

procedure TMainForm.BuildSettingsPage;
var
  Page, Row: TPanel;
begin
  Page := FPages[pgSettings];
  FClipToggle := NewToggleRow(Page, 'Guardar o que eu copio',
    Format('Últimos %d textos ficam no histórico. Snippets ficam para sempre.', [HistoryLimit]));
  FClipToggle.Checked := Store.GetSetting('clip_on', '1') = '1';
  FHotkeyToggle := NewToggleRow(Page, 'Atalho Win+Alt+B',
    'Abre a busca do clipboard de qualquer programa. Enter cola onde você estava.');
  FHotkeyToggle.Checked := Store.GetSetting('hotkey_on', '1') = '1';
  FAutostartToggle := NewToggleRow(Page, 'Iniciar com o Windows',
    'O Devbox abre escondido na bandeja quando você entra no Windows.');
  FAutostartToggle.Checked := AutostartEnabled;
  Row := NewPanel(Page, alTop, 48);
  Row.Padding.SetBounds(0, ScaleValue(8), 0, 0);
  NewButton(Row, 'Limpar histórico', ClearHistoryClick);
end;

procedure TMainForm.ShowPage(APage: TPage);
var
  P: TPage;
begin
  for P := Low(TPage) to High(TPage) do
    FPages[P].Visible := P = APage;
  if FTabs.ActiveIndex <> Ord(APage) then
  begin
    FTabs.OnChange := nil;
    FTabs.ActiveIndex := Ord(APage);
    FTabs.OnChange := TabChange;
  end;
  FRefreshTimer.Enabled := APage = pgServices;
  if APage = pgServices then
    RefreshServices;
end;

procedure TMainForm.TabChange(Sender: TObject; AIndex: Integer);
begin
  ShowPage(TPage(AIndex));
end;

procedure TMainForm.ShowWindow_;
begin
  if not Visible then
    Show;
  if IsIconic(Handle) then
    ShowWindow(Handle, SW_RESTORE);
  SetForegroundWindow(Handle);
end;

{ Clipboard }

procedure TMainForm.ClipCopied(const AText: string);
begin
  if (Store.GetSetting('clip_on', '1') <> '1') or LooksSecret(AText) then
    Exit;
  Store.AddClip(AText);
  ReloadClips;
end;

procedure TMainForm.ReloadClips;
begin
  FClips := Store.ListClips;
  FilterClips;
end;

procedure TMainForm.FilterClips;
const
  CMaxTitle = 140;
var
  C: TClip;
  Q, Sub: string;
  Item: TUIVListItem;
  Lines: Integer;
begin
  Q := Trim(FSearch.Value);
  FShown := nil;
  for C in FClips do
    if (not FSnippetChip.Active or C.Pinned) and ((Q = '') or ContainsText(C.Text, Q)) then
      FShown := FShown + [C];
  FClipList.ClearItems;
  for C in FShown do
  begin
    Item := Default(TUIVListItem);
    Item.ID := IntToStr(C.Id);
    Item.Title := Copy(C.Title, 1, CMaxTitle);
    Lines := Length(C.Text) - Length(StringReplace(C.Text, #10, '', [rfReplaceAll])) + 1;
    Sub := Ago(C.CreatedAt, Now);
    if Lines > 1 then
      Sub := Sub + Format('  ·  %d linhas', [Lines])
    else
      Sub := Sub + Format('  ·  %d caracteres', [Length(C.Text)]);
    Item.Subtitle := Sub;
    if C.Pinned then
      Item.MetaText := 'snippet';
    FClipList.AddItem(Item);
  end;
  FClipList.Visible := FShown <> nil;
  FClipEmpty.Visible := FShown = nil;
  if FShown <> nil then
  begin
    if Q <> '' then
      FClipEmpty.Title := 'Nada encontrado'
    else
      FClipEmpty.Title := 'Nada copiado ainda';
    FClipList.SelectIndex(0);
  end
  else if (Q <> '') or FSnippetChip.Active then
    FClipEmpty.Title := 'Nada encontrado';
  FSnippetChip.Count := 0;
  for C in FClips do
    if C.Pinned then
      FSnippetChip.Count := FSnippetChip.Count + 1;
  UpdatePreview;
end;

function TMainForm.SelectedClip(out AClip: TClip): Boolean;
var
  Sel: TArray<Integer>;
begin
  Sel := FClipList.GetSelectedIndices;
  Result := (Sel <> nil) and (Sel[0] >= 0) and (Sel[0] <= High(FShown));
  if Result then
    AClip := FShown[Sel[0]];
end;

procedure TMainForm.UpdatePreview;
const
  CLineHeight = 17;
  CPad = 24;
var
  C: TClip;
  Lines: Integer;
begin
  if not SelectedClip(C) then
  begin
    FPreview.Text := '';
    FPreview.Height := ScaleValue(CPad * 2);
    Exit;
  end;
  FPreview.Text := StringReplace(C.Text, #13, '', [rfReplaceAll]);  // texto copiado no Windows vem com CR+LF
  Lines := Length(C.Text) - Length(StringReplace(C.Text, #10, '', [rfReplaceAll])) + 1;
  FPreview.Height := ScaleValue(Max(Lines * CLineHeight + CPad, 120));
  FPinBtn.Caption := IfThen(C.Pinned, 'Desafixar', 'Fixar como snippet');
end;

procedure TMainForm.SearchChange(Sender: TObject);
begin
  FilterClips;
end;

procedure TMainForm.ClipClick(Sender: TObject; AIndex: Integer; const AItem: TUIVListItem);
begin
  UpdatePreview;
end;

procedure TMainForm.ClipDblClick(Sender: TObject; AIndex: Integer; const AItem: TUIVListItem);
begin
  PasteClick(nil);
end;

procedure TMainForm.MoveSelection(ADelta: Integer);
var
  Sel: TArray<Integer>;
  I: Integer;
begin
  if FShown = nil then
    Exit;
  Sel := FClipList.GetSelectedIndices;
  if Sel = nil then
    I := 0
  else
    I := EnsureRange(Sel[0] + ADelta, 0, High(FShown));
  FClipList.SelectIndex(I);
  FClipList.ScrollToIndex(I);
  UpdatePreview;
end;

procedure TMainForm.CopyClick(Sender: TObject);
var
  C: TClip;
begin
  if not SelectedClip(C) then
    Exit;
  FWatcher.SetText(C.Text);
  TUIToastManager.Show('Copiado', ttSuccess, 1500);
end;

{ Cola na janela que estava na frente quando o atalho abriu o Devbox. Aberto
  pela bandeja, não há janela de antes: só copia. }
procedure TMainForm.PasteClick(Sender: TObject);
var
  C: TClip;
begin
  if not SelectedClip(C) then
    Exit;
  FWatcher.SetText(C.Text);
  Store.AddClip(C.Text);  // usado agora sobe para o topo
  if (FPrevWnd = 0) or (FPrevWnd = Handle) or not IsWindow(FPrevWnd) then
  begin
    ReloadClips;
    TUIToastManager.Show('Copiado. Abra pelo Win+Alt+B para colar direto.', ttSuccess, 3000);
    Exit;
  end;
  Hide;
  FPasteTimer.Enabled := True;
end;

procedure TMainForm.PasteTimerTick(Sender: TObject);
begin
  FPasteTimer.Enabled := False;
  PasteInto(FPrevWnd);
  FPrevWnd := 0;
  ReloadClips;
end;

procedure TMainForm.PinClick(Sender: TObject);
var
  C: TClip;
begin
  if not SelectedClip(C) then
    Exit;
  Store.SetPinned(C.Id, not C.Pinned);
  ReloadClips;
end;

procedure TMainForm.DeleteClick(Sender: TObject);
var
  C: TClip;
begin
  if not SelectedClip(C) then
    Exit;
  Store.DeleteClip(C.Id);
  ReloadClips;
end;

{ Serviços }

{ Junta os containers de um motor em AList. False = motor não respondeu. }
function CollectContainers(const ADistro, AEngine: string; var AList: TContainers): Boolean;
var
  Output: string;
  C: TContainer;
begin
  Result := RunCapture(ContainerListCmd(ADistro, AEngine), Output) = 0;
  if not Result then
    Exit;
  for C in ParseDockerPs(Output, Now) do
  begin
    AList := AList + [C];
    AList[High(AList)].Distro := ADistro;
    AList[High(AList)].Engine := AEngine;
  end;
end;

{ Docker, WSL e portas numa thread só; a tela atualiza no fim. }
procedure TMainForm.RefreshServices;
begin
  if FBusy then
    Exit;
  FBusy := True;
  FProgress.Visible := True;
  TTask.Run(
    procedure
    var
      Out1, Out2: string;
      Containers: TContainers;
      Distros: TDistros;
      Ports: TListenPorts;
      Engines: TArray<string>;
      I, J: Integer;
      P: Integer;
      D: TDistro;
    begin
      Containers := nil;
      Engines := nil;
      Distros := nil;
      if RunCapture('wsl.exe -l -q', Out1) = 0 then
      begin
        RunCapture('wsl.exe -l --running -q', Out2);
        Distros := ParseWslLists(Out1, Out2);
      end;
      // Docker Desktop no Windows e, em cada distro já ligada, podman ou docker.
      // Distro desligada fica de fora: rodar o wsl -d nela a ligaria.
      if CollectContainers('', 'docker', Containers) then
        Engines := Engines + ['docker (Windows)'];
      for D in Distros do
        if D.Running and not StartsText('docker-desktop', D.Name) then
          if CollectContainers(D.Name, 'podman', Containers) then
            Engines := Engines + ['podman (' + D.Name + ')']
          else if CollectContainers(D.Name, 'docker', Containers) then
            Engines := Engines + ['docker (' + D.Name + ')'];
      Ports := ListListenPorts;
      for I := 0 to High(Ports) do
        for J := 0 to High(Containers) do
          for P in PublishedPorts(Containers[J].Ports) do
            if P = Ports[I].Port then
              Ports[I].Container := Containers[J].Name;
      System.Classes.TThread.Queue(nil,
        procedure
        begin
          FContainers := Containers;
          FDistros := Distros;
          FPorts := Ports;
          FEngines := Engines;
          ServicesLoaded;
        end);
    end);
end;

procedure TMainForm.ServicesLoaded;
var
  C: TContainer;
  D: TDistro;
  P: TListenPort;
  Running: Integer;
  T: TServiceTab;
begin
  FBusy := False;
  FProgress.Visible := False;
  for T := Low(TServiceTab) to High(TServiceTab) do
  begin
    FTables[T].BeginRowUpdate;
    FTables[T].ClearMemRows;
    FSel[T] := -1;
  end;
  Running := 0;
  for C in FContainers do
  begin
    FTables[stContainers].AddMemRow([C.Name, StateText(C.State), IfThen(C.Distro = '', 'Windows', C.Distro),
      StringReplace(C.Image, 'docker.io/library/', '', []), C.Status, C.Ports]);
    if C.Running then
      Inc(Running);
  end;
  FStats[0].Value := Format('%d/%d', [Running, Length(FContainers)]);
  FStats[0].SubText := 'rodando';
  Running := 0;
  for D in FDistros do
  begin
    FTables[stWsl].AddMemRow([D.Name, IfThen(D.Running, 'ligada', 'desligada'), IfThen(D.IsDefault, 'sim', '')]);
    if D.Running then
      Inc(Running);
  end;
  FStats[1].Value := Format('%d/%d', [Running, Length(FDistros)]);
  FStats[1].SubText := 'ligadas';
  for P in FPorts do
    FTables[stPorts].AddMemRow([IntToStr(P.Port), P.Address, P.Process, IntToStr(P.Pid), P.Container]);
  FStats[2].Value := IntToStr(Length(FPorts));
  FStats[2].SubText := 'TCP, IPv4 e IPv6';
  FStats[3].Value := IntToStr(Length(FEngines));
  if FEngines = nil then
    FStats[3].SubText := 'nenhum docker ou podman respondeu'
  else
    FStats[3].SubText := string.Join(', ', FEngines);
  FStats[3].Tone := TUISemanticTone(IfThen(FEngines <> nil, Ord(stSuccess), Ord(stWarning)));
  for T := Low(TServiceTab) to High(TServiceTab) do
    FTables[T].EndRowUpdate;
end;

procedure TMainForm.RefreshClick(Sender: TObject);
begin
  RefreshServices;
end;

procedure TMainForm.RefreshTimerTick(Sender: TObject);
begin
  if Visible and not IsIconic(Handle) then
    RefreshServices;
end;

procedure TMainForm.ServiceTabChange(Sender: TObject; AIndex: Integer);
var
  T: TServiceTab;
begin
  for T := Low(TServiceTab) to High(TServiceTab) do
  begin
    FToolbars[T].Visible := Ord(T) = AIndex;
    FTables[T].Visible := Ord(T) = AIndex;
  end;
end;

procedure TMainForm.RowSelect(Sender: TObject; ARowIndex: Integer);
begin
  FSel[TServiceTab(TComponent(Sender).Tag)] := ARowIndex;
end;

{ A linha da tabela guarda o nome na coluna 0: acha o registro por ele, que a
  ordem da tabela pode ter mudado pelo clique no cabeçalho. }
function TMainForm.SelectedContainer(out AContainer: TContainer): Boolean;
var
  Name, Where: string;
  C: TContainer;
begin
  Result := False;
  if FSel[stContainers] < 0 then
    Exit;
  Name := FTables[stContainers].MemCellValue(FSel[stContainers], 0);
  Where := FTables[stContainers].MemCellValue(FSel[stContainers], 2);
  for C in FContainers do
    if (C.Name = Name) and (IfThen(C.Distro = '', 'Windows', C.Distro) = Where) then
    begin
      AContainer := C;
      Exit(True);
    end;
end;

function TMainForm.SelectedDistro(out ADistro: TDistro): Boolean;
var
  Name: string;
  D: TDistro;
begin
  Result := False;
  if FSel[stWsl] < 0 then
    Exit;
  Name := FTables[stWsl].MemCellValue(FSel[stWsl], 0);
  for D in FDistros do
    if D.Name = Name then
    begin
      ADistro := D;
      Exit(True);
    end;
end;

function TMainForm.SelectedPort(out APort: TListenPort): Boolean;
var
  Port: Integer;
  P: TListenPort;
begin
  Result := False;
  if FSel[stPorts] < 0 then
    Exit;
  Port := StrToIntDef(FTables[stPorts].MemCellValue(FSel[stPorts], 0), -1);
  for P in FPorts do
    if P.Port = Port then
    begin
      APort := P;
      Exit(True);
    end;
end;

procedure TMainForm.RunAndRefresh(const ACmdLine, ADoneMessage: string);
begin
  FProgress.Visible := True;
  TTask.Run(
    procedure
    var
      Output: string;
      Code: Integer;
    begin
      Code := RunCapture(ACmdLine, Output, 60000);
      System.Classes.TThread.Queue(nil,
        procedure
        begin
          if Code = 0 then
            TUIToastManager.Show(ADoneMessage, ttSuccess, 2500)
          else
            TUIToastManager.Show(IfThen(Trim(Output) = '', 'O comando falhou', Trim(Output)), ttError, 6000);
          RefreshServices;
        end);
    end);
end;

procedure TMainForm.ContainerStart(Sender: TObject);
var
  C: TContainer;
begin
  if SelectedContainer(C) then
    RunAndRefresh(C.Cli + ' start ' + C.Id, C.Name + ' iniciado');
end;

procedure TMainForm.ContainerStop(Sender: TObject);
var
  C: TContainer;
begin
  if SelectedContainer(C) then
    RunAndRefresh(C.Cli + ' stop ' + C.Id, C.Name + ' parado');
end;

procedure TMainForm.ContainerRestart(Sender: TObject);
var
  C: TContainer;
begin
  if SelectedContainer(C) then
    RunAndRefresh(C.Cli + ' restart ' + C.Id, C.Name + ' reiniciado');
end;

procedure TMainForm.ContainerLogs(Sender: TObject);
var
  C: TContainer;
  Id, Name, Cli: string;
begin
  if not SelectedContainer(C) then
    Exit;
  Id := C.Id;
  Name := C.Name;
  Cli := C.Cli;
  FLogTitle.Caption := 'Logs de ' + Name + '  ·  últimas ' + IntToStr(CLogLines) + ' linhas';
  FLog.Text := 'carregando...';
  FLogPanel.Height := FPages[pgServices].Height * 2 div 5;
  FLogPanel.Visible := True;
  TTask.Run(
    procedure
    var
      Output: string;
    begin
      RunCapture(Format('%s logs --tail %d %s', [Cli, CLogLines, Id]), Output);
      System.Classes.TThread.Queue(nil,
        procedure
        const
          CLineHeight = 15;
        var
          Lines: Integer;
        begin
          // Podman manda CR+LF; o desenho do TUICode quebra nos dois e dobrava as linhas.
          FLog.Text := StringReplace(TrimRight(Output), #13, '', [rfReplaceAll]);
          if FLog.Text = '' then
            FLog.Text := '(sem logs)';
          Lines := Length(FLog.Text) - Length(StringReplace(FLog.Text, #10, '', [rfReplaceAll])) + 1;
          FLog.Height := ScaleValue(Lines * CLineHeight + 24);
          // Abre no fim: o mais novo é o que interessa.
          FLogScroll.ScrollTo(0, FLog.Height);
        end);
    end);
end;

procedure TMainForm.LogClose(Sender: TObject);
begin
  FLogPanel.Visible := False;
end;

procedure TMainForm.DistroOpen(Sender: TObject);
var
  D: TDistro;
begin
  if SelectedDistro(D) then
    Launch('wsl.exe', '-d ' + D.Name + ' --cd ~');
end;

procedure TMainForm.DistroTerminate(Sender: TObject);
var
  D: TDistro;
begin
  if SelectedDistro(D) then
    RunAndRefresh('wsl.exe --terminate ' + D.Name, D.Name + ' desligada');
end;

procedure TMainForm.WslShutdown(Sender: TObject);
begin
  RunAndRefresh('wsl.exe --shutdown', 'WSL desligado');
end;

procedure TMainForm.PortOpen(Sender: TObject);
var
  P: TListenPort;
begin
  if SelectedPort(P) then
    OpenUrl(Format('http://localhost:%d', [P.Port]));
end;

{ Encerrar pede confirmação no próprio aviso: o botão do toast é o "sim". }
procedure TMainForm.PortKill(Sender: TObject);
var
  P: TListenPort;
begin
  if not SelectedPort(P) then
    Exit;
  if P.Pid <= 4 then
  begin
    TUIToastManager.Show('Processo do sistema: não dá para encerrar', ttWarning, 4000);
    Exit;
  end;
  FKillPid := P.Pid;
  TUIToastManager.Show(Format('Encerrar %s (PID %d), dono da porta %d?', [P.Process, P.Pid, P.Port]),
    ttWarning, 8000, 'Encerrar', PortKillConfirmed);
end;

procedure TMainForm.PortKillConfirmed(Sender: TObject);
begin
  if KillProcess(FKillPid) then
    TUIToastManager.Show('Processo encerrado', ttSuccess, 2500)
  else
    TUIToastManager.Show('Não deu para encerrar. Ele pode ser de outro usuário ou do sistema.', ttError, 6000);
  FKillPid := 0;
  RefreshServices;
end;

{ Configurações }

procedure TMainForm.SettingToggle(Sender: TObject);
begin
  if Sender = FClipToggle then
    Store.SetSetting('clip_on', IfThen(FClipToggle.Checked, '1', '0'))
  else if Sender = FHotkeyToggle then
  begin
    Store.SetSetting('hotkey_on', IfThen(FHotkeyToggle.Checked, '1', '0'));
    SetHotkey(FHotkeyToggle.Checked);
  end
  else if Sender = FAutostartToggle then
    SetAutostart(FAutostartToggle.Checked);
end;

procedure TMainForm.ClearHistoryClick(Sender: TObject);
begin
  Store.ClearHistory;
  ReloadClips;
  TUIToastManager.Show('Histórico limpo. Os snippets ficaram.', ttSuccess, 2500);
end;

{ Bandeja e janela }

procedure TMainForm.MenuOpenClick(Sender: TObject);
begin
  FPrevWnd := 0;
  ShowWindow_;
end;

procedure TMainForm.MenuExitClick(Sender: TObject);
begin
  FExitRequested := True;
  Close;
end;

procedure TMainForm.FormCloseQuery(Sender: TObject; var CanClose: Boolean);
begin
  CanClose := FExitRequested;
  if not CanClose then
    Hide;
end;

procedure TMainForm.FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  case Key of
    VK_ESCAPE:
      begin
        Hide;
        Key := 0;
      end;
    VK_UP, VK_DOWN:
      if FPages[pgClipboard].Visible and not FClipList.Focused then
      begin
        MoveSelection(IfThen(Key = VK_UP, -1, 1));
        Key := 0;
      end;
    VK_RETURN:
      if FPages[pgClipboard].Visible then
      begin
        PasteClick(nil);
        Key := 0;
      end;
  end;
end;

initialization
  WM_DEVBOX_SHOW := RegisterWindowMessage(ShowMessageName);

end.
