unit Devbox.UI.System;

{ Sistema: recursos da máquina ao vivo (CPU, memória, discos, processos que
  mais gastam) e o editor do PATH do usuário. }

interface

uses
  System.Classes,
  System.SysUtils,
  System.UITypes,
  Vcl.Controls,
  Vcl.ExtCtrls,
  UI.Labels,
  UI.Tabs,
  UI.Stat,
  UI.Sparkline,
  UI.ProgressBar,
  UI.DataTable,
  Devbox.SysInfo,
  Devbox.UI.Kit;

type
  TSysTab = (stResources, stPath);

  TSystemPage = class(TDevPage)
  private
    FTabs: TUITabs;
    FViews: array[TSysTab] of TPanel;
    // Recursos
    FSampler: TCpuSampler;
    FCpuStat, FMemStat: TUIStat;
    FCpuSpark, FMemSpark: TUISparkline;
    FCpuHist, FMemHist: TArray<Integer>;
    FDisks: TPanel;
    FProcTable: TUIDataTable;
    FProcs: TProcInfos;
    FProcSel: Integer;
    FTimer: TTimer;
    FKillPid: Cardinal;
    // PATH
    FPathTable: TUIDataTable;
    FPath: TPathEntries;
    FPathSel: Integer;
    FPathDirty: Boolean;
    FPathInfo: TUILabel;
    FPendingPath: string;
    function NewView(ATab: TSysTab; const AHint: string): TPanel;
    procedure TabChange(Sender: TObject; AIndex: Integer);
    procedure Tick(Sender: TObject);
    procedure FillDisks;
    procedure ProcSelect(Sender: TObject; ARowIndex: Integer);
    procedure KillClick(Sender: TObject);
    procedure KillConfirmed(Sender: TObject);
    procedure LoadPath;
    procedure FillPath;
    procedure PathFromText(const AText: string);
    function PathText: string;
    procedure PathSelect(Sender: TObject; ARowIndex: Integer);
    procedure PathClean(Sender: TObject);
    procedure PathDropMissing(Sender: TObject);
    procedure PathAdd(Sender: TObject);
    procedure PathRemove(Sender: TObject);
    procedure PathUp(Sender: TObject);
    procedure PathDown(Sender: TObject);
    procedure PathSave(Sender: TObject);
    procedure PathSaveConfirmed(Sender: TObject);
    procedure PathUndo(Sender: TObject);
  public
    constructor Create(AOwner: TComponent); override;
    procedure PageRefresh; override;
    destructor Destroy; override;
    procedure PageShown; override;
    procedure PageHidden; override;
  end;

implementation

uses
  System.StrUtils,
  System.Math,
  System.IOUtils,
  Vcl.Dialogs,
  UI.Theme,
  UI.Tokens,
  UI.Button,
  UI.Toast,
  Devbox.Store,
  Devbox.Sys;

const
  CTickMs = 2000;
  CHistLen = 60;
  CTopProcs = 25;
  StateText: array[TPathState] of string = ('ok', 'não existe', 'repetida', 'vazia');

function GB(ABytes: Int64): string;
begin
  Result := Format('%.1f GB', [ABytes / (1024 * 1024 * 1024)]);
end;

function MB(ABytes: Int64): string;
begin
  Result := Format('%.0f MB', [ABytes / (1024 * 1024)]);
end;

function Points(const AValues: TArray<Integer>): string;
var
  V: Integer;
begin
  Result := '';
  for V in AValues do
    Result := Result + IfThen(Result <> '', ',') + IntToStr(V);
end;

constructor TSystemPage.Create(AOwner: TComponent);
const
  TabNames: array[TSysTab] of string = ('Recursos', 'PATH do usuário');
var
  T: TSysTab;
  Cards, Col, Bar: TPanel;
  C: TUIColorTokens;

  function NewSpark(AParent: TWinControl; AColor: TAlphaColor): TUISparkline;
  begin
    Result := TUISparkline.Create(Self);
    Result.Kind := skArea;
    Result.Color := AColor;
    Result.ShowDot := False;
    Result.Height := ScaleValue(40);
    Result.Top := 100000;
    Result.Align := alTop;
    Result.Parent := AParent;
  end;

begin
  inherited Create(AOwner);
  FRefreshable := True;
  Caption := 'Sistema';
  Hint := 'CPU, memória, discos e processos ao vivo; e o PATH do usuário sem pastas mortas';
  C := UITheme.Tokens.Color;
  FSampler := TCpuSampler.Create;
  FProcSel := -1;
  FPathSel := -1;
  FTabs := TUITabs.Create(Self);
  for T := Low(TSysTab) to High(TSysTab) do
    FTabs.AddTab(TabNames[T]);
  FTabs.Align := alTop;
  FTabs.Parent := Self;
  FTabs.OnChange := TabChange;

  // Recursos
  FViews[stResources] := NewView(stResources, 'Atualiza a cada 2 s com a tela aberta. Processos do sistema ' +
    'e do antivírus não aparecem (o Windows não deixa ler).');
  Cards := NewPanel(FViews[stResources], alTop, 160);
  Cards.Padding.SetBounds(0, ScaleValue(6), 0, ScaleValue(10));
  Col := NewPanel(Cards, alLeft);
  Col.Width := ScaleValue(260);
  FCpuStat := TUIStat.Create(Self);
  FCpuStat.CardLabel := 'CPU';
  FCpuStat.Value := '–';
  FCpuStat.Height := ScaleValue(100);
  FCpuStat.Align := alTop;
  FCpuStat.Parent := Col;
  FCpuSpark := NewSpark(Col, C.Primary);
  Col := NewPanel(Cards, alLeft);
  Col.Width := ScaleValue(260);
  Col.Left := 1000;
  Col.Padding.SetBounds(ScaleValue(12), 0, 0, 0);
  FMemStat := TUIStat.Create(Self);
  FMemStat.CardLabel := 'Memória';
  FMemStat.Value := '–';
  FMemStat.Height := ScaleValue(100);
  FMemStat.Align := alTop;
  FMemStat.Parent := Col;
  FMemSpark := NewSpark(Col, C.Success);
  FDisks := NewPanel(Cards, alClient);
  FDisks.Padding.SetBounds(ScaleValue(16), 0, 0, 0);
  Bar := NewPanel(FViews[stResources], alTop, 50);
  Bar.Padding.SetBounds(0, ScaleValue(6), 0, ScaleValue(6));
  NewButton(Bar, 'Encerrar processo', KillClick);
  FProcTable := TUIDataTable.Create(Self);
  FProcTable.SelectionMode := tsmSingle;
  FProcTable.Density := tdCompact;
  FProcTable.OnRowSelect := ProcSelect;
  FProcTable.AddColumn('name', 'Processo', 'name', 260);
  FProcTable.AddColumn('pid', 'PID', 'pid', 90, False, caRight);
  FProcTable.AddColumn('cpu', 'CPU', 'cpu', 90, False, caRight);
  FProcTable.AddColumn('mem', 'Memória', 'mem', 110, False, caRight);
  FProcTable.EmptyStateText := 'Carregando...';
  FProcTable.Top := 100000;
  FProcTable.Align := alClient;
  FProcTable.Parent := FViews[stResources];

  // PATH
  FViews[stPath] := NewView(stPath, 'Só o PATH do usuário muda aqui. Salvar guarda o valor antigo: Desfazer volta. ' +
    'Programas já abertos só veem o PATH novo depois de reabrir.');
  Bar := NewPanel(FViews[stPath], alTop, 50);
  Bar.Padding.SetBounds(0, ScaleValue(6), 0, ScaleValue(6));
  NewButton(Bar, 'Salvar', PathSave, bvPrimary);
  NewButton(Bar, 'Tirar repetidas e vazias', PathClean);
  NewButton(Bar, 'Tirar as que não existem', PathDropMissing);
  NewButton(Bar, 'Desfazer gravação', PathUndo, bvGhost, alRight);
  Bar := NewPanel(FViews[stPath], alTop, 50);
  Bar.Padding.SetBounds(0, ScaleValue(2), 0, ScaleValue(6));
  NewButton(Bar, 'Adicionar pasta…', PathAdd, bvGhost);
  NewButton(Bar, 'Remover', PathRemove, bvGhost);
  NewButton(Bar, 'Subir', PathUp, bvGhost);
  NewButton(Bar, 'Descer', PathDown, bvGhost);
  FPathInfo := NewHint(FViews[stPath], '', alBottom);
  FPathTable := TUIDataTable.Create(Self);
  FPathTable.SelectionMode := tsmSingle;
  FPathTable.Density := tdCompact;
  FPathTable.OnRowSelect := PathSelect;
  FPathTable.AddColumn('n', '#', 'n', 50, False, caRight);
  FPathTable.AddColumn('state', 'Estado', 'state', 110);
  FPathTable.AddColumn('dir', 'Pasta', 'dir', 640);
  FPathTable.SetColType('state', ctBadge);
  FPathTable.AddBadgeMap('state', 'ok', C.SuccessSubtle, C.Success);
  FPathTable.AddBadgeMap('state', 'não existe', C.ErrorSubtle, C.Error);
  FPathTable.AddBadgeMap('state', 'repetida', C.WarningSubtle, C.Warning);
  FPathTable.AddBadgeMap('state', 'vazia', C.BGMuted, C.FGMuted);
  FPathTable.Top := 100000;
  FPathTable.Align := alClient;
  FPathTable.Parent := FViews[stPath];

  FTimer := TTimer.Create(Self);
  FTimer.Interval := CTickMs;
  FTimer.Enabled := False;
  FTimer.OnTimer := Tick;
  FTabs.ActiveIndex := 0;
  TabChange(nil, 0);
  LoadPath;
end;

destructor TSystemPage.Destroy;
begin
  FSampler.Free;
  inherited;
end;

function TSystemPage.NewView(ATab: TSysTab; const AHint: string): TPanel;
begin
  Result := NewPanel(Self, alClient);
  Result.Padding.SetBounds(0, ScaleValue(10), 0, 0);
  Result.Visible := False;
  NewHint(Result, AHint);
end;

procedure TSystemPage.TabChange(Sender: TObject; AIndex: Integer);
var
  T: TSysTab;
begin
  for T := Low(TSysTab) to High(TSysTab) do
    FViews[T].Visible := Ord(T) = AIndex;
end;

procedure TSystemPage.PageShown;
begin
  FTimer.Enabled := True;
  Tick(nil);
  FillDisks;
end;

procedure TSystemPage.PageHidden;
begin
  FTimer.Enabled := False;
end;

{ Recursos }

procedure TSystemPage.Tick(Sender: TObject);
var
  Cpu: Double;
  Used, Total: Int64;
  P: TProcInfo;
begin
  Cpu := FSampler.TotalCpu;
  MemoryInfo(Used, Total);
  FCpuStat.Value := Format('%.0f%%', [Cpu]);
  FMemStat.Value := Format('%.0f%%', [100 * Used / Max(Total, 1)]);
  FMemStat.SubText := GB(Used) + ' de ' + GB(Total);
  FCpuHist := FCpuHist + [Round(Cpu)];
  FMemHist := FMemHist + [Round(100 * Used / Max(Total, 1))];
  if Length(FCpuHist) > CHistLen then
    FCpuHist := Copy(FCpuHist, Length(FCpuHist) - CHistLen, CHistLen);
  if Length(FMemHist) > CHistLen then
    FMemHist := Copy(FMemHist, Length(FMemHist) - CHistLen, CHistLen);
  FCpuSpark.DataPoints := Points(FCpuHist);
  FMemSpark.DataPoints := Points(FMemHist);
  FProcs := FSampler.TopProcesses(CTopProcs);
  FProcTable.BeginRowUpdate;
  try
    FProcTable.ClearMemRows;
    for P in FProcs do
      FProcTable.AddMemRow([P.Name, IntToStr(P.Pid), Format('%.1f%%', [P.CpuPct]), MB(P.MemBytes)]);
  finally
    FProcTable.EndRowUpdate;
  end;
  FProcSel := -1;
end;

procedure TSystemPage.FillDisks;
var
  D: TDiskInfo;
  Row: TPanel;
  L: TUILabel;
  Bar: TUIProgressBar;
begin
  while FDisks.ControlCount > 0 do
    FDisks.Controls[0].Free;
  for D in ListDisks do
  begin
    Row := NewPanel(FDisks, alTop, 34);
    L := TUILabel.Create(Self);
    L.Caption := Format('%s  %s livres de %s', [D.Drive, GB(D.Free), GB(D.Total)]);
    L.AutoSize := False;
    L.Width := ScaleValue(250);
    L.Align := alLeft;
    L.Parent := Row;
    Bar := TUIProgressBar.Create(Self);
    Bar.Max := 100;
    Bar.Value := D.UsedPct;
    Bar.TrackHeight := 8;
    Bar.AlignWithMargins := True;
    Bar.Margins.SetBounds(ScaleValue(8), ScaleValue(12), 0, ScaleValue(12));
    Bar.Align := alClient;
    Bar.Parent := Row;
  end;
  PaintPanels(FDisks);
end;

procedure TSystemPage.ProcSelect(Sender: TObject; ARowIndex: Integer);
begin
  FProcSel := ARowIndex;
end;

procedure TSystemPage.KillClick(Sender: TObject);
begin
  if (FProcSel < 0) or (FProcSel > High(FProcs)) then
    Exit;
  FKillPid := FProcs[FProcSel].Pid;
  TUIToastManager.Show(Format('Encerrar %s (PID %d)? O que não foi salvo nele se perde.',
    [FProcs[FProcSel].Name, FKillPid]), ttWarning, 8000, 'Encerrar', KillConfirmed);
end;

procedure TSystemPage.KillConfirmed(Sender: TObject);
begin
  if KillProcess(FKillPid) then
    TUIToastManager.Show('Processo encerrado', ttSuccess, 2500)
  else
    TUIToastManager.Show('Não deu para encerrar (é do sistema ou de outro usuário)', ttError, 5000);
  Tick(nil);
end;

{ PATH }

procedure TSystemPage.PathFromText(const AText: string);
begin
  FPath := AnalyzePath(AText,
    function(ADir: string): Boolean
    begin
      Result := TDirectory.Exists(ADir);
    end);
end;

function TSystemPage.PathText: string;
var
  E: TPathEntry;
begin
  Result := '';
  for E in FPath do
    Result := Result + IfThen(Result <> '', ';') + E.Raw;
end;

procedure TSystemPage.LoadPath;
begin
  PathFromText(ReadUserPath);
  FPathDirty := False;
  FillPath;
end;

procedure TSystemPage.FillPath;
var
  I, Bad: Integer;
  Machine: TPathEntries;
  E: TPathEntry;
begin
  Bad := 0;
  FPathTable.BeginRowUpdate;
  try
    FPathTable.ClearMemRows;
    for I := 0 to High(FPath) do
    begin
      FPathTable.AddMemRow([IntToStr(I + 1), StateText[FPath[I].State], FPath[I].Raw]);
      if FPath[I].State <> psOk then
        Inc(Bad);
    end;
  finally
    FPathTable.EndRowUpdate;
  end;
  Machine := AnalyzePath(ReadMachinePath,
    function(ADir: string): Boolean
    begin
      Result := TDirectory.Exists(ADir);
    end);
  I := 0;
  for E in Machine do
    if E.State <> psOk then
      Inc(I);
  FPathInfo.Caption := Format('Usuário: %d pastas, %d com problema%s  ·  Máquina (só leitura, precisa de admin): ' +
    '%d pastas, %d com problema', [Length(FPath), Bad, IfThen(FPathDirty, '  ·  NÃO SALVO', ''), Length(Machine), I]);
end;

procedure TSystemPage.PathSelect(Sender: TObject; ARowIndex: Integer);
begin
  FPathSel := ARowIndex;
end;

procedure TSystemPage.PathClean(Sender: TObject);
begin
  PathFromText(CleanPath(FPath, False));
  FPathDirty := True;
  FillPath;
end;

procedure TSystemPage.PathDropMissing(Sender: TObject);
begin
  PathFromText(CleanPath(FPath, True));
  FPathDirty := True;
  FillPath;
end;

procedure TSystemPage.PathAdd(Sender: TObject);
var
  Dlg: TFileOpenDialog;
begin
  Dlg := TFileOpenDialog.Create(nil);
  try
    Dlg.Options := [fdoPickFolders, fdoPathMustExist];
    if not Dlg.Execute then
      Exit;
    PathFromText(PathText + ';' + Dlg.FileName);
    FPathDirty := True;
    FillPath;
  finally
    Dlg.Free;
  end;
end;

procedure TSystemPage.PathRemove(Sender: TObject);
begin
  if (FPathSel < 0) or (FPathSel > High(FPath)) then
    Exit;
  Delete(FPath, FPathSel, 1);
  PathFromText(PathText);
  FPathDirty := True;
  FPathSel := -1;
  FillPath;
end;

procedure TSystemPage.PathUp(Sender: TObject);
var
  E: TPathEntry;
begin
  if (FPathSel <= 0) or (FPathSel > High(FPath)) then
    Exit;
  E := FPath[FPathSel - 1];
  FPath[FPathSel - 1] := FPath[FPathSel];
  FPath[FPathSel] := E;
  PathFromText(PathText);
  FPathDirty := True;
  Dec(FPathSel);
  FillPath;
  FPathTable.SelectRow(FPathSel);
end;

procedure TSystemPage.PathDown(Sender: TObject);
var
  E: TPathEntry;
begin
  if (FPathSel < 0) or (FPathSel >= High(FPath)) then
    Exit;
  E := FPath[FPathSel + 1];
  FPath[FPathSel + 1] := FPath[FPathSel];
  FPath[FPathSel] := E;
  PathFromText(PathText);
  FPathDirty := True;
  Inc(FPathSel);
  FillPath;
  FPathTable.SelectRow(FPathSel);
end;

{ Salvar pede o "sim" no aviso e guarda o PATH antigo para o Desfazer. }
procedure TSystemPage.PathSave(Sender: TObject);
begin
  if not FPathDirty then
  begin
    TUIToastManager.Show('Nada mudou no PATH', ttInfo, 2000);
    Exit;
  end;
  FPendingPath := PathText;
  TUIToastManager.Show(Format('Gravar o PATH do usuário com %d pastas?', [Length(FPath)]), ttWarning, 10000,
    'Gravar', PathSaveConfirmed);
end;

procedure TSystemPage.PathSaveConfirmed(Sender: TObject);
begin
  Store.SetSetting('path_backup', ReadUserPath);
  WriteUserPath(FPendingPath);
  LoadPath;
  TUIToastManager.Show('PATH gravado. Reabra o terminal para ver.', ttSuccess, 4000);
end;

procedure TSystemPage.PathUndo(Sender: TObject);
var
  Old: string;
begin
  Old := Store.GetSetting('path_backup');
  if Old = '' then
  begin
    TUIToastManager.Show('Nenhuma gravação para desfazer', ttInfo, 2500);
    Exit;
  end;
  FPathDirty := True;
  PathFromText(Old);
  FillPath;
  TUIToastManager.Show('PATH antigo carregado. Clique em Salvar para gravar.', ttInfo, 4000);
end;

procedure TSystemPage.PageRefresh;
begin
  Tick(nil);
  FillDisks;
end;

end.
