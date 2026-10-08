unit Devbox.UI.Cleanup;

{ Limpeza: lixo de build, temporários e caches, arquivos grandes, pastas vazias,
  imagens órfãs de container e programas que iniciam com o Windows. Tudo passa
  por "Analisar" antes; apagar sempre pede confirmação no aviso. }

interface

uses
  System.Classes,
  System.SysUtils,
  Vcl.Controls,
  Vcl.ExtCtrls,
  UI.Labels,
  UI.Tabs,
  UI.Stat,
  UI.Input,
  UI.Select,
  UI.Chart,
  UI.Button,
  UI.DataTable,
  UI.ProgressBar,
  Devbox.Cleanup,
  Devbox.UI.Kit;

type
  TCleanTab = (ctJunk, ctTemp, ctBig, ctEmpty, ctContainers, ctStartup);

  TCleanupPage = class(TDevPage)
  private
    FTabs: TUITabs;
    FViews: array[TCleanTab] of TPanel;
    FTables: array[TCleanTab] of TUIDataTable;
    FFound, FFreed: TUIStat;
    FFreedTotal: Int64;
    FProgress: TUIProgressBar;
    FStatus: TUILabel;
    FStopBtn: TUIButton;
    FFoundBy: array[TCleanTab] of string;   // texto do cartão "Encontrado" por aba
    FFoundSubBy: array[TCleanTab] of string;
    FBusy: Boolean;
    FCancel: Boolean;
    FLastStatus: UInt64;
    FPending: TProc;               // ação esperando o "sim" do aviso
    // Dados de cada aba, na ordem das linhas
    FJunk: TJunkItems;
    FSpots: TCleanSpots;
    FBig: TBigFiles;
    FEmpty: TArray<string>;
    FDangling: TDanglings;
    FStartup: TStartupItems;
    // Campos
    FJunkRoots, FBigRoot, FEmptyRoot: TUIInput;
    FJunkDays, FBigSize, FBigDays: TUISelect;
    FChart: TUIChart;
    function NewView(ATab: TCleanTab; const AHint: string): TPanel;
    function NewTable(ATab: TCleanTab): TUIDataTable;
    function NewToolbar(AView: TPanel): TPanel;
    function NewRootInput(ABar: TPanel; const ASetting, ADefault: string): TUIInput;
    function NewSelect(ABar: TPanel; const ACaption: string; const AItems: array of string; AIndex: Integer): TUISelect;
    function SelectedIndices(ATab: TCleanTab): TArray<Integer>;
    procedure TabChange(Sender: TObject; AIndex: Integer);
    procedure ShowTab(ATab: TCleanTab);
    procedure SetBusy(ABusy: Boolean; const AStatus: string = '');
    procedure Progress(const APath: string);
    function ProgressProc: TProc<string>;
    procedure RunScan(const AScan: TProc; const ADone: TProc);
    procedure Confirm(const AQuestion: string; const AAction: TProc);
    procedure ConfirmClick(Sender: TObject);
    procedure DeleteSelected(ATab: TCleanTab; const APaths: TArray<string>; ARecycle: Boolean; const AAfter: TProc);
    procedure AddFreed(ABytes: Int64);
    procedure SetFound(ABytes: Int64; ACount: Integer);
    procedure FillJunk;
    procedure FillSpots;
    procedure FillBig;
    procedure FillEmpty;
    procedure FillDangling;
    procedure FillStartup;
    procedure PickFolder(Sender: TObject);
    procedure SelectAllClick(Sender: TObject);
    procedure CancelClick(Sender: TObject);
    procedure JunkScan(Sender: TObject);
    procedure JunkDelete(Sender: TObject);
    procedure TempScan(Sender: TObject);
    procedure TempDelete(Sender: TObject);
    procedure BigScan(Sender: TObject);
    procedure BigDelete(Sender: TObject);
    procedure BigOpenFolder(Sender: TObject);
    procedure EmptyScan(Sender: TObject);
    procedure EmptyDelete(Sender: TObject);
    procedure DanglingScan(Sender: TObject);
    procedure DanglingImages(Sender: TObject);
    procedure DanglingVolumes(Sender: TObject);
    procedure StartupScan(Sender: TObject);
    procedure StartupToggle(AEnable: Boolean);
    procedure StartupOff(Sender: TObject);
    procedure StartupOn(Sender: TObject);
  public
    constructor Create(AOwner: TComponent); override;
    procedure PageShown; override;
  end;

implementation

uses
  Winapi.Windows,
  System.StrUtils,
  System.Math,
  System.IOUtils,
  System.Threading,
  System.Generics.Collections,
  System.Generics.Defaults,
  Vcl.Dialogs,
  UI.Theme,
  UI.Tokens,
  UI.Toast,
  Devbox.Model,
  Devbox.Store,
  Devbox.Sys;

const
  JunkDayOptions: array[0..3] of Integer = (7, 30, 90, 180);
  BigSizeOptions: array[0..3] of Int64 = (50, 100, 500, 1024);   // MB
  BigDayOptions: array[0..3] of Integer = (0, 90, 180, 365);
  CBigLimit = 300;
  CStatusEveryMs = 150;

{ Montagem }

constructor TCleanupPage.Create(AOwner: TComponent);
const
  TabNames: array[TCleanTab] of string = ('Lixo de build', 'Temporários e caches', 'Arquivos grandes',
    'Pastas vazias', 'Containers', 'Inicialização');
var
  Cards, Bar, Right: TPanel;
  T: TCleanTab;
  C: TUIColorTokens;
begin
  inherited Create(AOwner);
  Caption := 'Limpeza';
  Hint := 'Espaço que dá para recuperar e o que inicia com o Windows. Nada sai sem você confirmar.';
  C := UITheme.Tokens.Color;

  Cards := NewPanel(Self, alTop, 112);
  Cards.Padding.SetBounds(0, 0, 0, ScaleValue(12));
  FFound := TUIStat.Create(Self);
  FFound.CardLabel := 'Encontrado';
  FFound.Value := '–';
  FFound.Width := ScaleValue(240);
  FFound.Align := alLeft;
  FFound.Parent := Cards;
  FFreed := TUIStat.Create(Self);
  FFreed.CardLabel := 'Liberado nesta sessão';
  FFreed.Value := '0 B';
  FFreed.Tone := stSuccess;
  FFreed.Width := ScaleValue(240);
  FFreed.AlignWithMargins := True;
  FFreed.Margins.SetBounds(ScaleValue(12), 0, 0, 0);
  FFreed.Left := 1000;
  FFreed.Align := alLeft;
  FFreed.Parent := Cards;

  FTabs := TUITabs.Create(Self);
  for T := Low(TCleanTab) to High(TCleanTab) do
    FTabs.AddTab(TabNames[T]);
  FTabs.Top := 100000;
  FTabs.Align := alTop;
  FTabs.Parent := Self;
  FTabs.OnChange := TabChange;

  FProgress := TUIProgressBar.Create(Self);
  FProgress.Indeterminate := True;
  FProgress.TrackHeight := 3;
  FProgress.Height := 3;
  FProgress.Visible := False;
  FProgress.Top := 100000;
  FProgress.Align := alTop;
  FProgress.Parent := Self;

  Bar := NewPanel(Self, alBottom, 30);
  FStopBtn := NewButton(Bar, 'Parar', CancelClick, bvGhost, alRight);
  FStopBtn.Visible := False;
  FStatus := NewHint(Bar, '', alClient);

  // Lixo de build
  FViews[ctJunk] := NewView(ctJunk, 'node_modules, bin/obj, dcu, __history, target, .gradle e caches de Python ' +
    'de projetos parados. Sai de vez: o próximo build refaz.');
  Bar := NewToolbar(FViews[ctJunk]);
  NewButton(Bar, 'Analisar', JunkScan, bvPrimary);
  FJunkDays := NewSelect(Bar, 'Parado há', ['7 dias', '30 dias', '90 dias', '180 dias'], 1);
  NewButton(Bar, 'Escolher pasta…', PickFolder, bvGhost).Tag := Ord(ctJunk);
  FJunkRoots := NewRootInput(Bar, 'junk_roots', GetEnvironmentVariable('USERPROFILE'));
  Bar := NewToolbar(FViews[ctJunk]);
  NewButton(Bar, 'Selecionar tudo', SelectAllClick, bvGhost).Tag := Ord(ctJunk);
  NewButton(Bar, 'Apagar selecionados', JunkDelete);
  FTables[ctJunk] := NewTable(ctJunk);
  FTables[ctJunk].AddColumn('project', 'Projeto', 'project', 220);
  FTables[ctJunk].AddColumn('kind', 'Tipo', 'kind', 170);
  FTables[ctJunk].AddColumn('size', 'Tamanho', 'size', 100, False, caRight);
  FTables[ctJunk].AddColumn('idle', 'Parado há', 'idle', 100, False, caRight);
  FTables[ctJunk].AddColumn('path', 'Caminho', 'path', 420);

  // Temporários e caches
  FViews[ctTemp] := NewView(ctTemp, 'Arquivos que o Windows e os programas refazem sozinhos. ' +
    'Feche o navegador antes de limpar o cache dele.');
  Bar := NewToolbar(FViews[ctTemp]);
  NewButton(Bar, 'Analisar', TempScan, bvPrimary);
  NewButton(Bar, 'Selecionar tudo', SelectAllClick, bvGhost).Tag := Ord(ctTemp);
  NewButton(Bar, 'Limpar selecionados', TempDelete);
  FTables[ctTemp] := NewTable(ctTemp);
  FTables[ctTemp].AddColumn('name', 'Local', 'name', 260);
  FTables[ctTemp].AddColumn('size', 'Tamanho', 'size', 110, False, caRight);
  FTables[ctTemp].AddColumn('files', 'Itens', 'files', 80, False, caRight);
  FTables[ctTemp].AddColumn('note', 'Observação', 'note', 420);

  // Arquivos grandes
  FViews[ctBig] := NewView(ctBig, 'Os maiores arquivos a partir da pasta escolhida. "Sem mudar há" usa a data de ' +
    'modificação. Vai para a Lixeira.');
  Bar := NewToolbar(FViews[ctBig]);
  NewButton(Bar, 'Analisar', BigScan, bvPrimary);
  FBigDays := NewSelect(Bar, 'Sem mudar há', ['qualquer data', '90 dias', '180 dias', '1 ano'], 0);
  FBigSize := NewSelect(Bar, 'A partir de', ['50 MB', '100 MB', '500 MB', '1 GB'], 1);
  NewButton(Bar, 'Escolher pasta…', PickFolder, bvGhost).Tag := Ord(ctBig);
  FBigRoot := NewRootInput(Bar, 'big_root', GetEnvironmentVariable('USERPROFILE'));
  Bar := NewToolbar(FViews[ctBig]);
  NewButton(Bar, 'Mandar para a Lixeira', BigDelete);
  NewButton(Bar, 'Abrir pasta', BigOpenFolder, bvGhost);
  Right := NewPanel(FViews[ctBig], alRight);
  Right.Width := ScaleValue(320);
  Right.Padding.SetBounds(ScaleValue(12), 0, 0, 0);
  FChart := TUIChart.Create(Self);
  FChart.Backend := cbSkia;
  FChart.ChartType := ctTreemap;
  FChart.Title := 'Espaço por tipo (GB)';
  FChart.ShowLegend := False;
  FChart.AnimEnabled := True;
  FChart.Align := alClient;
  FChart.Parent := Right;
  FTables[ctBig] := NewTable(ctBig);
  FTables[ctBig].AddColumn('name', 'Arquivo', 'name', 260);
  FTables[ctBig].AddColumn('size', 'Tamanho', 'size', 100, False, caRight);
  FTables[ctBig].AddColumn('date', 'Mudou em', 'date', 100);
  FTables[ctBig].AddColumn('dir', 'Pasta', 'dir', 360);

  // Pastas vazias
  FViews[ctEmpty] := NewView(ctEmpty, 'Pastas sem nenhum arquivo dentro. .git e junções ficam de fora. ' +
    'Vai para a Lixeira.');
  Bar := NewToolbar(FViews[ctEmpty]);
  NewButton(Bar, 'Analisar', EmptyScan, bvPrimary);
  NewButton(Bar, 'Escolher pasta…', PickFolder, bvGhost).Tag := Ord(ctEmpty);
  FEmptyRoot := NewRootInput(Bar, 'empty_root', GetEnvironmentVariable('USERPROFILE'));
  Bar := NewToolbar(FViews[ctEmpty]);
  NewButton(Bar, 'Selecionar tudo', SelectAllClick, bvGhost).Tag := Ord(ctEmpty);
  NewButton(Bar, 'Mandar para a Lixeira', EmptyDelete);
  FTables[ctEmpty] := NewTable(ctEmpty);
  FTables[ctEmpty].AddColumn('path', 'Pasta', 'path', 760);

  // Containers
  FViews[ctContainers] := NewView(ctContainers, 'Imagens sem tag (sobras de build) e volumes que nenhum ' +
    'container usa, no Docker do Windows e no Podman/Docker das distros WSL ligadas.');
  Bar := NewToolbar(FViews[ctContainers]);
  NewButton(Bar, 'Analisar', DanglingScan, bvPrimary);
  NewButton(Bar, 'Limpar imagens órfãs', DanglingImages);
  NewButton(Bar, 'Apagar volumes sem uso', DanglingVolumes, bvGhost);
  FTables[ctContainers] := NewTable(ctContainers);
  FTables[ctContainers].AddColumn('where', 'Onde', 'where', 260);
  FTables[ctContainers].AddColumn('images', 'Imagens órfãs', 'images', 120, False, caRight);
  FTables[ctContainers].AddColumn('size', 'Tamanho', 'size', 120, False, caRight);
  FTables[ctContainers].AddColumn('volumes', 'Volumes sem uso', 'volumes', 140, False, caRight);

  // Inicialização
  FViews[ctStartup] := NewView(ctStartup, 'Desligar não apaga: é o mesmo liga e desliga do Gerenciador de ' +
    'Tarefas. Itens da máquina precisam de admin.');
  Bar := NewToolbar(FViews[ctStartup]);
  NewButton(Bar, 'Atualizar', StartupScan, bvPrimary);
  NewButton(Bar, 'Desligar', StartupOff);
  NewButton(Bar, 'Religar', StartupOn);
  FTables[ctStartup] := NewTable(ctStartup);
  FTables[ctStartup].SelectionMode := tsmSingle;
  FTables[ctStartup].AddColumn('name', 'Programa', 'name', 220);
  FTables[ctStartup].AddColumn('state', 'Estado', 'state', 110);
  FTables[ctStartup].AddColumn('source', 'Onde', 'source', 190);
  FTables[ctStartup].AddColumn('command', 'Comando', 'command', 440);
  FTables[ctStartup].SetColType('state', ctBadge);
  FTables[ctStartup].AddBadgeMap('state', 'ligado', C.SuccessSubtle, C.Success);
  FTables[ctStartup].AddBadgeMap('state', 'desligado', C.BGMuted, C.FGMuted);

  FTabs.ActiveIndex := 0;
  ShowTab(ctJunk);
end;

function TCleanupPage.NewView(ATab: TCleanTab; const AHint: string): TPanel;
begin
  Result := NewPanel(Self, alClient);
  Result.Padding.SetBounds(0, ScaleValue(10), 0, 0);
  Result.Visible := False;
  NewHint(Result, AHint);
end;

function TCleanupPage.NewToolbar(AView: TPanel): TPanel;
begin
  Result := NewPanel(AView, alTop, 50);
  Result.Padding.SetBounds(0, ScaleValue(6), 0, ScaleValue(6));
end;

function TCleanupPage.NewTable(ATab: TCleanTab): TUIDataTable;
begin
  Result := TUIDataTable.Create(Self);
  Result.SelectionMode := tsmMultiple;
  Result.Density := tdCompact;
  Result.EmptyStateText := 'Clique em Analisar';
  Result.Top := 100000;
  Result.Align := alClient;
  Result.Parent := FViews[ATab];
end;

function TCleanupPage.NewRootInput(ABar: TPanel; const ASetting, ADefault: string): TUIInput;
begin
  Result := TUIInput.Create(Self);
  Result.LabelMode := ilmBorder;
  Result.LabelText := 'Pastas (separe com ;)';
  Result.ReserveHintSpace := False;
  Result.Value := Store.GetSetting(ASetting, ADefault);
  Result.HelpKeyword := ASetting;
  Result.AlignWithMargins := True;
  Result.Margins.SetBounds(0, 0, ScaleValue(8), 0);
  Result.Align := alClient;
  Result.Parent := ABar;
end;

function TCleanupPage.NewSelect(ABar: TPanel; const ACaption: string; const AItems: array of string;
  AIndex: Integer): TUISelect;
var
  S: string;
begin
  Result := TUISelect.Create(Self);
  for S in AItems do
    Result.Items.Add(S);
  Result.ItemIndex := AIndex;
  Result.Hint := ACaption;
  Result.ShowHint := True;
  Result.Width := ScaleValue(150);
  Result.AlignWithMargins := True;
  Result.Margins.SetBounds(0, 0, ScaleValue(8), 0);
  Result.Left := 100000;
  Result.Align := alLeft;
  Result.Parent := ABar;
end;

procedure TCleanupPage.PageShown;
begin
  if FStartup = nil then
    StartupScan(nil);
end;

procedure TCleanupPage.TabChange(Sender: TObject; AIndex: Integer);
begin
  ShowTab(TCleanTab(AIndex));
end;

procedure TCleanupPage.ShowTab(ATab: TCleanTab);
var
  T: TCleanTab;
begin
  for T := Low(TCleanTab) to High(TCleanTab) do
    FViews[T].Visible := T = ATab;
  FFound.Value := IfThen(FFoundBy[ATab] = '', '–', FFoundBy[ATab]);
  FFound.SubText := FFoundSubBy[ATab];
end;

function TCleanupPage.SelectedIndices(ATab: TCleanTab): TArray<Integer>;
var
  R: Integer;
begin
  // A tabela guarda a linha da tela; os dados seguem a ordem original.
  Result := nil;
  for R in FTables[ATab].SelectedRows do
    Result := Result + [FTables[ATab].ActualRowIndex(R)];
end;

procedure TCleanupPage.SelectAllClick(Sender: TObject);
var
  T: TUIDataTable;
  I: Integer;
begin
  T := FTables[TCleanTab(TComponent(Sender).Tag)];
  T.ClearSelection;
  for I := 0 to T.VisibleRowCount - 1 do
    T.AddToSelection(I);
end;

procedure TCleanupPage.PickFolder(Sender: TObject);
var
  Dlg: TFileOpenDialog;
  Input: TUIInput;
begin
  case TCleanTab(TComponent(Sender).Tag) of
    ctJunk: Input := FJunkRoots;
    ctBig: Input := FBigRoot;
  else
    Input := FEmptyRoot;
  end;
  Dlg := TFileOpenDialog.Create(nil);
  try
    Dlg.Options := [fdoPickFolders, fdoPathMustExist];
    Dlg.Title := 'Escolher pasta';
    if not Dlg.Execute then
      Exit;
    // Lixo de build aceita várias raízes: a escolhida entra junto das outras.
    if (Input = FJunkRoots) and (Trim(Input.Value) <> '') then
      Input.Value := Input.Value + ';' + Dlg.FileName
    else
      Input.Value := Dlg.FileName;
  finally
    Dlg.Free;
  end;
end;

{ Varredura em segundo plano }

procedure TCleanupPage.SetBusy(ABusy: Boolean; const AStatus: string);
begin
  FBusy := ABusy;
  FProgress.Visible := ABusy;
  FStopBtn.Visible := ABusy;
  FStatus.Caption := AStatus;
end;

{ Chamado de dentro da varredura (outra thread): mostra a pasta atual, sem
  inundar a fila da tela. }
procedure TCleanupPage.Progress(const APath: string);
begin
  if GetTickCount64 - FLastStatus < CStatusEveryMs then
    Exit;
  FLastStatus := GetTickCount64;
  QueueUI(
    procedure
    begin
      if FBusy then
        FStatus.Caption := 'Olhando ' + APath;
    end);
end;

function TCleanupPage.ProgressProc: TProc<string>;
begin
  Result :=
    procedure(APath: string)
    begin
      Progress(APath);
    end;
end;

procedure TCleanupPage.RunScan(const AScan: TProc; const ADone: TProc);
begin
  if FBusy then
  begin
    TUIToastManager.Show('Já tem uma análise rodando', ttInfo, 2000);
    Exit;
  end;
  FCancel := False;
  SetBusy(True, 'Analisando...');
  TTask.Run(
    procedure
    var
      Error: string;
    begin
      Error := '';
      try
        AScan();
      except
        on E: Exception do
          Error := E.Message;
      end;
      QueueUI(
        procedure
        begin
          SetBusy(False);
          if Error <> '' then
            TUIToastManager.Show('A análise parou: ' + Error, ttError, 6000)
          else
            ADone();
        end);
    end);
end;

procedure TCleanupPage.CancelClick(Sender: TObject);
begin
  // A varredura confere a flag a cada pasta e devolve o que já achou.
  FCancel := True;
  FStatus.Caption := 'Parando...';
end;

procedure TCleanupPage.SetFound(ABytes: Int64; ACount: Integer);
var
  T: TCleanTab;
begin
  T := TCleanTab(Max(FTabs.ActiveIndex, 0));
  FFoundBy[T] := SizeText(ABytes);
  FFoundSubBy[T] := Format('%d itens nesta aba', [ACount]);
  FFound.Value := FFoundBy[T];
  FFound.SubText := FFoundSubBy[T];
end;

procedure TCleanupPage.AddFreed(ABytes: Int64);
begin
  Inc(FFreedTotal, ABytes);
  FFreed.Value := SizeText(FFreedTotal);
end;

{ Confirmação no próprio aviso: o botão do toast é o "sim". }
procedure TCleanupPage.Confirm(const AQuestion: string; const AAction: TProc);
begin
  FPending := AAction;
  TUIToastManager.Show(AQuestion, ttWarning, 10000, 'Confirmar', ConfirmClick);
end;

procedure TCleanupPage.ConfirmClick(Sender: TObject);
var
  Action: TProc;
begin
  Action := FPending;
  FPending := nil;
  if Assigned(Action) then
    Action();
end;

procedure TCleanupPage.DeleteSelected(ATab: TCleanTab; const APaths: TArray<string>; ARecycle: Boolean;
  const AAfter: TProc);
var
  Paths: TArray<string>;
begin
  Paths := APaths;
  SetBusy(True, IfThen(ARecycle, 'Mandando para a Lixeira...', 'Apagando...'));
  TTask.Run(
    procedure
    var
      Freed: Int64;
      Failed: Integer;
    begin
      Failed := DeletePaths(Paths, ARecycle, Freed);
      QueueUI(
        procedure
        begin
          SetBusy(False);
          AddFreed(Freed);
          if Failed = 0 then
            TUIToastManager.Show(Format('Pronto: %s liberados', [SizeText(Freed)]), ttSuccess, 3500)
          else
            TUIToastManager.Show(Format('%s liberados. %d itens não saíram (em uso ou sem permissão).',
              [SizeText(Freed), Failed]), ttWarning, 6000);
          AAfter();
        end);
    end);
end;

{ Lixo de build }

procedure TCleanupPage.FillJunk;
var
  J: TJunkItem;
  Total: Int64;
begin
  Total := 0;
  FTables[ctJunk].BeginRowUpdate;
  try
    FTables[ctJunk].ClearMemRows;
    for J in FJunk do
    begin
      FTables[ctJunk].AddMemRow([ExtractFileName(J.Project), J.Kind, SizeText(J.Size),
        Format('%d dias', [J.IdleDays]), J.Path]);
      Inc(Total, J.Size);
    end;
  finally
    FTables[ctJunk].EndRowUpdate;
  end;
  FTables[ctJunk].EmptyStateText := 'Nenhum lixo de build em projeto parado';
  SetFound(Total, Length(FJunk));
end;

procedure TCleanupPage.JunkScan(Sender: TObject);
var
  Roots: TArray<string>;
  Days: Integer;
  Found: TJunkItems;
begin
  Store.SetSetting('junk_roots', FJunkRoots.Value);
  Roots := FJunkRoots.Value.Split([';'], TStringSplitOptions.ExcludeEmpty);
  Days := JunkDayOptions[Max(FJunkDays.ItemIndex, 0)];
  RunScan(
    procedure
    begin
      Found := ScanBuildJunk(Roots, Days,
        function: Boolean
        begin
          Result := FCancel;
        end, ProgressProc());
    end,
    procedure
    begin
      FJunk := Found;
      FillJunk;
    end);
end;

procedure TCleanupPage.JunkDelete(Sender: TObject);
var
  Rows: TArray<Integer>;
  Paths: TArray<string>;
  I: Integer;
  Size: Int64;
begin
  Rows := SelectedIndices(ctJunk);
  if Rows = nil then
  begin
    TUIToastManager.Show('Escolha as linhas (Ctrl ou Shift para várias) ou use Selecionar tudo', ttInfo, 3500);
    Exit;
  end;
  Paths := nil;
  Size := 0;
  for I in Rows do
  begin
    Paths := Paths + [FJunk[I].Path];
    Inc(Size, FJunk[I].Size);
  end;
  Confirm(Format('Apagar de vez %d pastas de build (%s)? O próximo build refaz.', [Length(Paths), SizeText(Size)]),
    procedure
    begin
      DeleteSelected(ctJunk, Paths, False,
        procedure
        begin
          JunkScan(nil);
        end);
    end);
end;

{ Temporários e caches }

procedure TCleanupPage.FillSpots;
var
  S: TCleanSpot;
  Total: Int64;
begin
  Total := 0;
  FTables[ctTemp].BeginRowUpdate;
  try
    FTables[ctTemp].ClearMemRows;
    for S in FSpots do
    begin
      FTables[ctTemp].AddMemRow([S.Name, SizeText(S.Size), IfThen(S.Files > 0, IntToStr(S.Files), ''), S.Note]);
      Inc(Total, S.Size);
    end;
  finally
    FTables[ctTemp].EndRowUpdate;
  end;
  FTables[ctTemp].EmptyStateText := 'Nada para limpar';
  SetFound(Total, Length(FSpots));
end;

procedure TCleanupPage.TempScan(Sender: TObject);
var
  Found: TCleanSpots;
begin
  RunScan(
    procedure
    begin
      Found := ScanCleanSpots;
    end,
    procedure
    begin
      FSpots := Found;
      FillSpots;
    end);
end;

procedure TCleanupPage.TempDelete(Sender: TObject);
var
  Rows: TArray<Integer>;
  Paths: TArray<string>;
  I: Integer;
  Size: Int64;
  Bin: Boolean;
begin
  Rows := SelectedIndices(ctTemp);
  if Rows = nil then
    Exit;
  Paths := nil;
  Size := 0;
  Bin := False;
  for I in Rows do
  begin
    Inc(Size, FSpots[I].Size);
    if FSpots[I].Name = 'Lixeira' then
      Bin := True
    else
      Paths := Paths + FSpots[I].Paths;
  end;
  Confirm(Format('Limpar %d locais (%s)?%s', [Length(Rows), SizeText(Size),
    IfThen(Bin, ' A Lixeira será esvaziada e não tem volta.', '')]),
    procedure
    begin
      if Bin and EmptyRecycleBin then
        TUIToastManager.Show('Lixeira esvaziada', ttSuccess, 2500);
      DeleteSelected(ctTemp, Paths, False,
        procedure
        begin
          TempScan(nil);
        end);
    end);
end;

{ Arquivos grandes }

procedure TCleanupPage.FillBig;
var
  F: TBigFile;
  Total: Int64;
  ByExt: TDictionary<string, Double>;
  Ext: string;
  Pairs: TArray<TPair<string, Double>>;
  Labels: TArray<string>;
  Values: TArray<Double>;
  I: Integer;
begin
  Total := 0;
  ByExt := TDictionary<string, Double>.Create;
  FTables[ctBig].BeginRowUpdate;
  try
    FTables[ctBig].ClearMemRows;
    for F in FBig do
    begin
      FTables[ctBig].AddMemRow([ExtractFileName(F.Path), SizeText(F.Size),
        FormatDateTime('dd/mm/yyyy', F.Modified), ExtractFileDir(F.Path)]);
      Inc(Total, F.Size);
      Ext := LowerCase(ExtractFileExt(F.Path));
      if Ext = '' then
        Ext := '(sem extensão)';
      if ByExt.ContainsKey(Ext) then
        ByExt[Ext] := ByExt[Ext] + F.Size / (1024 * 1024 * 1024)
      else
        ByExt.Add(Ext, F.Size / (1024 * 1024 * 1024));
    end;
    Pairs := ByExt.ToArray;
    TArray.Sort<TPair<string, Double>>(Pairs, TComparer<TPair<string, Double>>.Construct(
      function(const A, B: TPair<string, Double>): Integer
      begin
        Result := CompareValue(B.Value, A.Value);
      end));
    Labels := nil;
    Values := nil;
    for I := 0 to Min(High(Pairs), 11) do
    begin
      Labels := Labels + [Pairs[I].Key];
      Values := Values + [RoundTo(Pairs[I].Value, -2)];
    end;
    if Labels <> nil then
      FChart.SetSeries(Labels, [TUIChartSeries.Create('GB', Values)]);
  finally
    FTables[ctBig].EndRowUpdate;
    ByExt.Free;
  end;
  FTables[ctBig].EmptyStateText := 'Nenhum arquivo com esse tamanho';
  SetFound(Total, Length(FBig));
end;

procedure TCleanupPage.BigScan(Sender: TObject);
var
  Root: string;
  MinSize: Int64;
  Days: Integer;
  Found: TBigFiles;
begin
  Root := Trim(FBigRoot.Value);
  Store.SetSetting('big_root', Root);
  MinSize := BigSizeOptions[Max(FBigSize.ItemIndex, 0)] * 1024 * 1024;
  Days := BigDayOptions[Max(FBigDays.ItemIndex, 0)];
  RunScan(
    procedure
    begin
      Found := ScanBigFiles(Root, MinSize, Days, CBigLimit,
        function: Boolean
        begin
          Result := FCancel;
        end, ProgressProc());
    end,
    procedure
    begin
      FBig := Found;
      FillBig;
    end);
end;

procedure TCleanupPage.BigDelete(Sender: TObject);
const
  // Disco de distro WSL, de VM ou de emulador: apagar destrói o sistema que mora dentro.
  VirtualDisks: array[0..5] of string = ('.vhdx', '.vhd', '.avhdx', '.qcow2', '.vmdk', '.vdi');
var
  Rows: TArray<Integer>;
  Paths: TArray<string>;
  I, Kept: Integer;
  Size: Int64;
begin
  Rows := SelectedIndices(ctBig);
  if Rows = nil then
    Exit;
  Paths := nil;
  Size := 0;
  Kept := 0;
  for I in Rows do
    if MatchText(ExtractFileExt(FBig[I].Path), VirtualDisks) then
      Inc(Kept)
    else
    begin
      Paths := Paths + [FBig[I].Path];
      Inc(Size, FBig[I].Size);
    end;
  if Kept > 0 then
    TUIToastManager.Show(Format('%d discos virtuais ficaram de fora (WSL, VM, emulador). ' +
      'Apague pela ferramenta dona deles.', [Kept]), ttWarning, 6000);
  if Paths = nil then
    Exit;
  Confirm(Format('Mandar %d arquivos (%s) para a Lixeira?', [Length(Paths), SizeText(Size)]),
    procedure
    begin
      DeleteSelected(ctBig, Paths, True,
        procedure
        begin
          BigScan(nil);
        end);
    end);
end;

procedure TCleanupPage.BigOpenFolder(Sender: TObject);
var
  Rows: TArray<Integer>;
begin
  Rows := SelectedIndices(ctBig);
  if Rows <> nil then
    Launch('explorer.exe', '/select,"' + FBig[Rows[0]].Path + '"');
end;

{ Pastas vazias }

procedure TCleanupPage.FillEmpty;
var
  P: string;
begin
  FTables[ctEmpty].BeginRowUpdate;
  try
    FTables[ctEmpty].ClearMemRows;
    for P in FEmpty do
      FTables[ctEmpty].AddMemRow([P]);
  finally
    FTables[ctEmpty].EndRowUpdate;
  end;
  FTables[ctEmpty].EmptyStateText := 'Nenhuma pasta vazia';
  FFoundBy[ctEmpty] := IntToStr(Length(FEmpty));
  FFoundSubBy[ctEmpty] := 'pastas vazias';
  FFound.Value := FFoundBy[ctEmpty];
  FFound.SubText := FFoundSubBy[ctEmpty];
end;

procedure TCleanupPage.EmptyScan(Sender: TObject);
var
  Root: string;
  Found: TArray<string>;
begin
  Root := Trim(FEmptyRoot.Value);
  Store.SetSetting('empty_root', Root);
  RunScan(
    procedure
    begin
      Found := ScanEmptyDirs(Root,
        function: Boolean
        begin
          Result := FCancel;
        end);
    end,
    procedure
    begin
      FEmpty := Found;
      FillEmpty;
    end);
end;

procedure TCleanupPage.EmptyDelete(Sender: TObject);
var
  Rows: TArray<Integer>;
  Paths: TArray<string>;
  I: Integer;
begin
  Rows := SelectedIndices(ctEmpty);
  if Rows = nil then
    Exit;
  Paths := nil;
  for I in Rows do
    Paths := Paths + [FEmpty[I]];
  Confirm(Format('Mandar %d pastas vazias para a Lixeira?', [Length(Paths)]),
    procedure
    begin
      DeleteSelected(ctEmpty, Paths, True,
        procedure
        begin
          EmptyScan(nil);
        end);
    end);
end;

{ Containers }

procedure TCleanupPage.FillDangling;
var
  D: TDangling;
  Total: Int64;
begin
  Total := 0;
  FTables[ctContainers].BeginRowUpdate;
  try
    FTables[ctContainers].ClearMemRows;
    for D in FDangling do
    begin
      FTables[ctContainers].AddMemRow([D.Where, IntToStr(D.Images), SizeText(D.ImagesSize), IntToStr(D.Volumes)]);
      Inc(Total, D.ImagesSize);
    end;
  finally
    FTables[ctContainers].EndRowUpdate;
  end;
  FTables[ctContainers].EmptyStateText := 'Nenhum docker ou podman respondeu';
  SetFound(Total, Length(FDangling));
end;

procedure TCleanupPage.DanglingScan(Sender: TObject);
var
  Found: TDanglings;
begin
  RunScan(
    procedure
    begin
      Found := ScanDangling;
    end,
    procedure
    begin
      FDangling := Found;
      FillDangling;
    end);
end;

procedure TCleanupPage.DanglingImages(Sender: TObject);
var
  Cmds: TArray<string>;
  D: TDangling;
begin
  Cmds := nil;
  for D in FDangling do
    if D.Images > 0 then
      Cmds := Cmds + [D.Cli + ' image prune -f'];
  if Cmds = nil then
  begin
    TUIToastManager.Show('Nenhuma imagem órfã. Clique em Analisar antes.', ttInfo, 3000);
    Exit;
  end;
  Confirm('Apagar as imagens sem tag? Nenhum container usa essas imagens.',
    procedure
    begin
      RunScan(
        procedure
        var
          C, Output: string;
        begin
          for C in Cmds do
            RunCapture(C, Output, 120000);
        end,
        procedure
        begin
          TUIToastManager.Show('Imagens órfãs apagadas', ttSuccess, 3000);
          DanglingScan(nil);
        end);
    end);
end;

procedure TCleanupPage.DanglingVolumes(Sender: TObject);
var
  Cmds: TArray<string>;
  D: TDangling;
  Count: Integer;
begin
  Cmds := nil;
  Count := 0;
  for D in FDangling do
    if D.Volumes > 0 then
    begin
      Cmds := Cmds + [D.Cli + ' volume prune -f'];
      Inc(Count, D.Volumes);
    end;
  if Cmds = nil then
  begin
    TUIToastManager.Show('Nenhum volume sem uso. Clique em Analisar antes.', ttInfo, 3000);
    Exit;
  end;
  Confirm(Format('Apagar %d volumes sem uso? Dados de banco de container removido somem junto.', [Count]),
    procedure
    begin
      RunScan(
        procedure
        var
          C, Output: string;
        begin
          for C in Cmds do
            RunCapture(C, Output, 120000);
        end,
        procedure
        begin
          TUIToastManager.Show('Volumes sem uso apagados', ttSuccess, 3000);
          DanglingScan(nil);
        end);
    end);
end;

{ Inicialização }

procedure TCleanupPage.FillStartup;
var
  S: TStartupItem;
begin
  FTables[ctStartup].BeginRowUpdate;
  try
    FTables[ctStartup].ClearMemRows;
    for S in FStartup do
      FTables[ctStartup].AddMemRow([S.Name, IfThen(S.Enabled, 'ligado', 'desligado'), S.SourceText, S.Command]);
  finally
    FTables[ctStartup].EndRowUpdate;
  end;
  FTables[ctStartup].EmptyStateText := 'Nada inicia com o Windows';
end;

procedure TCleanupPage.StartupScan(Sender: TObject);
begin
  FStartup := ListStartup;
  FillStartup;
end;

procedure TCleanupPage.StartupToggle(AEnable: Boolean);
var
  Rows: TArray<Integer>;
  S: TStartupItem;
begin
  Rows := SelectedIndices(ctStartup);
  if Rows = nil then
    Exit;
  S := FStartup[Rows[0]];
  if S.ReadOnly then
  begin
    TUIToastManager.Show('Item da máquina: só muda rodando como administrador', ttWarning, 4000);
    Exit;
  end;
  if SetStartupEnabled(S, AEnable) then
    TUIToastManager.Show(S.Name + IfThen(AEnable, ' volta a iniciar com o Windows', ' não inicia mais com o Windows'),
      ttSuccess, 3000);
  StartupScan(nil);
end;

procedure TCleanupPage.StartupOff(Sender: TObject);
begin
  StartupToggle(False);
end;

procedure TCleanupPage.StartupOn(Sender: TObject);
begin
  StartupToggle(True);
end;

end.
