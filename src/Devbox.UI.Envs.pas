unit Devbox.UI.Envs;

{ Ambientes de projeto: um clique liga distro, containers, terminal, editor e
  navegador do projeto; outro desliga. Os passos aparecem num TUISteps. }

interface

uses
  System.Classes,
  System.SysUtils,
  Vcl.Controls,
  Vcl.ExtCtrls,
  UI.Labels,
  UI.Steps,
  UI.Code,
  UI.DataTable,
  UI.ProgressBar,
  Devbox.Model,
  Devbox.Envs,
  Devbox.UI.Kit;

type
  TEnvsPage = class(TDevPage)
  private
    FTable: TUIDataTable;
    FEnvs: TEnvs;
    FSel: Integer;
    FTitle: TUILabel;
    FSteps: TUISteps;
    FLog: TUICode;
    FProgress: TUIProgressBar;
    FBusy: Boolean;
    procedure Reload;
    function Selected(out AEnv: TEnv): Boolean;
    procedure ShowSteps(const AEnv: TEnv; const ASteps: TEnvSteps);
    procedure Run(const AEnv: TEnv; AStop: Boolean);
    procedure RowSelect(Sender: TObject; ARowIndex: Integer);
    procedure NewClick(Sender: TObject);
    procedure EditClick(Sender: TObject);
    procedure StartClick(Sender: TObject);
    procedure StopClick(Sender: TObject);
    procedure DeleteClick(Sender: TObject);
  public
    constructor Create(AOwner: TComponent); override;
  end;

implementation

uses
  System.StrUtils,
  System.Math,
  System.Threading,
  UI.Button,
  UI.Toast,
  Devbox.Store,
  Devbox.Notify,
  Devbox.UI.Dialogs;

const
  CSample =
    '# Exemplo: troque pelos seus nomes'#13#10 +
    'distro: Ubuntu'#13#10 +
    'container: meu-postgres @Ubuntu'#13#10 +
    'esperar: localhost:5432'#13#10 +
    'terminal: C:\projetos\api | npm run dev'#13#10 +
    'editor: C:\projetos\api'#13#10 +
    'abrir: http://localhost:3000'#13#10;

constructor TEnvsPage.Create(AOwner: TComponent);
var
  Bar, Right: TPanel;
begin
  inherited Create(AOwner);
  Caption := 'Ambientes de projeto';
  Hint := 'Liga tudo de um projeto num clique: distro, containers, terminal, editor e navegador';
  FSel := -1;

  Bar := NewPanel(Self, alTop, 50);
  Bar.Padding.SetBounds(0, 0, 0, ScaleValue(8));
  NewButton(Bar, 'Ligar', StartClick, bvPrimary);
  NewButton(Bar, 'Desligar', StopClick);
  NewButton(Bar, 'Novo ambiente', NewClick, bvGhost);
  NewButton(Bar, 'Editar', EditClick, bvGhost);
  NewButton(Bar, 'Excluir', DeleteClick, bvGhost, alRight);
  FProgress := TUIProgressBar.Create(Self);
  FProgress.Indeterminate := True;
  FProgress.TrackHeight := 3;
  FProgress.Height := 3;
  FProgress.Visible := False;
  FProgress.Top := 100000;
  FProgress.Align := alTop;
  FProgress.Parent := Self;

  Right := NewPanel(Self, alRight);
  Right.Width := ScaleValue(460);
  Right.Padding.SetBounds(ScaleValue(14), 0, 0, 0);
  FTitle := TUILabel.Create(Self);
  FTitle.Caption := 'Escolha um ambiente';
  FTitle.Bold := True;
  FTitle.AutoSize := False;
  FTitle.Height := ScaleValue(28);
  FTitle.Align := alTop;
  FTitle.Parent := Right;
  FSteps := TUISteps.Create(Self);
  FSteps.Height := ScaleValue(120);
  FSteps.Top := 100000;
  FSteps.Align := alTop;
  FSteps.Parent := Right;
  FLog := TUICode.Create(Self);
  FLog.FontSize := 11;
  FLog.Top := 100000;
  FLog.Align := alClient;
  FLog.Parent := Right;

  FTable := TUIDataTable.Create(Self);
  FTable.SelectionMode := tsmSingle;
  FTable.Density := tdCompact;
  FTable.OnRowSelect := RowSelect;
  FTable.AddColumn('name', 'Ambiente', 'name', 220);
  FTable.AddColumn('steps', 'Passos', 'steps', 70, False, caRight);
  FTable.AddColumn('what', 'Liga', 'what', 300);
  FTable.EmptyStateText := 'Nenhum ambiente. Clique em Novo ambiente.';
  FTable.Top := 100000;
  FTable.Align := alClient;
  FTable.Parent := Self;
  Reload;
end;

procedure TEnvsPage.Reload;
var
  E: TEnv;
  Steps: TEnvSteps;
  S: TEnvStep;
  Error, What: string;
begin
  FEnvs := Store.ListEnvs;
  FTable.BeginRowUpdate;
  try
    FTable.ClearMemRows;
    for E in FEnvs do
    begin
      ParseEnvScript(E.Script, Steps, Error);
      What := '';
      for S in Steps do
        if S.Kind in [eskDistro, eskContainer] then
          What := What + IfThen(What <> '', ', ') + IfThen(S.Kind = eskDistro, S.Value, S.Target);
      FTable.AddMemRow([E.Name, IntToStr(Length(Steps)), What]);
    end;
  finally
    FTable.EndRowUpdate;
  end;
  FSel := -1;
end;

function TEnvsPage.Selected(out AEnv: TEnv): Boolean;
begin
  Result := (FSel >= 0) and (FSel <= High(FEnvs));
  if Result then
    AEnv := FEnvs[FSel];
end;

procedure TEnvsPage.ShowSteps(const AEnv: TEnv; const ASteps: TEnvSteps);
var
  S: TEnvStep;
begin
  FTitle.Caption := AEnv.Name;
  FSteps.Steps.Clear;
  for S in ASteps do
    FSteps.AddStep(S.Caption, '');
  FSteps.ActiveStep := 0;
  FSteps.Invalidate;
end;

procedure TEnvsPage.RowSelect(Sender: TObject; ARowIndex: Integer);
var
  E: TEnv;
  Steps: TEnvSteps;
  Error: string;
begin
  FSel := ARowIndex;
  if FBusy or not Selected(E) then
    Exit;
  ParseEnvScript(E.Script, Steps, Error);
  ShowSteps(E, Steps);
  FLog.Text := StringReplace(E.Script, #13, '', [rfReplaceAll]);
end;

{ Roda os passos em ordem numa thread; cada passo concluído avança o TUISteps.
  Passo que falha não para os outros: o resto pode não depender dele. }
procedure TEnvsPage.Run(const AEnv: TEnv; AStop: Boolean);
var
  Steps: TEnvSteps;
  Error: string;
  Env: TEnv;
begin
  if FBusy then
    Exit;
  if not ParseEnvScript(AEnv.Script, Steps, Error) then
  begin
    TUIToastManager.Show(Error, ttError, 5000);
    Exit;
  end;
  if AStop then
  begin
    Steps := StopSteps(Steps);
    // Desligar: container para e distro desliga, em vez de subir.
    if Steps = nil then
    begin
      TUIToastManager.Show('Nada para desligar neste ambiente', ttInfo, 3000);
      Exit;
    end;
  end;
  Env := AEnv;
  ShowSteps(Env, Steps);
  if AStop then
    FTitle.Caption := 'Desligando ' + Env.Name
  else
    FTitle.Caption := 'Ligando ' + Env.Name;
  FLog.Text := '';
  FBusy := True;
  FProgress.Visible := True;
  TTask.Run(
    procedure
    var
      I, Failed: Integer;
      Ok: Boolean;
      Msg: string;
      S: TEnvStep;
    begin
      Failed := 0;
      for I := 0 to High(Steps) do
      begin
        S := Steps[I];
        try
          if AStop then
            Ok := RunStopStep(S, Msg)
          else
            Ok := RunEnvStep(S, Msg);
        except
          on E: Exception do
          begin
            Ok := False;
            Msg := E.Message;
          end;
        end;
        if not Ok then
          Inc(Failed);
        // Synchronize (e não Queue): o laço captura I e S por referência;
        // esperar a tela usar garante que ela vê os valores desta volta.
        System.Classes.TThread.Synchronize(nil,
          procedure
          begin
            FSteps.ActiveStep := I + 1;
            FLog.Text := FLog.Text + IfThen(Ok, '✓ ', '✗ ') + S.Caption +
              IfThen((Msg <> '') and (Msg <> 'ok'), '  ·  ' + Copy(Msg, 1, 200), '') + #10;
          end);
      end;
      System.Classes.TThread.Queue(nil,
        procedure
        begin
          FBusy := False;
          FProgress.Visible := False;
          if Failed = 0 then
            Notify(Env.Name + IfThen(AStop, ' desligado', ' pronto'), Format('%d passos ok', [Length(Steps)]))
          else
            Notify(Env.Name + ': ' + IntToStr(Failed) + ' passos falharam', 'Veja o log na tela Ambientes', True);
        end);
    end);
end;

procedure TEnvsPage.NewClick(Sender: TObject);
var
  E: TEnv;
begin
  E := Default(TEnv);
  E.Script := CSample;
  if not EditEnv(E) then
    Exit;
  Store.SaveEnv(E);
  Reload;
end;

procedure TEnvsPage.EditClick(Sender: TObject);
var
  E: TEnv;
begin
  if not Selected(E) or not EditEnv(E) then
    Exit;
  Store.SaveEnv(E);
  Reload;
end;

procedure TEnvsPage.StartClick(Sender: TObject);
var
  E: TEnv;
begin
  if Selected(E) then
    Run(E, False)
  else
    TUIToastManager.Show('Escolha um ambiente da lista', ttInfo, 2500);
end;

procedure TEnvsPage.StopClick(Sender: TObject);
var
  E: TEnv;
begin
  if Selected(E) then
    Run(E, True);
end;

procedure TEnvsPage.DeleteClick(Sender: TObject);
var
  E: TEnv;
begin
  if not Selected(E) then
    Exit;
  Store.DeleteEnv(E.Id);
  Reload;
end;

end.
