unit Devbox.UI.Network;

{ Rede: monitor de URLs (no ar, tempo, vencimento do certificado), aviso de VPN
  e receptor de webhook local. }

interface

uses
  System.Classes,
  System.SysUtils,
  System.Generics.Collections,
  Vcl.Controls,
  Vcl.ExtCtrls,
  UI.Labels,
  UI.Tabs,
  UI.Stat,
  UI.Input,
  UI.Select,
  UI.Status,
  UI.Code,
  UI.Timeline,
  UI.ScrollArea,
  UI.DataTable,
  Devbox.Model,
  Devbox.Net,
  Devbox.UI.Kit;

type
  TNetTab = (ntUrls, ntVpn, ntWebhook);

  TUrlState = record
    Result: TUrlResult;
    LastCheck: TDateTime;
    History: TArray<Double>;     // ms das últimas checagens (0 = não respondeu)
    Known: Boolean;              // já checou uma vez (o primeiro resultado não avisa)
    CertWarned: Boolean;
  end;

  TNetworkPage = class(TDevPage)
  private
    FTabs: TUITabs;
    FViews: array[TNetTab] of TPanel;
    // URLs
    FUrlTable: TUIDataTable;
    FChecks: TUrlChecks;
    FStates: TDictionary<Integer, TUrlState>;
    FChecking: TDictionary<Integer, Boolean>;
    FUrlSel: Integer;
    FUrlTimer: TTimer;
    // VPN
    FVpnHost: TUIInput;
    FVpnStatus: TUIStatus;
    FVpnLabel: TUILabel;
    FVpnAdapters: TUILabel;
    FVpnTimeline: TUITimeline;
    FVpnTimer: TTimer;
    FVpnUp: Integer;              // -1 desconhecido, 0 fora, 1 no ar
    FVpnBusy: Boolean;
    // Webhook
    FServer: TWebhookServer;
    FHookPort: TUIInput;
    FHookCode: TUISelect;
    FHookUrl: TUILabel;
    FHookTable: TUIDataTable;
    FHookDetail: TUICode;
    FHits: TList<TWebhookHit>;
    function NewView(ATab: TNetTab; const AHint: string): TPanel;
    procedure TabChange(Sender: TObject; AIndex: Integer);
    // URLs
    procedure ReloadUrls;
    procedure FillUrls;
    procedure UrlTimerTick(Sender: TObject);
    procedure CheckOne(const ACheck: TUrlCheck);
    procedure UrlChecked(const ACheck: TUrlCheck; const AResult: TUrlResult);
    procedure UrlSelect(Sender: TObject; ARowIndex: Integer);
    procedure UrlNew(Sender: TObject);
    procedure UrlEdit(Sender: TObject);
    procedure UrlCheckNow(Sender: TObject);
    procedure UrlDelete(Sender: TObject);
    // VPN
    procedure VpnTimerTick(Sender: TObject);
    procedure VpnSaveClick(Sender: TObject);
    procedure VpnShow(AUp: Boolean; const AWhy: string; const AAdapters: TArray<string>);
    // Webhook
    procedure HookToggle(Sender: TObject);
    procedure HookCopy(Sender: TObject);
    procedure HookClear(Sender: TObject);
    procedure HookSelect(Sender: TObject; ARowIndex: Integer);
    procedure HookHit(const AHit: TWebhookHit);
    procedure HookCodeChange(Sender: TObject);
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
  end;

implementation

uses
  System.StrUtils,
  System.Math,
  System.DateUtils,
  System.Threading,
  UI.Theme,
  UI.Tokens,
  UI.Button,
  UI.Toast,
  Devbox.Store,
  Devbox.Notify,
  Devbox.Convert,
  Vcl.Clipbrd,
  Devbox.UI.Dialogs;

const
  CUrlTickMs = 5000;
  CHistory = 30;
  CCertWarnDays = 14;
  CVpnTickMs = 30000;
  CVpnTimeoutMs = 3000;
  CHookDefaultPort = 4081;   // faixa 4081-4090 reservada para o Devbox
  CHookKeep = 200;
  HookCodes: array[0..4] of Integer = (200, 201, 204, 400, 500);

constructor TNetworkPage.Create(AOwner: TComponent);
const
  TabNames: array[TNetTab] of string = ('URLs', 'VPN', 'Receptor de webhook');
var
  Bar, Right, Row: TPanel;
  T: TNetTab;
  C: TUIColorTokens;
  I: Integer;
begin
  inherited Create(AOwner);
  Caption := 'Rede';
  Hint := 'Seus endereços no ar, certificados, VPN e um receptor de webhook para testar integrações';
  C := UITheme.Tokens.Color;
  FStates := TDictionary<Integer, TUrlState>.Create;
  FChecking := TDictionary<Integer, Boolean>.Create;
  FHits := TList<TWebhookHit>.Create;
  FUrlSel := -1;
  FVpnUp := -1;

  FTabs := TUITabs.Create(Self);
  for T := Low(TNetTab) to High(TNetTab) do
    FTabs.AddTab(TabNames[T]);
  FTabs.Align := alTop;
  FTabs.Parent := Self;
  FTabs.OnChange := TabChange;

  // URLs
  FViews[ntUrls] := NewView(ntUrls, 'Avisa na bandeja quando um endereço cai ou volta, e quando o certificado ' +
    'vence em menos de 14 dias.');
  Bar := NewPanel(FViews[ntUrls], alTop, 50);
  Bar.Padding.SetBounds(0, ScaleValue(6), 0, ScaleValue(6));
  NewButton(Bar, 'Nova URL', UrlNew, bvPrimary);
  NewButton(Bar, 'Editar', UrlEdit);
  NewButton(Bar, 'Checar agora', UrlCheckNow);
  NewButton(Bar, 'Excluir', UrlDelete, bvGhost, alRight);
  FUrlTable := TUIDataTable.Create(Self);
  FUrlTable.SelectionMode := tsmSingle;
  FUrlTable.Density := tdCompact;
  FUrlTable.OnRowSelect := UrlSelect;
  FUrlTable.AddColumn('name', 'Nome', 'name', 170);
  FUrlTable.AddColumn('state', 'Estado', 'state', 90);
  FUrlTable.AddColumn('code', 'Código', 'code', 70, False, caRight);
  FUrlTable.AddColumn('ms', 'Tempo', 'ms', 80, False, caRight);
  FUrlTable.AddColumn('trend', 'Últimas checagens', 'trend', 160, False);
  FUrlTable.AddColumn('cert', 'Certificado', 'cert', 150);
  FUrlTable.AddColumn('url', 'Endereço', 'url', 260);
  FUrlTable.SetColType('state', ctBadge);
  FUrlTable.AddBadgeMap('state', 'no ar', C.SuccessSubtle, C.Success);
  FUrlTable.AddBadgeMap('state', 'fora', C.ErrorSubtle, C.Error);
  FUrlTable.AddBadgeMap('state', 'checando', C.InfoSubtle, C.Info);
  FUrlTable.SetColType('trend', ctSparkline);
  FUrlTable.EmptyStateText := 'Nenhuma URL. Ex.: a API de homologação ou o seu site.';
  FUrlTable.Top := 100000;
  FUrlTable.Align := alClient;
  FUrlTable.Parent := FViews[ntUrls];

  // VPN
  FViews[ntVpn] := NewView(ntVpn, 'Informe um servidor que só responde com a VPN ligada (ex.: o Jira da empresa). ' +
    'Sem servidor, vale o adaptador de VPN do Windows.');
  Bar := NewPanel(FViews[ntVpn], alTop, 50);
  Bar.Padding.SetBounds(0, ScaleValue(6), 0, ScaleValue(6));
  NewButton(Bar, 'Salvar e testar', VpnSaveClick, bvPrimary, alRight);
  FVpnHost := TUIInput.Create(Self);
  FVpnHost.LabelMode := ilmBorder;
  FVpnHost.LabelText := 'Servidor interno (host:porta, ex.: jira.empresa.com:443)';
  FVpnHost.ReserveHintSpace := False;
  FVpnHost.Value := Store.GetSetting('vpn_host');
  FVpnHost.Align := alClient;
  FVpnHost.Parent := Bar;
  Row := NewPanel(FViews[ntVpn], alTop, 56);
  Row.Padding.SetBounds(0, ScaleValue(10), 0, 0);
  FVpnStatus := TUIStatus.Create(Self);
  FVpnStatus.Status := sdOffline;
  FVpnStatus.Width := ScaleValue(20);
  FVpnStatus.Align := alLeft;
  FVpnStatus.Parent := Row;
  FVpnLabel := TUILabel.Create(Self);
  FVpnLabel.Caption := 'Verificando...';
  FVpnLabel.Bold := True;
  FVpnLabel.FontSize := 16;
  FVpnLabel.AutoSize := False;
  FVpnLabel.AlignWithMargins := True;
  FVpnLabel.Margins.SetBounds(ScaleValue(10), 0, 0, 0);
  FVpnLabel.Align := alClient;
  FVpnLabel.Parent := Row;
  FVpnAdapters := NewHint(FViews[ntVpn], '');
  with TUILabel.Create(Self) do
  begin
    Caption := 'Histórico';
    Bold := True;
    AutoSize := False;
    Height := ScaleValue(30);
    Top := 100000;
    Align := alTop;
    Parent := FViews[ntVpn];
  end;
  with TUIScrollArea.Create(Self) do
  begin
    Top := 100000;
    Align := alClient;
    Parent := FViews[ntVpn];
    FVpnTimeline := TUITimeline.Create(Self);
    FVpnTimeline.Align := alTop;
    FVpnTimeline.Parent := InnerPanel;
  end;

  // Webhook
  FViews[ntWebhook] := NewView(ntWebhook, 'Endereço local que registra cada chamada recebida: método, cabeçalhos e ' +
    'corpo. Só aceita conexões desta máquina.');
  Bar := NewPanel(FViews[ntWebhook], alTop, 50);
  Bar.Padding.SetBounds(0, ScaleValue(6), 0, ScaleValue(6));
  NewButton(Bar, 'Ligar/desligar', HookToggle, bvPrimary);
  FHookPort := TUIInput.Create(Self);
  FHookPort.LabelMode := ilmBorder;
  FHookPort.LabelText := 'Porta';
  FHookPort.ReserveHintSpace := False;
  FHookPort.Value := Store.GetSetting('hook_port', IntToStr(CHookDefaultPort));
  FHookPort.Width := ScaleValue(110);
  FHookPort.AlignWithMargins := True;
  FHookPort.Margins.SetBounds(0, 0, ScaleValue(8), 0);
  FHookPort.Left := 100000;
  FHookPort.Align := alLeft;
  FHookPort.Parent := Bar;
  FHookCode := TUISelect.Create(Self);
  for I in HookCodes do
    FHookCode.Items.Add('Responde ' + IntToStr(I));
  FHookCode.ItemIndex := 0;
  FHookCode.OnChange := HookCodeChange;
  FHookCode.Width := ScaleValue(160);
  FHookCode.AlignWithMargins := True;
  FHookCode.Margins.SetBounds(0, 0, ScaleValue(8), 0);
  FHookCode.Left := 100000;
  FHookCode.Align := alLeft;
  FHookCode.Parent := Bar;
  NewButton(Bar, 'Copiar endereço', HookCopy, bvGhost);
  NewButton(Bar, 'Limpar', HookClear, bvGhost, alRight);
  FHookUrl := NewHint(FViews[ntWebhook], 'Desligado');
  Right := NewPanel(FViews[ntWebhook], alRight);
  Right.Width := ScaleValue(420);
  Right.Padding.SetBounds(ScaleValue(12), 0, 0, 0);
  with TUIScrollArea.Create(Self) do
  begin
    Align := alClient;
    Parent := Right;
    FHookDetail := TUICode.Create(Self);
    FHookDetail.FontSize := 11;
    FHookDetail.Text := 'Escolha uma chamada para ver os detalhes';
    FHookDetail.Height := ScaleValue(600);
    FHookDetail.Align := alTop;
    FHookDetail.Parent := InnerPanel;
  end;
  FHookTable := TUIDataTable.Create(Self);
  FHookTable.SelectionMode := tsmSingle;
  FHookTable.Density := tdCompact;
  FHookTable.OnRowSelect := HookSelect;
  FHookTable.AddColumn('at', 'Hora', 'at', 90);
  FHookTable.AddColumn('method', 'Método', 'method', 80);
  FHookTable.AddColumn('path', 'Caminho', 'path', 260);
  FHookTable.AddColumn('size', 'Corpo', 'size', 80, False, caRight);
  FHookTable.SetColType('method', ctBadge);
  FHookTable.AddBadgeMap('method', 'GET', C.InfoSubtle, C.Info);
  FHookTable.AddBadgeMap('method', 'POST', C.SuccessSubtle, C.Success);
  FHookTable.AddBadgeMap('method', 'PUT', C.WarningSubtle, C.Warning);
  FHookTable.AddBadgeMap('method', 'DELETE', C.ErrorSubtle, C.Error);
  FHookTable.EmptyStateText := 'Nenhuma chamada ainda';
  FHookTable.Top := 100000;
  FHookTable.Align := alClient;
  FHookTable.Parent := FViews[ntWebhook];

  FServer := TWebhookServer.Create(
    procedure(const AHit: TWebhookHit)
    var
      Hit: TWebhookHit;
    begin
      Hit := AHit;
      System.Classes.TThread.Queue(nil,
        procedure
        begin
          HookHit(Hit);
        end);
    end);

  FTabs.ActiveIndex := 0;
  TabChange(nil, 0);
  ReloadUrls;
  FUrlTimer := TTimer.Create(Self);
  FUrlTimer.Interval := CUrlTickMs;
  FUrlTimer.OnTimer := UrlTimerTick;
  FUrlTimer.Enabled := True;
  FVpnTimer := TTimer.Create(Self);
  FVpnTimer.Interval := CVpnTickMs;
  FVpnTimer.OnTimer := VpnTimerTick;
  FVpnTimer.Enabled := True;
  System.Classes.TThread.ForceQueue(nil,
    procedure
    begin
      VpnTimerTick(nil);
    end);
  if Store.GetSetting('hook_on') = '1' then
    System.Classes.TThread.ForceQueue(nil,
      procedure
      begin
        HookToggle(nil);
      end);
end;

destructor TNetworkPage.Destroy;
begin
  FServer.Free;
  FStates.Free;
  FChecking.Free;
  FHits.Free;
  inherited;
end;

function TNetworkPage.NewView(ATab: TNetTab; const AHint: string): TPanel;
begin
  Result := NewPanel(Self, alClient);
  Result.Padding.SetBounds(0, ScaleValue(10), 0, 0);
  Result.Visible := False;
  NewHint(Result, AHint);
end;

procedure TNetworkPage.TabChange(Sender: TObject; AIndex: Integer);
var
  T: TNetTab;
begin
  for T := Low(TNetTab) to High(TNetTab) do
    FViews[T].Visible := Ord(T) = AIndex;
end;

{ URLs }

procedure TNetworkPage.ReloadUrls;
begin
  FChecks := Store.ListUrlChecks;
  FillUrls;
end;

procedure TNetworkPage.FillUrls;
var
  C: TUrlCheck;
  S: TUrlState;
  State, Cert: string;
  Trends: TArray<TArray<Double>>;
  Days: Integer;
begin
  Trends := nil;
  FUrlTable.BeginRowUpdate;
  try
    FUrlTable.ClearMemRows;
    for C in FChecks do
    begin
      if not FStates.TryGetValue(C.Id, S) then
        S := Default(TUrlState);
      if FChecking.ContainsKey(C.Id) and not S.Known then
        State := 'checando'
      else if not S.Known then
        State := ''
      else if S.Result.Up then
        State := 'no ar'
      else
        State := 'fora';
      Cert := '';
      if S.Result.CertExpiry > 0 then
      begin
        Days := DaysBetween(Now, S.Result.CertExpiry);
        if S.Result.CertExpiry < Now then
          Cert := 'venceu'
        else
          Cert := Format('vence em %d dias', [Days]);
      end
      else if StartsText('https', C.Url) and S.Known then
        Cert := '–';
      FUrlTable.AddMemRow([C.Name, State, IfThen(S.Result.Code > 0, IntToStr(S.Result.Code), ''),
        IfThen(S.Known, Format('%d ms', [S.Result.Ms]), ''), '', Cert, C.Url]);
      Trends := Trends + [S.History];
    end;
  finally
    FUrlTable.EndRowUpdate;
  end;
  FUrlTable.SetSparklineData('trend', slArea, Trends);
end;

procedure TNetworkPage.UrlTimerTick(Sender: TObject);
var
  C: TUrlCheck;
  S: TUrlState;
begin
  for C in FChecks do
  begin
    if not C.Enabled or FChecking.ContainsKey(C.Id) then
      Continue;
    if FStates.TryGetValue(C.Id, S) and (SecondsBetween(Now, S.LastCheck) < C.IntervalSec) then
      Continue;
    CheckOne(C);
  end;
end;

procedure TNetworkPage.CheckOne(const ACheck: TUrlCheck);
var
  Check: TUrlCheck;
begin
  Check := ACheck;
  FChecking.AddOrSetValue(Check.Id, True);
  TTask.Run(
    procedure
    var
      R: TUrlResult;
    begin
      try
        R := CheckUrl(Check.Url);
      except
        on E: Exception do
        begin
          R := Default(TUrlResult);
          R.Error := E.Message;
        end;
      end;
      System.Classes.TThread.Queue(nil,
        procedure
        begin
          UrlChecked(Check, R);
        end);
    end);
end;

procedure TNetworkPage.UrlChecked(const ACheck: TUrlCheck; const AResult: TUrlResult);
var
  S: TUrlState;
  WasUp: Boolean;
begin
  FChecking.Remove(ACheck.Id);
  if not FStates.TryGetValue(ACheck.Id, S) then
    S := Default(TUrlState);
  WasUp := S.Result.Up;
  // Aviso só na troca de estado, e não na primeira checagem.
  if S.Known and (WasUp <> AResult.Up) then
    if AResult.Up then
      Notify(ACheck.Name + ' voltou', Format('%s respondeu %d em %d ms', [ACheck.Url, AResult.Code, AResult.Ms]))
    else
      Notify(ACheck.Name + ' caiu', IfThen(AResult.Error <> '', AResult.Error,
        Format('%s respondeu %d', [ACheck.Url, AResult.Code])), True);
  if (AResult.CertExpiry > 0) and not S.CertWarned and (DaysBetween(Now, AResult.CertExpiry) < CCertWarnDays) then
  begin
    Notify('Certificado vencendo: ' + ACheck.Name, 'Vence em ' + FormatDateTime('dd/mm/yyyy', AResult.CertExpiry), True);
    S.CertWarned := True;
  end;
  S.Result := AResult;
  S.LastCheck := Now;
  S.Known := True;
  S.History := S.History + [IfThen(AResult.Up, AResult.Ms, 0)];
  if Length(S.History) > CHistory then
    S.History := Copy(S.History, Length(S.History) - CHistory, CHistory);
  FStates.AddOrSetValue(ACheck.Id, S);
  FillUrls;
end;

procedure TNetworkPage.UrlSelect(Sender: TObject; ARowIndex: Integer);
begin
  FUrlSel := ARowIndex;
end;

procedure TNetworkPage.UrlNew(Sender: TObject);
var
  C: TUrlCheck;
begin
  C := Default(TUrlCheck);
  C.IntervalSec := 60;
  C.Enabled := True;
  C.Url := 'https://';
  if not EditUrlCheck(C) then
    Exit;
  Store.SaveUrlCheck(C);
  ReloadUrls;
  CheckOne(C);
end;

procedure TNetworkPage.UrlEdit(Sender: TObject);
var
  C: TUrlCheck;
begin
  if (FUrlSel < 0) or (FUrlSel > High(FChecks)) then
    Exit;
  C := FChecks[FUrlSel];
  if not EditUrlCheck(C) then
    Exit;
  Store.SaveUrlCheck(C);
  FStates.Remove(C.Id);
  ReloadUrls;
  CheckOne(C);
end;

procedure TNetworkPage.UrlCheckNow(Sender: TObject);
var
  C: TUrlCheck;
begin
  for C in FChecks do
    if not FChecking.ContainsKey(C.Id) then
      CheckOne(C);
end;

procedure TNetworkPage.UrlDelete(Sender: TObject);
begin
  if (FUrlSel < 0) or (FUrlSel > High(FChecks)) then
    Exit;
  Store.DeleteUrlCheck(FChecks[FUrlSel].Id);
  FStates.Remove(FChecks[FUrlSel].Id);
  FUrlSel := -1;
  ReloadUrls;
end;

{ VPN }

procedure TNetworkPage.VpnSaveClick(Sender: TObject);
var
  Host: string;
  Port: Integer;
begin
  if (Trim(FVpnHost.Value) <> '') and not ParseHostPort(FVpnHost.Value, Host, Port) then
  begin
    FVpnHost.ErrorMessage := 'Use host:porta, ex.: jira.empresa.com:443';
    Exit;
  end;
  FVpnHost.ErrorMessage := '';
  Store.SetSetting('vpn_host', Trim(FVpnHost.Value));
  FVpnUp := -1;
  VpnTimerTick(nil);
end;

procedure TNetworkPage.VpnTimerTick(Sender: TObject);
var
  Target: string;
begin
  if FVpnBusy then
    Exit;
  FVpnBusy := True;
  Target := Store.GetSetting('vpn_host');
  TTask.Run(
    procedure
    var
      Host, Why: string;
      Port: Integer;
      Up: Boolean;
      Adapters: TArray<string>;
    begin
      Up := False;
      Why := '';
      try
        Adapters := ActiveVpnAdapters;
        if ParseHostPort(Target, Host, Port) then
        begin
          Up := TcpReachable(Host, Port, CVpnTimeoutMs);
          Why := IfThen(Up, Target + ' responde', Target + ' não responde');
        end
        else
        begin
          Up := Adapters <> nil;
          Why := IfThen(Up, 'adaptador de VPN ligado', 'nenhum adaptador de VPN ligado');
        end;
      except
        on E: Exception do
          Why := E.Message;
      end;
      System.Classes.TThread.Queue(nil,
        procedure
        begin
          FVpnBusy := False;
          VpnShow(Up, Why, Adapters);
        end);
    end);
end;

procedure TNetworkPage.VpnShow(AUp: Boolean; const AWhy: string; const AAdapters: TArray<string>);
begin
  if (FVpnUp >= 0) and (Ord(AUp) <> FVpnUp) then
  begin
    if AUp then
      Notify('VPN ligada', AWhy)
    else
      Notify('VPN caiu', AWhy, True);
  end;
  if Ord(AUp) <> FVpnUp then
    FVpnTimeline.AddEvent(FormatDateTime('dd/mm hh:nn', Now), IfThen(AUp, 'VPN ligada', 'VPN fora'), AWhy, '',
      TUISemanticTone(IfThen(AUp, Ord(stSuccess), Ord(stError))));
  FVpnUp := Ord(AUp);
  if AUp then
    FVpnStatus.Status := sdOnline
  else
    FVpnStatus.Status := sdOffline;
  FVpnLabel.Caption := IfThen(AUp, 'VPN ligada', 'VPN fora') + '  ·  ' + AWhy;
  if AAdapters <> nil then
    FVpnAdapters.Caption := 'Adaptadores de VPN ligados: ' + string.Join(', ', AAdapters)
  else
    FVpnAdapters.Caption := 'Nenhum adaptador de VPN ligado no Windows';
end;

{ Webhook }

procedure TNetworkPage.HookToggle(Sender: TObject);
var
  Port: Integer;
begin
  if FServer.Active then
  begin
    FServer.Stop;
    Store.SetSetting('hook_on', '0');
    FHookUrl.Caption := 'Desligado';
    Exit;
  end;
  if not TryStrToInt(Trim(FHookPort.Value), Port) or not InRange(Port, 1024, 65535) then
  begin
    FHookPort.ErrorMessage := '1024 a 65535';
    Exit;
  end;
  FHookPort.ErrorMessage := '';
  try
    FServer.Start(Port);
  except
    on E: Exception do
    begin
      TUIToastManager.Show(Format('Porta %d ocupada ou bloqueada: %s', [Port, E.Message]), ttError, 6000);
      Exit;
    end;
  end;
  Store.SetSetting('hook_port', IntToStr(Port));
  Store.SetSetting('hook_on', '1');
  FHookUrl.Caption := Format('Recebendo em http://localhost:%d/  ·  qualquer caminho e método', [Port]);
end;

procedure TNetworkPage.HookCopy(Sender: TObject);
begin
  TUIToastManager.Show('Copiado', ttSuccess, 1500);
  Clipboard.AsText := Format('http://localhost:%s/', [Trim(FHookPort.Value)]);
end;

procedure TNetworkPage.HookCodeChange(Sender: TObject);
begin
  FServer.ResponseCode := HookCodes[Max(FHookCode.ItemIndex, 0)];
end;

procedure TNetworkPage.HookClear(Sender: TObject);
begin
  FHits.Clear;
  FHookTable.ClearMemRows;
  FHookDetail.Text := '';
end;

procedure TNetworkPage.HookHit(const AHit: TWebhookHit);
var
  H: TWebhookHit;
begin
  FHits.Insert(0, AHit);
  while FHits.Count > CHookKeep do
    FHits.Delete(FHits.Count - 1);
  FHookTable.BeginRowUpdate;
  try
    FHookTable.ClearMemRows;
    for H in FHits do
      FHookTable.AddMemRow([FormatDateTime('hh:nn:ss', H.At), H.Method, H.Path,
        IfThen(H.Body = '', '', Format('%d B', [Length(H.Body)]))]);
  finally
    FHookTable.EndRowUpdate;
  end;
end;

procedure TNetworkPage.HookSelect(Sender: TObject; ARowIndex: Integer);
var
  H: TWebhookHit;
  Body, Pretty, Error: string;
begin
  if (ARowIndex < 0) or (ARowIndex >= FHits.Count) then
    Exit;
  H := FHits[ARowIndex];
  // Corpo JSON sai formatado; o resto, como veio.
  Body := H.Body;
  if (Trim(Body).StartsWith('{') or Trim(Body).StartsWith('[')) and
    ConvertText(cvJsonPretty, H.Body, Pretty, Error) then
    Body := Pretty;
  FHookDetail.Text := Format('%s %s'#10'de %s às %s'#10#10'%s'#10'%s', [H.Method, H.Path, H.Remote,
    FormatDateTime('hh:nn:ss', H.At), StringReplace(Trim(H.Headers), #13, '', [rfReplaceAll]),
    StringReplace(Body, #13, '', [rfReplaceAll])]);
end;

end.
