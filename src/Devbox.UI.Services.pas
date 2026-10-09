unit Devbox.UI.Services;

{ Containers (Docker no Windows e Podman/Docker nas distros WSL ligadas),
  distros WSL e portas TCP em escuta. }

interface

uses
  System.Classes,
  System.SysUtils,
  Vcl.Controls,
  Vcl.ExtCtrls,
  UI.Labels,
  UI.Tabs,
  UI.Code,
  UI.Stat,
  UI.ScrollArea,
  UI.DataTable,
  UI.ProgressBar,
  Devbox.Model,
  Devbox.Jobs,
  Devbox.UI.SidePeek,
  Devbox.UI.Kit;

type
  TServiceTab = (stContainers, stWsl, stPorts);
  TWatchRequestEvent = procedure(AKind: TWatchKind; const ATarget, ACli, ACaption: string) of object;

  TServicesPage = class(TDevPage)
  private
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
    FLogPeek: TSidePeek;
    FLogTitle: TUILabel;
    FLogScroll: TUIScrollArea;
    FLog: TUICode;
    FKillPid: Cardinal;
    FOnWatchRequest: TWatchRequestEvent;
    procedure CardsResize(Sender: TObject);
    procedure WatchContainer(Sender: TObject);
    procedure WatchPort(Sender: TObject);
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
  public
    constructor Create(AOwner: TComponent); override;
    procedure PageRefresh; override;
    procedure PageShown; override;
    procedure PageHidden; override;
    function PageContext: string; override;
    { "Avisar quando parar": a tela de Avisos é quem vigia. }
    property OnWatchRequest: TWatchRequestEvent read FOnWatchRequest write FOnWatchRequest;
  end;

implementation

uses
  Vcl.Forms,
  System.StrUtils,
  System.Math,
  System.Threading,
  UI.Theme,
  UI.Tokens,
  UI.Button,
  UI.Toast,
  Devbox.AI,
  Devbox.UI.DialogBase,
  Devbox.Sys;

const
  CRefreshMs = 30000;  // cada volta roda ~1,5 s de wsl por distro ligada
  CLogLines = 200;
  CLogPeekW = 680;

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

procedure TServicesPage.CardsResize(Sender: TObject);
var
  LCards: TPanel;
  LIndex, LGap, LWidth: Integer;
begin
  LCards := TPanel(Sender);
  LGap := ScaleValue(12);
  LWidth := (LCards.ClientWidth - LGap * High(FStats)) div Length(FStats);
  for LIndex := 0 to High(FStats) do
    FStats[LIndex].SetBounds(LIndex * (LWidth + LGap), 0, LWidth,
      LCards.ClientHeight - LCards.Padding.Bottom);
end;

constructor TServicesPage.Create(AOwner: TComponent);
const
  StatLabels: array[0..3] of string = ('Containers', 'Distros WSL', 'Portas em escuta', 'Motores');
  CStatTones: array[0..3] of TUISemanticTone = (stPrimary, stInfo, stPrimary, stSuccess);
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
  inherited Create(AOwner);
  FRefreshable := True;
  Caption := 'Serviços';
  Hint := 'Containers, distros WSL e portas em escuta nesta máquina';
  C := UITheme.Tokens.Color;
  Page := Self;

  Cards := NewPanel(Page, alTop, 124);
  Cards.Padding.SetBounds(0, 0, 0, ScaleValue(12));
  for I := 0 to High(FStats) do
  begin
    FStats[I] := TUIStat.Create(Self);
    FStats[I].CardLabel := StatLabels[I];
    FStats[I].Value := '–';
    FStats[I].Tone := CStatTones[I];
    FStats[I].Left := (I + 1) * 1000;
    FStats[I].Parent := Cards;
  end;
  // Os 4 cards dividem a largura (antes tinham largura fixa e o último saía cortado).
  Cards.OnResize := CardsResize;

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
    FToolbars[T] := Bar;
    FSel[T] := -1;
  end;
  NewButton(FToolbars[stContainers], 'Iniciar', ContainerStart);
  NewButton(FToolbars[stContainers], 'Parar', ContainerStop);
  NewButton(FToolbars[stContainers], 'Reiniciar', ContainerRestart);
  NewButton(FToolbars[stContainers], 'Ver logs', ContainerLogs);
  NewButton(FToolbars[stContainers], 'Avisar quando parar', WatchContainer, bvGhost);
  NewButton(FToolbars[stWsl], 'Abrir terminal', DistroOpen);
  NewButton(FToolbars[stWsl], 'Desligar', DistroTerminate);
  NewButton(FToolbars[stWsl], 'Desligar o WSL todo', WslShutdown, bvGhost);
  NewButton(FToolbars[stPorts], 'Abrir no navegador', PortOpen);
  NewButton(FToolbars[stPorts], 'Encerrar processo', PortKill);
  NewButton(FToolbars[stPorts], 'Avisar quando fechar', WatchPort, bvGhost);

  // Logs do container: painel de baixo, fecha no X.
  // Logs abrem no painel ao lado da janela (FLogPeek, no primeiro "Ver logs").
  FLogPanel := NewPanel(Page, alClient);
  FLogPanel.Parent := nil;
  Bar := NewPanel(FLogPanel, alTop, 36);
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
  FRefreshTimer := TTimer.Create(Self);
  FRefreshTimer.Enabled := False;
  FRefreshTimer.Interval := CRefreshMs;
  FRefreshTimer.OnTimer := RefreshTimerTick;
end;

procedure TServicesPage.PageShown;
begin
  FRefreshTimer.Enabled := True;
  RefreshServices;
end;

procedure TServicesPage.PageHidden;
begin
  FRefreshTimer.Enabled := False;
  if FLogPeek <> nil then
    FLogPeek.Close_;
end;

{ Docker, WSL e portas numa thread só; a tela atualiza no fim. }
procedure TServicesPage.RefreshServices;
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
      Ports := nil;
      // Exceção no TTask some sem aviso e deixaria FBusy preso: a tela nunca
      // mais atualizaria. Com erro, mostra o que deu para ler.
      try
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
      except
        on E: Exception do
          Engines := Engines + ['erro: ' + E.Message];
      end;
      QueueUI(
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

procedure TServicesPage.ServicesLoaded;
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

procedure TServicesPage.RefreshClick(Sender: TObject);
begin
  RefreshServices;
end;

procedure TServicesPage.RefreshTimerTick(Sender: TObject);
begin
  if Showing then
    RefreshServices;
end;

procedure TServicesPage.ServiceTabChange(Sender: TObject; AIndex: Integer);
var
  T: TServiceTab;
begin
  for T := Low(TServiceTab) to High(TServiceTab) do
  begin
    FToolbars[T].Visible := Ord(T) = AIndex;
    FTables[T].Visible := Ord(T) = AIndex;
  end;
end;

procedure TServicesPage.RowSelect(Sender: TObject; ARowIndex: Integer);
begin
  FSel[TServiceTab(TComponent(Sender).Tag)] := ARowIndex;
end;

{ A linha da tabela guarda o nome na coluna 0: acha o registro por ele, que a
  ordem da tabela pode ter mudado pelo clique no cabeçalho. }
function TServicesPage.SelectedContainer(out AContainer: TContainer): Boolean;
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

function TServicesPage.SelectedDistro(out ADistro: TDistro): Boolean;
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

function TServicesPage.SelectedPort(out APort: TListenPort): Boolean;
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

procedure TServicesPage.RunAndRefresh(const ACmdLine, ADoneMessage: string);
begin
  FProgress.Visible := True;
  TTask.Run(
    procedure
    var
      Output: string;
      Code: Integer;
    begin
      Code := RunCapture(ACmdLine, Output, 60000);
      QueueUI(
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

procedure TServicesPage.ContainerStart(Sender: TObject);
var
  C: TContainer;
begin
  if SelectedContainer(C) then
    RunAndRefresh(C.Cli + ' start ' + C.Id, C.Name + ' iniciado');
end;

procedure TServicesPage.ContainerStop(Sender: TObject);
var
  C: TContainer;
begin
  if SelectedContainer(C) then
    RunAndRefresh(C.Cli + ' stop ' + C.Id, C.Name + ' parado');
end;

procedure TServicesPage.ContainerRestart(Sender: TObject);
var
  C: TContainer;
begin
  if SelectedContainer(C) then
    RunAndRefresh(C.Cli + ' restart ' + C.Id, C.Name + ' reiniciado');
end;

procedure TServicesPage.ContainerLogs(Sender: TObject);
var
  C: TContainer;
  Id, Name, Cli: string;
begin
  if not SelectedContainer(C) then
    Exit;
  Id := C.Id;
  Name := C.Name;
  Cli := C.Cli;
  FLogTitle.Caption := 'Últimas ' + IntToStr(CLogLines) + ' linhas';
  FLog.Text := 'carregando...';
  if FLogPeek = nil then
  begin
    FLogPeek := TSidePeek.CreatePeek(GetParentForm(Self), CLogPeekW);
    FLogPanel.Parent := FLogPeek.Body;
  end;
  FLogPeek.Title := 'Logs de ' + Name;
  FLogPeek.Open;
  TTask.Run(
    procedure
    var
      Output: string;
    begin
      RunCapture(Format('%s logs --tail %d %s', [Cli, CLogLines, Id]), Output);
      QueueUI(
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

procedure TServicesPage.WatchContainer(Sender: TObject);
var
  C: TContainer;
begin
  if SelectedContainer(C) and Assigned(FOnWatchRequest) then
    FOnWatchRequest(wkContainer, C.Id, C.Cli, 'Container ' + C.Name);
end;

procedure TServicesPage.WatchPort(Sender: TObject);
var
  P: TListenPort;
begin
  if SelectedPort(P) and Assigned(FOnWatchRequest) then
    FOnWatchRequest(wkPort, IntToStr(P.Port), '', Format('Porta %d (%s)', [P.Port, P.Process]));
end;

function TServicesPage.PageContext: string;
const
  CMaxChars = 6000;
begin
  Result := '';
  if (FLogPeek <> nil) and FLogPeek.IsOpen then
    Result := FLogPeek.Title + ' (fim do log, mais novo embaixo):' + sLineBreak +
      Copy(FLog.Text, Max(1, Length(FLog.Text) - CMaxChars), CMaxChars);
end;

procedure TServicesPage.LogClose(Sender: TObject);
begin
  if FLogPeek <> nil then
    FLogPeek.Close_;
end;

procedure TServicesPage.DistroOpen(Sender: TObject);
var
  D: TDistro;
begin
  if SelectedDistro(D) then
    Launch('wsl.exe', '-d ' + D.Name + ' --cd ~');
end;

procedure TServicesPage.DistroTerminate(Sender: TObject);
var
  D: TDistro;
begin
  if SelectedDistro(D) then
    RunAndRefresh('wsl.exe --terminate ' + D.Name, D.Name + ' desligada');
end;

procedure TServicesPage.WslShutdown(Sender: TObject);
begin
  RunAndRefresh('wsl.exe --shutdown', 'WSL desligado');
end;

procedure TServicesPage.PortOpen(Sender: TObject);
var
  P: TListenPort;
begin
  if SelectedPort(P) then
    OpenUrl(Format('http://localhost:%d', [P.Port]));
end;

{ Encerrar pede confirmação no próprio aviso: o botão do toast é o "sim". }
procedure TServicesPage.PortKill(Sender: TObject);
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

procedure TServicesPage.PortKillConfirmed(Sender: TObject);
begin
  if KillProcess(FKillPid) then
    TUIToastManager.Show('Processo encerrado', ttSuccess, 2500)
  else
    TUIToastManager.Show('Não deu para encerrar. Ele pode ser de outro usuário ou do sistema.', ttError, 6000);
  FKillPid := 0;
  RefreshServices;
end;


procedure TServicesPage.PageRefresh;
begin
  RefreshServices;
end;

end.
