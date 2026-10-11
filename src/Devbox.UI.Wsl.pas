unit Devbox.UI.Wsl;

{ Ambiente › WSL: distros com o tamanho do disco e ações (padrão, desligar, backup,
  compactar), o .wslconfig em linhas explicadas e a manutenção (desligar, liberar
  memória, trim, reiniciar o serviço, atualizar). Os comandos rodam fora da tela. }

interface

uses
  System.Classes,
  System.SysUtils,
  Vcl.Controls,
  Vcl.ExtCtrls,
  UI.Labels,
  UI.Tabs,
  UI.Input,
  UI.Select,
  UI.Toggle,
  UI.DataTable,
  UI.ScrollArea,
  UI.ProgressBar,
  UI.Code,
  Devbox.Wsl,
  Devbox.UI.Kit;

type
  TWslPage = class(TDevPage)
  private
    FTabs: TUITabs;
    FViews: array[0..2] of TControl;
    FTable: TUIDataTable;
    FDistros: TWslDistros;
    FProgress: TUIProgressBar;
    FStatus: TUILabel;
    FBusy: Boolean;
    FPending: Integer;           // distro esperando o "sim" do aviso (compactar)
    // .wslconfig
    FMemory, FProcessors, FSwap: TUIInput;
    FReclaim, FNetwork: TUISelect;
    FSparse, FDnsTunnel: TUIToggle;
    FVersion: TUICode;
    procedure TabChange(Sender: TObject; AIndex: Integer);
    procedure Reload;
    procedure LoadConfig;
    procedure ActionClick(Sender: TObject; ARowIdx, AActionIdx: Integer);
    procedure CompactConfirmed(Sender: TObject);
    procedure SaveConfigClick(Sender: TObject);
    procedure ShutdownClick(Sender: TObject);
    procedure DropCachesClick(Sender: TObject);
    procedure TrimClick(Sender: TObject);
    procedure RestartServiceClick(Sender: TObject);
    procedure UpdateClick(Sender: TObject);
    { Roda AWork fora da tela; ADone recebe o texto do resultado. }
    procedure RunBusy(const AStatus: string; const AWork: TFunc<string>; const ADone: TProc<string> = nil);
  public
    constructor Create(AOwner: TComponent); override;
    procedure PageShown; override;
    procedure PageRefresh; override;
    function PageContext: string; override;
  end;

implementation

uses
  System.Math,
  System.StrUtils,
  System.IOUtils,
  UI.Button,
  UI.Card,
  UI.Toast,
  UI.Tokens,
  UI.Theme,
  Devbox.Cleanup,
  Devbox.Store;

const
  CTabNames: array[0..2] of string = ('Distros', 'Configuração', 'Manutenção');
  CReclaimValues: array[0..2] of string = ('disabled', 'gradual', 'dropcache');
  CNetworkValues: array[0..1] of string = ('nat', 'mirrored');
  CInputW = 220;
  CSelectW = 300;
  CToggleW = 60;
  CButtonW = 220;
  ActionExport = 'M12 4v11 M7.5 10.5 12 15l4.5-4.5 M5 19h14';
  ActionCompact = 'M4 9h5V4 M20 9h-5V4 M4 15h5v5 M20 15h-5v5';

constructor TWslPage.Create(AOwner: TComponent);
var
  LIndex: Integer;
  LScroll: TUIScrollArea;
  LCard: TUICard;
  LHost, LBar: TPanel;
  LView: TPanel;
  C: TUIColorTokens;

  function Input(AHost: TPanel; const AHint: string): TUIInput;
  begin
    Result := TUIInput.Create(Self);
    Result.LabelMode := ilmBorder;
    Result.LabelText := AHint;
    Result.ReserveHintSpace := False;
    Result.Align := alClient;
    Result.Parent := AHost;
  end;

  function Select(AHost: TPanel; const AItems: array of string): TUISelect;
  var
    LItem: string;
  begin
    Result := TUISelect.Create(Self);
    for LItem in AItems do
      Result.Items.Add(LItem);
    Result.Align := alClient;
    Result.Parent := AHost;
  end;

  function Toggle(AHost: TPanel): TUIToggle;
  begin
    Result := TUIToggle.Create(Self);
    Result.Align := alClient;
    Result.Parent := AHost;
  end;

  procedure Button(AHost: TPanel; const ACaption: string; AOnClick: TNotifyEvent);
  begin
    NewButton(AHost, ACaption, AOnClick, bvOutline, alClient);
  end;

begin
  inherited Create(AOwner);
  FRefreshable := True;
  Caption := 'WSL';
  Hint := 'Distros, disco de cada uma, configuração e manutenção do WSL';
  C := UITheme.Tokens.Color;
  FPending := -1;
  FTabs := TUITabs.Create(Self);
  for LIndex := 0 to High(CTabNames) do
    FTabs.AddTab(CTabNames[LIndex]);
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
  FStatus := NewHint(Self, '', alBottom);

  // Distros
  LView := NewPanel(Self, alClient);
  LView.Padding.SetBounds(0, ScaleValue(10), 0, 0);
  FViews[0] := LView;
  NewHint(LView, 'Disco = tamanho do arquivo ext4.vhdx no Windows. Ele cresce e não encolhe sozinho: compactar ' +
    'devolve o espaço (desliga o WSL e pede administrador).');
  FTable := TUIDataTable.Create(Self);
  FTable.Density := tdCompact;
  FTable.SelectionMode := tsmSingle;
  FTable.AddColumn('name', 'Distro', 'name', 200);
  FTable.AddColumn('state', 'Estado', 'state', 100);
  FTable.AddColumn('version', 'Versão', 'version', 70, False, caRight);
  FTable.AddColumn('disk', 'Disco', 'disk', 100, False, caRight);
  FTable.AddColumn('path', 'Pasta', 'path', 240);
  FTable.AddColumn('acoes', '', 'acoes', 140);
  FTable.SetColType('state', ctBadge);
  FTable.AddBadgeMap('state', 'ligada', C.SuccessSubtle, C.Success);
  FTable.AddBadgeMap('state', 'desligada', C.BGMuted, C.FGMuted);
  FTable.AddBadgeMap('state', 'padrão · ligada', C.SuccessSubtle, C.Success);
  FTable.AddBadgeMap('state', 'padrão', C.InfoSubtle, C.Info);
  FTable.SetColType('acoes', ctAction);
  FTable.AddActionToCol('acoes', 'star', 'Tornar padrão');
  FTable.AddActionToCol('acoes', LineIcon(ActionStop), 'Desligar');
  FTable.AddActionToCol('acoes', LineIcon(ActionExport), 'Backup (exportar .tar)');
  FTable.AddActionToCol('acoes', LineIcon(ActionCompact), 'Compactar o disco');
  FTable.OnActionClick := ActionClick;
  FTable.EmptyState.Title := 'Nenhuma distro';
  FTable.EmptyState.Description := 'Instale uma com wsl --install -d Ubuntu.';
  FTable.Top := 100000;
  FTable.Align := alClient;
  FTable.Parent := LView;

  // Configuração (.wslconfig)
  LScroll := TUIScrollArea.Create(Self);
  LScroll.Align := alClient;
  LScroll.Visible := False;
  LScroll.Parent := Self;
  FViews[1] := LScroll;
  LCard := NewSection(LScroll.InnerPanel, 'Recursos do WSL (.wslconfig)', 7);
  LHost := NewSettingRow(LCard, 'Memória', 'Teto de RAM da máquina do WSL (vmmem). Vazio = metade da RAM do PC. ' +
    'Ex.: 8GB.', CInputW);
  FMemory := Input(LHost, 'ex.: 8GB');
  LHost := NewSettingRow(LCard, 'Processadores', 'Quantos núcleos o WSL usa. Vazio = todos.', CInputW);
  FProcessors := Input(LHost, 'ex.: 4');
  LHost := NewSettingRow(LCard, 'Swap', 'Memória extra em disco. 0 desliga. Ex.: 2GB.', CInputW);
  FSwap := Input(LHost, 'ex.: 2GB');
  LHost := NewSettingRow(LCard, 'Devolver memória ao Windows',
    'Gradual: devolve aos poucos a memória parada. Dropcache: devolve de vez quando fica ocioso.', CSelectW);
  FReclaim := Select(LHost, ['Desligado', 'Gradual (recomendado)', 'De vez (dropcache)']);
  LHost := NewSettingRow(LCard, 'Disco esparso', 'Distros novas ganham disco que devolve espaço sozinho.', CToggleW);
  FSparse := Toggle(LHost);
  LHost := NewSettingRow(LCard, 'Rede', 'NAT é o padrão. Espelhada usa a rede do Windows (localhost dos dois lados, ' +
    'VPN funciona melhor).', CSelectW);
  FNetwork := Select(LHost, ['NAT (padrão)', 'Espelhada (mirrored)']);
  LHost := NewSettingRow(LCard, 'Túnel de DNS', 'Resolve nomes pelo Windows: ajuda com VPN corporativa.', CToggleW);
  FDnsTunnel := Toggle(LHost);
  LBar := NewPanel(LScroll.InnerPanel, alTop, 56);
  LBar.Top := 100000;
  LBar.Padding.SetBounds(0, ScaleValue(DSGap), 0, 0);
  NewButton(LBar, 'Salvar', SaveConfigClick, bvPrimary, alRight);
  NewHint(LBar, 'Vale depois de desligar o WSL (Manutenção › Desligar o WSL).', alClient);

  // Manutenção
  LScroll := TUIScrollArea.Create(Self);
  LScroll.Align := alClient;
  LScroll.Visible := False;
  LScroll.Parent := Self;
  FViews[2] := LScroll;
  LCard := NewSection(LScroll.InnerPanel, 'Manutenção', 5);
  LHost := NewSettingRow(LCard, 'Desligar o WSL', 'Para todas as distros. Aplica a configuração e solta a memória ' +
    'do vmmem.', CButtonW);
  Button(LHost, 'Desligar o WSL', ShutdownClick);
  LHost := NewSettingRow(LCard, 'Liberar memória', 'Limpa o cache de arquivos das distros ligadas (o Linux guarda ' +
    'cache e o Windows vê como memória usada).', CButtonW);
  Button(LHost, 'Liberar memória', DropCachesClick);
  LHost := NewSettingRow(LCard, 'Trim do disco', 'Avisa o disco virtual do que foi apagado dentro das distros. Faça ' +
    'antes de compactar.', CButtonW);
  Button(LHost, 'Rodar trim', TrimClick);
  LHost := NewSettingRow(LCard, 'Reiniciar o serviço', 'Quando o WSL trava e nem o desligar responde. Pede ' +
    'administrador.', CButtonW);
  Button(LHost, 'Reiniciar serviço', RestartServiceClick);
  LHost := NewSettingRow(LCard, 'Atualizar o WSL', 'Baixa a versão nova do WSL da Microsoft (wsl --update).', CButtonW);
  Button(LHost, 'Atualizar', UpdateClick);
  LCard := NewSection(LScroll.InnerPanel, 'Versão', 0);
  LCard.Height := ScaleValue(DSSectionTitleH + 150);
  FVersion := TUICode.Create(Self);
  FVersion.FontSize := 11;
  FVersion.Align := alClient;
  FVersion.Parent := LCard;

  FTabs.ActiveIndex := 0;
  TabChange(nil, 0);
  LoadConfig;
end;

procedure TWslPage.TabChange(Sender: TObject; AIndex: Integer);
var
  LIndex: Integer;
begin
  for LIndex := 0 to High(FViews) do
    FViews[LIndex].Visible := LIndex = AIndex;
  if AIndex = 2 then
    RunBusy('Lendo a versão do WSL...',
      function: string
      begin
        Result := WslVersionText;
      end,
      procedure(AText: string)
      begin
        FVersion.Text := AText;
      end);
  // Conteúdo das áreas de rolagem.
  if FViews[AIndex] is TUIScrollArea then
    TUIScrollArea(FViews[AIndex]).ContentHeight := ScaleValue(900);
end;

procedure TWslPage.PageShown;
begin
  inherited;
  Reload;
end;

procedure TWslPage.PageRefresh;
begin
  Reload;
  LoadConfig;
end;

procedure TWslPage.Reload;
var
  LDistro: TWslDistro;
  LState: string;
begin
  FDistros := ListWslDistros;
  FTable.BeginRowUpdate;
  try
    FTable.ClearMemRows;
    for LDistro in FDistros do
    begin
      LState := IfThen(LDistro.Running, 'ligada', 'desligada');
      if LDistro.IsDefault then
        LState := IfThen(LDistro.Running, 'padrão · ligada', 'padrão');
      FTable.AddMemRow([LDistro.Name, LState, IntToStr(LDistro.Version),
        IfThen(LDistro.VhdxSize > 0, SizeText(LDistro.VhdxSize), '–'), LDistro.BasePath]);
    end;
  finally
    FTable.EndRowUpdate;
  end;
end;

procedure TWslPage.LoadConfig;
var
  LText: string;
begin
  LText := '';
  if TFile.Exists(WslConfigPath) then
    LText := TFile.ReadAllText(WslConfigPath);
  FMemory.Value := WslConfigGet(LText, 'memory');
  FProcessors.Value := WslConfigGet(LText, 'processors');
  FSwap.Value := WslConfigGet(LText, 'swap');
  FReclaim.ItemIndex := Max(0, IndexText(WslConfigGet(LText, 'autoMemoryReclaim'), CReclaimValues));
  FNetwork.ItemIndex := Max(0, IndexText(WslConfigGet(LText, 'networkingMode'), CNetworkValues));
  FSparse.Checked := SameText(WslConfigGet(LText, 'sparseVhd'), 'true');
  FDnsTunnel.Checked := SameText(WslConfigGet(LText, 'dnsTunneling'), 'true');
end;

procedure TWslPage.SaveConfigClick(Sender: TObject);
var
  LText: string;
begin
  LText := '';
  if TFile.Exists(WslConfigPath) then
    LText := TFile.ReadAllText(WslConfigPath);
  LText := WslConfigSet(LText, 'memory', Trim(FMemory.Value));
  LText := WslConfigSet(LText, 'processors', Trim(FProcessors.Value));
  LText := WslConfigSet(LText, 'swap', Trim(FSwap.Value));
  LText := WslConfigSet(LText, 'autoMemoryReclaim', IfThen(FReclaim.ItemIndex > 0,
    CReclaimValues[Max(0, FReclaim.ItemIndex)], ''));
  LText := WslConfigSet(LText, 'networkingMode', IfThen(FNetwork.ItemIndex = 1, 'mirrored', ''));
  LText := WslConfigSet(LText, 'sparseVhd', IfThen(FSparse.Checked, 'true', ''));
  LText := WslConfigSet(LText, 'dnsTunneling', IfThen(FDnsTunnel.Checked, 'true', ''));
  // Cópia de segurança do arquivo de antes, uma só.
  if TFile.Exists(WslConfigPath) then
    TFile.Copy(WslConfigPath, WslConfigPath + '.devbox.bak', True);
  TFile.WriteAllText(WslConfigPath, LText, TEncoding.UTF8);
  TUIToastManager.Show('Configuração salva. Vale depois de desligar o WSL.', ttSuccess, 4000);
end;

procedure TWslPage.RunBusy(const AStatus: string; const AWork: TFunc<string>; const ADone: TProc<string>);
begin
  if FBusy then
  begin
    TUIToastManager.Show('Espere a ação anterior terminar', ttInfo, 2500);
    Exit;
  end;
  FBusy := True;
  FProgress.Visible := True;
  FStatus.Caption := AStatus;
  RunTask(
    procedure
    var
      LText: string;
    begin
      try
        LText := AWork();
      except
        on E: Exception do
          LText := 'Falhou: ' + E.Message;
      end;
      QueueUI(
        procedure
        begin
          FBusy := False;
          FProgress.Visible := False;
          FStatus.Caption := LText.Replace(sLineBreak, '  ·  ');
          if Assigned(ADone) then
            ADone(LText);
          Reload;
        end);
    end);
end;

procedure TWslPage.ActionClick(Sender: TObject; ARowIdx, AActionIdx: Integer);
var
  LName, LDir: string;
begin
  if (ARowIdx < 0) or (ARowIdx > High(FDistros)) then
    Exit;
  LName := FDistros[ARowIdx].Name;
  case AActionIdx of
    0:
      RunBusy('Tornando ' + LName + ' padrão...',
        function: string
        var
          LError: string;
        begin
          if WslSetDefault(LName, LError) then
            Result := LName + ' é a distro padrão.'
          else
            Result := 'Não deu: ' + LError;
        end);
    1:
      RunBusy('Desligando ' + LName + '...',
        function: string
        var
          LError: string;
        begin
          if WslTerminate(LName, LError) then
            Result := LName + ' desligada.'
          else
            Result := 'Não deu: ' + LError;
        end);
    2:
      begin
        LDir := Store.GetSetting('wsl_backup_dir', TPath.Combine(GetEnvironmentVariable('USERPROFILE'), 'WSL-Backups'));
        RunBusy('Exportando ' + LName + ' (pode levar minutos)...',
          function: string
          var
            LFile, LError: string;
          begin
            if WslExport(LName, LDir, LFile, LError) then
              Result := 'Backup pronto: ' + LFile
            else
              Result := 'Backup falhou: ' + LError;
          end);
      end;
    3:
      begin
        if FDistros[ARowIdx].VhdxPath = '' then
        begin
          TUIToastManager.Show('Não achei o disco desta distro', ttWarning, 3000);
          Exit;
        end;
        FPending := ARowIdx;
        TUIToastManager.Show('Compactar o disco de ' + LName + '? Desliga o WSL inteiro e pede administrador.',
          ttWarning, 10000, 'Compactar', CompactConfirmed);
      end;
  end;
end;

procedure TWslPage.CompactConfirmed(Sender: TObject);
var
  LDistro: TWslDistro;
begin
  if (FPending < 0) or (FPending > High(FDistros)) then
    Exit;
  LDistro := FDistros[FPending];
  RunBusy('Compactando ' + LDistro.Name + '...',
    function: string
    var
      LError: string;
    begin
      if WslCompact(LDistro.VhdxPath, LError) then
        Result := Format('%s compactada: %s antes, %s agora.', [LDistro.Name, SizeText(LDistro.VhdxSize),
          SizeText(TFile.GetSize(LDistro.VhdxPath))])
      else
        Result := 'Não compactou: ' + LError;
    end);
end;

procedure TWslPage.ShutdownClick(Sender: TObject);
begin
  RunBusy('Desligando o WSL...',
    function: string
    var
      LError: string;
    begin
      if WslShutdown(LError) then
        Result := 'WSL desligado.'
      else
        Result := 'Não deu: ' + LError;
    end);
end;

procedure TWslPage.DropCachesClick(Sender: TObject);
begin
  RunBusy('Liberando memória nas distros ligadas...',
    function: string
    begin
      Result := 'Memória: ' + WslRunAsRootInRunning('sync; echo 3 > /proc/sys/vm/drop_caches');
    end);
end;

procedure TWslPage.TrimClick(Sender: TObject);
begin
  RunBusy('Rodando trim nas distros ligadas...',
    function: string
    begin
      Result := 'Trim: ' + WslRunAsRootInRunning('fstrim -av');
    end);
end;

procedure TWslPage.RestartServiceClick(Sender: TObject);
begin
  RunBusy('Reiniciando o serviço do WSL...',
    function: string
    var
      LError: string;
    begin
      if WslRestartService(LError) then
        Result := 'Serviço do WSL reiniciado.'
      else
        Result := 'Não reiniciou: ' + LError;
    end);
end;

procedure TWslPage.UpdateClick(Sender: TObject);
begin
  RunBusy('Atualizando o WSL...',
    function: string
    var
      LOut: string;
    begin
      if WslUpdate(LOut) then
        Result := 'WSL atualizado.'
      else
        Result := 'Atualização: ' + Copy(Trim(LOut), 1, 200);
    end);
end;

function TWslPage.PageContext: string;
var
  LDistro: TWslDistro;
begin
  Result := 'WSL. Distros:';
  for LDistro in FDistros do
    Result := Result + sLineBreak + Format('- %s: %s, versão %d, disco %s, pasta %s', [LDistro.Name,
      IfThen(LDistro.Running, 'ligada', 'desligada'), LDistro.Version, SizeText(LDistro.VhdxSize), LDistro.BasePath]);
end;

end.
