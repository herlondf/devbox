unit Devbox.UI.Tools;

{ Ferramentas: captura de tela para bug, comparar .env e log ao vivo. }

interface

uses
  System.Classes,
  System.SysUtils,
  System.Types,
  System.UITypes,
  Vcl.Controls,
  Vcl.ExtCtrls,
  System.Skia,
  UI.Labels,
  UI.Tabs,
  UI.Input,
  UI.Button,
  UI.FilterChip,
  UI.VirtualList,
  UI.DataTable,
  Devbox.Tools,
  Devbox.UI.Kit;

type
  TToolTab = (ttCapture, ttEnv, ttLog);

  TToolsPage = class(TDevPage)
  private
    FTabs: TUITabs;
    FViews: array[TToolTab] of TPanel;
    // .env
    FEnvFolder: TUIInput;
    FEnvOnlyMissing: TUIFilterChip;
    FEnvTable: TUIDataTable;
    FEnvRows: TEnvRows;
    FEnvFiles: TArray<string>;
    // Log
    FLogFile: TUIInput;
    FLogFilter: TUIInput;
    FLogErrors: TUIFilterChip;
    FLogList: TUIVirtualList;
    FLogLines: TArray<string>;
    FLogPos: Int64;
    FLogTimer: TTimer;
    FLogStatus: TUILabel;
    FLogPaused: Boolean;
    function NewView(ATab: TToolTab; const AHint: string): TPanel;
    function NewBar(AView: TPanel): TPanel;
    function NewPathInput(ABar: TPanel; const ALabel, ASetting: string): TUIInput;
    procedure TabChange(Sender: TObject; AIndex: Integer);
    procedure CaptureClick(Sender: TObject);
    procedure EnvPick(Sender: TObject);
    procedure EnvCompare(Sender: TObject);
    procedure EnvFill(Sender: TObject);
    procedure LogPick(Sender: TObject);
    procedure LogOpen(Sender: TObject);
    procedure LogPause(Sender: TObject);
    procedure LogTick(Sender: TObject);
    procedure LogFill(Sender: TObject);
    procedure LogDraw(Sender: TObject; AIndex: Integer; const AItem: TUIVListItem; const ACanvas: ISkCanvas;
      const ARowRect: TRectF);
  public
    constructor Create(AOwner: TComponent); override;
  end;

implementation

uses
  System.StrUtils,
  System.Math,
  System.IOUtils,
  System.Threading,
  System.RegularExpressions,
  Vcl.Dialogs,
  Vcl.Clipbrd,
  UI.Theme,
  UI.Tokens,
  UI.Toast,
  UI.Fonts,
  UI.Painter,
  Devbox.Store,
  Devbox.Helper;

const
  CLogMax = 5000;
  CLogTickMs = 500;

constructor TToolsPage.Create(AOwner: TComponent);
const
  TabNames: array[TToolTab] of string = ('Captura para bug', 'Comparar .env', 'Log ao vivo');
var
  T: TToolTab;
  Bar: TPanel;
  B: TUIButton;
begin
  inherited Create(AOwner);
  Caption := 'Ferramentas';
  Hint := 'Captura de tela para bug, comparar .env e log ao vivo';
  FTabs := TUITabs.Create(Self);
  for T := Low(TToolTab) to High(TToolTab) do
    FTabs.AddTab(TabNames[T]);
  FTabs.Align := alTop;
  FTabs.Parent := Self;
  FTabs.OnChange := TabChange;

  // Captura
  FViews[ttCapture] := NewView(ttCapture, 'Arraste a região, marque com seta, retângulo, texto ou número de passo e ' +
    'borre o que é sensível. Copiar põe a imagem no clipboard e no histórico.');
  Bar := NewBar(FViews[ttCapture]);
  B := NewButton(Bar, 'Capturar região  (Win+Alt+S)', CaptureClick, bvPrimary);
  B.Height := ScaleValue(44);

  // .env
  FViews[ttEnv] := NewView(ttEnv, 'Compara .env, .env.example, .env.local... da pasta. Os valores não aparecem: ' +
    'só se a chave está definida, vazia ou faltando.');
  Bar := NewBar(FViews[ttEnv]);
  NewButton(Bar, 'Comparar', EnvCompare, bvPrimary);
  NewButton(Bar, 'Escolher pasta…', EnvPick, bvGhost);
  FEnvOnlyMissing := TUIFilterChip.Create(Self);
  FEnvOnlyMissing.Caption := 'Só o que falta';
  FEnvOnlyMissing.Tone := btWarning;
  FEnvOnlyMissing.OnToggle := EnvFill;
  FEnvOnlyMissing.AlignWithMargins := True;
  FEnvOnlyMissing.Margins.SetBounds(ScaleValue(8), ScaleValue(4), 0, ScaleValue(4));
  FEnvOnlyMissing.Align := alRight;
  FEnvOnlyMissing.Parent := Bar;
  FEnvFolder := NewPathInput(Bar, 'Pasta do projeto', 'env_folder');
  FEnvTable := TUIDataTable.Create(Self);
  FEnvTable.Density := tdCompact;
  FEnvTable.EmptyStateText := 'Escolha a pasta e clique em Comparar';
  FEnvTable.Top := 100000;
  FEnvTable.Align := alClient;
  FEnvTable.Parent := FViews[ttEnv];

  // Log ao vivo
  FViews[ttLog] := NewView(ttLog, 'Acompanha um arquivo de log enquanto ele cresce. Erro em vermelho, aviso em ' +
    'amarelo. Caminho do WSL funciona (\\wsl$\Distro\...).');
  Bar := NewBar(FViews[ttLog]);
  NewButton(Bar, 'Abrir', LogOpen, bvPrimary);
  NewButton(Bar, 'Escolher…', LogPick, bvGhost);
  NewButton(Bar, 'Pausar/seguir', LogPause, bvGhost);
  FLogFile := NewPathInput(Bar, 'Arquivo de log', 'log_file');
  Bar := NewBar(FViews[ttLog]);
  FLogErrors := TUIFilterChip.Create(Self);
  FLogErrors.Caption := 'Só erros e avisos';
  FLogErrors.Tone := btError;
  FLogErrors.OnToggle := LogFill;
  FLogErrors.AlignWithMargins := True;
  FLogErrors.Margins.SetBounds(ScaleValue(8), ScaleValue(4), 0, ScaleValue(4));
  FLogErrors.Align := alRight;
  FLogErrors.Parent := Bar;
  FLogFilter := TUIInput.Create(Self);
  FLogFilter.LabelMode := ilmBorder;
  FLogFilter.LabelText := 'Filtrar linhas';
  FLogFilter.ReserveHintSpace := False;
  FLogFilter.ShowClearButton := True;
  FLogFilter.OnChange := LogFill;
  FLogFilter.Align := alClient;
  FLogFilter.Parent := Bar;
  FLogStatus := NewHint(FViews[ttLog], '', alBottom);
  FLogList := TUIVirtualList.Create(Self);
  FLogList.RowHeight := 22;
  FLogList.OnCustomDraw := LogDraw;
  FLogList.Top := 100000;
  FLogList.Align := alClient;
  FLogList.Parent := FViews[ttLog];
  FLogTimer := TTimer.Create(Self);
  FLogTimer.Interval := CLogTickMs;
  FLogTimer.Enabled := False;
  FLogTimer.OnTimer := LogTick;

  FTabs.ActiveIndex := 0;
  TabChange(nil, 0);
end;

function TToolsPage.NewView(ATab: TToolTab; const AHint: string): TPanel;
begin
  Result := NewPanel(Self, alClient);
  Result.Padding.SetBounds(0, ScaleValue(10), 0, 0);
  Result.Visible := False;
  NewHint(Result, AHint);
end;

function TToolsPage.NewBar(AView: TPanel): TPanel;
begin
  Result := NewPanel(AView, alTop, 52);
  Result.Padding.SetBounds(0, ScaleValue(6), 0, ScaleValue(6));
end;

function TToolsPage.NewPathInput(ABar: TPanel; const ALabel, ASetting: string): TUIInput;
begin
  Result := TUIInput.Create(Self);
  Result.LabelMode := ilmBorder;
  Result.LabelText := ALabel;
  Result.ReserveHintSpace := False;
  Result.Value := Store.GetSetting(ASetting);
  Result.HelpKeyword := ASetting;
  Result.Align := alClient;
  Result.Parent := ABar;
end;

procedure TToolsPage.TabChange(Sender: TObject; AIndex: Integer);
var
  T: TToolTab;
begin
  for T := Low(TToolTab) to High(TToolTab) do
    FViews[T].Visible := Ord(T) = AIndex;
end;

procedure TToolsPage.CaptureClick(Sender: TObject);
begin
  // A captura é do ajudante (DevboxHelper.exe).
  if not PostToHelper(WM_HELPER_CAPTURE) then
    TUIToastManager.Show('O ajudante não está rodando: feche e abra o Devbox de novo', ttWarning, 5000);
end;

{ .env }

procedure TToolsPage.EnvPick(Sender: TObject);
var
  Dlg: TFileOpenDialog;
begin
  Dlg := TFileOpenDialog.Create(nil);
  try
    Dlg.Options := [fdoPickFolders, fdoPathMustExist];
    if Dlg.Execute then
    begin
      FEnvFolder.Value := Dlg.FileName;
      EnvCompare(nil);
    end;
  finally
    Dlg.Free;
  end;
end;

procedure TToolsPage.EnvCompare(Sender: TObject);
var
  Parsed: TArray<TEnvEntries>;
  F: string;
begin
  Store.SetSetting('env_folder', Trim(FEnvFolder.Value));
  FEnvFiles := FindEnvFiles(Trim(FEnvFolder.Value));
  if FEnvFiles = nil then
  begin
    TUIToastManager.Show('Nenhum arquivo .env nessa pasta', ttWarning, 3000);
    Exit;
  end;
  Parsed := nil;
  for F in FEnvFiles do
    Parsed := Parsed + [ParseEnvText(TFile.ReadAllText(F, TEncoding.UTF8))];
  FEnvRows := CompareEnvs(Parsed);
  EnvFill(nil);
end;

procedure TToolsPage.EnvFill(Sender: TObject);
const
  StateText: array[TEnvState] of string = ('falta', 'vazia', 'ok');
var
  C: TUIColorTokens;
  I, Missing: Integer;
  Row: TEnvRow;
  Values: TArray<string>;
  S: TEnvState;
begin
  C := UITheme.Tokens.Color;
  FEnvTable.BeginRowUpdate;
  try
    FEnvTable.ClearMemRows;
    FEnvTable.ClearColumns;
    FEnvTable.AddColumn('key', 'Chave', 'key', 240);
    for I := 0 to High(FEnvFiles) do
    begin
      FEnvTable.AddColumn('f' + IntToStr(I), ExtractFileName(FEnvFiles[I]), 'f' + IntToStr(I), 130, False, caCenter);
      FEnvTable.SetColType('f' + IntToStr(I), ctBadge);
      FEnvTable.AddBadgeMap('f' + IntToStr(I), 'ok', C.SuccessSubtle, C.Success);
      FEnvTable.AddBadgeMap('f' + IntToStr(I), 'vazia', C.WarningSubtle, C.Warning);
      FEnvTable.AddBadgeMap('f' + IntToStr(I), 'falta', C.ErrorSubtle, C.Error);
    end;
    Missing := 0;
    for Row in FEnvRows do
    begin
      if Row.MissingSomewhere then
        Inc(Missing);
      if FEnvOnlyMissing.Active and not Row.MissingSomewhere then
        Continue;
      Values := [Row.Key];
      for S in Row.States do
        Values := Values + [StateText[S]];
      FEnvTable.AddMemRow(Values);
    end;
  finally
    FEnvTable.EndRowUpdate;
  end;
  FEnvOnlyMissing.Count := Missing;
  FEnvTable.EmptyStateText := IfThen(FEnvOnlyMissing.Active, 'Nada faltando', 'Nenhuma chave');
end;

{ Log ao vivo }

procedure TToolsPage.LogPick(Sender: TObject);
var
  Dlg: TFileOpenDialog;
begin
  Dlg := TFileOpenDialog.Create(nil);
  try
    with Dlg.FileTypes.Add do
    begin
      DisplayName := 'Logs';
      FileMask := '*.log;*.txt;*.out;*.json';
    end;
    with Dlg.FileTypes.Add do
    begin
      DisplayName := 'Todos';
      FileMask := '*.*';
    end;
    if Dlg.Execute then
    begin
      FLogFile.Value := Dlg.FileName;
      LogOpen(nil);
    end;
  finally
    Dlg.Free;
  end;
end;

procedure TToolsPage.LogOpen(Sender: TObject);
begin
  if not TFile.Exists(Trim(FLogFile.Value)) then
  begin
    TUIToastManager.Show('Arquivo não encontrado', ttWarning, 3000);
    Exit;
  end;
  Store.SetSetting('log_file', Trim(FLogFile.Value));
  FLogLines := nil;
  FLogPos := 0;
  FLogPaused := False;
  LogTick(nil);
  FLogTimer.Enabled := True;
end;

procedure TToolsPage.LogPause(Sender: TObject);
begin
  FLogPaused := not FLogPaused;
  FLogStatus.Caption := IfThen(FLogPaused, 'Pausado: novas linhas esperam', FLogStatus.Caption);
end;

procedure TToolsPage.LogTick(Sender: TObject);
var
  Text: string;
  Trunc: Boolean;
  L: TStringList;
  S: string;
begin
  if FLogPaused then
    Exit;
  try
    Text := ReadNewText(Trim(FLogFile.Value), FLogPos, Trunc);
  except
    on E: Exception do
    begin
      FLogStatus.Caption := 'Não deu para ler: ' + E.Message;
      Exit;
    end;
  end;
  if Trunc then
    FLogLines := nil;
  if Text = '' then
    Exit;
  L := TStringList.Create;
  try
    L.Text := Text;
    for S in L do
      FLogLines := FLogLines + [S];
  finally
    L.Free;
  end;
  if Length(FLogLines) > CLogMax then
    FLogLines := Copy(FLogLines, Length(FLogLines) - CLogMax, CLogMax);
  LogFill(nil);
end;

function IsErrorLine(const S: string): Boolean;
begin
  Result := TRegEx.IsMatch(S, '(?i)\b(error|erro|exception|fatal|fail(ed)?|falhou|traceback)\b');
end;

function IsWarnLine(const S: string): Boolean;
begin
  Result := TRegEx.IsMatch(S, '(?i)\b(warn(ing)?|aviso|deprecated)\b');
end;

procedure TToolsPage.LogFill(Sender: TObject);
var
  S, Q: string;
  N: Integer;
  Item: TUIVListItem;
begin
  Q := Trim(FLogFilter.Value);
  FLogList.ClearItems;
  N := 0;
  for S in FLogLines do
  begin
    if FLogErrors.Active and not (IsErrorLine(S) or IsWarnLine(S)) then
      Continue;
    if (Q <> '') and not ContainsText(S, Q) then
      Continue;
    // A linha vai no ID: o desenho padrão da lista pinta o Title, e o nosso
    // (fonte de código e cor por nível) sairia por cima dele.
    Item := Default(TUIVListItem);
    Item.ID := S;
    FLogList.AddItem(Item);
    Inc(N);
  end;
  if N > 0 then
    FLogList.ScrollToIndex(N - 1);
  FLogStatus.Caption := Format('%d linhas  ·  %s  ·  atualiza a cada 0,5 s', [Length(FLogLines),
    ExtractFileName(Trim(FLogFile.Value))]);
end;

{ Linha do log em fonte de código; erro em vermelho, aviso em amarelo. }
procedure TToolsPage.LogDraw(Sender: TObject; AIndex: Integer; const AItem: TUIVListItem;
  const ACanvas: ISkCanvas; const ARowRect: TRectF);
var
  T: TUITokens;
  Color: TAlphaColor;
  Font: ISkFont;
begin
  T := UITheme.Tokens;
  if IsErrorLine(AItem.ID) then
    Color := T.Color.Error
  else if IsWarnLine(AItem.ID) then
    Color := T.Color.Warning
  else
    Color := T.Color.FG;
  Font := TUIFontManager.GetFont(T.Typography.FamilyMono, 12, T.Typography.WeightRegular);
  UIDrawText(ACanvas, AItem.ID, TRectF.Create(ARowRect.Left + 8, ARowRect.Top, ARowRect.Right - 8,
    ARowRect.Bottom), Font, Color, taLeft, False);
end;

end.
