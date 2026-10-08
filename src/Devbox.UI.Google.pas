unit Devbox.UI.Google;

{ Contas: Google (login pelo navegador; refresh token no Credential Manager),
  outro e-mail por IMAP com senha de app e agendas por link iCal. }

interface

uses
  System.Classes,
  System.SysUtils,
  Vcl.Controls,
  Vcl.ExtCtrls,
  UI.Labels,
  UI.Input,
  UI.Tabs,
  UI.DataTable,
  Devbox.Store,
  Devbox.ICal,
  Devbox.UI.Kit;

type
  TGooglePage = class(TDevPage)
  private
    FTabs: TUITabs;
    FViews: array[0..2] of TPanel;
    FClientId, FClientSecret: TUIInput;
    FImapEmail, FImapHost, FImapPort, FImapPass: TUIInput;
    FImapTable: TUIDataTable;
    FImaps: TImapAccounts;
    FImapSel: Integer;
    FImapTesting: Boolean;
    FTable: TUIDataTable;
    FAccounts: TGoogleAccounts;
    FSel: Integer;
    FFeedName, FFeedUrl: TUIInput;
    FFeedTable: TUIDataTable;
    FFeeds: TICalFeeds;
    FFeedSel: Integer;
    FPending: TProc;
    FSigningIn: Boolean;
    FOnAccountsChanged: TNotifyEvent;
    procedure LoadClient;
    procedure SaveClientClick(Sender: TObject);
    procedure HelpClick(Sender: TObject);
    procedure AddClick(Sender: TObject);
    procedure ReloginClick(Sender: TObject);
    procedure ToggleClick(Sender: TObject);
    procedure RemoveClick(Sender: TObject);
    procedure ConfirmClick(Sender: TObject);
    procedure TableSelect(Sender: TObject; ARowIndex: Integer);
    procedure FeedSelect(Sender: TObject; ARowIndex: Integer);
    procedure AddFeedClick(Sender: TObject);
    procedure RemoveFeedClick(Sender: TObject);
    procedure ReloadFeeds;
    procedure ReloadImaps;
    procedure ImapSelect(Sender: TObject; ARowIndex: Integer);
    procedure ImapEmailChange(Sender: TObject);
    procedure ImapAddClick(Sender: TObject);
    procedure ImapToggleClick(Sender: TObject);
    procedure ImapRemoveClick(Sender: TObject);
    procedure TabChange(Sender: TObject; AIndex: Integer);
    function NewTitle(AParent: TWinControl; const AText: string): TUILabel;
    function NewField(AParent: TWinControl; const ALabel: string; AWidth: Integer): TUIInput;
    procedure SignIn;
    procedure Changed;
    function Selected(out AAccount: TGoogleAccount): Boolean;
  public
    constructor Create(AOwner: TComponent); override;
    procedure Reload;
    property OnAccountsChanged: TNotifyEvent read FOnAccountsChanged write FOnAccountsChanged;
  end;

implementation

uses
  System.StrUtils,
  System.Threading,
  UI.Toast,
  UI.Button,
  UI.Theme,
  UI.Tokens,
  Devbox.Google,
  Devbox.Imap,
  Devbox.Secrets,
  Devbox.Sys;

const
  CConsoleUrl = 'https://console.cloud.google.com/apis/credentials';

function TGooglePage.NewTitle(AParent: TWinControl; const AText: string): TUILabel;
begin
  Result := TUILabel.Create(Self);
  Result.Caption := AText;
  Result.Bold := True;
  Result.FontSize := 15;
  Result.AutoSize := False;
  Result.Height := ScaleValue(40);
  Result.Top := 100000;
  Result.Align := alTop;
  Result.Parent := AParent;
end;

{ Campo com rótulo na borda; AWidth = 0 ocupa o resto da linha. }
function TGooglePage.NewField(AParent: TWinControl; const ALabel: string; AWidth: Integer): TUIInput;
begin
  Result := TUIInput.Create(Self);
  Result.LabelMode := ilmBorder;
  Result.LabelText := ALabel;
  Result.ReserveHintSpace := False;
  if AWidth > 0 then
  begin
    Result.Width := ScaleValue(AWidth);
    Result.AlignWithMargins := True;
    Result.Margins.SetBounds(0, 0, ScaleValue(8), 0);
    Result.Left := 100000;
    Result.Align := alLeft;
  end
  else
    Result.Align := alClient;
  Result.Parent := AParent;
end;

constructor TGooglePage.Create(AOwner: TComponent);
const
  CTabNames: array[0..2] of string = ('Google', 'Outro e-mail (IMAP)', 'Agenda por link');
var
  Row: TPanel;
  V: TPanel;
  C: TUIColorTokens;
  I: Integer;
begin
  inherited Create(AOwner);
  Caption := 'Contas';
  Hint := 'Contas de e-mail e agendas. Senhas e acessos ficam no Credential Manager, só nesta máquina.';
  FSel := -1;
  FImapSel := -1;
  C := UITheme.Tokens.Color;
  FTabs := TUITabs.Create(Self);
  for I := 0 to High(CTabNames) do
    FTabs.AddTab(CTabNames[I]);
  FTabs.Align := alTop;
  FTabs.Parent := Self;
  FTabs.OnChange := TabChange;
  for I := 0 to High(FViews) do
  begin
    FViews[I] := NewPanel(Self, alClient);
    FViews[I].Padding.SetBounds(0, ScaleValue(10), 0, 0);
    FViews[I].Visible := False;
  end;

  // Google
  V := FViews[0];
  if GoogleEmbeddedClient then
  begin
    NewHint(V, 'Clique em Adicionar conta e entre com o Google no navegador. O Google avisa que o app não é ' +
      'verificado: siga por Avançado.');
    NewHint(V, 'Acesso pedido: ler e organizar o Gmail e ler a Agenda.');
  end;
  Row := NewPanel(V, alTop, 46);
  Row.Padding.SetBounds(0, ScaleValue(4), 0, ScaleValue(8));
  NewButton(Row, 'Adicionar conta', AddClick, bvPrimary);
  NewButton(Row, 'Entrar de novo', ReloginClick);
  NewButton(Row, 'Ligar/desligar', ToggleClick);
  NewButton(Row, 'Remover', RemoveClick, bvGhost, alRight);
  FTable := TUIDataTable.Create(Self);
  FTable.SelectionMode := tsmSingle;
  FTable.Density := tdCompact;
  FTable.OnRowSelect := TableSelect;
  FTable.AddColumn('email', 'Conta', 'email', 300);
  FTable.AddColumn('state', 'Situação', 'state', 140);
  FTable.SetColType('state', ctBadge);
  FTable.AddBadgeMap('state', 'ligada', C.SuccessSubtle, C.Success);
  FTable.AddBadgeMap('state', 'desligada', C.BGMuted, C.FGMuted);
  FTable.AddBadgeMap('state', 'sem login', C.ErrorSubtle, C.Error);
  FTable.EmptyStateText := 'Nenhuma conta';
  FTable.Height := ScaleValue(180);
  FTable.Top := 100000;
  FTable.Align := alTop;
  FTable.Parent := V;
  NewTitle(V, IfThen(GoogleEmbeddedClient, 'Cliente OAuth próprio (opcional)', 'Cliente OAuth'));
  if GoogleEmbeddedClient then
    NewHint(V, 'Só se quiser usar um projeto seu do Google Cloud. Vazio = o cliente que vem no Devbox.')
  else
  begin
    NewHint(V, 'No Google Cloud: crie um projeto e ative a Gmail API e a Google Calendar API.');
    NewHint(V, 'Crie um "ID do cliente OAuth" do tipo "App para computador" e cole o ID e a chave aqui.');
    NewHint(V, 'Na tela de consentimento, publique o app ("Em produção"): em "Teste", o Google ' +
      'derruba o acesso a cada 7 dias.');
  end;
  Row := NewPanel(V, alTop, 56);
  Row.Padding.SetBounds(0, ScaleValue(8), 0, ScaleValue(4));
  NewButton(Row, 'Como criar', HelpClick, bvGhost, alRight);
  NewButton(Row, 'Salvar', SaveClientClick, bvOutline, alRight);
  FClientId := NewField(Row, 'ID do cliente (...apps.googleusercontent.com)', 420);
  FClientSecret := NewField(Row, '', 0);
  FClientSecret.PasswordChar := '*';
  FClientSecret.PasswordToggle := True;

  // IMAP
  V := FViews[1];
  NewHint(V, 'Gmail, Yahoo, iCloud e IMAP de empresa. Use uma senha de app (gerada na segurança da conta, com ' +
    'verificação em 2 etapas), não a senha normal.');
  NewHint(V, 'Outlook e Hotmail não aceitam senha no IMAP. Gmail: prefira a aba Google (tem rótulos e Agenda).');
  Row := NewPanel(V, alTop, 56);
  Row.Padding.SetBounds(0, ScaleValue(8), 0, ScaleValue(4));
  FImapEmail := NewField(Row, 'E-mail', 260);
  FImapEmail.OnChange := ImapEmailChange;
  FImapPort := NewField(Row, 'Porta', 90);
  FImapPort.Value := '993';
  FImapHost := NewField(Row, 'Servidor IMAP (ex.: imap.mail.yahoo.com)', 0);
  Row := NewPanel(V, alTop, 56);
  Row.Padding.SetBounds(0, ScaleValue(4), 0, ScaleValue(8));
  NewButton(Row, 'Testar e adicionar', ImapAddClick, bvPrimary, alRight);
  FImapPass := NewField(Row, 'Senha de app (fica no Credential Manager)', 0);
  FImapPass.PasswordChar := '*';
  FImapPass.PasswordToggle := True;
  Row := NewPanel(V, alTop, 46);
  Row.Padding.SetBounds(0, ScaleValue(4), 0, ScaleValue(8));
  NewButton(Row, 'Ligar/desligar', ImapToggleClick);
  NewButton(Row, 'Remover', ImapRemoveClick, bvGhost, alRight);
  FImapTable := TUIDataTable.Create(Self);
  FImapTable.SelectionMode := tsmSingle;
  FImapTable.Density := tdCompact;
  FImapTable.OnRowSelect := ImapSelect;
  FImapTable.AddColumn('email', 'Conta', 'email', 260);
  FImapTable.AddColumn('host', 'Servidor', 'host', 240);
  FImapTable.AddColumn('state', 'Situação', 'state', 120);
  FImapTable.SetColType('state', ctBadge);
  FImapTable.AddBadgeMap('state', 'ligada', C.SuccessSubtle, C.Success);
  FImapTable.AddBadgeMap('state', 'desligada', C.BGMuted, C.FGMuted);
  FImapTable.AddBadgeMap('state', 'sem senha', C.ErrorSubtle, C.Error);
  FImapTable.EmptyStateText := 'Nenhuma conta IMAP';
  FImapTable.Top := 100000;
  FImapTable.Align := alClient;
  FImapTable.Parent := V;

  // Agenda por link
  V := FViews[2];
  NewHint(V, 'Sem login: no Google Agenda, Configurações da agenda › "Endereço secreto em formato iCal". ' +
    'Serve qualquer .ics.');
  Row := NewPanel(V, alTop, 56);
  Row.Padding.SetBounds(0, ScaleValue(6), 0, ScaleValue(6));
  NewButton(Row, 'Remover', RemoveFeedClick, bvGhost, alRight);
  NewButton(Row, 'Adicionar agenda', AddFeedClick, bvPrimary, alRight);
  FFeedName := NewField(Row, 'Nome', 180);
  FFeedUrl := NewField(Row, 'Link .ics (fica no Credential Manager)', 0);
  FFeedUrl.PasswordChar := '*';
  FFeedUrl.PasswordToggle := True;
  FFeedTable := TUIDataTable.Create(Self);
  FFeedTable.SelectionMode := tsmSingle;
  FFeedTable.Density := tdCompact;
  FFeedTable.OnRowSelect := FeedSelect;
  FFeedTable.AddColumn('name', 'Agenda', 'name', 200);
  FFeedTable.AddColumn('host', 'Endereço', 'host', 300);
  FFeedTable.EmptyStateText := 'Nenhum link';
  FFeedTable.Top := 100000;
  FFeedTable.Align := alClient;
  FFeedTable.Parent := V;

  FTabs.ActiveIndex := 0;
  TabChange(nil, 0);
  LoadClient;
  Reload;
  ReloadImaps;
  ReloadFeeds;
end;

procedure TGooglePage.TabChange(Sender: TObject; AIndex: Integer);
var
  I: Integer;
begin
  for I := 0 to High(FViews) do
    FViews[I].Visible := I = AIndex;
end;

{ IMAP }

procedure TGooglePage.ReloadImaps;
var
  A: TImapAccount;
  State: string;
begin
  FImaps := Store.ListImapAccounts;
  FImapTable.BeginRowUpdate;
  try
    FImapTable.ClearMemRows;
    for A in FImaps do
    begin
      if not ImapHasPassword(A.Email) then
        State := 'sem senha'
      else if A.Enabled then
        State := 'ligada'
      else
        State := 'desligada';
      FImapTable.AddMemRow([A.Email, Format('%s:%d', [A.Host, A.Port]), State]);
    end;
  finally
    FImapTable.EndRowUpdate;
  end;
  FImapSel := -1;
end;

procedure TGooglePage.ImapSelect(Sender: TObject; ARowIndex: Integer);
begin
  FImapSel := ARowIndex;
end;

{ Servidor sugerido pelo domínio enquanto digita (sem apagar o que o usuário já pôs). }
procedure TGooglePage.ImapEmailChange(Sender: TObject);
var
  Host, Warn: string;
  Port: Integer;
begin
  GuessImapServer(Trim(FImapEmail.Value), Host, Port, Warn);
  // Tag 1 = o servidor foi sugerido aqui (pode trocar); o que o usuário digitou fica.
  if (Host <> '') and ((FImapHost.Value = '') or (FImapHost.Tag = 1)) then
  begin
    FImapHost.Value := Host;
    FImapHost.Tag := 1;
    FImapPort.Value := IntToStr(Port);
  end;
end;

procedure TGooglePage.ImapAddClick(Sender: TObject);
var
  A: TImapAccount;
  Pass, Host, Warn: string;
  Port: Integer;
  Existed: Boolean;
begin
  if FImapTesting then
    Exit;
  A.Email := Trim(FImapEmail.Value);
  A.Host := Trim(FImapHost.Value);
  A.Port := StrToIntDef(Trim(FImapPort.Value), 993);
  A.User := A.Email;
  A.Enabled := True;
  Pass := Trim(FImapPass.Value).Replace(' ', '');
  GuessImapServer(A.Email, Host, Port, Warn);
  if A.Host = '' then
  begin
    A.Host := Host;
    A.Port := Port;
  end;
  if Warn <> '' then
  begin
    TUIToastManager.Show(Warn, ttWarning, 6000);
    Exit;
  end;
  if (Pos('@', A.Email) < 2) or (A.Host = '') or (Pass = '') then
  begin
    TUIToastManager.Show('Informe e-mail, servidor IMAP e a senha de app', ttWarning, 3500);
    Exit;
  end;
  if (A.Port < 1) or (A.Port > 65535) then
  begin
    TUIToastManager.Show('Porta inválida (o IMAP com TLS usa 993)', ttWarning, 3500);
    Exit;
  end;
  Existed := ImapHasPassword(A.Email);
  // A sessão lê a senha do Credential Manager: grava antes de testar.
  SaveImapPassword(A.Email, Pass);
  FImapTesting := True;
  TUIToastManager.Show('Testando ' + A.Host + '...', ttLoading, 4000);
  TTask.Run(
    procedure
    var
      Err: string;
      Ok: Boolean;
    begin
      try
        Ok := ImapTest(A, Err);
      except
        on E: Exception do
        begin
          Ok := False;
          Err := E.Message;
        end;
      end;
      QueueUI(
        procedure
        begin
          FImapTesting := False;
          if not Ok then
          begin
            if not Existed then
              ForgetImapPassword(A.Email);
            TUIToastManager.Show('Não entrou: ' + Err, ttError, 8000);
            Exit;
          end;
          Store.SaveImapAccount(A);
          FImapPass.Value := '';
          ReloadImaps;
          Changed;
          TUIToastManager.Show('Conta IMAP ligada: ' + A.Email, ttSuccess, 3500);
        end);
    end);
end;

procedure TGooglePage.ImapToggleClick(Sender: TObject);
var
  A: TImapAccount;
begin
  if (FImapSel < 0) or (FImapSel > High(FImaps)) then
  begin
    TUIToastManager.Show('Escolha uma conta na lista', ttInfo, 2500);
    Exit;
  end;
  A := FImaps[FImapSel];
  A.Enabled := not A.Enabled;
  Store.SaveImapAccount(A);
  ReloadImaps;
  Changed;
end;

procedure TGooglePage.ImapRemoveClick(Sender: TObject);
var
  A: TImapAccount;
begin
  if (FImapSel < 0) or (FImapSel > High(FImaps)) then
  begin
    TUIToastManager.Show('Escolha uma conta na lista', ttInfo, 2500);
    Exit;
  end;
  A := FImaps[FImapSel];
  FPending :=
    procedure
    begin
      ForgetImapPassword(A.Email);
      Store.DeleteImapAccount(A.Email);
      ReloadImaps;
      Changed;
    end;
  TUIToastManager.Show('Remover ' + A.Email + ' do Devbox? A senha salva nesta máquina é apagada.', ttWarning,
    10000, 'Confirmar', ConfirmClick);
end;

procedure TGooglePage.LoadClient;
begin
  LoadGoogleClient;
  // Só o cliente próprio aparece aqui; o embutido não vai para a tela.
  FClientId.Value := Store.GetSetting('google_client_id');
  // O segredo não volta para a tela: só se sabe que existe.
  FClientSecret.Value := '';
  FClientSecret.LabelText := IfThen((FClientId.Value <> '') and (LoadSecret('Devbox:google-client') <> ''),
    'Chave salva (vazio mantém)', 'Chave secreta');
end;

procedure TGooglePage.SaveClientClick(Sender: TObject);
var
  Secret: string;
begin
  Secret := Trim(FClientSecret.Value);
  if Secret = '' then
    Secret := LoadSecret('Devbox:google-client');
  SaveGoogleClient(FClientId.Value, Secret);
  LoadClient;
  TUIToastManager.Show('Cliente OAuth salvo', ttSuccess, 2000);
end;

procedure TGooglePage.HelpClick(Sender: TObject);
begin
  OpenUrl(CConsoleUrl);
end;

procedure TGooglePage.Reload;
var
  A: TGoogleAccount;
  I: Integer;
  State: string;
begin
  FAccounts := Store.ListGoogleAccounts;
  FTable.BeginRowUpdate;
  try
    FTable.ClearMemRows;
    for I := 0 to High(FAccounts) do
    begin
      A := FAccounts[I];
      if not GoogleSignedIn(A.Email) then
        State := 'sem login'
      else if A.Enabled then
        State := 'ligada'
      else
        State := 'desligada';
      FTable.AddMemRow([A.Email, State]);
    end;
  finally
    FTable.EndRowUpdate;
  end;
  FSel := -1;
end;

procedure TGooglePage.ReloadFeeds;
var
  F: TICalFeed;
  Host: string;
begin
  FFeeds := LoadICalFeeds;
  FFeedTable.BeginRowUpdate;
  try
    FFeedTable.ClearMemRows;
    for F in FFeeds do
    begin
      // Só o servidor: o resto do link é o segredo.
      Host := F.Url.Replace('webcal://', '').Replace('https://', '').Replace('http://', '');
      Host := Copy(Host, 1, Pos('/', Host + '/') - 1) + '/…';
      FFeedTable.AddMemRow([F.Name, Host]);
    end;
  finally
    FFeedTable.EndRowUpdate;
  end;
  FFeedSel := -1;
end;

procedure TGooglePage.FeedSelect(Sender: TObject; ARowIndex: Integer);
begin
  FFeedSel := ARowIndex;
end;

procedure TGooglePage.AddFeedClick(Sender: TObject);
var
  F: TICalFeed;
  Old: TICalFeed;
  Kept: TICalFeeds;
  Url: string;
begin
  F.Name := Trim(FFeedName.Value);
  Url := Trim(FFeedUrl.Value);
  if (F.Name = '') or not (StartsText('https://', Url) or StartsText('http://', Url) or
    StartsText('webcal://', Url)) then
  begin
    TUIToastManager.Show('Informe um nome e o link (https:// ou webcal://)', ttWarning, 3500);
    Exit;
  end;
  F.Url := Url;
  Kept := nil;
  // Mesmo nome troca o link em vez de duplicar.
  for Old in FFeeds do
    if not SameText(Old.Name, F.Name) then
      Kept := Kept + [Old];
  SaveICalFeeds(Kept + [F]);
  FFeedName.Value := '';
  FFeedUrl.Value := '';
  ReloadFeeds;
  Changed;
  TUIToastManager.Show('Agenda adicionada: ' + F.Name, ttSuccess, 2500);
end;

procedure TGooglePage.RemoveFeedClick(Sender: TObject);
var
  Kept: TICalFeeds;
  I: Integer;
begin
  if (FFeedSel < 0) or (FFeedSel > High(FFeeds)) then
  begin
    TUIToastManager.Show('Escolha uma agenda na lista', ttInfo, 2500);
    Exit;
  end;
  Kept := nil;
  for I := 0 to High(FFeeds) do
    if I <> FFeedSel then
      Kept := Kept + [FFeeds[I]];
  SaveICalFeeds(Kept);
  ReloadFeeds;
  Changed;
end;

procedure TGooglePage.TableSelect(Sender: TObject; ARowIndex: Integer);
begin
  FSel := ARowIndex;
end;

function TGooglePage.Selected(out AAccount: TGoogleAccount): Boolean;
begin
  Result := (FSel >= 0) and (FSel <= High(FAccounts));
  if Result then
    AAccount := FAccounts[FSel]
  else
    TUIToastManager.Show('Escolha uma conta na lista', ttInfo, 2500);
end;

procedure TGooglePage.Changed;
begin
  Reload;
  if Assigned(FOnAccountsChanged) then
    FOnAccountsChanged(Self);
end;

procedure TGooglePage.AddClick(Sender: TObject);
begin
  SignIn;
end;

procedure TGooglePage.ReloginClick(Sender: TObject);
var
  A: TGoogleAccount;
begin
  // Entrar de novo é o mesmo login: o Google devolve a conta escolhida.
  if Selected(A) then
    SignIn;
end;

procedure TGooglePage.SignIn;
var
  Client: TGoogleClient;
begin
  if FSigningIn then
  begin
    TUIToastManager.Show('Já tem um login aberto no navegador', ttInfo, 2500);
    Exit;
  end;
  if Trim(FClientId.Value) <> Store.GetSetting('google_client_id') then
    SaveClientClick(nil);
  Client := LoadGoogleClient;
  if not Client.Ready then
  begin
    TUIToastManager.Show('Informe o ID e a chave secreta do cliente OAuth antes', ttWarning, 4000);
    Exit;
  end;
  FSigningIn := True;
  TUIToastManager.Show('Abrindo o login do Google no navegador...', ttLoading, 4000);
  TTask.Run(
    procedure
    var
      Email, Err: string;
      Ok: Boolean;
    begin
      try
        Ok := GoogleSignIn(Client,
          procedure(AUrl: string)
          begin
            OpenUrl(AUrl);
          end, Email, Err);
      except
        on E: Exception do
        begin
          Ok := False;
          Err := E.Message;
        end;
      end;
      QueueUI(
        procedure
        begin
          FSigningIn := False;
          if Ok then
          begin
            Store.SaveGoogleAccount(Email, True);
            TUIToastManager.Show('Conta ligada: ' + Email, ttSuccess, 3500);
            Changed;
          end
          else
            TUIToastManager.Show('Login não concluído: ' + Err, ttError, 8000);
        end);
    end);
end;

procedure TGooglePage.ToggleClick(Sender: TObject);
var
  A: TGoogleAccount;
begin
  if not Selected(A) then
    Exit;
  Store.SaveGoogleAccount(A.Email, not A.Enabled);
  Changed;
end;

procedure TGooglePage.RemoveClick(Sender: TObject);
var
  A: TGoogleAccount;
begin
  if not Selected(A) then
    Exit;
  FPending :=
    procedure
    begin
      GoogleForget(A.Email);
      Store.DeleteGoogleAccount(A.Email);
      Changed;
      TUIToastManager.Show('Conta removida do Devbox', ttSuccess, 2500);
    end;
  TUIToastManager.Show('Remover ' + A.Email + ' do Devbox? O acesso salvo nesta máquina é apagado.', ttWarning,
    10000, 'Confirmar', ConfirmClick);
end;

procedure TGooglePage.ConfirmClick(Sender: TObject);
var
  Action: TProc;
begin
  Action := FPending;
  FPending := nil;
  if Assigned(Action) then
    Action();
end;

end.
