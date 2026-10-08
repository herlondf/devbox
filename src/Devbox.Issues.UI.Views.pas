unit Devbox.Issues.UI.Views;

{ Dashboard: números, gráficos e atividade sobre as issues acompanhadas.
  Reconstruído por inteiro em Update; são poucas dezenas de itens. }

interface

uses
  System.Classes,
  System.UITypes,
  Vcl.Controls,
  UI.Tokens,
  Vcl.ExtCtrls,
  UI.DashboardGrid,
  UI.ScrollArea,
  UI.VirtualList,
  System.Generics.Collections,
  Devbox.Issues.Model;

type
  TItemOpenEvent = procedure(Sender: TObject; const AItem: TItem) of object;

  { Clique num card do Dashboard: qual filtro aplicar na aba Issues. }
  TDrillKind = (dkNone, dkAll, dkMine, dkFlagged, dkDueSoon, dkWithDue, dkCategory, dkStatus, dkTag,
    dkRepo, dkPrState, dkKind, dkMyPrs);
  TDrill = record
    Kind: TDrillKind;
    Value: string;     // categoria (new/indeterminate/done), status ou nome da tag
    Caption: string;   // texto do chip removível na aba Issues
  end;
  TDrillEvent = procedure(Sender: TObject; const ADrill: TDrill) of object;

  TVigiaView = class(TPanel)
  protected
    FItems: TItems;
    FAccounts: TArray<TAccount>;
    FOnOpenItem: TItemOpenEvent;
    function AccountOf(const AItem: TItem; out AAccount: TAccount): Boolean;
  public
    constructor Create(AOwner: TComponent); override;
    procedure Update(const AItems: TItems; const AAccounts: TArray<TAccount>); reintroduce; virtual;
    property OnOpenItem: TItemOpenEvent read FOnOpenItem write FOnOpenItem;
  end;

  TDashboardView = class(TVigiaView)
  private
    FScroll: TUIScrollArea;
    FGrid: TUIDashboardGrid;
    FUpcoming: TItems;  // linhas da lista "Próximas entregas"
    FPrevStats: TDictionary<string, Double>;  // número anima só quando muda
    FWelcome: TPanel;
    FAccountFilter: Integer;
    FOnAddAccount: TNotifyEvent;
    FOnDrill: TDrillEvent;
    FRecent: TItems;              // linhas da lista "Atividade recente"
    FStatusNames: TArray<string>; // barras do "Por status"
    FTagNames: TArray<string>;    // barras do "Pendências por #tag"
    FRepoNames: TArray<string>;   // barras do "Por repositório" (GitHub)
    FSignature: string;           // dados com que o grid foi montado
    function Signature: string;
    function GitHubView: Boolean;
    procedure EmptyNote(AParent: TWinControl; const AText: string);
    procedure KindClick(Sender: TObject; SeriesIndex, DataIndex: Integer; const Value: Double);
    procedure PrStateClick(Sender: TObject; SeriesIndex, DataIndex: Integer; const Value: Double);
    procedure RepoClick(Sender: TObject; SeriesIndex, DataIndex: Integer; const Value: Double);
    procedure Drill(AKind: TDrillKind; const AValue, ACaption: string);
    procedure StatClick(Sender: TObject);
    procedure RingClick(Sender: TObject);
    procedure RingHostResize(Sender: TObject);
    procedure CategoryClick(Sender: TObject; SeriesIndex, DataIndex: Integer; const Value: Double);
    procedure FunnelClick(Sender: TObject; SeriesIndex, DataIndex: Integer; const Value: Double);
    procedure StatusClick(Sender: TObject; SeriesIndex, DataIndex: Integer; const Value: Double);
    procedure TagClick(Sender: TObject; SeriesIndex, DataIndex: Integer; const Value: Double);
    procedure RecentClick(Sender: TObject; AIndex: Integer; const AItem: TUIVListItem);
    procedure LayoutGrid;
    procedure ShowWelcome(AShow: Boolean);
    procedure WelcomeAddClick(Sender: TObject);
    procedure UpcomingClick(Sender: TObject; AIndex: Integer; const AItem: TUIVListItem);
  protected
    procedure Resize; override;
  public
    destructor Destroy; override;
    property AccountFilter: Integer read FAccountFilter write FAccountFilter;
    property OnAddAccount: TNotifyEvent read FOnAddAccount write FOnAddAccount;
    property OnDrill: TDrillEvent read FOnDrill write FOnDrill;
    procedure Update(const AItems: TItems; const AAccounts: TArray<TAccount>); override;
  end;


{ Cor do prazo: vermelho até CriticalDays (ou vencido), laranja até WarnDays, verde. }
function DueTone(ADue: TDateTime; const AAccount: TAccount): TUIBadgeTone;
function StatusTone(const ACategory: string): TUIBadgeTone;
{ Categoria do andamento como o Dashboard conta: desconhecida vira 'new'. }
function CategoryOf(const AItem: TItem): string;

implementation

uses
  Devbox.I18n,
  System.SysUtils,
  System.StrUtils,
  System.DateUtils,
  System.Math,
  UI.Theme,
  UI.Painter,
  UI.Painter.Vcl,
  UI.Stat,
  UI.Chart,
  UI.Sparkline,
  UI.Timeline,
  UI.RadialProgress,
  UI.Hero,
  UI.Steps,
  UI.Button,
  UI.Labels,
  System.Generics.Defaults,
  System.Hash,
  Devbox.Issues.Store;

function DueTone(ADue: TDateTime; const AAccount: TAccount): TUIBadgeTone;
var
  Left: Integer;
begin
  Left := Trunc(DateOf(ADue) - Date);
  if Left <= AAccount.CriticalDays then
    Result := btError
  else if Left <= AAccount.WarnDays then
    Result := btWarning
  else
    Result := btSuccess;
end;

function StatusTone(const ACategory: string): TUIBadgeTone;
begin
  if ACategory = 'indeterminate' then
    Result := btInfo
  else if ACategory = 'done' then
    Result := btSuccess
  else
    Result := btNeutral;
end;

const
  Categories: array[0..2] of string = ('new', 'indeterminate', 'done');
  CategoryNames: array[0..2] of string = ('A fazer', 'Em andamento', 'Concluído');

type
  TControlAccess = class(TControl);

function CategoryOf(const AItem: TItem): string;
begin
  Result := Categories[Max(0, IndexText(AItem.StatusCategory, Categories))];
end;

{ ── Base ────────────────────────────────────────────────────────────────── }

constructor TVigiaView.Create(AOwner: TComponent);
begin
  inherited;
  BevelOuter := bvNone;
  ParentBackground := False;
  DoubleBuffered := True;
  Color := UIThemeVclBackground;
  Align := alClient;
end;

function TVigiaView.AccountOf(const AItem: TItem; out AAccount: TAccount): Boolean;
var
  A: TAccount;
begin
  for A in FAccounts do
    if A.Id = AItem.AccountId then
    begin
      AAccount := A;
      Exit(True);
    end;
  Result := False;
end;
procedure TVigiaView.Update(const AItems: TItems; const AAccounts: TArray<TAccount>);
begin
  FItems := AItems;
  FAccounts := AAccounts;
  Color := UIThemeVclBackground;
end;

{ ── Painel ──────────────────────────────────────────────────────────────── }

procedure TDashboardView.Update(const AItems: TItems; const AAccounts: TArray<TAccount>);

  procedure AddStat(const AId, ALabel: string; ACol: Integer; AValue: Integer;
    const ASub: string; ATone: TUISemanticTone);
  var
    W: TUIDashboardWidget;
    S: TUIStat;
  begin
    W := FGrid.AddWidget(AId, ALabel, ACol, 0, 3, 3);
    W.ShowHeader := False;  // o TUIStat já mostra o rótulo
    S := TUIStat.Create(W);
    S.Parent := W;
    S.Align := alClient;
    S.CardLabel := ALabel;
    // Busca sem mudança não refaz a contagem animada.
    if FPrevStats = nil then
      FPrevStats := TDictionary<string, Double>.Create;
    S.AnimateValue := not FPrevStats.ContainsKey(AId) or (FPrevStats[AId] <> AValue);
    FPrevStats.AddOrSetValue(AId, AValue);
    S.NumericValue := AValue;
    S.SubText := ASub;
    S.Tone := ATone;
    S.Hint := Tr('Ver na aba Issues');
    S.ShowHint := True;
    S.Cursor := crHandPoint;
    TControlAccess(S).OnClick := StatClick;
  end;

var
  It: TItem;
  A: TAccount;
  Mine, Flagged, Soon, I, MyPrs, PrCount, Waiting, Approved, Changes, CiFail: Integer;
  RepoCounts: TDictionary<string, Integer>;
  RepoName: string;
  Labels: TArray<string>;
  CatCount: array[0..2] of Double;
  StatusNames: TArray<string>;
  StatusCounts: TArray<Double>;
  W: TUIDashboardWidget;
  Chart: TUIChart;
  Idx: Integer;
  List: TUIVirtualList;
  V: TUIVListItem;
  DaysLeft, Shown: Integer;
  E: TIssueEvent;
  Known: Boolean;
  Series: TArray<TUIChartSeries>;
  WithDue, OnTime: Integer;
  Ring: TUIRadialProgress;
  Lbl: TUILabel;
  Tags: TTags;
  TagCounts: TArray<Double>;
  Recent: TUIVirtualList;
begin
  inherited;
  ShowWelcome(AAccounts = nil);
  if AAccounts = nil then
    Exit;
  // Busca sem mudança não refaz o grid (piscava e gastava CPU a cada 5 min).
  if (FGrid <> nil) and (Signature = FSignature) then
    Exit;
  FSignature := Signature;
  Mine := 0;
  Flagged := 0;
  Soon := 0;
  MyPrs := 0;
  PrCount := 0;
  FillChar(CatCount, SizeOf(CatCount), 0);
  StatusNames := nil;
  StatusCounts := nil;
  for It in FItems do
  begin
    if isAssigned in It.Sources then
      Inc(Mine);
    if It.Flagged then
      Inc(Flagged);
    if isMine in It.Sources then
      Inc(MyPrs);
    if It.Url.Contains('/pull/') then
      Inc(PrCount);
    if (It.DueDate > 0) and AccountOf(It, A) and (DueTone(It.DueDate, A) <> btSuccess) then
      Inc(Soon);
    CatCount[Max(0, IndexText(It.StatusCategory, ['new', 'indeterminate', 'done']))] :=
      CatCount[Max(0, IndexText(It.StatusCategory, ['new', 'indeterminate', 'done']))] + 1;
    Idx := IndexText(It.Status, StatusNames);
    if Idx < 0 then
    begin
      StatusNames := StatusNames + [It.Status];
      StatusCounts := StatusCounts + [1];
    end
    else
      StatusCounts[Idx] := StatusCounts[Idx] + 1;
  end;

  // A grade tem altura fixa (linhas x RowHeight); quem rola é o ScrollArea.
  if FScroll = nil then
  begin
    FScroll := TUIScrollArea.Create(Self);
    FScroll.Align := alClient;
    FScroll.Parent := Self;
  end;
  FreeAndNil(FGrid);
  FGrid := TUIDashboardGrid.Create(Self);
  FGrid.Editable := False;
  FGrid.Responsive := False;  // mantém as 12 colunas; a janela tem largura mínima
  FGrid.RowHeight := 36;
  FGrid.Parent := FScroll.InnerPanel;

  AddStat('abertas', Tr('Acompanhadas'), 0, Length(FItems), Tr('issues abertas'), stNone);
  AddStat('comigo', Tr('Comigo'), 3, Mine, Tr('associadas a mim'), stPrimary);
  if GitHubView then
    AddStat('meusprs', Tr('Meus PRs'), 6, MyPrs, Tr('abertos por mim'), stSuccess)
  else
    AddStat('impedidas', Tr('Impedidas'), 6, Flagged, Tr('com Flagged'), stError);
  AddStat('prazo', Tr('Prazo perto'), 9, Soon, Tr('laranja ou vermelho'), stWarning);

  if GitHubView then
    W := FGrid.AddWidget('categorias', Tr('Por tipo'), 0, 3, 4, 6)
  else
    W := FGrid.AddWidget('categorias', Tr('Por andamento'), 0, 3, 4, 6);
  if FItems = nil then
    EmptyNote(W, Tr('Nenhuma issue nesta visão.'))
  else
  begin
  Chart := TUIChart.Create(W);
  Chart.Backend := cbSkia;
  Chart.Parent := W;
  Chart.Align := alClient;
  Chart.ChartType := ctDonut;
  Chart.AnimEnabled := True;
  if GitHubView then
  begin
    Chart.SetSeries([Tr('Issues'), Tr('PRs')],
      [TUIChartSeries.Create(Tr('Itens'), [Length(FItems) - PrCount, PrCount])]);
    Chart.OnDataPointClick := KindClick;
  end
  else
  begin
    Chart.SetSeries([Tr('A fazer'), Tr('Em andamento'), Tr('Concluído')],
      [TUIChartSeries.Create(Tr('Issues'), [CatCount[0], CatCount[1], CatCount[2]])]);
    Chart.OnDataPointClick := CategoryClick;
  end;
  Chart.Cursor := crHandPoint;
  Chart.Refresh;
  end;

  // Entregas no prazo: das issues com prazo, quantas não estão no vermelho.
  WithDue := 0;
  OnTime := 0;
  for It in FItems do
    if (It.DueDate > 0) and AccountOf(It, A) then
    begin
      Inc(WithDue);
      if DueTone(It.DueDate, A) <> btError then
        Inc(OnTime);
    end;
  W := FGrid.AddWidget('noprazo', Tr('Entregas no prazo'), 4, 3, 3, 6);
  if WithDue = 0 then
    // Sem prazo nenhum: nem 100% (enganoso) nem 0% (parece atraso).
    EmptyNote(W, IfThen(GitHubView, Tr('Nenhuma issue com milestone com data.'),
      Tr('Nenhuma issue com prazo.')))
  else
  begin
  Ring := TUIRadialProgress.Create(W);
  Ring.RingSize := 120;
  Ring.StrokeWidth := 12;
  Ring.ShowPercent := True;
  Ring.Max := 100;
  if WithDue = 0 then
    Ring.Value := 100
  else
    Ring.Value := OnTime * 100 / WithDue;
  if Ring.Value >= 80 then
    Ring.Tone := ptSuccess
  else if Ring.Value >= 50 then
    Ring.Tone := ptWarning
  else
    Ring.Tone := ptError;
  Ring.Parent := W;
  TControlAccess(W).OnResize := RingHostResize;
  Ring.Cursor := crHandPoint;
  TControlAccess(Ring).OnClick := RingClick;
  Lbl := TUILabel.Create(W);
  Lbl.Caption := Format(Tr('%d de %d com prazo'), [OnTime, WithDue]);
  Lbl.Variant := lvMuted;
  Lbl.TextAlign := UI.Painter.taCenter;
  Lbl.AutoSize := False;
  Lbl.Height := 20;
  Lbl.Align := alBottom;
  Lbl.Parent := W;
  end;

  if GitHubView then
  begin
    // Meus PRs: onde cada um está (review e CI).
    Waiting := 0;
    Approved := 0;
    Changes := 0;
    CiFail := 0;
    for It in FItems do
      if isMine in It.Sources then
      begin
        if SameText(It.ReviewState, 'APPROVED') then
          Inc(Approved)
        else if SameText(It.ReviewState, 'CHANGES_REQUESTED') then
          Inc(Changes)
        else
          Inc(Waiting);
        if MatchText(It.CiState, ['FAILURE', 'ERROR']) then
          Inc(CiFail);
      end;
    W := FGrid.AddWidget('funil', Tr('Meus PRs'), 7, 3, 5, 6);
    if MyPrs = 0 then
      EmptyNote(W, Tr('Nenhum PR seu aberto.'))
    else
    begin
      Chart := TUIChart.Create(W);
      Chart.Backend := cbSkia;
      Chart.Parent := W;
      Chart.Align := alClient;
      Chart.ChartType := ctProgress;
      Chart.ShowLegend := False;
      Chart.AnimEnabled := True;
      Chart.SetSeries([Tr('Em review'), Tr('Mudanças'), Tr('Aprovados'), Tr('CI falhou')],
        [TUIChartSeries.Create(Tr('Em review'), [Waiting]),
         TUIChartSeries.Create(Tr('Mudanças'), [Changes]),
         TUIChartSeries.Create(Tr('Aprovados'), [Approved]),
         TUIChartSeries.Create(Tr('CI falhou'), [CiFail])]);
      Chart.OnDataPointClick := PrStateClick;
      Chart.Cursor := crHandPoint;
      Chart.Refresh;
    end;
  end
  else
  begin
  // Funil do andamento: quanto já passou de cada etapa.
  W := FGrid.AddWidget('funil', Tr('Funil do andamento'), 7, 3, 5, 6);
  Chart := TUIChart.Create(W);
  Chart.Backend := cbSkia;
  Chart.Parent := W;
  Chart.Align := alClient;
  Chart.ChartType := ctFunnel;
  Chart.ShowLegend := False;
  Chart.AnimEnabled := True;
  Chart.SetSeries([Tr('Todas'), Tr('Começadas'), Tr('Concluídas')],
    [TUIChartSeries.Create(Tr('Issues'), [CatCount[0] + CatCount[1] + CatCount[2],
      CatCount[1] + CatCount[2], CatCount[2]])]);
  Chart.OnDataPointClick := FunnelClick;
  Chart.Cursor := crHandPoint;
  Chart.Refresh;
  end;

  if GitHubView then
  begin
    // Por repositório: cada repo tem o seu fluxo; status do GitHub não diz muito.
    RepoCounts := TDictionary<string, Integer>.Create;
    try
      for It in FItems do
      begin
        RepoName := RepoOf(It.Key);
        if not RepoCounts.TryGetValue(RepoName, I) then
          I := 0;
        RepoCounts.AddOrSetValue(RepoName, I + 1);
      end;
      FRepoNames := RepoCounts.Keys.ToArray;
      TArray.Sort<string>(FRepoNames, TComparer<string>.Construct(
        function(const L, R: string): Integer
        begin
          Result := RepoCounts[R] - RepoCounts[L];
        end));
      if Length(FRepoNames) > 10 then
        SetLength(FRepoNames, 10);  // ponytail: top 10; o resto fica no seletor do cabeçalho
      W := FGrid.AddWidget('status', Tr('Por repositório'), 0, 9, 6, 7);
      if FRepoNames = nil then
        EmptyNote(W, Tr('Nenhuma issue nesta visão.'))
      else
      begin
        Chart := TUIChart.Create(W);
        Chart.Backend := cbSkia;
        Chart.Parent := W;
        Chart.Align := alClient;
        Chart.ChartType := ctProgress;
        Chart.ShowLegend := False;
        Chart.AnimEnabled := True;
        // Rótulo só com o nome do repo: 'dono/' cortava na coluna de rótulos.
        Series := nil;
        Labels := nil;
        for I := 0 to High(FRepoNames) do
        begin
          Labels := Labels + [FRepoNames[I].Substring(FRepoNames[I].IndexOf('/') + 1)];
          Series := Series + [TUIChartSeries.Create(Labels[I], [RepoCounts[FRepoNames[I]]])];
        end;
        Chart.SetSeries(Labels, Series);
        Chart.OnDataPointClick := RepoClick;
        Chart.Cursor := crHandPoint;
        Chart.Refresh;
      end;
    finally
      RepoCounts.Free;
    end;
  end
  else
  begin
  W := FGrid.AddWidget('status', Tr('Por status'), 0, 9, 6, 7);
  Chart := TUIChart.Create(W);
  Chart.Backend := cbSkia;
  Chart.Parent := W;
  Chart.Align := alClient;
  Chart.ChartType := ctProgress;  // barras horizontais: nomes de status longos cabem
  Chart.ShowLegend := False;
  Chart.AnimEnabled := True;
  // ctProgress desenha uma barra por série, com o rótulo de mesmo índice.
  Series := nil;
  for I := 0 to High(StatusNames) do
    Series := Series + [TUIChartSeries.Create(StatusNames[I], [StatusCounts[I]])];
  Chart.SetSeries(StatusNames, Series);
  FStatusNames := StatusNames;
  Chart.OnDataPointClick := StatusClick;
  Chart.Cursor := crHandPoint;
  Chart.Refresh;
  end;

  // Pendências por #tag: quanto tem aberto em cada projeto do usuário.
  W := FGrid.AddWidget('tags', Tr('Pendências por #tag'), 6, 9, 6, 7);
  Tags := nil;
  for var Tg in IssueStore.ListTags do
    if (FAccountFilter = 0) or (Tg.AccountId = FAccountFilter) then
      Tags := Tags + [Tg];
  FTagNames := nil;
  TagCounts := nil;
  for I := 0 to High(Tags) do
  begin
    FTagNames := FTagNames + ['#' + Tags[I].Name];
    TagCounts := TagCounts + [0];
    for It in FItems do
      if Tags[I].Matches(It) then
        TagCounts[I] := TagCounts[I] + 1;
  end;
  if Tags = nil then
  begin
    Lbl := TUILabel.Create(W);
    Lbl.Caption := Tr('Crie tags (botão direito numa issue › Tag) para ver as pendências por projeto.');
    Lbl.Variant := lvMuted;
    Lbl.WordWrap := True;
    Lbl.AutoSize := False;
    Lbl.Align := alClient;
    Lbl.Parent := W;
  end
  else
  begin
    Chart := TUIChart.Create(W);
    Chart.Backend := cbSkia;
    Chart.Parent := W;
    Chart.Align := alClient;
    Chart.ChartType := ctProgress;
    Chart.ShowLegend := False;
    Chart.AnimEnabled := True;
    Series := nil;
    for I := 0 to High(FTagNames) do
      Series := Series + [TUIChartSeries.Create(FTagNames[I], [TagCounts[I]])];
    Chart.SetSeries(FTagNames, Series);
    Chart.OnDataPointClick := TagClick;
    Chart.Cursor := crHandPoint;
    Chart.Refresh;
  end;

  // Próximas entregas: só issues com prazo, da mais perto para a mais longe.
  FUpcoming := nil;
  for It in FItems do
    if It.DueDate > 0 then
      FUpcoming := FUpcoming + [It];
  TArray.Sort<TItem>(FUpcoming, TComparer<TItem>.Construct(
    function(const L, R: TItem): Integer
    begin
      Result := CompareValue(L.DueDate, R.DueDate);
    end));
  W := FGrid.AddWidget('entregas', Tr('Próximas entregas'), 0, 16, 6, 9);
  List := TUIVirtualList.Create(W);
  List.RowHeight := 52;
  List.OnItemClick := UpcomingClick;
  List.Align := alClient;
  List.Parent := W;
  for It in FUpcoming do
  begin
    V := Default(TUIVListItem);
    V.Title := It.Key + '  ' + It.Title;
    V.Subtitle := FormatDateTime('dd/mm/yyyy', It.DueDate) + '  ·  ' + It.Status;
    DaysLeft := Trunc(DateOf(It.DueDate) - Date);
    if DaysLeft < 0 then
      V.MetaText := Format(Tr('vencida há %d d'), [-DaysLeft])
    else if DaysLeft = 0 then
      V.MetaText := 'hoje'
    else
      V.MetaText := Format(Tr('em %d d'), [DaysLeft]);
    List.AddItem(V);
  end;
  if FUpcoming = nil then
    List.AddItem('Nenhuma issue com prazo', Tr('Configure o campo de entrega na conta, se o Jira usar um.'));

  // Atividade recente: avisos das issues que estão na tela (respeita a conta).
  W := FGrid.AddWidget('atividade-recente', Tr('Atividade recente'), 6, 16, 6, 9);
  Recent := TUIVirtualList.Create(W);
  Recent.RowHeight := 52;
  Recent.OnItemClick := RecentClick;
  Recent.Align := alClient;
  Recent.Parent := W;
  FRecent := nil;
  Shown := 0;
  for E in IssueStore.ListRecentEvents(60) do
  begin
    Known := False;
    for It in FItems do
      if (It.AccountId = E.AccountId) and SameText(It.Key, E.Key) then
      begin
        Known := True;
        FRecent := FRecent + [It];
        Break;
      end;
    if not Known then
      Continue;
    V := Default(TUIVListItem);
    V.Title := E.Key + '  ·  ' + Tr(EventNames[E.Kind]);
    V.Subtitle := E.Body;
    V.MetaText := FormatDateTime('dd/mm hh:nn', E.At);
    Recent.AddItem(V);
    Inc(Shown);
    if Shown = 8 then
      Break;
  end;
  if Shown = 0 then
    Recent.AddItem('Sem avisos ainda', Tr('Mudanças nas issues aparecem aqui.'));
  LayoutGrid;
end;

{ Resumo do que o Dashboard mostra: muda se qualquer issue, conta, tag ou
  tema mudou. }
function TDashboardView.Signature: string;
var
  Sb: TStringBuilder;
  It: TItem;
  T: TTag;
begin
  Sb := TStringBuilder.Create;
  try
    Sb.Append(FAccountFilter).Append('|').Append(Ord(UITheme.Mode)).Append('|');
    for It in FItems do
      Sb.Append(It.AccountId).Append(It.Key).Append(It.Status).Append(It.StatusCategory)
        .Append(Ord(It.Flagged)).Append(FloatToStr(It.DueDate)).Append(It.ReviewState)
        .Append(It.CiState).Append(Byte(It.Sources)).Append(';');
    for T in IssueStore.ListTags do
      Sb.Append(T.Id).Append(T.Name).Append(T.Keywords).Append(Length(T.Manual)).Append(';');
    Sb.Append(IssueStore.CountEvents(ekComment, 24 * 30, FAccountFilter));
    Result := THashMD5.GetHashString(Sb.ToString);
  finally
    Sb.Free;
  end;
end;

destructor TDashboardView.Destroy;
begin
  FPrevStats.Free;
  inherited;
end;

procedure TDashboardView.WelcomeAddClick(Sender: TObject);
begin
  if Assigned(FOnAddAccount) then
    FOnAddAccount(Self);
end;

{ Primeiro uso: herói com gradiente + passos, no lugar do Dashboard vazio. }
procedure TDashboardView.ShowWelcome(AShow: Boolean);
var
  Hero: TUIHero;
  Steps: TUISteps;
  Btn: TUIButton;
  Row: TPanel;
begin
  if FScroll <> nil then
    FScroll.Visible := not AShow;
  if not AShow then
  begin
    if FWelcome <> nil then
      FWelcome.Visible := False;
    Exit;
  end;
  if FWelcome = nil then
  begin
    FWelcome := TPanel.Create(Self);
    FWelcome.BevelOuter := bvNone;
    FWelcome.ParentBackground := False;
    FWelcome.Padding.SetBounds(32, 24, 32, 24);
    FWelcome.Align := alClient;
    FWelcome.Parent := Self;

    Hero := TUIHero.Create(Self);
    Hero.Title := Tr('Bem-vindo às Issues do Devbox');
    Hero.Subtitle := Tr('Suas issues do GitHub e do Jira na bandeja, com aviso do que mudar.');
    Hero.UseGradient := True;
    Hero.MinHeight := 180;
    Hero.Height := 200;
    Hero.Align := alTop;
    Hero.Parent := FWelcome;

    Steps := TUISteps.Create(Self);
    Steps.AddStep(Tr('Conta'), Tr('GitHub, Jira Server ou Jira Cloud'));
    Steps.AddStep(Tr('Testar'), Tr('O Devbox confere o token'));
    Steps.AddStep(Tr('Pronto'), Tr('Busca a cada 5 min e avisa'));
    Steps.ActiveStep := 0;
    Steps.Height := 90;
    Steps.AlignWithMargins := True;
    Steps.Margins.SetBounds(0, 24, 0, 0);
    Steps.Parent := FWelcome;
    Steps.Top := 1000;
    Steps.Align := alTop;

    Row := TPanel.Create(Self);
    Row.BevelOuter := bvNone;
    Row.ParentBackground := False;
    Row.Height := 44;
    Row.AlignWithMargins := True;
    Row.Margins.SetBounds(0, 16, 0, 0);
    Row.Parent := FWelcome;
    Row.Top := 2000;
    Row.Align := alTop;
    Btn := TUIButton.Create(Self);
    Btn.Caption := Tr('Adicionar a primeira conta');
    Btn.AutoWidth := True;
    Btn.OnClick := WelcomeAddClick;
    Btn.Align := alLeft;
    Btn.Parent := Row;
  end;
  FWelcome.Color := UIThemeVclBackground;
  for var I := 0 to FWelcome.ControlCount - 1 do
    if FWelcome.Controls[I] is TPanel then
      TPanel(FWelcome.Controls[I]).Color := UIThemeVclBackground;
  FWelcome.Visible := True;
end;

procedure TDashboardView.Drill(AKind: TDrillKind; const AValue, ACaption: string);
var
  D: TDrill;
begin
  if not Assigned(FOnDrill) then
    Exit;
  D.Kind := AKind;
  D.Value := AValue;
  D.Caption := ACaption;
  FOnDrill(Self, D);
end;

{ GitHub na tela: a conta escolhida é GitHub, ou todas as contas são. }
function TDashboardView.GitHubView: Boolean;
var
  A: TAccount;
begin
  Result := FAccounts <> nil;
  for A in FAccounts do
    if ((FAccountFilter = 0) or (A.Id = FAccountFilter)) and not (A.Kind in RepoKinds) then
      Exit(False);
end;

procedure TDashboardView.EmptyNote(AParent: TWinControl; const AText: string);
var
  L: TUILabel;
begin
  L := TUILabel.Create(AParent);
  L.Caption := AText;
  L.Variant := lvMuted;
  L.TextAlign := UI.Painter.taCenter;
  L.WordWrap := True;
  L.AutoSize := False;
  L.Align := alClient;
  L.Parent := AParent;
end;

procedure TDashboardView.KindClick(Sender: TObject; SeriesIndex, DataIndex: Integer;
  const Value: Double);
begin
  case DataIndex of
    0: Drill(dkKind, 'issue', Tr('Só issues'));
    1: Drill(dkKind, 'pr', Tr('Só PRs'));
  end;
end;

{ ctProgress: uma série por barra; o índice da barra vem em SeriesIndex. }
procedure TDashboardView.PrStateClick(Sender: TObject; SeriesIndex, DataIndex: Integer;
  const Value: Double);
begin
  case SeriesIndex of
    0: Drill(dkPrState, 'WAITING', Tr('Aguardando review'));
    1: Drill(dkPrState, 'CHANGES_REQUESTED', Tr('Mudanças pedidas'));
    2: Drill(dkPrState, 'APPROVED', Tr('Aprovados'));
    3: Drill(dkPrState, 'CI', Tr('CI falhou'));
  end;
end;

procedure TDashboardView.RepoClick(Sender: TObject; SeriesIndex, DataIndex: Integer;
  const Value: Double);
begin
  if (SeriesIndex >= 0) and (SeriesIndex <= High(FRepoNames)) then
    Drill(dkRepo, FRepoNames[SeriesIndex], FRepoNames[SeriesIndex]);
end;

procedure TDashboardView.StatClick(Sender: TObject);
var
  Id: string;
begin
  Id := TControl(Sender).Parent.Name;
  if TControl(Sender).Parent is TUIDashboardWidget then
    Id := TUIDashboardWidget(TControl(Sender).Parent).WidgetId;
  if Id = 'comigo' then
    Drill(dkMine, '', '')
  else if Id = 'meusprs' then
    Drill(dkMyPrs, '', '')
  else if Id = 'impedidas' then
    Drill(dkFlagged, '', '')
  else if Id = 'prazo' then
    Drill(dkDueSoon, '', Tr('Prazo perto'))
  else
    Drill(dkAll, '', '');
end;

{ Anel sempre redondo: quadrado no centro do card, acima do rótulo. }
procedure TDashboardView.RingHostResize(Sender: TObject);
var
  W: TWinControl;
  I, Sz, Top0: Integer;
begin
  W := TWinControl(Sender);
  Top0 := ScaleValue(40);  // cabeçalho do card
  Sz := Min(W.ClientWidth - ScaleValue(24), W.ClientHeight - Top0 - ScaleValue(28));
  for I := 0 to W.ControlCount - 1 do
    if W.Controls[I] is TUIRadialProgress then
      W.Controls[I].SetBounds((W.ClientWidth - Sz) div 2, Top0, Max(Sz, 10), Max(Sz, 10));
end;

procedure TDashboardView.RingClick(Sender: TObject);
begin
  Drill(dkWithDue, '', Tr('Com prazo'));
end;

procedure TDashboardView.CategoryClick(Sender: TObject; SeriesIndex, DataIndex: Integer;
  const Value: Double);
begin
  if (DataIndex >= 0) and (DataIndex <= High(Categories)) then
    Drill(dkCategory, Categories[DataIndex], CategoryNames[DataIndex]);
end;

{ Funil: Todas | Começadas | Concluídas. }
procedure TDashboardView.FunnelClick(Sender: TObject; SeriesIndex, DataIndex: Integer;
  const Value: Double);
begin
  case DataIndex of
    0: Drill(dkAll, '', '');
    1: Drill(dkCategory, 'indeterminate', Tr('Em andamento'));
    2: Drill(dkCategory, 'done', Tr('Concluído'));
  end;
end;

{ ctProgress: uma série por barra; o índice da barra vem em SeriesIndex. }
procedure TDashboardView.StatusClick(Sender: TObject; SeriesIndex, DataIndex: Integer;
  const Value: Double);
begin
  if (SeriesIndex >= 0) and (SeriesIndex <= High(FStatusNames)) then
    Drill(dkStatus, FStatusNames[SeriesIndex], Tr('Status: ') + FStatusNames[SeriesIndex]);
end;

procedure TDashboardView.TagClick(Sender: TObject; SeriesIndex, DataIndex: Integer;
  const Value: Double);
begin
  if (SeriesIndex >= 0) and (SeriesIndex <= High(FTagNames)) then
    Drill(dkTag, FTagNames[SeriesIndex].Substring(1), FTagNames[SeriesIndex]);
end;

procedure TDashboardView.RecentClick(Sender: TObject; AIndex: Integer; const AItem: TUIVListItem);
begin
  if Assigned(FOnOpenItem) and (AIndex >= 0) and (AIndex <= High(FRecent)) then
    FOnOpenItem(Self, FRecent[AIndex]);
end;

procedure TDashboardView.UpcomingClick(Sender: TObject; AIndex: Integer; const AItem: TUIVListItem);
begin
  if Assigned(FOnOpenItem) and (AIndex >= 0) and (AIndex <= High(FUpcoming)) then
    FOnOpenItem(Self, FUpcoming[AIndex]);
end;

procedure TDashboardView.LayoutGrid;
const
  Rows = 25;  // números (3) + gráficos (6) + status/tags (7) + entregas/atividade (9)
  Pad = 12;
var
  H: Integer;
begin
  if (FGrid = nil) or (FScroll = nil) then
    Exit;
  H := ScaleValue(Rows * FGrid.RowHeight + (Rows + 1) * FGrid.Gap);
  FGrid.SetBounds(ScaleValue(Pad), ScaleValue(Pad div 2), FScroll.ClientWidth - 2 * ScaleValue(Pad), H);
  FScroll.ContentHeight := H + ScaleValue(Pad * 2);
end;

procedure TDashboardView.Resize;
begin
  inherited;
  LayoutGrid;
end;

end.
