unit Devbox.Issues.Model;

{ Issues (vindo do Vigia 0.23.0): contas, itens, eventos e tags de GitHub, Jira, GitLab e Azure DevOps.
  TEvent do Vigia virou TIssueEvent (System.SyncObjs também tem TEvent). }

interface

type
  TProviderKind = (pkGitHub, pkJiraServer, pkJiraCloud, pkGitLab, pkAzure);

  { Formato da chave de acompanhamento manual: 'dono/repo#12' (GitHub, GitLab),
    'PROJ-123' (Jira), 'Projeto#123' (Azure DevOps). }
  TKeyFamily = (kfNone, kfRepo, kfJira, kfAzure);

  TEventKind = (ekAssigned, ekComment, ekMention, ekStatus, ekDueSoon,
    ekOverdue, ekReviewRequested, ekFlagged, ekPrApproved, ekChangesRequested, ekCiFailed);
  TEventKinds = set of TEventKind;

  TAccount = record
    Id: Integer;          // 0 = ainda não salva
    Name: string;
    Kind: TProviderKind;
    BaseUrl: string;
    Login: string;        // e-mail no Jira Cloud; vazio nos outros
    Enabled: Boolean;
    Events: TEventKinds;
    DueDays: Integer;
    DueField: string;     // Jira: nome ou id do campo de data de entrega; vazio = duedate
    WarnDays: Integer;    // prazo fica laranja com até N dias
    CriticalDays: Integer;// prazo fica vermelho com até N dias (vencido também)
    MyPrs: Boolean;       // GitHub: traz os PRs que abri (review e CI)
    OwnRepos: Boolean;    // GitHub: traz as issues abertas dos meus repositórios
    Mentions: Boolean;    // GitHub: traz issues em que fui mencionado
    ExtraQuery: string;   // busca a mais: query do GitHub ou JQL do Jira
    IncludeList: string;  // só estes repos/orgs (GitHub) ou projetos (Jira); vírgula ou ;
    ExcludeList: string;  // ignora estes
    PollMinutes: Integer; // 0 = intervalo geral das Configurações
    function SecretTarget: string;
  end;

  // Por que o item está na lista.
  TItemSource = (isAssigned, isWatching, isReview, isMine, isMention, isQuery, isOwnRepo, isSprint);
  TItemSources = set of TItemSource;

  { Issue/PR normalizado, igual para GitHub e Jira. }
  TItem = record
    AccountId: Integer;
    Key: string;              // 'owner/repo#12' ou 'PROJ-123'
    Title: string;
    Url: string;              // link para o navegador
    Status: string;
    StatusCategory: string;   // 'new', 'indeterminate' ou 'done' (Jira); GitHub: new/done
    Flagged: Boolean;         // Jira: campo Flagged marcado (impedimento)
    Assignee: string;
    DueDate: TDateTime;       // 0 = sem prazo; Jira usa o DueField da conta quando houver
    UpdatedAt: TDateTime;     // UTC
    CommentCount: Integer;
    LastCommentBy: string;    // vazio no GitHub (vem pelas notifications)
    LastCommentText: string;
    MentionsMe: Boolean;      // último comentário (Jira) ou notification 'mention' (GitHub)
    UnreadReason: string;     // GitHub: reason da notification não lida; vazio no Jira
    Sources: TItemSources;
    DueAlert: Integer;        // 0 nada avisado, 1 avisou "chegando", 2 avisou "vencido"
    ReviewState: string;      // PR: APPROVED, CHANGES_REQUESTED, REVIEW_REQUIRED ou vazio
    CiState: string;          // PR: SUCCESS, FAILURE, ERROR, PENDING ou vazio
    CiDetail: string;         // PR: nome do job que falhou
    CiUrl: string;            // PR: link do job que falhou
    Reviewers: string;        // PR: 'aprovado: a, b · mudanças: c'
    ThreadId: string;         // GitHub: notification não lida (para marcar como lida)
    NodeId: string;           // GitHub: id GraphQL (não vai para o banco)
  end;
  TItems = TArray<TItem>;

  TIssueEvent = record
    Kind: TEventKind;
    AccountId: Integer;
    Key: string;
    Url: string;
    Title: string;            // título do toast
    Body: string;             // texto do toast
    At: TDateTime;            // preenchido ao ler do histórico
  end;
  TIssueEvents = TArray<TIssueEvent>;

  // Campo que a transição pede na tela do Jira.
  TTransitionField = record
    Id: string;
    Name: string;
    Kind: string;               // string, number, date, option, array-option, user, outro
    Required: Boolean;
    Allowed: TArray<string>;    // valores possíveis (option)
  end;

  // Mudança de status possível agora (Jira: transição do fluxo; GitHub: fechar/reabrir).
  TTransition = record
    Id: string;
    Name: string;       // nome da ação, ex.: "Iniciar desenvolvimento"
    ToStatus: string;   // status de destino
    Fields: TArray<TTransitionField>;
  end;

  TIssueLink = record
    Kind: string;       // "bloqueia", "relacionada a"...
    Key: string;
    Summary: string;
    Url: string;
  end;

  TAttachment = record
    Name: string;
    Url: string;
    Size: Int64;
  end;

  { Detalhes buscados na hora para o painel: descrição, anexos e links. }
  TIssueInfo = record
    Description: string;
    Attachments: TArray<TAttachment>;
    Links: TArray<TIssueLink>;
  end;
  TTransitions = TArray<TTransition>;

  TComment = record
    Author: string;           // nome para exibir
    AuthorId: string;         // login/name/accountId, para saber se é meu
    At: TDateTime;            // UTC
    Text: string;
  end;
  TComments = TArray<TComment>;

  // Quem é o dono do token, para separar ação minha de ação dos outros.
  TIdentity = record
    Id: string;               // GitHub login, Jira Server 'name', Jira Cloud accountId
    DisplayName: string;
  end;

  // Agrupador criado pelo usuário (ex.: "Pagamentos", "Mobile"). A issue entra pela
  // marcação manual ou porque o título tem uma das palavras-chave.
  TTag = record
    Id: Integer;
    AccountId: Integer;            // tag é de uma conta (a do Jira não aparece no GitHub)
    Name: string;
    Keywords: string;              // separadas por vírgula; vazio = só manual
    Manual: TArray<string>;        // ItemTagKey das issues marcadas à mão
    function HasManual(AAccountId: Integer; const AKey: string): Boolean;
    function ByKeyword(const ATitle: string): Boolean;
    function Matches(const AItem: TItem): Boolean;
  end;
  TTags = TArray<TTag>;

const
  ProviderNames: array[TProviderKind] of string = (
    'GitHub', 'Jira Server/DC', 'Jira Cloud', 'GitLab', 'Azure DevOps');

  DefaultBaseUrls: array[TProviderKind] of string = (
    'https://api.github.com', 'https://',
    'https://<empresa>.atlassian.net', 'https://gitlab.com', 'https://dev.azure.com/<organização>');

  // Curto, para caber ao lado do nome da conta no seletor.
  ShortProviderNames: array[TProviderKind] of string = ('GitHub', 'Jira', 'Jira Cloud', 'GitLab', 'Azure');

  EventNames: array[TEventKind] of string = (
    'Fui associado', 'Novo comentário', 'Menção', 'Mudança de status',
    'Prazo chegando', 'Prazo vencido', 'Review de PR pedido', 'Sinalizada',
    'PR aprovado', 'Mudanças pedidas', 'CI falhou');

  AllEvents = [Low(TEventKind)..High(TEventKind)];

  // Issues e PRs/MRs de repositório (avisos por notificação, chave dono/repo#12).
  RepoKinds = [pkGitHub, pkGitLab];
  JiraKinds = [pkJiraServer, pkJiraCloud];
  // Registram horas na issue.
  WorklogKinds = [pkJiraServer, pkJiraCloud, pkGitLab];
  KeyFamilies: array[TProviderKind] of TKeyFamily = (kfRepo, kfJira, kfJira, kfRepo, kfAzure);

function NewAccount(AKind: TProviderKind): TAccount;
function ItemTagKey(AAccountId: Integer; const AKey: string): string;
{ Nome da preferência onde fica a sugestão de triagem da IA para a issue. }
function TriageSettingName(AAccountId: Integer; const AKey: string): string;
{ Filtro de repositórios/projetos da conta. GitHub 'dono/repo#12' casa com
  'dono/repo' ou 'dono'; Jira 'PROJ-12' casa com 'PROJ'. Incluir vazio = tudo. }
function ItemAllowed(const AAccount: TAccount; const AKey: string): Boolean;
{ 'dono/repo' de uma chave do GitHub ('dono/repo#12'); vazio no Jira. }
function RepoOf(const AKey: string): string;

implementation

uses
  System.SysUtils;

function TAccount.SecretTarget: string;
begin
  // O token continua onde o Vigia guardou: a unificação não copia segredo.
  Result := 'Vigia:' + IntToStr(Id);
end;

function TriageSettingName(AAccountId: Integer; const AKey: string): string;
begin
  Result := 'triage:' + ItemTagKey(AAccountId, AKey);
end;

function ItemTagKey(AAccountId: Integer; const AKey: string): string;
begin
  Result := IntToStr(AAccountId) + '|' + AKey.ToUpper;
end;

function ListHas(const AList, ARepo, AOwner: string): Boolean;
var
  W: string;
begin
  for W in AList.Split([',', ';']) do
    if (W.Trim <> '') and (SameText(W.Trim, ARepo) or SameText(W.Trim, AOwner)) then
      Exit(True);
  Result := False;
end;

function RepoOf(const AKey: string): string;
var
  P: Integer;
begin
  // GitLab: MR é 'grupo/projeto!5'.
  P := AKey.IndexOfAny(['#', '!']);
  if P > 0 then
    Result := AKey.Substring(0, P)
  else
    Result := '';
end;

function ItemAllowed(const AAccount: TAccount; const AKey: string): Boolean;
var
  Repo, Owner: string;
begin
  if RepoOf(AKey) <> '' then
  begin
    Repo := RepoOf(AKey);
    // Azure 'Projeto#12' não tem dono: o projeto vale pelos dois.
    if Repo.Contains('/') then
      Owner := Repo.Substring(0, Repo.IndexOf('/'))
    else
      Owner := Repo;
  end
  else
  begin
    Repo := AKey.Substring(0, AKey.IndexOf('-'));
    Owner := Repo;
  end;
  Result := ((AAccount.IncludeList.Trim = '') or ListHas(AAccount.IncludeList, Repo, Owner)) and
    not ListHas(AAccount.ExcludeList, Repo, Owner);
end;

function TTag.HasManual(AAccountId: Integer; const AKey: string): Boolean;
var
  K, S: string;
begin
  K := ItemTagKey(AAccountId, AKey);
  for S in Manual do
    if S = K then
      Exit(True);
  Result := False;
end;

function TTag.ByKeyword(const ATitle: string): Boolean;
var
  W: string;
begin
  for W in Keywords.Split([',', ';']) do
    if (W.Trim <> '') and ATitle.ToUpper.Contains(W.Trim.ToUpper) then
      Exit(True);
  Result := False;
end;

function TTag.Matches(const AItem: TItem): Boolean;
begin
  if (AccountId <> 0) and (AItem.AccountId <> AccountId) then
    Exit(False);
  Result := HasManual(AItem.AccountId, AItem.Key) or ByKeyword(AItem.Title);
end;

function NewAccount(AKind: TProviderKind): TAccount;
begin
  Result := Default(TAccount);
  Result.Kind := AKind;
  Result.BaseUrl := DefaultBaseUrls[AKind];
  Result.Enabled := True;
  Result.Events := AllEvents;
  Result.DueDays := 2;
  Result.WarnDays := 5;
  Result.CriticalDays := 2;
  Result.MyPrs := AKind in RepoKinds;
  Result.OwnRepos := AKind = pkGitHub;
end;

end.
