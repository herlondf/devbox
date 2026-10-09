unit Devbox.UI.Digest;

{ Hoje: o painel de abertura, numa grade de 12 colunas.
  - Números: agenda, e-mails importantes, issues e foco do dia.
  - Três listas lado a lado: agenda de hoje, e-mails importantes não lidos e
    issues que pedem atenção (atrasada, vence hoje, impedida, menção, review, CI).
  - Atividade recente das issues.
  - Issues por status e minutos de foco na semana.
  Clique em qualquer linha leva para a tela certa. O resumo do dia é o assistente
  quem faz, quando pedido (ferramenta devbox_meu_dia). }

interface

uses
  System.Classes,
  System.SysUtils,
  Vcl.ExtCtrls,
  UI.Labels,
  UI.Code,
  UI.Button,
  UI.Stat,
  UI.Chart,
  UI.VirtualList,
  UI.ScrollArea,
  UI.DashboardGrid,
  UI.Tokens,
  Devbox.Google,
  Devbox.MailSource,
  Devbox.Issues.Model,
  Devbox.UI.Kit;

type
  TDigestPage = class(TDevPage)
  private
    FScroll: TUIScrollArea;
    FStats: TPanel;
    FGrid: TUIDashboardGrid;
    FEventsStat, FMailStat, FIssuesStat, FFocusStat: TUIStat;
    FAgendaList, FMailList, FIssueList, FRecentList: TUIVirtualList;
    FStatusChart, FFocusChart: TUIChart;
    // Linhas das listas, na ordem (para o clique)
    FMails: TMailMsgs;
    FIssues, FRecent: TItems;
    FOnTodayEvents: TFunc<TCalEvents>;
    FOnOpenIssues: TFunc<TItems>;
    FOnImportantMails: TFunc<TMailMsgs>;
    FOnOpenMail: TProc<string>;
    FOnOpenIssue: TProc<TItem>;
    FOnNavigate: TProc<string>;
    function NewList(const AId, ATitle: string; ACol, ARow, AColSpan, ARowSpan: Integer;
      AOnClick: TUIVListItemEvent): TUIVirtualList;
    function NewStat(const AId, ALabel: string; ACol: Integer; ATone: TUISemanticTone): TUIStat;
    procedure BuildGrid;
    procedure LayoutGrid;
    procedure ScrollResize(Sender: TObject);
    procedure StatsResize(Sender: TObject);
    procedure FillAgenda;
    procedure FillMails;
    procedure FillIssues;
    procedure FillCharts;
    procedure StatClick(Sender: TObject);
    procedure AgendaClick(Sender: TObject; AIndex: Integer; const AItem: TUIVListItem);
    procedure MailClick(Sender: TObject; AIndex: Integer; const AItem: TUIVListItem);
    procedure IssueClick(Sender: TObject; AIndex: Integer; const AItem: TUIVListItem);
    procedure RecentClick(Sender: TObject; AIndex: Integer; const AItem: TUIVListItem);
    procedure StatusChartClick(Sender: TObject; SeriesIndex, DataIndex: Integer; const Value: Double);
  public
    constructor Create(AOwner: TComponent); override;
    procedure PageShown; override;
    { F5: tudo de novo na tela. }
    procedure PageRefresh; override;
    { Eventos de hoje (a tela Agenda). }
    property OnTodayEvents: TFunc<TCalEvents> read FOnTodayEvents write FOnTodayEvents;
    { Issues abertas (a tela Issues). }
    property OnOpenIssues: TFunc<TItems> read FOnOpenIssues write FOnOpenIssues;
    { E-mails não lidos da caixa (a tela E-mail). }
    property OnImportantMails: TFunc<TMailMsgs> read FOnImportantMails write FOnImportantMails;
    { Clique: abre o e-mail (pelo Id), a issue ou uma tela (id do menu). }
    property OnOpenMail: TProc<string> read FOnOpenMail write FOnOpenMail;
    property OnOpenIssue: TProc<TItem> read FOnOpenIssue write FOnOpenIssue;
    property OnNavigate: TProc<string> read FOnNavigate write FOnNavigate;
  end;

implementation

uses
  System.StrUtils,
  System.Math,
  System.DateUtils,
  System.Threading,
  System.Generics.Defaults,
  System.Generics.Collections,
  Vcl.Controls,
  UI.Toast,
  Devbox.Store,
  Devbox.Issues.Store,
  Devbox.AI,
  Devbox.Notify;

type
  TControlAccess = class(TControl);

const
  CRows = 25;          // listas (10) + atividade (8) + gráficos (7)
  CStatsH = 124;
  CGridGap = 16;       // folga padrão da TUIDashboardGrid (CUIGridDefaultGap)
  CPad = 12;
  CListRowH = 52;
  CMaxRows = 12;
  CWeekDays = 7;
  CStatIds: array[0..3] of string = ('agenda', 'mail', 'issues', 'focus');

constructor TDigestPage.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FRefreshable := True;
  Caption := 'Hoje';
  Hint := 'Seu dia num lugar só: agenda, e-mails, issues e foco. Resumo: peça ao assistente.';
  FStats := NewPanel(Self, alTop, CStatsH);
  FStats.Padding.SetBounds(ScaleValue(CGridGap), 0, ScaleValue(CGridGap), ScaleValue(CPad));
  FStats.OnResize := StatsResize;
  FScroll := TUIScrollArea.Create(Self);
  FScroll.Top := 100000;
  FScroll.Align := alClient;
  FScroll.Parent := Self;
  FScroll.OnResize := ScrollResize;
  BuildGrid;
end;

function TDigestPage.NewStat(const AId, ALabel: string; ACol: Integer; ATone: TUISemanticTone): TUIStat;
begin
  Result := TUIStat.Create(Self);
  Result.CardLabel := ALabel;
  Result.Value := '–';
  Result.Tone := ATone;
  Result.Cursor := crHandPoint;
  Result.HelpKeyword := AId;
  TControlAccess(Result).OnClick := StatClick;
  Result.Parent := FStats;
end;

{ Os quatro números dividem a largura. }
procedure TDigestPage.StatsResize(Sender: TObject);
var
  LStats: array[0..3] of TUIStat;
  LIndex, LWidth, LGap: Integer;
begin
  LStats[0] := FEventsStat;
  LStats[1] := FMailStat;
  LStats[2] := FIssuesStat;
  LStats[3] := FFocusStat;
  LGap := ScaleValue(CPad);
  LWidth := (FStats.ClientWidth - FStats.Padding.Left - FStats.Padding.Right - LGap * High(LStats)) div
    Length(LStats);
  for LIndex := 0 to High(LStats) do
    if LStats[LIndex] <> nil then
      LStats[LIndex].SetBounds(FStats.Padding.Left + LIndex * (LWidth + LGap), 0, LWidth,
        FStats.ClientHeight - FStats.Padding.Bottom);
end;

function TDigestPage.NewList(const AId, ATitle: string; ACol, ARow, AColSpan, ARowSpan: Integer;
  AOnClick: TUIVListItemEvent): TUIVirtualList;
var
  LWidget: TUIDashboardWidget;
begin
  LWidget := FGrid.AddWidget(AId, ATitle, ACol, ARow, AColSpan, ARowSpan);
  Result := TUIVirtualList.Create(LWidget);
  Result.RowHeight := CListRowH;
  Result.OnItemClick := AOnClick;
  Result.Cursor := crHandPoint;
  Result.Align := alClient;
  Result.Parent := LWidget;
end;

procedure TDigestPage.BuildGrid;
var
  LWidget: TUIDashboardWidget;
begin
  FGrid := TUIDashboardGrid.Create(Self);
  FGrid.Editable := False;
  FGrid.Responsive := False;
  FGrid.RowHeight := 36;
  FGrid.Parent := FScroll.InnerPanel;

  FEventsStat := NewStat(CStatIds[0], 'Compromissos hoje', 0, stPrimary);
  FMailStat := NewStat(CStatIds[1], 'E-mails não lidos', 3, stInfo);
  FIssuesStat := NewStat(CStatIds[2], 'Issues pedindo atenção', 6, stWarning);
  FFocusStat := NewStat(CStatIds[3], 'Foco hoje', 9, stSuccess);

  FAgendaList := NewList('agenda-hoje', 'Agenda de hoje', 0, 0, 4, 10, AgendaClick);
  FMailList := NewList('emails', 'E-mails não lidos', 4, 0, 4, 10, MailClick);
  FIssueList := NewList('atencao', 'Issues que pedem atenção', 8, 0, 4, 10, IssueClick);

  FRecentList := NewList('atividade', 'Atividade recente nas issues', 0, 10, 12, 8, RecentClick);

  LWidget := FGrid.AddWidget('status', 'Issues por status', 0, 18, 7, 7);
  FStatusChart := TUIChart.Create(LWidget);
  FStatusChart.Backend := cbSkia;
  FStatusChart.ChartType := ctProgress;  // barras deitadas: nomes de status longos cabem
  FStatusChart.ShowLegend := False;
  FStatusChart.AnimEnabled := True;
  FStatusChart.Cursor := crHandPoint;
  FStatusChart.OnDataPointClick := StatusChartClick;
  FStatusChart.Align := alClient;
  FStatusChart.Parent := LWidget;

  LWidget := FGrid.AddWidget('foco-semana', 'Minutos de foco, últimos 7 dias', 7, 18, 5, 7);
  FFocusChart := TUIChart.Create(LWidget);
  FFocusChart.Backend := cbSkia;
  FFocusChart.ChartType := ctBar;
  FFocusChart.ShowLegend := False;
  FFocusChart.AnimEnabled := True;
  FFocusChart.Align := alClient;
  FFocusChart.Parent := LWidget;
end;

procedure TDigestPage.LayoutGrid;
var
  LHeight: Integer;
begin
  LHeight := ScaleValue(CRows * FGrid.RowHeight + (CRows + 1) * FGrid.Gap);
  // A grade tem a folga dela nas bordas (Gap): a faixa dos números usa a mesma.
  FGrid.SetBounds(0, 0, FScroll.ClientWidth, LHeight);
  FScroll.ContentHeight := LHeight + ScaleValue(CPad);
end;

procedure TDigestPage.ScrollResize(Sender: TObject);
begin
  LayoutGrid;
end;

procedure TDigestPage.PageShown;
begin
  inherited;
  PageRefresh;
end;

procedure TDigestPage.PageRefresh;
begin
  FillAgenda;
  FillMails;
  FillIssues;
  FillCharts;
  LayoutGrid;
end;

{ ── Listas ──────────────────────────────────────────────────────────────── }

procedure TDigestPage.FillAgenda;
var
  LEvents: TCalEvents;
  LEvent, LNext: TCalEvent;
  LFound: Boolean;
  LItem: TUIVListItem;
begin
  LEvents := nil;
  if Assigned(FOnTodayEvents) then
    LEvents := FOnTodayEvents();
  LFound := False;
  FAgendaList.ClearItems;
  for LEvent in LEvents do
  begin
    LItem := Default(TUIVListItem);
    LItem.Title := LEvent.Title;
    if LEvent.AllDay then
      LItem.Subtitle := 'dia todo'
    else
      LItem.Subtitle := FormatDateTime('hh:nn', LEvent.Start) + ' às ' + FormatDateTime('hh:nn', LEvent.Finish);
    if LEvent.AllDay then
      LItem.MetaText := ''
    else if LEvent.Finish <= Now then
      LItem.MetaText := 'terminou'
    else if LEvent.Start <= Now then
      LItem.MetaText := 'agora'
    else
      LItem.MetaText := Format('em %s', [IfThen(MinutesBetween(Now, LEvent.Start) < 60,
        IntToStr(MinutesBetween(Now, LEvent.Start) + 1) + ' min', IntToStr(HoursBetween(Now, LEvent.Start)) + ' h')]);
    if LEvent.MeetUrl <> '' then
      LItem.Subtitle := LItem.Subtitle + '  ·  Meet';
    FAgendaList.AddItem(LItem);
    if not LEvent.AllDay and (LEvent.Finish > Now) and (not LFound or (LEvent.Start < LNext.Start)) then
    begin
      LNext := LEvent;
      LFound := True;
    end;
  end;
  if LEvents = nil then
    FAgendaList.AddItem('Nada na agenda hoje', 'Agendas em Configuração › E-mail e agenda');
  FEventsStat.Value := IntToStr(Length(LEvents));
  if not LFound then
    FEventsStat.SubText := 'nenhuma reunião pela frente'
  else if LNext.Start <= Now then
    FEventsStat.SubText := 'agora: ' + LNext.Title
  else
    FEventsStat.SubText := 'próxima ' + FormatDateTime('hh:nn', LNext.Start) + ': ' + LNext.Title;
end;

procedure TDigestPage.FillMails;
var
  LAll: TMailMsgs;
  LMsg: TMailMsg;
  LItem: TUIVListItem;
  LImportant: Integer;
begin
  LAll := nil;
  if Assigned(FOnImportantMails) then
    LAll := FOnImportantMails();
  // Importantes primeiro; dentro de cada grupo, o mais novo em cima.
  TArray.Sort<TMailMsg>(LAll, TComparer<TMailMsg>.Construct(
    function(const A, B: TMailMsg): Integer
    begin
      Result := Ord(B.Important) - Ord(A.Important);
      if Result = 0 then
        Result := CompareValue(B.Date, A.Date);
    end));
  FMails := Copy(LAll, 0, CMaxRows);
  LImportant := 0;
  for LMsg in LAll do
    if LMsg.Important then
      Inc(LImportant);
  FMailList.ClearItems;
  for LMsg in FMails do
  begin
    LItem := Default(TUIVListItem);
    LItem.Title := IfThen(LMsg.Important, '★ ', '') + LMsg.Subject;
    LItem.Subtitle := IfThen(LMsg.FromName <> '', LMsg.FromName, LMsg.FromEmail);
    if Trunc(LMsg.Date) = Date then
      LItem.MetaText := FormatDateTime('hh:nn', LMsg.Date)
    else
      LItem.MetaText := FormatDateTime('dd/mm', LMsg.Date);
    FMailList.AddItem(LItem);
  end;
  if FMails = nil then
    FMailList.AddItem('Nenhum e-mail não lido', 'Contas em Configuração › E-mail e agenda');
  FMailStat.Value := IntToStr(Length(LAll));
  FMailStat.SubText := Format('%d importantes', [LImportant]);
end;

{ Por que a issue pede atenção (vazio = não pede). Ordem = urgência. }
function AttentionOf(const AItem: TItem; out ARank: Integer): string;
begin
  ARank := 99;
  Result := '';
  if (AItem.DueDate > 0) and (Trunc(AItem.DueDate) < Date) then
  begin
    ARank := 0;
    Result := Format('atrasada %d d', [Trunc(Date - Trunc(AItem.DueDate))]);
  end
  else if (AItem.DueDate > 0) and (Trunc(AItem.DueDate) = Date) then
  begin
    ARank := 1;
    Result := 'vence hoje';
  end
  else if AItem.Flagged then
  begin
    ARank := 2;
    Result := 'impedida';
  end
  else if (isMine in AItem.Sources) and MatchText(AItem.CiState, ['FAILURE', 'ERROR']) then
  begin
    ARank := 3;
    Result := 'CI falhou';
  end
  else if isReview in AItem.Sources then
  begin
    ARank := 4;
    Result := 'review pedido';
  end
  else if AItem.MentionsMe then
  begin
    ARank := 5;
    Result := 'mencionado';
  end
  else if (AItem.DueDate > 0) and (AItem.DueDate < Date + 3) then
  begin
    ARank := 6;
    Result := 'vence em ' + IntToStr(Trunc(AItem.DueDate - Date)) + ' d';
  end;
end;

procedure TDigestPage.FillIssues;
type
  TRanked = record
    Item: TItem;
    Rank: Integer;
    Why: string;
  end;
var
  LAll: TItems;
  LIt: TItem;
  LRanked: TArray<TRanked>;
  LOne: TRanked;
  LItem: TUIVListItem;
  LLate, LMine: Integer;
  LEvent: TIssueEvent;
begin
  LAll := nil;
  if Assigned(FOnOpenIssues) then
    LAll := FOnOpenIssues();
  LRanked := nil;
  LLate := 0;
  LMine := 0;
  for LIt in LAll do
  begin
    if isAssigned in LIt.Sources then
      Inc(LMine);
    LOne.Item := LIt;
    LOne.Why := AttentionOf(LIt, LOne.Rank);
    if LOne.Rank = 0 then
      Inc(LLate);
    if LOne.Why <> '' then
      LRanked := LRanked + [LOne];
  end;
  TArray.Sort<TRanked>(LRanked, TComparer<TRanked>.Construct(
    function(const A, B: TRanked): Integer
    begin
      Result := A.Rank - B.Rank;
      if Result = 0 then
        Result := CompareValue(A.Item.DueDate, B.Item.DueDate);
    end));
  FIssues := nil;
  FIssueList.ClearItems;
  for LOne in Copy(LRanked, 0, CMaxRows) do
  begin
    FIssues := FIssues + [LOne.Item];
    LItem := Default(TUIVListItem);
    LItem.Title := LOne.Item.Key + '  ' + LOne.Item.Title;
    LItem.Subtitle := LOne.Item.Status;
    LItem.MetaText := LOne.Why;
    FIssueList.AddItem(LItem);
  end;
  if LRanked = nil then
    FIssueList.AddItem('Nada urgente', IfThen(LAll = nil, 'Contas em Configuração › Issues',
      'Sem atraso, impedimento, review ou menção'));
  FIssuesStat.Value := IntToStr(Length(LRanked));
  FIssuesStat.SubText := Format('%d atrasadas · %d comigo · %d abertas', [LLate, LMine, Length(LAll)]);
  if LLate > 0 then
    FIssuesStat.Tone := stError
  else
    FIssuesStat.Tone := stWarning;

  // Atividade recente: o que mudou nas issues abertas.
  FRecent := nil;
  FRecentList.ClearItems;
  for LEvent in IssueStore.ListRecentEvents(60) do
  begin
    for LIt in LAll do
      if (LIt.AccountId = LEvent.AccountId) and SameText(LIt.Key, LEvent.Key) then
      begin
        FRecent := FRecent + [LIt];
        LItem := Default(TUIVListItem);
        LItem.Title := LEvent.Key + '  ·  ' + EventNames[LEvent.Kind];
        LItem.Subtitle := LEvent.Body;
        LItem.MetaText := FormatDateTime('dd/mm hh:nn', LEvent.At);
        FRecentList.AddItem(LItem);
        Break;
      end;
    if Length(FRecent) = CMaxRows then
      Break;
  end;
  if FRecent = nil then
    FRecentList.AddItem('Sem novidades', 'Mudanças nas issues aparecem aqui');
end;

procedure TDigestPage.FillCharts;
var
  LAll: TItems;
  LIt: TItem;
  LNames: TArray<string>;
  LCounts: TArray<Double>;
  LSeries: TArray<TUIChartSeries>;
  LIndex: Integer;
  LMinutes: TArray<Integer>;
  LDays: TArray<string>;
  LValues: TArray<Double>;
  LToday: Integer;
begin
  LAll := nil;
  if Assigned(FOnOpenIssues) then
    LAll := FOnOpenIssues();
  LNames := nil;
  LCounts := nil;
  for LIt in LAll do
  begin
    LIndex := IndexText(LIt.Status, LNames);
    if LIndex < 0 then
    begin
      LNames := LNames + [LIt.Status];
      LCounts := LCounts + [1];
    end
    else
      LCounts[LIndex] := LCounts[LIndex] + 1;
  end;
  // ctProgress: uma barra por série, com o rótulo de mesmo índice.
  LSeries := nil;
  for LIndex := 0 to High(LNames) do
    LSeries := LSeries + [TUIChartSeries.Create(LNames[LIndex], [LCounts[LIndex]])];
  FStatusChart.SetSeries(LNames, LSeries);
  FStatusChart.Refresh;

  LMinutes := Store.FocusMinutesPerDay(CWeekDays);
  LDays := nil;
  LValues := nil;
  for LIndex := 0 to High(LMinutes) do
  begin
    LDays := LDays + [FormatDateTime('ddd dd', Date - High(LMinutes) + LIndex)];
    LValues := LValues + [LMinutes[LIndex]];
  end;
  FFocusChart.SetSeries(LDays, [TUIChartSeries.Create('Minutos', LValues)]);
  FFocusChart.Refresh;
  LToday := LMinutes[High(LMinutes)];
  FFocusStat.Value := Format('%d min', [LToday]);
  if Store.GetSetting('pomo_day') = FormatDateTime('yyyy-mm-dd', Date) then
    FFocusStat.SubText := Store.GetSetting('pomo_today', '0') + ' pomodoros terminados'
  else
    FFocusStat.SubText := 'nenhum pomodoro ainda';
end;

{ ── Cliques ─────────────────────────────────────────────────────────────── }

procedure TDigestPage.StatClick(Sender: TObject);
const
  CPages: array[0..3] of string = ('agenda', 'mail', 'issues', 'focus');
begin
  if Assigned(FOnNavigate) then
    FOnNavigate(CPages[Max(0, IndexStr(TControl(Sender).HelpKeyword, CStatIds))]);
end;

procedure TDigestPage.AgendaClick(Sender: TObject; AIndex: Integer; const AItem: TUIVListItem);
begin
  if Assigned(FOnNavigate) then
    FOnNavigate('agenda');
end;

procedure TDigestPage.MailClick(Sender: TObject; AIndex: Integer; const AItem: TUIVListItem);
begin
  if (AIndex <= High(FMails)) and Assigned(FOnOpenMail) then
    FOnOpenMail(FMails[AIndex].Id)
  else if Assigned(FOnNavigate) then
    FOnNavigate('google');
end;

procedure TDigestPage.IssueClick(Sender: TObject; AIndex: Integer; const AItem: TUIVListItem);
begin
  if (AIndex <= High(FIssues)) and Assigned(FOnOpenIssue) then
    FOnOpenIssue(FIssues[AIndex])
  else if Assigned(FOnNavigate) then
    FOnNavigate('issues');
end;

procedure TDigestPage.RecentClick(Sender: TObject; AIndex: Integer; const AItem: TUIVListItem);
begin
  if (AIndex <= High(FRecent)) and Assigned(FOnOpenIssue) then
    FOnOpenIssue(FRecent[AIndex]);
end;

procedure TDigestPage.StatusChartClick(Sender: TObject; SeriesIndex, DataIndex: Integer; const Value: Double);
begin
  if Assigned(FOnNavigate) then
    FOnNavigate('issues');
end;

end.
