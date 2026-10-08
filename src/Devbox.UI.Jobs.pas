unit Devbox.UI.Jobs;

{ Agendador: comandos que rodam a cada N minutos, todo dia ou em dias da
  semana, com o histórico das execuções numa linha do tempo. Roda com o
  Devbox aberto; tarefa perdida (app fechado na hora) roda ao abrir. }

interface

uses
  System.Classes,
  System.SysUtils,
  System.Generics.Collections,
  Vcl.Controls,
  Vcl.ExtCtrls,
  UI.Labels,
  UI.Code,
  UI.ScrollArea,
  UI.Timeline,
  UI.DataTable,
  Devbox.Jobs,
  Devbox.UI.Kit;

type
  TJobsPage = class(TDevPage)
  private
    FTable: TUIDataTable;
    FJobs: TJobs;
    FSel: Integer;
    FRunning: TDictionary<Integer, Boolean>;
    FTimer: TTimer;
    FRunsTitle: TUILabel;
    FRunsScroll: TUIScrollArea;
    FTimeline: TUITimeline;
    FOutput: TUICode;
    procedure Reload;
    procedure FillRuns;
    function SelectedJob(out AJob: TJob): Boolean;
    procedure RunJob(const AJob: TJob);
    procedure TimerTick(Sender: TObject);
    procedure RowSelect(Sender: TObject; ARowIndex: Integer);
    procedure RowDblClick(Sender: TObject; ARowIdx: Integer);
    procedure NewClick(Sender: TObject);
    procedure EditClick(Sender: TObject);
    procedure RunNowClick(Sender: TObject);
    procedure ToggleClick(Sender: TObject);
    procedure DeleteClick(Sender: TObject);
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure PageShown; override;
  end;

implementation

uses
  Winapi.Windows,
  System.StrUtils,
  System.Math,
  System.DateUtils,
  System.Threading,
  UI.Theme,
  UI.Tokens,
  UI.Button,
  UI.Toast,
  Devbox.Store,
  Devbox.Sys,
  Devbox.Notify,
  Devbox.UI.Dialogs;

const
  CCheckMs = 20000;
  CJobTimeoutMs = 30 * 60 * 1000;
  COutputLines = 40;
  CTimelineRuns = 15;

function WhenShort(AWhen: TDateTime): string;
begin
  if AWhen <= 0 then
    Result := '–'
  else if DateOf(AWhen) = Date then
    Result := 'hoje ' + FormatDateTime('hh:nn', AWhen)
  else if DateOf(AWhen) = Date + 1 then
    Result := 'amanhã ' + FormatDateTime('hh:nn', AWhen)
  else if DateOf(AWhen) = Date - 1 then
    Result := 'ontem ' + FormatDateTime('hh:nn', AWhen)
  else
    Result := FormatDateTime('dd/mm hh:nn', AWhen);
end;

constructor TJobsPage.Create(AOwner: TComponent);
var
  Bar, Right: TPanel;
  C: TUIColorTokens;
begin
  inherited Create(AOwner);
  Caption := 'Agendador';
  Hint := 'Comandos que rodam sozinhos. Falhou, avisa na bandeja.';
  C := UITheme.Tokens.Color;
  FRunning := TDictionary<Integer, Boolean>.Create;
  FSel := -1;

  Bar := NewPanel(Self, alTop, 50);
  Bar.Padding.SetBounds(0, 0, 0, ScaleValue(8));
  NewButton(Bar, 'Nova tarefa', NewClick, bvPrimary);
  NewButton(Bar, 'Editar', EditClick);
  NewButton(Bar, 'Rodar agora', RunNowClick);
  NewButton(Bar, 'Ligar/desligar', ToggleClick, bvGhost);
  NewButton(Bar, 'Excluir', DeleteClick, bvGhost, alRight);

  Right := NewPanel(Self, alRight);
  Right.Width := ScaleValue(340);
  Right.Padding.SetBounds(ScaleValue(14), 0, 0, 0);
  FRunsTitle := TUILabel.Create(Self);
  FRunsTitle.Caption := 'Últimas execuções';
  FRunsTitle.Bold := True;
  FRunsTitle.AutoSize := False;
  FRunsTitle.Height := ScaleValue(26);
  FRunsTitle.Align := alTop;
  FRunsTitle.Parent := Right;
  FOutput := TUICode.Create(Self);
  FOutput.FontSize := 11;
  FOutput.Height := ScaleValue(200);
  FOutput.Align := alBottom;
  FOutput.Parent := Right;
  FRunsScroll := TUIScrollArea.Create(Self);
  FRunsScroll.Top := 100000;
  FRunsScroll.Align := alClient;
  FRunsScroll.Parent := Right;
  FTimeline := TUITimeline.Create(Self);
  FTimeline.Align := alTop;
  FTimeline.Parent := FRunsScroll.InnerPanel;

  FTable := TUIDataTable.Create(Self);
  FTable.SelectionMode := tsmSingle;
  FTable.Density := tdCompact;
  FTable.OnRowSelect := RowSelect;
  FTable.OnRowDblClick := RowDblClick;
  FTable.AddColumn('name', 'Tarefa', 'name', 170);
  FTable.AddColumn('when', 'Quando', 'when', 140);
  FTable.AddColumn('next', 'Próxima', 'next', 100);
  FTable.AddColumn('last', 'Última', 'last', 100);
  FTable.AddColumn('state', 'Resultado', 'state', 90);
  FTable.SetColType('state', ctBadge);
  FTable.AddBadgeMap('state', 'ok', C.SuccessSubtle, C.Success);
  FTable.AddBadgeMap('state', 'falhou', C.ErrorSubtle, C.Error);
  FTable.AddBadgeMap('state', 'rodando', C.InfoSubtle, C.Info);
  FTable.AddBadgeMap('state', 'desligada', C.BGMuted, C.FGMuted);
  FTable.AddBadgeMap('state', 'nunca', C.BGMuted, C.FGMuted);
  FTable.EmptyStateText := 'Nenhuma tarefa. Ex.: backup do banco todo dia às 18:00.';
  FTable.Top := 100000;
  FTable.Align := alClient;
  FTable.Parent := Self;

  Reload;
  FTimer := TTimer.Create(Self);
  FTimer.Interval := CCheckMs;
  FTimer.OnTimer := TimerTick;
  FTimer.Enabled := True;
  // Na largada também: pega as que passaram da hora com o app fechado.
  System.Classes.TThread.ForceQueue(nil,
    procedure
    begin
      TimerTick(nil);
    end);
end;

destructor TJobsPage.Destroy;
begin
  FRunning.Free;
  inherited;
end;

procedure TJobsPage.PageShown;
begin
  Reload;
end;

procedure TJobsPage.Reload;
var
  J: TJob;
  State: string;
begin
  FJobs := Store.ListJobs;
  FTable.BeginRowUpdate;
  try
    FTable.ClearMemRows;
    for J in FJobs do
    begin
      if FRunning.ContainsKey(J.Id) then
        State := 'rodando'
      else if not J.Enabled then
        State := 'desligada'
      else if J.LastExit < 0 then
        State := 'nunca'
      else if J.LastExit = 0 then
        State := 'ok'
      else
        State := 'falhou';
      FTable.AddMemRow([J.Name, J.WhenText, IfThen(J.Enabled, WhenShort(J.NextRun), '–'),
        WhenShort(J.LastRun), State]);
    end;
  finally
    FTable.EndRowUpdate;
  end;
  if FSel > High(FJobs) then
    FSel := -1;
  FillRuns;
end;

procedure TJobsPage.FillRuns;
var
  J: TJob;
  R: TJobRun;
  Runs: TJobRuns;
  Name: string;
  Names: TDictionary<Integer, string>;
begin
  Names := TDictionary<Integer, string>.Create;
  try
    for J in FJobs do
      Names.AddOrSetValue(J.Id, J.Name);
    if SelectedJob(J) then
    begin
      Runs := Store.ListJobRuns(J.Id, CTimelineRuns);
      FRunsTitle.Caption := 'Execuções de ' + J.Name;
    end
    else
    begin
      Runs := Store.ListJobRuns(0, CTimelineRuns);
      FRunsTitle.Caption := 'Últimas execuções';
    end;
    FTimeline.ClearEvents;
    for R in Runs do
    begin
      if not Names.TryGetValue(R.JobId, Name) then
        Name := '?';
      FTimeline.AddEvent(FormatDateTime('dd/mm hh:nn', R.Started),
        Name + IfThen(R.ExitCode = 0, ' · ok', Format(' · falhou (%d)', [R.ExitCode])),
        Format('%.1f s', [R.DurationMs / 1000]), '',
        TUISemanticTone(IfThen(R.ExitCode = 0, Ord(stSuccess), Ord(stError))));
    end;
    if Runs <> nil then
      FOutput.Text := StringReplace(TailLines(Runs[0].Output, 12), #13, '', [rfReplaceAll])
    else
      FOutput.Text := 'Nenhuma execução ainda';
  finally
    Names.Free;
  end;
end;

function TJobsPage.SelectedJob(out AJob: TJob): Boolean;
begin
  Result := (FSel >= 0) and (FSel <= High(FJobs));
  if Result then
    AJob := FJobs[FSel];
end;

procedure TJobsPage.RowSelect(Sender: TObject; ARowIndex: Integer);
begin
  FSel := ARowIndex;
  FillRuns;
end;

procedure TJobsPage.RowDblClick(Sender: TObject; ARowIdx: Integer);
begin
  EditClick(nil);
end;

{ Roda em segundo plano; no fim grava o histórico, agenda a próxima e avisa. }
procedure TJobsPage.RunJob(const AJob: TJob);
var
  Job: TJob;
begin
  if FRunning.ContainsKey(AJob.Id) then
    Exit;
  Job := AJob;
  FRunning.Add(Job.Id, True);
  Reload;
  TTask.Run(
    procedure
    var
      Output: string;
      Code: Integer;
      Start: TDateTime;
      Ticks: UInt64;
    begin
      Start := Now;
      Ticks := GetTickCount64;
      // Exceção dentro do TTask some sem aviso: aqui vira uma execução com falha.
      try
        Code := RunCapture('cmd.exe /c ' + Job.Command, Output, CJobTimeoutMs, Job.WorkDir);
      except
        on E: Exception do
        begin
          Code := -3;
          Output := E.Message;
        end;
      end;
      if Code = -1 then
        Output := 'Não deu para iniciar o comando';
      if Code = -2 then
        Output := Output + #13#10'(parado: passou de 30 minutos)';
      QueueUI(
        procedure
        var
          Run: TJobRun;
        begin
          Run.JobId := Job.Id;
          Run.Started := Start;
          Run.DurationMs := GetTickCount64 - Ticks;
          Run.ExitCode := Code;
          Run.Output := TailLines(Output, COutputLines);
          Store.AddJobRun(Run);
          Store.SetJobRunInfo(Job.Id, NextRunAfter(Job, Now), Start, Code);
          FRunning.Remove(Job.Id);
          if Code <> 0 then
            Notify('Tarefa falhou: ' + Job.Name, TailLines(Output, 3), True)
          else if Job.NotifyOk then
            Notify('Tarefa pronta: ' + Job.Name, TailLines(Output, 3));
          Reload;
        end);
    end);
end;

procedure TJobsPage.TimerTick(Sender: TObject);
var
  J: TJob;
begin
  for J in Store.ListJobs do
    if J.Enabled and (J.NextRun > 0) and (J.NextRun <= Now) then
      RunJob(J);
end;

procedure TJobsPage.NewClick(Sender: TObject);
var
  J: TJob;
begin
  J := Default(TJob);
  J.Kind := jkDaily;
  J.EveryMin := 60;
  J.AtMin := 18 * 60;
  J.Weekdays := $3E;  // seg a sex
  J.Enabled := True;
  J.LastExit := -1;
  if not EditJob(J) then
    Exit;
  J.NextRun := NextRunAfter(J, Now);
  Store.SaveJob(J);
  Reload;
  TUIToastManager.Show('Tarefa criada. Próxima: ' + WhenShort(J.NextRun), ttSuccess, 3000);
end;

procedure TJobsPage.EditClick(Sender: TObject);
var
  J: TJob;
begin
  if not SelectedJob(J) then
    Exit;
  if not EditJob(J) then
    Exit;
  J.NextRun := NextRunAfter(J, Now);
  Store.SaveJob(J);
  Reload;
end;

procedure TJobsPage.RunNowClick(Sender: TObject);
var
  J: TJob;
begin
  if SelectedJob(J) then
    RunJob(J);
end;

procedure TJobsPage.ToggleClick(Sender: TObject);
var
  J: TJob;
begin
  if not SelectedJob(J) then
    Exit;
  J.Enabled := not J.Enabled;
  J.NextRun := NextRunAfter(J, Now);
  Store.SaveJob(J);
  Reload;
end;

procedure TJobsPage.DeleteClick(Sender: TObject);
var
  J: TJob;
begin
  if not SelectedJob(J) then
    Exit;
  Store.DeleteJob(J.Id);
  FSel := -1;
  Reload;
  TUIToastManager.Show('Tarefa excluída: ' + J.Name, ttSuccess, 2500);
end;

end.
