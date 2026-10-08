unit Devbox.Issues.UI.Account;

{ Modal de uma conta: conexão à esquerda, regras de aviso à direita. }

interface

uses
  System.Classes,
  Vcl.Controls,
  Vcl.Forms,
  Vcl.ExtCtrls,
  UI.Theme,
  UI.Input,
  UI.Select,
  UI.Toggle,
  UI.Checkbox,
  UI.NumberInput,
  UI.Button,
  UI.Fieldset,
  UI.Alert,
  UI.Labels,
  Devbox.Issues.Model;

type
  TAccountForm = class(TForm)
  private
    FAccount: TAccount;
    FLoading: Boolean;   // LoadFields em andamento: ignora OnChange dos campos
    FKind: TUISelect;
    FName: TUIInput;
    FUrl: TUIInput;
    FLogin: TUIInput;
    FToken: TUIInput;
    FTest: TUIButton;
    FTestResult: TUIAlert;
    FEnabled: TUIToggle;
    FEvents: array[TEventKind] of TUICheckbox;
    FEventsHost: TPanel;
    FDueDays: TUINumberInput;
    FDueField: TUIInput;
    FWarnDays: TUINumberInput;
    FCriticalDays: TUINumberInput;
    FDelete: TUIButton;
    FMyPrs: TUIToggle;
    FMyPrsRow: TControl;
    FMentions: TUIToggle;
    FMentionsRow: TControl;
    FOwnRepos: TUIToggle;
    FOwnReposRow: TControl;
    FExtraQuery: TUIInput;
    FInclude: TUIInput;
    FExclude: TUIInput;
    FPollMinutes: TUINumberInput;
    procedure Build;
    procedure LoadFields;
    procedure ReadFields;
    procedure SyncKindFields;
    procedure KindChange(Sender: TObject);
    procedure TestClick(Sender: TObject);
    procedure SaveClick(Sender: TObject);
    procedure DeleteClick(Sender: TObject);
    procedure CancelClick(Sender: TObject);
    function TokenOrStored: string;
  protected
    procedure CreateWnd; override;
  public
    constructor CreateFor(AOwner: TComponent; const AAccount: TAccount);
  end;

{ True quando algo mudou (salvou ou excluiu). }
function EditAccount(AOwner: TComponent; const AAccount: TAccount): Boolean;

implementation

uses
  Devbox.UI.Kit,
  Devbox.I18n,
  System.SysUtils,
  System.StrUtils,
  System.Math,
  System.Threading,
  UI.Tokens,
  UI.Painter.Vcl,
  UI.Containers,
  UI.Confirm,
  Devbox.Issues.Store,
  Devbox.Secrets,
  Devbox.Issues.Providers,
  Devbox.Issues.UI.Common;

const
  UrlHints: array[TProviderKind] of string = (
    'https://api.github.com, ou a URL da API do GitHub Enterprise',
    'Endereço do Jira, ex.: https://jira.empresa.com.br',
    'https://<empresa>.atlassian.net',
    'https://gitlab.com, ou o endereço do GitLab da empresa',
    'https://dev.azure.com/<organização>');
  TokenHints: array[TProviderKind] of string = (
    'PAT classic com os escopos repo e notifications',
    'Personal Access Token (Perfil > Tokens de acesso pessoal)',
    'API token de id.atlassian.com/manage-profile/security',
    'Personal access token com o escopo api (ou read_api só para ler)',
    'PAT do Azure DevOps com Work Items (leitura e escrita)');

function EditAccount(AOwner: TComponent; const AAccount: TAccount): Boolean;
var
  F: TAccountForm;
begin
  F := TAccountForm.CreateFor(AOwner, AAccount);
  try
    Result := F.ShowModal = mrOk;
  finally
    F.Free;
  end;
end;

constructor TAccountForm.CreateFor(AOwner: TComponent; const AAccount: TAccount);
begin
  inherited CreateNew(AOwner);
  FAccount := AAccount;
  Caption := IfThen(FAccount.Id = 0, Tr('Nova conta'), Tr('Conta: ') + FAccount.Name);
  ClientWidth := ScaleValue(1220);
  ClientHeight := ScaleValue(640);
  Position := poOwnerFormCenter;
  BorderStyle := bsDialog;
  DoubleBuffered := True;
  Color := UIThemeVclBackground;
  Build;
  LoadFields;
end;

procedure TAccountForm.CreateWnd;
begin
  inherited;
  ApplyTitleBarTheme(Self);
  FadeInOnShow(Self);
end;

procedure TAccountForm.Build;
var
  S: TUISpacingTokens;

  function NewPanel(AParent: TWinControl; AAlign: TAlign; AHeight: Integer = 0): TPanel;
  begin
    Result := TPanel.Create(Self);
    Result.BevelOuter := bvNone;
    Result.ParentBackground := False;
    Result.DoubleBuffered := True;
    Result.Color := UIThemeVclBackground;
    if AHeight > 0 then
      Result.Height := ScaleValue(AHeight);
    Result.Align := AAlign;
    Result.Parent := AParent;
  end;

  function NewFieldset(AParent: TWinControl; const ALegend: string; AAlign: TAlign): TUIFieldset;
  begin
    Result := TUIFieldset.Create(Self);
    Result.Legend := ALegend;
    // Topo maior para a legenda não ficar embaixo do primeiro campo.
    Result.Padding.SetBounds(Round(S.S4), Round(S.S8), Round(S.S4), Round(S.S3));
    Result.AlignWithMargins := True;
    Result.Margins.SetBounds(Round(S.S4), Round(S.S4), IfThen(AAlign = alLeft, 0, Round(S.S4)), 0);
    Result.Align := AAlign;
    Result.Parent := AParent;
  end;

  // Empilha de cima para baixo; a ordem de criação é a ordem na tela.
  procedure Stack(AControl: TControl; AParent: TWinControl; AGapTop: Integer);
  begin
    AControl.AlignWithMargins := True;
    AControl.Margins.SetBounds(0, AGapTop, 0, 0);
    AControl.Parent := AParent;
    // Top único e crescente: o alinhamento é adiado até a janela existir, e
    // com Tops iguais o VCL desempata fora da ordem de criação.
    AControl.Top := AParent.ControlCount * 1000;
    AControl.Align := alTop;
  end;

  function NewButton(const ACaption: string; AVariant: TUIButtonVariant;
    AOnClick: TNotifyEvent; AParent: TWinControl; AAlign: TAlign): TUIButton;
  begin
    Result := TUIButton.Create(Self);
    Result.Caption := ACaption;
    Result.Variant := AVariant;
    Result.AutoWidth := True;
    Result.OnClick := AOnClick;
    Result.AlignWithMargins := True;
    Result.Margins.SetBounds(IfThen(AAlign = alRight, Round(S.S2), 0), 0,
      IfThen(AAlign = alLeft, Round(S.S2), 0), 0);
    Result.Align := AAlign;
    Result.Parent := AParent;
  end;

  { Switch sem legenda + rótulo ao lado (a legenda do TUIToggle desalinhava). }
  function NewToggleRow(AParent: TWinControl; const ACaption: string; AGap: Integer;
    out ARow: TControl): TUIToggle;
  var
    R: TPanel;
    L: TUILabel;
  begin
    R := NewPanel(AParent, alTop, 28);
    Stack(R, AParent, AGap);
    ARow := R;
    Result := TUIToggle.Create(Self);
    Result.Width := ScaleValue(44);
    Result.Align := alLeft;
    Result.Parent := R;
    L := TUILabel.Create(Self);
    L.Caption := ACaption;
    L.AutoSize := False;
    L.AlignWithMargins := True;
    L.Margins.SetBounds(Round(S.S2), 0, 0, 0);
    L.Left := 1000;
    L.Align := alClient;
    L.Parent := R;
  end;

var
  Footer, Body, TestRow, RightCol, Row, Col: TPanel;
  Search: TUIFieldset;
  Dummy: TControl;
  Conn, Rules, Due: TUIFieldset;
  N: Integer;
  K: TProviderKind;
  E: TEventKind;
begin
  S := UITheme.Tokens.Spacing;

  Footer := NewPanel(Self, alBottom, 68);
  Footer.Padding.SetBounds(Round(S.S4), Round(S.S3), Round(S.S4), Round(S.S3));
  NewButton(Tr('Salvar'), bvPrimary, SaveClick, Footer, alRight).Default := True;
  NewButton(Tr('Cancelar'), bvOutline, CancelClick, Footer, alRight).Cancel := True;
  FDelete := NewButton(Tr('Excluir conta'), bvGhost, DeleteClick, Footer, alLeft);
  FDelete.Visible := FAccount.Id <> 0;

  Body := NewPanel(Self, alClient);
  Conn := NewFieldset(Body, Tr('Conexão'), alLeft);
  Conn.Width := ScaleValue(370);
  Search := NewFieldset(Body, Tr('Busca'), alLeft);
  Search.Width := ScaleValue(370);
  Search.Left := 2000;
  RightCol := NewPanel(Body, alClient);
  Rules := NewFieldset(RightCol, Tr('Avisos'), alTop);
  Rules.Height := ScaleValue(300);
  Due := NewFieldset(RightCol, Tr('Prazo'), alClient);
  Due.Top := 100000;

  // Conexão
  FKind := TUISelect.Create(Self);
  FKind.Caption := Tr('Provedor');
  for K := Low(TProviderKind) to High(TProviderKind) do
    FKind.Items.Add(ProviderNames[K]);
  FKind.OnChange := KindChange;
  Stack(FKind, Conn, 0);

  FName := TUIInput.Create(Self);
  FName.LabelMode := ilmBorder;  // rótulo na borda: texto inteiro sem fonte maior
  FName.ReserveHintSpace := False;  // a dica vai dentro do campo; embaixo duplicava
  FName.LabelText := Tr('Nome da conta');
  FName.HintText := Tr('Como aparece na lista, ex.: Trabalho, Pessoal');
  FName.Required := True;
  Stack(FName, Conn, Round(S.S2));

  FUrl := TUIInput.Create(Self);
  FUrl.LabelMode := ilmBorder;  // rótulo na borda: texto inteiro sem fonte maior
  FUrl.ReserveHintSpace := False;  // a dica vai dentro do campo; embaixo duplicava
  FUrl.LabelText := Tr('URL base');
  Stack(FUrl, Conn, Round(S.S2));

  FLogin := TUIInput.Create(Self);
  FLogin.LabelMode := ilmBorder;  // rótulo na borda: texto inteiro sem fonte maior
  FLogin.ReserveHintSpace := False;  // a dica vai dentro do campo; embaixo duplicava
  FLogin.LabelText := Tr('E-mail da conta Atlassian');
  FLogin.InputType := uitEmail;
  Stack(FLogin, Conn, Round(S.S2));

  FToken := TUIInput.Create(Self);
  FToken.LabelMode := ilmBorder;  // rótulo na borda: texto inteiro sem fonte maior
  FToken.ReserveHintSpace := False;  // a dica vai dentro do campo; embaixo duplicava
  FToken.LabelText := Tr('Token de acesso');
  FToken.PasswordChar := '*';
  FToken.PasswordToggle := True;
  Stack(FToken, Conn, Round(S.S2));

  TestRow := NewPanel(Conn, alTop, 40);
  TestRow.Top := Conn.ControlCount * 1000;
  TestRow.AlignWithMargins := True;
  TestRow.Margins.SetBounds(0, Round(S.S3), 0, 0);
  FTest := NewButton(Tr('Testar conexão'), bvOutline, TestClick, TestRow, alLeft);

  FTestResult := TUIAlert.Create(Self);
  FTestResult.Style_ := asSoft;
  FTestResult.Visible := False;
  Stack(FTestResult, Conn, Round(S.S3));

  // Busca: o que mais entra na lista além do associado/review/manual.
  FMyPrs := NewToggleRow(Search, Tr('Meus PRs (aprovação, mudanças e CI)'), 0, FMyPrsRow);
  FOwnRepos := NewToggleRow(Search, Tr('Issues dos meus repositórios'), Round(S.S2), FOwnReposRow);
  FMentions := NewToggleRow(Search, Tr('Issues em que fui mencionado'), Round(S.S2), FMentionsRow);
  FExtraQuery := TUIInput.Create(Self);
  FExtraQuery.LabelMode := ilmBorder;  // rótulo na borda: texto inteiro sem fonte maior
  FExtraQuery.ReserveHintSpace := False;  // a dica vai dentro do campo; embaixo duplicava
  FExtraQuery.LabelText := Tr('Busca extra');
  Stack(FExtraQuery, Search, Round(S.S3));
  FInclude := TUIInput.Create(Self);
  FInclude.LabelMode := ilmBorder;  // rótulo na borda: texto inteiro sem fonte maior
  FInclude.ReserveHintSpace := False;  // a dica vai dentro do campo; embaixo duplicava
  Stack(FInclude, Search, Round(S.S2));
  FExclude := TUIInput.Create(Self);
  FExclude.LabelMode := ilmBorder;  // rótulo na borda: texto inteiro sem fonte maior
  FExclude.ReserveHintSpace := False;  // a dica vai dentro do campo; embaixo duplicava
  Stack(FExclude, Search, Round(S.S2));
  Row := NewPanel(Search, alTop, 64);
  Stack(Row, Search, Round(S.S2));
  FPollMinutes := TUINumberInput.Create(Self);
  FPollMinutes.LabelText := Tr('Buscar a cada (0 = padrão)');
  FPollMinutes.SuffixText := Tr('min');
  FPollMinutes.Min := 0;
  FPollMinutes.Max := 240;
  FPollMinutes.Width := ScaleValue(200);
  FPollMinutes.Align := alLeft;
  FPollMinutes.Parent := Row;

  // Avisos
  FEnabled := NewToggleRow(Rules, Tr('Conta ligada'), 0, Dummy);

  // Tipos de aviso em duas colunas; SyncKindFields mostra só os do provedor.
  FEventsHost := NewPanel(Rules, alTop, 28);
  Stack(FEventsHost, Rules, Round(S.S4));
  for E := Low(TEventKind) to High(TEventKind) do
  begin
    FEvents[E] := TUICheckbox.Create(Self);
    FEvents[E].Caption := Tr(EventNames[E]);
    FEvents[E].Parent := FEventsHost;
  end;

  // Prazo
  FDueField := TUIInput.Create(Self);
  FDueField.LabelMode := ilmBorder;  // rótulo na borda: texto inteiro sem fonte maior
  FDueField.ReserveHintSpace := False;  // a dica vai dentro do campo; embaixo duplicava
  FDueField.LabelText := Tr('Campo da data de entrega (Jira)');
  FDueField.HintText := Tr('Nome ou id do campo, ex.: Data Acordo Entrega. Vazio = Data limite.');
  Stack(FDueField, Due, 0);

  // Três números lado a lado.
  Row := NewPanel(Due, alTop, 84);
  Stack(Row, Due, Round(S.S3));
  FDueDays := TUINumberInput.Create(Self);
  FWarnDays := TUINumberInput.Create(Self);
  FCriticalDays := TUINumberInput.Create(Self);
  FDueDays.LabelText := Tr('Avisar com');
  FWarnDays.LabelText := Tr('Laranja até');
  FCriticalDays.LabelText := Tr('Vermelho até');
  N := 0;
  for var NI in [FDueDays, FWarnDays, FCriticalDays] do
  begin
    NI.SuffixText := Tr('dias');
    NI.Min := 0;
    NI.Max := 90;
    Col := NewPanel(Row, alLeft);
    Col.Width := ScaleValue(130);
    Col.Left := (N + 1) * 1000;
    Col.Padding.SetBounds(0, 0, Round(S.S2), 0);
    NI.Align := alClient;
    NI.Parent := Col;
    Inc(N);
  end;
end;

procedure TAccountForm.SyncKindFields;
const
  CEventColW = 200;
  CEventRowH = 36;
  GitHubOnlyEvents = [ekReviewRequested, ekPrApproved, ekChangesRequested, ekCiFailed];
var
  Kind: TProviderKind;
  E: TEventKind;
  N: Integer;
begin
  Kind := TProviderKind(FKind.ItemIndex);
  FLogin.Visible := Kind = pkJiraCloud;
  // Grade de duas colunas só com os avisos que o provedor tem.
  N := 0;
  for E := Low(TEventKind) to High(TEventKind) do
  begin
    FEvents[E].Visible := not ((E in GitHubOnlyEvents) and not (Kind in RepoKinds)) and
      not ((E = ekFlagged) and (Kind in RepoKinds));
    if not FEvents[E].Visible then
      Continue;
    FEvents[E].SetBounds((N mod 2) * ScaleValue(CEventColW), (N div 2) * ScaleValue(CEventRowH),
      ScaleValue(CEventColW - 8), ScaleValue(28));
    Inc(N);
  end;
  FEventsHost.Height := ((N + 1) div 2) * ScaleValue(CEventRowH);
  // GitHub: issue não tem prazo; vem de um campo de data do Projects.
  case Kind of
    pkGitHub:
      begin
        FDueField.LabelText := Tr('Campo de data do Projects (GitHub)');
        FDueField.HintText := Tr('Nome do campo de data no Projects, ex.: Prazo. Vazio = sem prazo.');
      end;
    pkGitLab:
      begin
        // GitLab já tem due_date na issue (e o milestone como reserva).
        FDueField.LabelText := Tr('Prazo');
        FDueField.HintText := Tr('O GitLab usa a data de entrega da issue ou do milestone.');
      end;
    pkAzure:
      begin
        FDueField.LabelText := Tr('Campo de prazo (Azure)');
        FDueField.HintText := Tr('Nome de referência, ex.: Custom.Prazo. Vazio = Due Date ou Target Date.');
      end;
  else
    FDueField.LabelText := Tr('Campo da data de entrega (Jira)');
    FDueField.HintText := Tr('Nome ou id do campo, ex.: Data Acordo Entrega. Vazio = Data limite.');
  end;
  FDueField.Enabled := Kind <> pkGitLab;
  FMyPrsRow.Visible := Kind in RepoKinds;
  FMentionsRow.Visible := Kind in [pkGitHub, pkGitLab, pkAzure];
  FOwnReposRow.Visible := Kind = pkGitHub;
  if Kind in RepoKinds then
  begin
    if Kind = pkGitLab then
      FExtraQuery.HintText := Tr('Parâmetros da API de issues, ex.: labels=bug&milestone=Sprint 5')
    else
      FExtraQuery.HintText := Tr('Query do GitHub, ex.: repo:dono/app label:bug');
    FInclude.LabelText := Tr('Só destes repositórios ou donos');
    FInclude.HintText := Tr('dono/repo ou dono, separados por vírgula. Vazio = todos.');
    FExclude.LabelText := Tr('Ignorar repositórios ou donos');
  end
  else if Kind = pkAzure then
  begin
    FExtraQuery.HintText := 'Trecho de WIQL, ex.: [System.AreaPath] UNDER ''App\Pagamentos''';
    FInclude.LabelText := Tr('Só destes projetos');
    FInclude.HintText := Tr('Nome do projeto, separados por vírgula. Vazio = todos.');
    FExclude.LabelText := Tr('Ignorar projetos');
  end
  else
  begin
    FExtraQuery.HintText := Tr('JQL, ex.: project = ABC AND labels = urgente');
    FInclude.LabelText := Tr('Só destes projetos');
    FInclude.HintText := Tr('Chave do projeto (ex.: APP), separadas por vírgula. Vazio = todos.');
    FExclude.LabelText := Tr('Ignorar projetos');
  end;
  FExclude.HintText := Tr('Mesmo formato. Acompanhamento manual nunca é ignorado.');
  FUrl.HintText := Tr(UrlHints[Kind]);
  if FAccount.Id = 0 then
    FToken.HintText := Tr(TokenHints[Kind])
  else
    FToken.HintText := Tr('Já existe um token salvo. Deixe vazio para manter.');
end;

procedure TAccountForm.LoadFields;
var
  E: TEventKind;
begin
  FLoading := True;
  try
    FKind.ItemIndex := Ord(FAccount.Kind);
    FName.Value := FAccount.Name;
    FUrl.Value := FAccount.BaseUrl;
    FLogin.Value := FAccount.Login;
    FToken.Value := '';
    FEnabled.Checked := FAccount.Enabled;
    for E := Low(TEventKind) to High(TEventKind) do
      FEvents[E].Checked := E in FAccount.Events;
    FDueDays.Value := FAccount.DueDays;
    FDueField.Value := FAccount.DueField;
    FWarnDays.Value := FAccount.WarnDays;
    FCriticalDays.Value := FAccount.CriticalDays;
    FMyPrs.Checked := FAccount.MyPrs;
    FMentions.Checked := FAccount.Mentions;
    FOwnRepos.Checked := FAccount.OwnRepos;
    FExtraQuery.Value := FAccount.ExtraQuery;
    FInclude.Value := FAccount.IncludeList;
    FExclude.Value := FAccount.ExcludeList;
    FPollMinutes.Value := FAccount.PollMinutes;
    SyncKindFields;
  finally
    FLoading := False;
  end;
end;

procedure TAccountForm.ReadFields;
var
  E: TEventKind;
begin
  FAccount.Kind := TProviderKind(FKind.ItemIndex);
  FAccount.Name := FName.Value.Trim;
  FAccount.BaseUrl := FUrl.Value.Trim;
  FAccount.Login := FLogin.Value.Trim;
  FAccount.Enabled := FEnabled.Checked;
  FAccount.Events := [];
  for E := Low(TEventKind) to High(TEventKind) do
    if FEvents[E].Checked then
      Include(FAccount.Events, E);
  FAccount.DueDays := Round(FDueDays.Value);
  FAccount.DueField := FDueField.Value.Trim;
  FAccount.WarnDays := Round(FWarnDays.Value);
  FAccount.CriticalDays := Round(FCriticalDays.Value);
  FAccount.MyPrs := FMyPrs.Checked;
  FAccount.Mentions := FMentions.Checked;
  FAccount.OwnRepos := FOwnRepos.Checked;
  FAccount.ExtraQuery := FExtraQuery.Value.Trim;
  FAccount.IncludeList := FInclude.Value.Trim;
  FAccount.ExcludeList := FExclude.Value.Trim;
  FAccount.PollMinutes := Round(FPollMinutes.Value);
end;

procedure TAccountForm.KindChange(Sender: TObject);
var
  Old: TProviderKind;
begin
  if FLoading or (FKind.ItemIndex < 0) then
    Exit;
  Old := FAccount.Kind;
  ReadFields;
  // Troca a URL só se ainda for a padrão do provedor anterior.
  if (FAccount.BaseUrl = '') or (FAccount.BaseUrl = DefaultBaseUrls[Old]) then
    FUrl.Value := DefaultBaseUrls[FAccount.Kind];
  FTestResult.Visible := False;
  SyncKindFields;
end;

function TAccountForm.TokenOrStored: string;
begin
  Result := FToken.Value.Trim;
  if (Result = '') and (FAccount.Id <> 0) then
    Result := LoadSecret(FAccount.SecretTarget);
end;

procedure TAccountForm.TestClick(Sender: TObject);
var
  A: TAccount;
  Token: string;
begin
  ReadFields;
  A := FAccount;
  Token := TokenOrStored;
  FTest.Loading := True;
  FTestResult.Visible := False;
  RunTask(
    procedure
    var
      Who, Err: string;
    begin
      try
        Who := TestConnection(A, Token);
      except
        on Ex: Exception do
          Err := Ex.Message;
      end;
      QueueUI(
        procedure
        begin
          FTest.Loading := False;
          if Err = '' then
          begin
            FTestResult.Tone := atSuccess;
            FTestResult.Title := Tr('Conectado');
            FTestResult.Message_ := Tr('Entrou como ') + Who;
          end
          else
          begin
            FTestResult.Tone := atError;
            FTestResult.Title := Tr('Não conectou');
            FTestResult.Message_ := Err;
          end;
          FTestResult.Visible := True;
        end);
    end);
end;

procedure TAccountForm.SaveClick(Sender: TObject);
var
  Token: string;
begin
  ReadFields;
  FName.ErrorMessage := '';
  FToken.ErrorMessage := '';
  if FAccount.Name = '' then
  begin
    FName.ErrorMessage := Tr('Informe um nome');
    Exit;
  end;
  Token := FToken.Value.Trim;
  if (FAccount.Id = 0) and (Token = '') then
  begin
    FToken.ErrorMessage := Tr('Informe o token');
    Exit;
  end;
  IssueStore.SaveAccount(FAccount);
  if Token <> '' then
    SaveSecret(FAccount.SecretTarget, FAccount.Login, Token);
  ModalResult := mrOk;
end;

procedure TAccountForm.DeleteClick(Sender: TObject);
begin
  if not TUIConfirm.Show(TVclWinControlContainer.Create(Self, False), Tr('Excluir conta'),
    Tr('Excluir "') + FAccount.Name + Tr('", o token salvo e o histórico dela?'), btError) then
    Exit;
  IssueStore.DeleteAccount(FAccount.Id);
  DeleteSecret(FAccount.SecretTarget);
  ModalResult := mrOk;
end;

procedure TAccountForm.CancelClick(Sender: TObject);
begin
  ModalResult := mrCancel;
end;

end.
