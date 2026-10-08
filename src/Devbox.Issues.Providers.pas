unit Devbox.Issues.Providers;

{ Chamadas HTTP ao GitHub, GitLab, Jira e Azure DevOps, normalizadas em TItem.
  Tudo bloqueante: chamar fora da thread de UI.
  As funções Parse* ficam públicas para o self-check rodar sem rede. }

interface

uses
  System.JSON,
  Devbox.Issues.Model;

function WhoAmI(const AAccount: TAccount; const AToken: string): TIdentity;

{ Devolve o nome do usuário autenticado ou levanta exceção com o motivo. }
function TestConnection(const AAccount: TAccount; const AToken: string): string;

{ Itens abertos: associados a mim, review pedido, observados (watcher no Jira)
  e os cadastrados à mão em AManualKeys. }
function FetchItems(const AAccount: TAccount; const AToken: string;
  const AManualKeys: TArray<string>; out AMe: TIdentity): TItems;

{ Confere que a issue existe e devolve o título. Levanta exceção se não existir.
  Usado antes de salvar um acompanhamento manual (chave errada derruba a JQL). }
function CheckItem(const AAccount: TAccount; const AToken, AKey: string): string;

{ Últimos comentários da issue (mais antigos primeiro), no máximo AMax. }
function FetchComments(const AAccount: TAccount; const AToken, AKey: string;
  AMax: Integer = 20): TComments;

{ Mudanças de status disponíveis para a issue. }
function FetchTransitions(const AAccount: TAccount; const AToken, AKey: string): TTransitions;

{ Aplica a mudança. Levanta exceção com a mensagem do servidor se recusar
  (ex.: transição que exige campos na tela do Jira). }
procedure ApplyTransition(const AAccount: TAccount; const AToken, AKey: string;
  const ATransition: TTransition);

{ Mesma coisa com os campos que a transição pede: AValues = ['id=valor', ...]. }
procedure ApplyTransitionWith(const AAccount: TAccount; const AToken, AKey: string;
  const ATransition: TTransition; const AValues: TArray<string>);

{ Publica um comentário na issue. }
procedure PostComment(const AAccount: TAccount; const AToken, AKey, AText: string);

{ ── Ações (escrita; sempre depois de confirmação do usuário) ── }
procedure AssignToMe(const AAccount: TAccount; const AToken, AKey: string);
procedure AddLabel(const AAccount: TAccount; const AToken, AKey, ALabel: string);
procedure ApprovePr(const AAccount: TAccount; const AToken, AKey: string);
procedure MarkNotificationRead(const AAccount: TAccount; const AToken, AThreadId: string);
function FetchPriorities(const AAccount: TAccount; const AToken: string): TArray<string>;
procedure SetPriority(const AAccount: TAccount; const AToken, AKey, AName: string);
{ Jira: liga/desliga o Flagged; com motivo, comenta "Impedimento: motivo". }
procedure SetImpediment(const AAccount: TAccount; const AToken, AKey: string; AOn: Boolean;
  const AReason: string);
{ Cria issue. AWhere = projeto (Jira) ou 'dono/repo' (GitHub). Devolve a chave. }
function CreateIssue(const AAccount: TAccount; const AToken, AWhere, ATitle, ABody: string): string;

{ ── Consultas para o painel e o resumo ── }
function FetchIssueInfo(const AAccount: TAccount; const AToken, AKey: string): TIssueInfo;
{ Jira: horas que lancei hoje e nesta semana (segunda a hoje). }
procedure FetchWeekHours(const AAccount: TAccount; const AToken: string; out AToday, AWeek: Double);
{ GitHub: log de um job do Actions (texto, cortado no fim). Vazio se não for Actions. }
function FetchJobLog(const AAccount: TAccount; const AToken, AJobUrl: string): string;

{ Jira: registra horas na issue (worklog). AStarted em hora local. }
procedure AddWorklog(const AAccount: TAccount; const AToken, AKey: string;
  AHours: Double; AStarted: TDateTime; const AComment: string);

{ 'dono/repo#12' (ou '!5' no GitLab) -> kfRepo; 'PROJ-123' -> kfJira;
  'Projeto#123' -> kfAzure; outro formato -> vazio. Já normalizada. }
function NormalizeManualKey(const AKey: string; out AFamily: TKeyFamily): string;

{ Texto de comentário para exibir: tira tags HTML e decodifica entidades
  (o Jira Server devolve '&aacute;' e afins em alguns comentários). }
function CleanCommentText(const S: string): string;
function WikiToText(const S: string): string;
{ Markdown do GitHub para texto lido de primeira (código, negrito, links, listas). }
function MarkdownToText(const S: string): string;

// Parse puro, exposto para teste.
function ParseIsoDate(const S: string): TDateTime;
function AdfToText(AValue: TJSONValue; const AMeId: string; out AMentionsMe: Boolean): string;
function ParseGitHubIssue(AJson: TJSONObject; AAccountId: Integer): TItem;
function GitHubKeyFromApiUrl(const AUrl: string): string;
function ParseJiraIssue(AJson: TJSONObject; const AAccount: TAccount;
  const AMe: TIdentity; const AFlagField: string = ''; const ADueField: string = ''): TItem;
function ParseGitLabItem(AJson: TJSONObject; AAccountId: Integer; AIsMR: Boolean): TItem;
function ParseAzureItem(AJson: TJSONObject; const AAccount: TAccount; const AMe: TIdentity): TItem;

implementation

uses
  System.SysUtils,
  System.Classes,
  System.StrUtils,
  System.DateUtils,
  System.TimeSpan,
  System.Math,
  System.RegularExpressions,
  System.Generics.Collections,
  System.NetEncoding,
  System.Net.URLClient,
  System.Net.HttpClient,
  Winapi.Windows;

const
  // Jira atrás de Cloudflare devolve 403 sem User-Agent de navegador.
  BrowserUA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
    '(KHTML, like Gecko) Chrome/124.0 Safari/537.36';
  PageSize = 100;
  // ponytail: teto de 3 páginas por consulta; subir se alguém tiver >300 issues abertas.
  MaxPages = 3;

{ ── HTTP ─────────────────────────────────────────────────────────────────── }

function TrimSlash(const AUrl: string): string;
begin
  Result := AUrl.Trim;
  while Result.EndsWith('/') do
    Result := Result.Substring(0, Result.Length - 1);
end;

function Enc(const S: string): string;
begin
  Result := TNetEncoding.URL.Encode(S);
end;

function AuthHeaders(const AAccount: TAccount; const AToken: string): TNetHeaders;
begin
  case AAccount.Kind of
    pkGitHub:
      Result := [TNameValuePair.Create('Authorization', 'Bearer ' + AToken),
        TNameValuePair.Create('Accept', 'application/vnd.github+json'),
        TNameValuePair.Create('X-GitHub-Api-Version', '2022-11-28'),
        TNameValuePair.Create('User-Agent', 'Devbox')];
    pkJiraServer:
      Result := [TNameValuePair.Create('Authorization', 'Bearer ' + AToken),
        TNameValuePair.Create('Accept', 'application/json'),
        TNameValuePair.Create('User-Agent', BrowserUA)];
    pkJiraCloud:
      Result := [TNameValuePair.Create('Authorization', 'Basic ' +
          TNetEncoding.Base64String.Encode(AAccount.Login + ':' + AToken)),
        TNameValuePair.Create('Accept', 'application/json')];
    pkGitLab:
      Result := [TNameValuePair.Create('PRIVATE-TOKEN', AToken),
        TNameValuePair.Create('Accept', 'application/json'),
        TNameValuePair.Create('User-Agent', 'Devbox')];
    pkAzure:
      // PAT do Azure DevOps vai como Basic com usuário vazio.
      Result := [TNameValuePair.Create('Authorization', 'Basic ' +
          TNetEncoding.Base64String.Encode(':' + AToken).Replace(#13#10, '')),
        TNameValuePair.Create('Accept', 'application/json')];
  end;
end;

type
  TCachedResponse = record
    ETag, Body: string;
  end;

var
  // GitHub: URL -> última resposta. Com If-None-Match o servidor devolve 304
  // quando nada mudou, e 304 não gasta o limite de chamadas.
  // ponytail: só em memória; some ao fechar o app.
  GitHubCache: TDictionary<string, TCachedResponse>;

function GetJson(const AAccount: TAccount; const AToken, APath: string): TJSONValue;
var
  Http: THTTPClient;
  Resp: IHTTPResponse;
  Body, Url: string;
  Headers: TNetHeaders;
  Cached: TCachedResponse;
  HasCache: Boolean;
begin
  Url := TrimSlash(AAccount.BaseUrl) + APath;
  Headers := AuthHeaders(AAccount, AToken);
  HasCache := False;
  if AAccount.Kind = pkGitHub then
  begin
    TMonitor.Enter(GitHubCache);
    try
      HasCache := GitHubCache.TryGetValue(Url, Cached);
    finally
      TMonitor.Exit(GitHubCache);
    end;
    if HasCache then
      Headers := Headers + [TNameValuePair.Create('If-None-Match', Cached.ETag)];
  end;
  Http := THTTPClient.Create;
  try
    Http.ConnectionTimeout := 10000;
    Http.ResponseTimeout := 30000;
    Resp := Http.Get(Url, nil, Headers);
    if HasCache and (Resp.StatusCode = 304) then
      Exit(TJSONObject.ParseJSONValue(Cached.Body));
    Body := Resp.ContentAsString(TEncoding.UTF8);
    if (AAccount.Kind = pkGitHub) and (Resp.StatusCode = 200) and (Resp.HeaderValue['ETag'] <> '') then
    begin
      Cached.ETag := Resp.HeaderValue['ETag'];
      Cached.Body := Body;
      TMonitor.Enter(GitHubCache);
      try
        GitHubCache.AddOrSetValue(Url, Cached);
      finally
        TMonitor.Exit(GitHubCache);
      end;
    end;
    if Resp.StatusCode <> 200 then
      raise Exception.CreateFmt('HTTP %d %s em %s', [Resp.StatusCode, Resp.StatusText,
        APath.Split(['?'])[0]]);
    Result := TJSONObject.ParseJSONValue(Body);
    if Result = nil then
      raise Exception.Create('Resposta não é JSON em ' + APath.Split(['?'])[0]);
  finally
    Http.Free;
  end;
end;

{ Escrita (POST/PATCH com JSON). Jira Server exige X-Atlassian-Token + Origin +
  Referer em escrita, senão devolve 403 "XSRF check failed". }
function SendJsonRead(const AAccount: TAccount; const AToken, AMethod, APath, ABody: string): string;
var
  Http: THTTPClient;
  Resp: IHTTPResponse;
  Src: TStringStream;
  Headers: TNetHeaders;
  Msg: string;
  J, V: TJSONValue;
  JO: TJSONObject;
  Pair: TJSONPair;
begin
  // Azure muda campos por JSON Patch (PATCH e criação de work item).
  if (AAccount.Kind = pkAzure) and ((AMethod = 'PATCH') or APath.Contains('/_apis/wit/workitems/$')) then
    Headers := AuthHeaders(AAccount, AToken) +
      [TNameValuePair.Create('Content-Type', 'application/json-patch+json')]
  else
    Headers := AuthHeaders(AAccount, AToken) +
      [TNameValuePair.Create('Content-Type', 'application/json')];
  if AAccount.Kind in JiraKinds then
    Headers := Headers + [TNameValuePair.Create('X-Atlassian-Token', 'no-check'),
      TNameValuePair.Create('Origin', TrimSlash(AAccount.BaseUrl)),
      TNameValuePair.Create('Referer', TrimSlash(AAccount.BaseUrl) + '/')];
  Http := THTTPClient.Create;
  Src := TStringStream.Create(ABody, TEncoding.UTF8);
  try
    Http.ConnectionTimeout := 10000;
    Http.ResponseTimeout := 30000;
    if AMethod = 'PATCH' then
      Resp := Http.Patch(TrimSlash(AAccount.BaseUrl) + APath, Src, nil, Headers)
    else if AMethod = 'PUT' then
      Resp := Http.Put(TrimSlash(AAccount.BaseUrl) + APath, Src, nil, Headers)
    else
      Resp := Http.Post(TrimSlash(AAccount.BaseUrl) + APath, Src, nil, Headers);
    if (Resp.StatusCode < 200) or (Resp.StatusCode > 299) then
    begin
      Msg := Format('HTTP %d %s', [Resp.StatusCode, Resp.StatusText]);
      // Jira explica o motivo em errorMessages/errors; GitHub em message.
      J := TJSONObject.ParseJSONValue(Resp.ContentAsString(TEncoding.UTF8));
      try
        if J is TJSONObject then
        begin
          JO := TJSONObject(J);
          if JO.GetValue('errorMessages') is TJSONArray then
            for V in TJSONArray(JO.GetValue('errorMessages')) do
              Msg := Msg + ' · ' + V.Value;
          if JO.GetValue('errors') is TJSONObject then
            for Pair in TJSONObject(JO.GetValue('errors')) do
              Msg := Msg + ' · ' + Pair.JsonString.Value + ': ' + Pair.JsonValue.Value;
          if JO.GetValue('message') is TJSONString then
            Msg := Msg + ' · ' + JO.GetValue('message').Value;
        end;
      finally
        J.Free;
      end;
      raise Exception.Create(Msg);
    end;
    Result := Resp.ContentAsString(TEncoding.UTF8);
  finally
    Src.Free;
    Http.Free;
  end;
end;

procedure SendJson(const AAccount: TAccount; const AToken, AMethod, APath, ABody: string);
begin
  SendJsonRead(AAccount, AToken, AMethod, APath, ABody);
end;

{ GitHub GraphQL: api.github.com -> /graphql; Enterprise .../api/v3 -> .../api/graphql. }
function GitHubGraphQL(const AAccount: TAccount; const AToken, AQuery: string): TJSONValue;
var
  A: TAccount;
  Body: TJSONObject;
  Errors: TJSONArray;
begin
  A := AAccount;
  A.BaseUrl := TrimSlash(A.BaseUrl);
  if A.BaseUrl.EndsWith('/v3') then
    A.BaseUrl := A.BaseUrl.Substring(0, A.BaseUrl.Length - 3);
  Body := TJSONObject.Create;
  try
    Body.AddPair('query', AQuery);
    Result := TJSONObject.ParseJSONValue(SendJsonRead(A, AToken, 'POST', '/graphql', Body.ToJSON));
  finally
    Body.Free;
  end;
  if Result = nil then
    raise Exception.Create('Resposta não é JSON em /graphql');
  if Result.TryGetValue<TJSONArray>('errors', Errors) and (Errors.Count > 0) then
  begin
    try
      raise Exception.Create('GraphQL: ' + Errors.Items[0].GetValue<string>('message', ''));
    finally
      Result.Free;
    end;
  end;
end;

{ ── Parse ────────────────────────────────────────────────────────────────── }

function ParseIsoDate(const S: string): TDateTime;
var
  V: string;
begin
  if S = '' then
    Exit(0);
  if Length(S) = 10 then // '2026-10-03' (duedate do Jira)
    Exit(EncodeDate(StrToInt(Copy(S, 1, 4)), StrToInt(Copy(S, 6, 2)), StrToInt(Copy(S, 9, 2))));
  // Jira manda '-0300'; o ISO8601ToDate quer '-03:00'.
  V := TRegEx.Replace(S, '([+-]\d{2})(\d{2})$', '$1:$2');
  Result := ISO8601ToDate(V, True);
end;

procedure AdfWalk(AValue: TJSONValue; const AMeId: string; ASb: TStringBuilder;
  var AMentions: Boolean);
var
  Arr: TJSONArray;
  Obj: TJSONObject;
  NodeType, S: string;
  I: Integer;
begin
  if AValue is TJSONArray then
  begin
    Arr := TJSONArray(AValue);
    for I := 0 to Arr.Count - 1 do
      AdfWalk(Arr.Items[I], AMeId, ASb, AMentions);
    Exit;
  end;
  if not (AValue is TJSONObject) then
    Exit;
  Obj := TJSONObject(AValue);
  NodeType := Obj.GetValue<string>('type', '');
  if NodeType = 'text' then
    ASb.Append(Obj.GetValue<string>('text', ''))
  else if NodeType = 'mention' then
  begin
    S := Obj.GetValue<string>('attrs.text', '');
    ASb.Append(S);
    if (AMeId <> '') and (Obj.GetValue<string>('attrs.id', '') = AMeId) then
      AMentions := True;
  end
  else if NodeType = 'hardBreak' then
    ASb.Append(' ');
  if Obj.GetValue('content') <> nil then
  begin
    AdfWalk(Obj.GetValue('content'), AMeId, ASb, AMentions);
    if (NodeType = 'paragraph') or (NodeType = 'heading') or (NodeType = 'listItem') then
      ASb.Append(' ');
  end;
end;

function AdfToText(AValue: TJSONValue; const AMeId: string; out AMentionsMe: Boolean): string;
var
  Sb: TStringBuilder;
begin
  AMentionsMe := False;
  Sb := TStringBuilder.Create;
  try
    if AValue <> nil then
      AdfWalk(AValue, AMeId, Sb, AMentionsMe);
    Result := Sb.ToString.Trim;
  finally
    Sb.Free;
  end;
end;

function GitHubKeyFromApiUrl(const AUrl: string): string;
var
  M: TMatch;
begin
  // .../repos/o/r/issues/12 ou .../repos/o/r/pulls/12
  M := TRegEx.Match(AUrl, '/repos/([^/]+/[^/]+)/(?:issues|pulls)/(\d+)');
  if M.Success then
    Result := M.Groups[1].Value + '#' + M.Groups[2].Value
  else
    Result := '';
end;

function ParseGitHubIssue(AJson: TJSONObject; AAccountId: Integer): TItem;
var
  Repo: string;
  Assignees: TJSONArray;
begin
  Result := Default(TItem);
  Result.AccountId := AAccountId;
  Repo := AJson.GetValue<string>('repository_url', '');
  Repo := Repo.Substring(Repo.IndexOf('/repos/') + 7);
  Result.Key := Repo + '#' + AJson.GetValue<string>('number', '');
  Result.Title := AJson.GetValue<string>('title', '');
  Result.Url := AJson.GetValue<string>('html_url', '');
  Result.Status := AJson.GetValue<string>('state', '');
  Result.StatusCategory := IfThen(Result.Status = 'closed', 'done', 'new');
  if AJson.TryGetValue<TJSONArray>('assignees', Assignees) and (Assignees.Count > 0) then
    Result.Assignee := Assignees.Items[0].GetValue<string>('login', '');
  if AJson.GetValue('milestone') is TJSONObject then
    Result.DueDate := ParseIsoDate(AJson.GetValue<string>('milestone.due_on', ''));
  Result.UpdatedAt := ParseIsoDate(AJson.GetValue<string>('updated_at', ''));
  Result.CommentCount := AJson.GetValue<Integer>('comments', 0);
  Result.NodeId := AJson.GetValue<string>('node_id', '');
end;

function JiraUserId(AUser: TJSONValue; ACloud: Boolean): string;
begin
  if not (AUser is TJSONObject) then
    Exit('');
  if ACloud then
    Result := AUser.GetValue<string>('accountId', '')
  else
    Result := AUser.GetValue<string>('name', '');
end;

function ParseJiraIssue(AJson: TJSONObject; const AAccount: TAccount;
  const AMe: TIdentity; const AFlagField, ADueField: string): TItem;
var
  FlagArr: TJSONArray;
  F, Last: TJSONObject;
  Comments: TJSONArray;
  Cloud: Boolean;
  Body: TJSONValue;
begin
  Cloud := AAccount.Kind = pkJiraCloud;
  Result := Default(TItem);
  Result.AccountId := AAccount.Id;
  Result.Key := AJson.GetValue<string>('key', '');
  Result.Url := TrimSlash(AAccount.BaseUrl) + '/browse/' + Result.Key;
  F := AJson.GetValue<TJSONObject>('fields');
  Result.Title := F.GetValue<string>('summary', '');
  Result.Status := F.GetValue<string>('status.name', '');
  Result.StatusCategory := F.GetValue<string>('status.statusCategory.key', '');
  // Flagged: lista de opções; qualquer valor marcado conta como impedimento.
  Result.Flagged := (AFlagField <> '') and F.TryGetValue<TJSONArray>(AFlagField, FlagArr) and
    (FlagArr.Count > 0);
  if F.GetValue('assignee') is TJSONObject then
  begin
    Result.Assignee := F.GetValue<string>('assignee.displayName', '');
    if (AMe.Id <> '') and (JiraUserId(F.GetValue('assignee'), Cloud) = AMe.Id) then
      Include(Result.Sources, isAssigned);
  end;
  // Prazo: o campo configurado na conta (ex.: Data Acordo Entrega); sem ele, duedate.
  if (ADueField <> '') and (F.GetValue(ADueField) is TJSONString) then
    Result.DueDate := DateOf(ParseIsoDate(F.GetValue<string>(ADueField)))
  else if (ADueField = '') and (F.GetValue('duedate') is TJSONString) then
    Result.DueDate := ParseIsoDate(F.GetValue<string>('duedate'));
  Result.UpdatedAt := ParseIsoDate(F.GetValue<string>('updated', ''));

  if F.TryGetValue<TJSONArray>('comment.comments', Comments) then
  begin
    Result.CommentCount := F.GetValue<Integer>('comment.total', Comments.Count);
    if Comments.Count > 0 then
    begin
      Last := Comments.Items[Comments.Count - 1] as TJSONObject;
      Result.LastCommentBy := JiraUserId(Last.GetValue('author'), Cloud);
      Body := Last.GetValue('body');
      if Cloud then
        Result.LastCommentText := AdfToText(Body, AMe.Id, Result.MentionsMe)
      else
      begin
        Result.LastCommentText := Body.Value;
        // Wiki markup do Server: menção é [~usuario].
        Result.MentionsMe := (AMe.Id <> '') and
          ContainsText(Result.LastCommentText, '[~' + AMe.Id + ']');
      end;
    end;
  end;
end;

{ ── Quem sou eu ─────────────────────────────────────────────────────────── }

function GitLabMe(const AAccount: TAccount; const AToken: string; out ANumericId: string): TIdentity; forward;
function AzureMe(const AAccount: TAccount; const AToken: string): TIdentity; forward;

function WhoAmI(const AAccount: TAccount; const AToken: string): TIdentity;
var
  J: TJSONValue;
  NumId: string;
begin
  if AToken = '' then
    raise Exception.Create('Token vazio');
  case AAccount.Kind of
    pkGitLab: Exit(GitLabMe(AAccount, AToken, NumId));
    pkAzure: Exit(AzureMe(AAccount, AToken));
  end;
  case AAccount.Kind of
    pkGitHub: J := GetJson(AAccount, AToken, '/user');
    pkJiraServer: J := GetJson(AAccount, AToken, '/rest/api/2/myself');
  else
    J := GetJson(AAccount, AToken, '/rest/api/3/myself');
  end;
  try
    case AAccount.Kind of
      pkGitHub:
        begin
          Result.Id := J.GetValue<string>('login', '');
          Result.DisplayName := J.GetValue<string>('name', Result.Id);
          if Result.DisplayName = '' then
            Result.DisplayName := Result.Id;
        end;
      pkJiraServer:
        begin
          Result.Id := J.GetValue<string>('name', '');
          Result.DisplayName := J.GetValue<string>('displayName', Result.Id);
        end;
      pkJiraCloud:
        begin
          Result.Id := J.GetValue<string>('accountId', '');
          Result.DisplayName := J.GetValue<string>('displayName', Result.Id);
        end;
    end;
  finally
    J.Free;
  end;
end;

{ Escopos do token clássico (cabeçalho X-OAuth-Scopes) contra o que o Devbox usa. }
function GitHubScopeAdvice(const AAccount: TAccount; const AToken: string): string;
var
  Http: THTTPClient;
  Resp: IHTTPResponse;
  Scopes, Missing: string;
begin
  Http := THTTPClient.Create;
  try
    Resp := Http.Get(TrimSlash(AAccount.BaseUrl) + '/user', nil, AuthHeaders(AAccount, AToken));
    if not Resp.ContainsHeader('X-OAuth-Scopes') then
      Exit('Token fine-grained: confira Issues, Pull requests e Contents (leitura); ' +
        'notificações e Projects não funcionam com ele.');
    Scopes := ',' + Resp.HeaderValue['X-OAuth-Scopes'].Replace(' ', '') + ',';
  finally
    Http.Free;
  end;
  Missing := '';
  if not Scopes.Contains(',repo,') then
    Missing := Missing + ' repo';
  if not Scopes.Contains(',notifications,') then
    Missing := Missing + ' notifications';
  if (AAccount.DueField.Trim <> '') and not (Scopes.Contains(',read:project,') or Scopes.Contains(',project,')) then
    Missing := Missing + ' read:project';
  if Missing = '' then
    Result := 'Escopos ok.'
  else
    Result := 'Faltam escopos:' + Missing + '.';
end;

function TestConnection(const AAccount: TAccount; const AToken: string): string;
var
  Me: TIdentity;
begin
  Me := WhoAmI(AAccount, AToken);
  Result := Me.DisplayName;
  if (Me.Id <> '') and (Me.Id <> Me.DisplayName) then
    Result := Result + ' (' + Me.Id + ')';
  if AAccount.Kind = pkGitHub then
    Result := Result + '. ' + GitHubScopeAdvice(AAccount, AToken);
end;

{ ── GitHub ──────────────────────────────────────────────────────────────── }

procedure Merge(var AItems: TItems; const AItem: TItem);
var
  I: Integer;
begin
  for I := 0 to High(AItems) do
    if SameText(AItems[I].Key, AItem.Key) then
    begin
      AItems[I].Sources := AItems[I].Sources + AItem.Sources;
      Exit;
    end;
  AItems := AItems + [AItem];
end;

{$I Devbox.Issues.Providers.GitLab.inc}
{$I Devbox.Issues.Providers.Azure.inc}

procedure GitHubSearch(const AAccount: TAccount; const AToken, AQuery: string;
  ASource: TItemSource; var AItems: TItems; APages: Integer = MaxPages);
var
  J: TJSONValue;
  Arr: TJSONArray;
  Page, I: Integer;
  It: TItem;
begin
  for Page := 1 to APages do
  begin
    J := GetJson(AAccount, AToken, Format('/search/issues?q=%s&sort=updated&order=desc&per_page=%d&page=%d',
      [Enc(AQuery), PageSize, Page]));
    try
      Arr := J.GetValue<TJSONArray>('items');
      for I := 0 to Arr.Count - 1 do
      begin
        It := ParseGitHubIssue(Arr.Items[I] as TJSONObject, AAccount.Id);
        It.Sources := [ASource];
        Merge(AItems, It);
      end;
      if Arr.Count < PageSize then
        Break;
    finally
      J.Free;
    end;
  end;
end;

procedure GitHubManual(const AAccount: TAccount; const AToken, AKey: string;
  var AItems: TItems);
var
  M: TMatch;
  J: TJSONValue;
  It: TItem;
begin
  M := TRegEx.Match(AKey.Trim, '^([^/\s]+/[^#\s]+)#(\d+)$');
  if not M.Success then
    Exit;
  J := GetJson(AAccount, AToken, Format('/repos/%s/issues/%s', [M.Groups[1].Value, M.Groups[2].Value]));
  try
    It := ParseGitHubIssue(J as TJSONObject, AAccount.Id);
    It.Sources := [isWatching];
    Merge(AItems, It);
  finally
    J.Free;
  end;
end;

{ Marca motivo das notifications não lidas (mention, comment, assign...).
  O GitHub não gera notification para ação do próprio usuário. }
procedure GitHubUnread(const AAccount: TAccount; const AToken: string; var AItems: TItems);
var
  J: TJSONValue;
  Arr: TJSONArray;
  I, K: Integer;
  Key, Reason: string;
begin
  J := GetJson(AAccount, AToken, '/notifications?all=false&per_page=50');
  try
    Arr := J as TJSONArray;
    for I := 0 to Arr.Count - 1 do
    begin
      Key := GitHubKeyFromApiUrl(Arr.Items[I].GetValue<string>('subject.url', ''));
      Reason := Arr.Items[I].GetValue<string>('reason', '');
      for K := 0 to High(AItems) do
        if SameText(AItems[K].Key, Key) then
        begin
          AItems[K].UnreadReason := Reason;
          AItems[K].ThreadId := Arr.Items[I].GetValue<string>('id', '');
          AItems[K].MentionsMe := AItems[K].MentionsMe or (Reason = 'mention');
        end;
    end;
  finally
    J.Free;
  end;
end;

{ PRs que abri, numa consulta só: decisão de review e estado do CI do último commit. }
procedure GitHubMyPrs(const AAccount: TAccount; const AToken: string; var AItems: TItems);
const
  Q = 'query { search(query: "is:pr is:open author:@me archived:false", type: ISSUE, first: 50) { ' +
    'nodes { ... on PullRequest { id number title url updatedAt isDraft reviewDecision ' +
    'repository { nameWithOwner } comments { totalCount } milestone { dueOn } ' +
    'assignees(first: 1) { nodes { login } } ' +
    'latestReviews(first: 10) { nodes { state author { login } } } ' +
    'commits(last: 1) { nodes { commit { statusCheckRollup { state contexts(first: 50) { nodes { ' +
    '__typename ... on CheckRun { name conclusion detailsUrl } ' +
    '... on StatusContext { context state targetUrl } } } } } } } } } } }';
var
  J: TJSONValue;
  Arr, Commits, Checks: TJSONArray;
  N: TJSONObject;
  I, C: Integer;
  It: TItem;
  Approved, Changes: string;
begin
  J := GitHubGraphQL(AAccount, AToken, Q);
  try
    Arr := J.GetValue<TJSONArray>('data.search.nodes');
    for I := 0 to Arr.Count - 1 do
    begin
      if not (Arr.Items[I] is TJSONObject) then
        Continue;
      N := TJSONObject(Arr.Items[I]);
      It := Default(TItem);
      It.AccountId := AAccount.Id;
      It.Key := N.GetValue<string>('repository.nameWithOwner', '') + '#' + N.GetValue<string>('number', '');
      It.Title := N.GetValue<string>('title', '');
      It.Url := N.GetValue<string>('url', '');
      It.Status := IfThen(N.GetValue<Boolean>('isDraft', False), 'rascunho', 'open');
      It.StatusCategory := 'indeterminate';
      It.UpdatedAt := ParseIsoDate(N.GetValue<string>('updatedAt', ''));
      It.CommentCount := N.GetValue<Integer>('comments.totalCount', 0);
      if N.GetValue('milestone') is TJSONObject then
        It.DueDate := ParseIsoDate(N.GetValue<string>('milestone.dueOn', ''));
      if N.TryGetValue<TJSONArray>('assignees.nodes', Commits) and (Commits.Count > 0) then
        It.Assignee := Commits.Items[0].GetValue<string>('login', '');
      if not (N.GetValue('reviewDecision') is TJSONNull) then
        It.ReviewState := N.GetValue<string>('reviewDecision', '');
      if N.TryGetValue<TJSONArray>('commits.nodes', Commits) and (Commits.Count > 0) and
        (Commits.Items[0].FindValue('commit.statusCheckRollup') is TJSONObject) then
        It.CiState := Commits.Items[0].GetValue<string>('commit.statusCheckRollup.state', '');
      It.NodeId := N.GetValue<string>('id', '');
      // Primeiro job que falhou: nome e link direto.
      if MatchText(It.CiState, ['FAILURE', 'ERROR']) and
        Commits.Items[0].TryGetValue<TJSONArray>('commit.statusCheckRollup.contexts.nodes', Checks) then
        for C := 0 to Checks.Count - 1 do
          if MatchText(Checks.Items[C].GetValue<string>('conclusion', ''), ['FAILURE', 'TIMED_OUT', 'CANCELLED']) or
            MatchText(Checks.Items[C].GetValue<string>('state', ''), ['FAILURE', 'ERROR']) then
          begin
            It.CiDetail := Checks.Items[C].GetValue<string>('name',
              Checks.Items[C].GetValue<string>('context', ''));
            It.CiUrl := Checks.Items[C].GetValue<string>('detailsUrl',
              Checks.Items[C].GetValue<string>('targetUrl', ''));
            Break;
          end;
      // Quem revisou: aprovado / mudanças.
      Approved := '';
      Changes := '';
      if N.TryGetValue<TJSONArray>('latestReviews.nodes', Checks) then
        for C := 0 to Checks.Count - 1 do
          if Checks.Items[C].GetValue<string>('state', '') = 'APPROVED' then
            Approved := Approved + IfThen(Approved <> '', ', ') + Checks.Items[C].GetValue<string>('author.login', '')
          else if Checks.Items[C].GetValue<string>('state', '') = 'CHANGES_REQUESTED' then
            Changes := Changes + IfThen(Changes <> '', ', ') + Checks.Items[C].GetValue<string>('author.login', '');
      if Approved <> '' then
        It.Reviewers := 'aprovado: ' + Approved;
      if Changes <> '' then
        It.Reviewers := It.Reviewers + IfThen(It.Reviewers <> '', ' · ') + 'mudanças: ' + Changes;
      It.Sources := [isMine];
      Merge(AItems, It);
    end;
  finally
    J.Free;
  end;
end;

{ Busca extra do usuário; sem estado na query, só as abertas. }
function OpenQuery(const AQuery: string): string;
begin
  Result := AQuery.Trim;
  if not (ContainsText(Result, 'is:open') or ContainsText(Result, 'is:closed') or
    ContainsText(Result, 'state:')) then
    Result := Result + ' is:open';
end;

{ Tira o que o filtro de repositórios/projetos da conta não quer. Acompanhamento
  manual fica sempre: foi o usuário que pediu. }
function ApplyRepoFilter(const AAccount: TAccount; const AItems: TItems): TItems;
var
  It: TItem;
begin
  Result := nil;
  for It in AItems do
    if (isWatching in It.Sources) or ItemAllowed(AAccount, It.Key) then
      Result := Result + [It];
end;

{ Projects v2: o campo de data (nome em DueField) vira prazo. Lotes de 100 ids
  pelo GraphQL; issue em mais de um projeto usa a primeira data achada.
  Precisa do escopo read:project. }
procedure GitHubProjectDates(const AAccount: TAccount; const AToken: string; var AItems: TItems);
var
  Ids: TArray<string>;
  Map: TDictionary<string, Integer>;
  I, J, K: Integer;
  Q, Field: string;
  R: TJSONValue;
  Nodes, PItems: TJSONArray;
  D: string;
begin
  Field := AAccount.DueField.Trim.Replace('"', '');
  Map := TDictionary<string, Integer>.Create;
  try
    for I := 0 to High(AItems) do
      if (AItems[I].NodeId <> '') and (AItems[I].DueDate = 0) then
        Map.AddOrSetValue(AItems[I].NodeId, I);
    Ids := Map.Keys.ToArray;
    I := 0;
    while I <= High(Ids) do
    begin
      Q := 'query { nodes(ids: [';
      for J := I to Min(I + 99, High(Ids)) do
        Q := Q + IfThen(J > I, ',') + '"' + Ids[J] + '"';
      Q := Q + ']) { ... on Issue { id projectItems(first: 5) { nodes { fieldValueByName(name: "' +
        Field + '") { ... on ProjectV2ItemFieldDateValue { date } } } } } ' +
        '... on PullRequest { id projectItems(first: 5) { nodes { fieldValueByName(name: "' +
        Field + '") { ... on ProjectV2ItemFieldDateValue { date } } } } } } }';
      R := GitHubGraphQL(AAccount, AToken, Q);
      try
        Nodes := R.GetValue<TJSONArray>('data.nodes');
        for J := 0 to Nodes.Count - 1 do
          if (Nodes.Items[J] is TJSONObject) and
            Nodes.Items[J].TryGetValue<TJSONArray>('projectItems.nodes', PItems) then
            for K := 0 to PItems.Count - 1 do
            begin
              D := '';
              if PItems.Items[K].FindValue('fieldValueByName.date') <> nil then
                D := PItems.Items[K].GetValue<string>('fieldValueByName.date', '');
              if D <> '' then
              begin
                AItems[Map[Nodes.Items[J].GetValue<string>('id')]].DueDate := ParseIsoDate(D);
                Break;
              end;
            end;
      finally
        R.Free;
      end;
      Inc(I, 100);
    end;
  finally
    Map.Free;
  end;
end;

function FetchGitHub(const AAccount: TAccount; const AToken: string;
  const AManualKeys: TArray<string>): TItems;
var
  Key: string;
begin
  Result := nil;
  GitHubSearch(AAccount, AToken, 'assignee:@me is:open', isAssigned, Result);
  GitHubSearch(AAccount, AToken, 'review-requested:@me is:open is:pr', isReview, Result);
  if AAccount.MyPrs then
    GitHubMyPrs(AAccount, AToken, Result);
  if AAccount.Mentions then
    GitHubSearch(AAccount, AToken, 'mentions:@me is:open', isMention, Result);
  // Issues abertas dos repositórios do usuário (privados entram se o token tem 'repo').
  // A busca não aceita user:@me: o login vem do /user.
  if AAccount.OwnRepos then
    GitHubSearch(AAccount, AToken, 'user:' + WhoAmI(AAccount, AToken).Id + ' is:open is:issue',
      isOwnRepo, Result, 10);  // até 1000: o teto da busca do GitHub
  if AAccount.ExtraQuery.Trim <> '' then
    GitHubSearch(AAccount, AToken, OpenQuery(AAccount.ExtraQuery), isQuery, Result);
  for Key in AManualKeys do
    if Key.Contains('/') then
      GitHubManual(AAccount, AToken, Key, Result);
  // Token sem acesso a /notifications (ex.: fine-grained) não derruba a busca:
  // as issues vêm igual, só sem o motivo (menção, comentário) das não lidas.
  try
    GitHubUnread(AAccount, AToken, Result);
  except
    on E: Exception do
      OutputDebugString(PChar('Devbox issues: /notifications indisponível (' + E.Message + ')'));
  end;
  if AAccount.DueField.Trim <> '' then
  try
    GitHubProjectDates(AAccount, AToken, Result);
  except
    on E: Exception do
      OutputDebugString(PChar('Devbox issues: datas do Projects indisponíveis (' + E.Message + ')'));
  end;
  Result := ApplyRepoFilter(AAccount, Result);
end;

{ ── Jira ────────────────────────────────────────────────────────────────── }

function JiraJql(const AManualKeys: TArray<string>): string;
var
  Keys: TArray<string>;
  K: string;
begin
  Keys := nil;
  for K in AManualKeys do
    if TRegEx.IsMatch(K.Trim, '^[A-Za-z][A-Za-z0-9_]*-\d+$') then
      Keys := Keys + [K.Trim.ToUpper];
  Result := '(assignee = currentUser() OR watcher = currentUser()) AND statusCategory != Done';
  // Manual entra mesmo concluída: assim o "status -> Concluído" vira aviso em vez de sumir.
  // Chave inexistente derrubaria a JQL (HTTP 400); o CheckItem barra isso no cadastro.
  if Keys <> nil then
    Result := '(' + Result + ') OR key in (' + string.Join(',', Keys) + ')';
  Result := Result + ' ORDER BY updated DESC';
end;

var
  // 'url|nome' -> id do campo. Lista de campos do Jira é grande; busca uma vez por execução.
  FieldIds: TDictionary<string, string>;

{ Aceita id ('customfield_11039', 'duedate') ou nome ('Data Acordo Entrega').
  Devolve '' se o nome não existir. }
function ResolveJiraField(const AAccount: TAccount; const AToken, ANameOrId: string): string;
var
  CacheKey: string;
  J: TJSONValue;
  Arr: TJSONArray;
  I: Integer;
begin
  Result := ANameOrId.Trim;
  if (Result = '') or TRegEx.IsMatch(Result, '^(customfield_\d+|duedate)$') then
    Exit;
  CacheKey := TrimSlash(AAccount.BaseUrl) + '|' + Result.ToLower;
  TMonitor.Enter(FieldIds);
  try
    if FieldIds.TryGetValue(CacheKey, Result) then
      Exit;
  finally
    TMonitor.Exit(FieldIds);
  end;
  Result := '';
  J := GetJson(AAccount, AToken, IfThen(AAccount.Kind = pkJiraCloud, '/rest/api/3/field', '/rest/api/2/field'));
  try
    Arr := J as TJSONArray;
    for I := 0 to Arr.Count - 1 do
      if SameText(Arr.Items[I].GetValue<string>('name', ''), ANameOrId.Trim) then
      begin
        Result := Arr.Items[I].GetValue<string>('id', '');
        Break;
      end;
  finally
    J.Free;
  end;
  TMonitor.Enter(FieldIds);
  try
    FieldIds.AddOrSetValue(CacheKey, Result);
  finally
    TMonitor.Exit(FieldIds);
  end;
end;

{ Uma JQL paginada (v2 com startAt; Cloud com nextPageToken). Itens sem
  "associado" ganham ASource. }
procedure JiraSearch(const AAccount: TAccount; const AToken, AJql, AFields: string;
  const AMe: TIdentity; const AFlagField, ADueField: string; ASource: TItemSource;
  var AItems: TItems);
var
  Jql, Path, NextToken: string;
  J: TJSONValue;
  Arr: TJSONArray;
  Page, I: Integer;
  It: TItem;
begin
  Jql := Enc(AJql);
  NextToken := '';
  for Page := 0 to MaxPages - 1 do
  begin
    if AAccount.Kind = pkJiraCloud then
    begin
      Path := Format('/rest/api/3/search/jql?jql=%s&fields=%s&maxResults=%d', [Jql, AFields, PageSize]);
      if NextToken <> '' then
        Path := Path + '&nextPageToken=' + Enc(NextToken);
    end
    else
      Path := Format('/rest/api/2/search?jql=%s&fields=%s&maxResults=%d&startAt=%d',
        [Jql, AFields, PageSize, Page * PageSize]);
    J := GetJson(AAccount, AToken, Path);
    try
      Arr := J.GetValue<TJSONArray>('issues');
      for I := 0 to Arr.Count - 1 do
      begin
        It := ParseJiraIssue(Arr.Items[I] as TJSONObject, AAccount, AMe, AFlagField, ADueField);
        if not (isAssigned in It.Sources) then
          Include(It.Sources, ASource);
        Merge(AItems, It);
      end;
      if AAccount.Kind = pkJiraCloud then
      begin
        NextToken := J.GetValue<string>('nextPageToken', '');
        if NextToken = '' then
          Break;
      end
      else if (Page + 1) * PageSize >= J.GetValue<Integer>('total', 0) then
        Break;
    finally
      J.Free;
    end;
  end;
end;

function FetchJira(const AAccount: TAccount; const AToken: string;
  const AManualKeys: TArray<string>; out AMe: TIdentity): TItems;
var
  Fields, FlagField, DueField: string;
  Me: TIdentity;
  Sprint: TItems;
  I, J: Integer;
begin
  Result := nil;
  Me := WhoAmI(AAccount, AToken);
  AMe := Me;
  FlagField := ResolveJiraField(AAccount, AToken, 'Flagged');
  DueField := ResolveJiraField(AAccount, AToken, AAccount.DueField);
  if (AAccount.DueField.Trim <> '') and (DueField = '') then
    raise Exception.CreateFmt('Campo de prazo "%s" não existe neste Jira', [AAccount.DueField]);
  Fields := 'summary,status,assignee,duedate,updated,comment';
  if FlagField <> '' then
    Fields := Fields + ',' + FlagField;
  if DueField <> '' then
    Fields := Fields + ',' + DueField;
  JiraSearch(AAccount, AToken, JiraJql(AManualKeys), Fields, Me, FlagField, DueField, isWatching, Result);
  // Sprint ativa: marca as minhas/observadas que estão nela. Jira sem Agile
  // recusa a JQL: segue sem a marca.
  try
    Sprint := nil;
    JiraSearch(AAccount, AToken, '(assignee = currentUser() OR watcher = currentUser()) AND ' +
      'sprint in openSprints() AND statusCategory != Done', 'summary', Me, '', '', isSprint, Sprint);
    for I := 0 to High(Result) do
      for J := 0 to High(Sprint) do
        if SameText(Result[I].Key, Sprint[J].Key) then
          Include(Result[I].Sources, isSprint);
  except
    on E: Exception do
      OutputDebugString(PChar('Devbox issues: sprint indisponível (' + E.Message + ')'));
  end;
  // JQL extra do usuário, só as abertas.
  if AAccount.ExtraQuery.Trim <> '' then
    JiraSearch(AAccount, AToken, '(' + AAccount.ExtraQuery.Trim + ') AND statusCategory != Done',
      Fields, Me, FlagField, DueField, isQuery, Result);
  Result := ApplyRepoFilter(AAccount, Result);
end;

function NormalizeManualKey(const AKey: string; out AFamily: TKeyFamily): string;
var
  K: string;
begin
  K := AKey.Trim;
  Result := K;
  // GitLab aceita subgrupos (a/b/c#12) e MR com '!'.
  if TRegEx.IsMatch(K, '^[^/\s]+(/[^/#!\s]+)+[#!]\d+$') then
    AFamily := kfRepo
  else if TRegEx.IsMatch(K, '^[A-Za-z][A-Za-z0-9_]*-\d+$') then
  begin
    AFamily := kfJira;
    Result := K.ToUpper;
  end
  else if TRegEx.IsMatch(K, '^[^/#!]+#\d+$') then
    AFamily := kfAzure
  else
  begin
    AFamily := kfNone;
    Result := '';
  end;
end;

function CheckItem(const AAccount: TAccount; const AToken, AKey: string): string;
var
  M: TMatch;
  J: TJSONValue;
  Desc: string;
begin
  case AAccount.Kind of
    pkGitLab: Exit(GitLabTitle(AAccount, AToken, AKey));
    pkAzure: Exit(AzureTitleAndDescription(AAccount, AToken, AKey, Desc));
  end;
  if AAccount.Kind = pkGitHub then
  begin
    M := TRegEx.Match(AKey, '^([^/\s]+/[^#\s]+)#(\d+)$');
    if not M.Success then
      raise Exception.Create('Formato esperado: dono/repo#12');
    J := GetJson(AAccount, AToken, Format('/repos/%s/issues/%s', [M.Groups[1].Value, M.Groups[2].Value]));
    try
      Result := J.GetValue<string>('title', '');
    finally
      J.Free;
    end;
  end
  else
  begin
    J := GetJson(AAccount, AToken, Format('/rest/api/%s/issue/%s?fields=summary',
      [IfThen(AAccount.Kind = pkJiraCloud, '3', '2'), Enc(AKey)]));
    try
      Result := J.GetValue<string>('fields.summary', '');
    finally
      J.Free;
    end;
  end;
end;

function CleanCommentText(const S: string): string;
const
  Names: array[0..21] of string = ('aacute', 'eacute', 'iacute', 'oacute', 'uacute', 'atilde',
    'otilde', 'acirc', 'ecirc', 'ocirc', 'ccedil', 'agrave', 'Aacute', 'Eacute', 'Iacute',
    'Oacute', 'Uacute', 'Atilde', 'Otilde', 'Ccedil', 'nbsp', 'quot');
  Chars: array[0..21] of string = ('á', 'é', 'í', 'ó', 'ú', 'ã', 'õ', 'â', 'ê', 'ô', 'ç', 'à',
    'Á', 'É', 'Í', 'Ó', 'Ú', 'Ã', 'Õ', 'Ç', ' ', '"');
var
  I: Integer;
  M: TMatch;
begin
  Result := TRegEx.Replace(S, '<br\s*/?>|</p>', sLineBreak, [roIgnoreCase]);
  Result := TRegEx.Replace(Result, '<[^>]+>', '');
  for I := Low(Names) to High(Names) do
    Result := Result.Replace('&' + Names[I] + ';', Chars[I]);
  // Entidades numéricas (&#233;). TMatchEvaluator é "of object": laço simples.
  M := TRegEx.Match(Result, '&#(\d+);');
  while M.Success do
  begin
    Result := Result.Replace(M.Value, Char(StrToIntDef(M.Groups[1].Value, 32)));
    M := TRegEx.Match(Result, '&#(\d+);');
  end;
  // &amp; por último para não reabrir entidades já decodificadas.
  Result := Result.Replace('&lt;', '<').Replace('&gt;', '>').Replace('&amp;', '&').Trim;
end;

// Wiki do Jira Server para texto lido de primeira: tira chaves duplas de código,
// *negrito*, h1., cores e links; tabela |a|b| vira "a · b"; marcador "* " vira "• ".
function WikiToText(const S: string): string;
var
  Lines: TArray<string>;
  I: Integer;
  L: string;
begin
  Result := TRegEx.Replace(S, '\{(code|noformat|quote|panel)[^}]*\}', '');
  Result := TRegEx.Replace(Result, '\{color[^}]*\}', '');
  Result := TRegEx.Replace(Result, '\{\{(.*?)\}\}', '$1');
  Result := TRegEx.Replace(Result, '\[~([^\]]+)\]', '@$1');
  Result := TRegEx.Replace(Result, '\[([^|\]]+)\|[^\]]+\]', '$1');
  Result := TRegEx.Replace(Result, '(^|[\s(])\*(\S[^*\r\n]*?\S|\S)\*(?=[\s.,;:)!?]|$)', '$1$2', [roMultiLine]);
  Lines := Result.Replace(#13#10, #10).Split([#10]);
  for I := 0 to High(Lines) do
  begin
    L := TRegEx.Replace(Lines[I], '^\s*h[1-6]\.\s*', '');
    L := TRegEx.Replace(L, '^\s*[*#-]+\s+', '• ');
    if L.Trim = '----' then
      L := ''
    else if L.TrimLeft.StartsWith('|') then
    begin
      L := L.Trim.Replace('||', '|');
      L := L.Trim(['|']).Trim;
      L := TRegEx.Replace(L, '\s*\|\s*', ' · ');
    end;
    Lines[I] := L.TrimRight;
  end;
  Result := string.Join(sLineBreak, Lines);
  // Mais de uma linha em branco seguida vira uma só.
  Result := TRegEx.Replace(Result, '(\r\n){3,}', sLineBreak + sLineBreak);
end;

function MarkdownToText(const S: string): string;
var
  Lines: TArray<string>;
  I: Integer;
  L: string;
begin
  Result := TRegEx.Replace(S, '<!--.*?-->', '', [roSingleLine]);
  Result := TRegEx.Replace(Result, '!\[([^\]]*)\]\([^)]*\)', '[imagem $1]');
  Result := TRegEx.Replace(Result, '\[([^\]]+)\]\(([^)]+)\)', '$1');
  Result := TRegEx.Replace(Result, '(\*\*|__)(.+?)\1', '$2');
  Result := TRegEx.Replace(Result, '`([^`\r\n]+)`', '$1');
  Lines := Result.Replace(#13#10, #10).Split([#10]);
  for I := 0 to High(Lines) do
  begin
    L := Lines[I];
    if L.TrimLeft.StartsWith('```') then
      L := ''
    else
    begin
      L := TRegEx.Replace(L, '^\s*#{1,6}\s+', '');
      L := TRegEx.Replace(L, '^(\s*)[-*+]\s+\[( |x)\]\s+', '$1☐ ');
      L := TRegEx.Replace(L, '^(\s*)[-*+]\s+', '$1• ');
    end;
    Lines[I] := L.TrimRight;
  end;
  Result := string.Join(sLineBreak, Lines);
  Result := TRegEx.Replace(Result, '(\r\n){3,}', sLineBreak + sLineBreak).Trim;
end;

function FetchComments(const AAccount: TAccount; const AToken, AKey: string;
  AMax: Integer): TComments;
var
  M: TMatch;
  J: TJSONValue;
  Arr: TJSONArray;
  I, First: Integer;
  C: TComment;
  Dummy: Boolean;
begin
  Result := nil;
  case AAccount.Kind of
    pkGitLab: Exit(GitLabComments(AAccount, AToken, AKey, AMax));
    pkAzure: Exit(AzureComments(AAccount, AToken, AKey, AMax));
  end;
  if AAccount.Kind = pkGitHub then
  begin
    M := TRegEx.Match(AKey, '^([^/\s]+/[^#\s]+)#(\d+)$');
    if not M.Success then
      Exit;
    // ponytail: só a primeira página (100); issue com mais comentários mostra os 100 primeiros.
    J := GetJson(AAccount, AToken, Format('/repos/%s/issues/%s/comments?per_page=100',
      [M.Groups[1].Value, M.Groups[2].Value]));
    try
      Arr := J as TJSONArray;
      First := Max(0, Arr.Count - AMax);
      for I := First to Arr.Count - 1 do
      begin
        C.AuthorId := Arr.Items[I].GetValue<string>('user.login', '');
        C.Author := C.AuthorId;
        C.At := ParseIsoDate(Arr.Items[I].GetValue<string>('created_at', ''));
        C.Text := MarkdownToText(Arr.Items[I].GetValue<string>('body', ''));
        Result := Result + [C];
      end;
    finally
      J.Free;
    end;
    Exit;
  end;

  J := GetJson(AAccount, AToken, Format('/rest/api/%s/issue/%s/comment?orderBy=-created&maxResults=%d',
    [IfThen(AAccount.Kind = pkJiraCloud, '3', '2'), Enc(AKey), AMax]));
  try
    Arr := J.GetValue<TJSONArray>('comments');
    // Veio do mais novo para o mais antigo; a conversa lê de cima para baixo.
    for I := Arr.Count - 1 downto 0 do
    begin
      C.Author := Arr.Items[I].GetValue<string>('author.displayName', '');
      C.AuthorId := JiraUserId((Arr.Items[I] as TJSONObject).GetValue('author'), AAccount.Kind = pkJiraCloud);
      C.At := ParseIsoDate(Arr.Items[I].GetValue<string>('created', ''));
      if AAccount.Kind = pkJiraCloud then
        C.Text := AdfToText((Arr.Items[I] as TJSONObject).GetValue('body'), '', Dummy)
      else
        C.Text := WikiToText(Arr.Items[I].GetValue<string>('body', ''));
      C.Text := CleanCommentText(C.Text);
      Result := Result + [C];
    end;
  finally
    J.Free;
  end;
end;

function GitHubIssuePath(const AKey: string): string;
var
  M: TMatch;
begin
  M := TRegEx.Match(AKey, '^([^/\s]+/[^#\s]+)#(\d+)$');
  if not M.Success then
    raise Exception.Create('Chave GitHub inválida: ' + AKey);
  Result := Format('/repos/%s/issues/%s', [M.Groups[1].Value, M.Groups[2].Value]);
end;

function FetchTransitions(const AAccount: TAccount; const AToken, AKey: string): TTransitions;
var
  J: TJSONValue;
  Arr, Allowed: TJSONArray;
  I, K: Integer;
  T: TTransition;
  F: TTransitionField;
  Pair: TJSONPair;
  State: string;
begin
  Result := nil;
  if AAccount.Kind = pkAzure then
    Exit(AzureTransitions(AAccount, AToken, AKey));
  if AAccount.Kind = pkGitLab then
  begin
    J := GetJson(AAccount, AToken, GitLabItemPath(AKey));
    try
      State := J.GetValue<string>('state', 'opened');
    finally
      J.Free;
    end;
    T := Default(TTransition);
    if State = 'opened' then
    begin
      T.Id := 'close';
      T.Name := 'Fechar';
      T.ToStatus := 'closed';
    end
    else
    begin
      T.Id := 'reopen';
      T.Name := 'Reabrir';
      T.ToStatus := 'open';
    end;
    Result := [T];
    Exit;
  end;
  if AAccount.Kind = pkGitHub then
  begin
    J := GetJson(AAccount, AToken, GitHubIssuePath(AKey));
    try
      State := J.GetValue<string>('state', 'open');
    finally
      J.Free;
    end;
    if State = 'open' then
    begin
      T.Id := 'closed';
      T.Name := 'Fechar';
      T.ToStatus := 'closed';
    end
    else
    begin
      T.Id := 'open';
      T.Name := 'Reabrir';
      T.ToStatus := 'open';
    end;
    Result := [T];
    Exit;
  end;

  J := GetJson(AAccount, AToken, Format('/rest/api/%s/issue/%s/transitions?expand=transitions.fields',
    [IfThen(AAccount.Kind = pkJiraCloud, '3', '2'), Enc(AKey)]));
  try
    Arr := J.GetValue<TJSONArray>('transitions');
    for I := 0 to Arr.Count - 1 do
    begin
      T := Default(TTransition);
      T.Id := Arr.Items[I].GetValue<string>('id', '');
      T.Name := Arr.Items[I].GetValue<string>('name', '');
      T.ToStatus := Arr.Items[I].GetValue<string>('to.name', T.Name);
      // Campos obrigatórios da tela da transição (resolução, comentário...).
      if Arr.Items[I].FindValue('fields') is TJSONObject then
        for Pair in TJSONObject(Arr.Items[I].FindValue('fields')) do
          if (Pair.JsonValue is TJSONObject) and Pair.JsonValue.GetValue<Boolean>('required', False) and
            not Pair.JsonValue.GetValue<Boolean>('hasDefaultValue', False) then
          begin
            F := Default(TTransitionField);
            F.Id := Pair.JsonString.Value;
            F.Name := Pair.JsonValue.GetValue<string>('name', F.Id);
            F.Required := True;
            F.Kind := Pair.JsonValue.GetValue<string>('schema.type', 'string');
            if (F.Kind = 'array') then
              F.Kind := 'array-' + Pair.JsonValue.GetValue<string>('schema.items', 'string');
            if Pair.JsonValue.TryGetValue<TJSONArray>('allowedValues', Allowed) then
            begin
              if F.Kind = 'array-option' then
                F.Kind := 'array-option'
              else if not F.Kind.StartsWith('array') then
                F.Kind := 'option';
              for K := 0 to Allowed.Count - 1 do
                F.Allowed := F.Allowed + [Allowed.Items[K].GetValue<string>('value',
                  Allowed.Items[K].GetValue<string>('name', ''))];
            end;
            T.Fields := T.Fields + [F];
          end;
      Result := Result + [T];
    end;
  finally
    J.Free;
  end;
end;

procedure PostComment(const AAccount: TAccount; const AToken, AKey, AText: string);
var
  Body: TJSONObject;
  Adf: string;
begin
  case AAccount.Kind of
    pkGitLab:
      begin
        SendJson(AAccount, AToken, 'POST', GitLabItemPath(AKey) + '/notes',
          Format('{"body":%s}', [TJSONString.Create(AText).ToJSON]));
        Exit;
      end;
    pkAzure:
      begin
        AzurePostComment(AAccount, AToken, AKey, AText);
        Exit;
      end;
  end;
  Body := TJSONObject.Create;
  try
    if AAccount.Kind = pkJiraCloud then
    begin
      // API v3 quer o corpo em ADF: um parágrafo com o texto.
      Adf := '{"type":"doc","version":1,"content":[{"type":"paragraph","content":' +
        '[{"type":"text","text":' + TJSONString.Create(AText).ToJSON + '}]}]}';
      Body.AddPair('body', TJSONObject.ParseJSONValue(Adf));
    end
    else
      Body.AddPair('body', AText);
    if AAccount.Kind = pkGitHub then
      SendJson(AAccount, AToken, 'POST', GitHubIssuePath(AKey) + '/comments', Body.ToJSON)
    else
      SendJson(AAccount, AToken, 'POST', Format('/rest/api/%s/issue/%s/comment',
        [IfThen(AAccount.Kind = pkJiraCloud, '3', '2'), Enc(AKey)]), Body.ToJSON);
  finally
    Body.Free;
  end;
end;

procedure AddWorklog(const AAccount: TAccount; const AToken, AKey: string;
  AHours: Double; AStarted: TDateTime; const AComment: string);
var
  Body: TJSONObject;
  Offset: Integer;
  Started: string;
begin
  if AAccount.Kind = pkGitLab then
  begin
    GitLabAddSpent(AAccount, AToken, AKey, AHours);
    if AComment.Trim <> '' then
      PostComment(AAccount, AToken, AKey, Format('Tempo: %.1fh. %s', [AHours, AComment.Trim]));
    Exit;
  end;
  if not (AAccount.Kind in WorklogKinds) then
    raise Exception.Create(ShortProviderNames[AAccount.Kind] + ' não tem registro de horas pelo Devbox');
  // Jira quer "2026-10-02T09:00:00.000-0300" (fuso sem dois-pontos).
  Offset := Round(TTimeZone.Local.GetUtcOffset(AStarted).TotalMinutes);
  Started := FormatDateTime('yyyy"-"mm"-"dd"T"hh":"nn":"ss".000"', AStarted) +
    Format('%s%.2d%.2d', [IfThen(Offset < 0, '-', '+'), Abs(Offset) div 60, Abs(Offset) mod 60]);
  Body := TJSONObject.Create;
  try
    Body.AddPair('timeSpentSeconds', TJSONNumber.Create(Round(AHours * 3600)));
    Body.AddPair('started', Started);
    if AComment.Trim <> '' then
      Body.AddPair('comment', AComment.Trim);
    SendJson(AAccount, AToken, 'POST', Format('/rest/api/%s/issue/%s/worklog',
      [IfThen(AAccount.Kind = pkJiraCloud, '3', '2'), Enc(AKey)]), Body.ToJSON);
  finally
    Body.Free;
  end;
end;

procedure ApplyTransition(const AAccount: TAccount; const AToken, AKey: string;
  const ATransition: TTransition);
begin
  if AAccount.Kind = pkGitLab then
    SendJson(AAccount, AToken, 'PUT', GitLabItemPath(AKey), Format('{"state_event":"%s"}', [ATransition.Id]))
  else if AAccount.Kind = pkAzure then
    AzurePatch(AAccount, AToken, AzureId(AKey), 'System.State', ATransition.Id)
  else if AAccount.Kind = pkGitHub then
    SendJson(AAccount, AToken, 'PATCH', GitHubIssuePath(AKey),
      Format('{"state":"%s"}', [ATransition.Id]))
  else
    SendJson(AAccount, AToken, 'POST', Format('/rest/api/%s/issue/%s/transitions',
      [IfThen(AAccount.Kind = pkJiraCloud, '3', '2'), Enc(AKey)]),
      Format('{"transition":{"id":"%s"}}', [ATransition.Id]));
end;

function JiraApi(const AAccount: TAccount): string;
begin
  Result := IfThen(AAccount.Kind = pkJiraCloud, '/rest/api/3', '/rest/api/2');
end;

procedure ApplyTransitionWith(const AAccount: TAccount; const AToken, AKey: string;
  const ATransition: TTransition; const AValues: TArray<string>);
var
  Body, Fields: TJSONObject;
  F: TTransitionField;
  V, Id, Val: string;
  Arr: TJSONArray;
  Num: Double;
begin
  if not (AAccount.Kind in JiraKinds) or (AValues = nil) then
  begin
    ApplyTransition(AAccount, AToken, AKey, ATransition);
    Exit;
  end;
  Body := TJSONObject.Create;
  try
    Body.AddPair('transition', TJSONObject.Create(TJSONPair.Create('id', ATransition.Id)));
    Fields := TJSONObject.Create;
    Body.AddPair('fields', Fields);
    for V in AValues do
    begin
      Id := V.Substring(0, V.IndexOf('='));
      Val := V.Substring(V.IndexOf('=') + 1);
      F := Default(TTransitionField);
      for var Tf in ATransition.Fields do
        if Tf.Id = Id then
          F := Tf;
      if F.Kind = 'option' then
        Fields.AddPair(Id, TJSONObject.Create(TJSONPair.Create(
          IfThen((Id = 'resolution') or (Id = 'priority'), 'name', 'value'), Val)))
      else if F.Kind = 'array-option' then
      begin
        Arr := TJSONArray.Create;
        Arr.Add(TJSONObject.Create(TJSONPair.Create('value', Val)));
        Fields.AddPair(Id, Arr);
      end
      else if (F.Kind = 'number') and TryStrToFloat(Val.Replace(',', '.'), Num, TFormatSettings.Invariant) then
        Fields.AddPair(Id, TJSONNumber.Create(Num))
      else
        Fields.AddPair(Id, Val);
    end;
    SendJson(AAccount, AToken, 'POST', Format('%s/issue/%s/transitions', [JiraApi(AAccount), Enc(AKey)]),
      Body.ToJSON);
  finally
    Body.Free;
  end;
end;

procedure AssignToMe(const AAccount: TAccount; const AToken, AKey: string);
var
  Me: TIdentity;
begin
  Me := WhoAmI(AAccount, AToken);
  case AAccount.Kind of
    pkGitHub:
      SendJson(AAccount, AToken, 'POST', GitHubIssuePath(AKey) + '/assignees',
        Format('{"assignees":[%s]}', [TJSONString.Create(Me.Id).ToJSON]));
    pkJiraServer:
      SendJson(AAccount, AToken, 'PUT', Format('%s/issue/%s/assignee', [JiraApi(AAccount), Enc(AKey)]),
        Format('{"name":%s}', [TJSONString.Create(Me.Id).ToJSON]));
    pkJiraCloud:
      SendJson(AAccount, AToken, 'PUT', Format('%s/issue/%s/assignee', [JiraApi(AAccount), Enc(AKey)]),
        Format('{"accountId":%s}', [TJSONString.Create(Me.Id).ToJSON]));
    pkGitLab:
      GitLabAssignToMe(AAccount, AToken, AKey);
    pkAzure:
      AzurePatch(AAccount, AToken, AzureId(AKey), 'System.AssignedTo', Me.Id);
  end;
end;

procedure AddLabel(const AAccount: TAccount; const AToken, AKey, ALabel: string);
begin
  if AAccount.Kind = pkGitLab then
    SendJson(AAccount, AToken, 'PUT', GitLabItemPath(AKey),
      Format('{"add_labels":%s}', [TJSONString.Create(ALabel.Trim).ToJSON]))
  else if AAccount.Kind = pkAzure then
    AzureAddTag(AAccount, AToken, AKey, ALabel)
  else if AAccount.Kind = pkGitHub then
    SendJson(AAccount, AToken, 'POST', GitHubIssuePath(AKey) + '/labels',
      Format('{"labels":[%s]}', [TJSONString.Create(ALabel.Trim).ToJSON]))
  else
    SendJson(AAccount, AToken, 'PUT', Format('%s/issue/%s', [JiraApi(AAccount), Enc(AKey)]),
      Format('{"update":{"labels":[{"add":%s}]}}', [TJSONString.Create(ALabel.Trim.Replace(' ', '-')).ToJSON]));
end;

procedure ApprovePr(const AAccount: TAccount; const AToken, AKey: string);
begin
  if AAccount.Kind = pkGitLab then
  begin
    SendJson(AAccount, AToken, 'POST', GitLabItemPath(AKey) + '/approve', '{}');
    Exit;
  end;
  if AAccount.Kind <> pkGitHub then
    raise Exception.Create('Aprovar só vale para PR do GitHub ou MR do GitLab');
  SendJson(AAccount, AToken, 'POST', GitHubIssuePath(AKey).Replace('/issues/', '/pulls/') + '/reviews',
    '{"event":"APPROVE"}');
end;

procedure MarkNotificationRead(const AAccount: TAccount; const AToken, AThreadId: string);
begin
  if (AAccount.Kind = pkGitHub) and (AThreadId <> '') then
    SendJson(AAccount, AToken, 'PATCH', '/notifications/threads/' + AThreadId, '');
end;

function FetchPriorities(const AAccount: TAccount; const AToken: string): TArray<string>;
var
  J: TJSONValue;
  I: Integer;
begin
  Result := nil;
  J := GetJson(AAccount, AToken, JiraApi(AAccount) + '/priority');
  try
    for I := 0 to TJSONArray(J).Count - 1 do
      Result := Result + [TJSONArray(J).Items[I].GetValue<string>('name', '')];
  finally
    J.Free;
  end;
end;

procedure SetPriority(const AAccount: TAccount; const AToken, AKey, AName: string);
begin
  SendJson(AAccount, AToken, 'PUT', Format('%s/issue/%s', [JiraApi(AAccount), Enc(AKey)]),
    Format('{"fields":{"priority":{"name":%s}}}', [TJSONString.Create(AName).ToJSON]));
end;

procedure SetImpediment(const AAccount: TAccount; const AToken, AKey: string; AOn: Boolean;
  const AReason: string);
var
  FlagField, Value: string;
  J: TJSONValue;
  Allowed: TJSONArray;
begin
  FlagField := ResolveJiraField(AAccount, AToken, 'Flagged');
  if FlagField = '' then
    raise Exception.Create('Este Jira não tem o campo Flagged');
  Value := 'Impediment';
  // O valor da opção muda entre instâncias: o editmeta diz qual é.
  J := GetJson(AAccount, AToken, Format('%s/issue/%s/editmeta', [JiraApi(AAccount), Enc(AKey)]));
  try
    if J.TryGetValue<TJSONArray>('fields.' + FlagField + '.allowedValues', Allowed) and (Allowed.Count > 0) then
      Value := Allowed.Items[0].GetValue<string>('value', Value);
  finally
    J.Free;
  end;
  if AOn then
    SendJson(AAccount, AToken, 'PUT', Format('%s/issue/%s', [JiraApi(AAccount), Enc(AKey)]),
      Format('{"fields":{"%s":[{"value":%s}]}}', [FlagField, TJSONString.Create(Value).ToJSON]))
  else
    SendJson(AAccount, AToken, 'PUT', Format('%s/issue/%s', [JiraApi(AAccount), Enc(AKey)]),
      Format('{"fields":{"%s":[]}}', [FlagField]));
  if AReason.Trim <> '' then
    PostComment(AAccount, AToken, AKey, IfThen(AOn, 'Impedimento: ', 'Impedimento resolvido: ') + AReason.Trim);
end;

function CreateIssue(const AAccount: TAccount; const AToken, AWhere, ATitle, ABody: string): string;
var
  Body, Fields: TJSONObject;
  R: TJSONValue;
  Adf: string;
begin
  case AAccount.Kind of
    pkGitLab: Exit(GitLabCreate(AAccount, AToken, AWhere, ATitle, ABody));
    pkAzure: Exit(AzureCreate(AAccount, AToken, AWhere, ATitle, ABody));
  end;
  Body := TJSONObject.Create;
  try
    if AAccount.Kind = pkGitHub then
    begin
      Body.AddPair('title', ATitle);
      Body.AddPair('body', ABody);
      R := TJSONObject.ParseJSONValue(SendJsonRead(AAccount, AToken, 'POST',
        '/repos/' + AWhere.Trim + '/issues', Body.ToJSON));
      try
        Result := AWhere.Trim + '#' + R.GetValue<string>('number', '');
      finally
        R.Free;
      end;
    end
    else
    begin
      Fields := TJSONObject.Create;
      Body.AddPair('fields', Fields);
      Fields.AddPair('project', TJSONObject.Create(TJSONPair.Create('key', AWhere.Trim.ToUpper)));
      Fields.AddPair('summary', ATitle);
      Fields.AddPair('issuetype', TJSONObject.Create(TJSONPair.Create('name', 'Task')));
      if AAccount.Kind = pkJiraCloud then
      begin
        Adf := '{"type":"doc","version":1,"content":[{"type":"paragraph","content":' +
          '[{"type":"text","text":' + TJSONString.Create(ABody).ToJSON + '}]}]}';
        Fields.AddPair('description', TJSONObject.ParseJSONValue(Adf));
      end
      else
        Fields.AddPair('description', ABody);
      R := TJSONObject.ParseJSONValue(SendJsonRead(AAccount, AToken, 'POST',
        JiraApi(AAccount) + '/issue', Body.ToJSON));
      try
        Result := R.GetValue<string>('key', '');
      finally
        R.Free;
      end;
    end;
  finally
    Body.Free;
  end;
end;

function FetchIssueInfo(const AAccount: TAccount; const AToken, AKey: string): TIssueInfo;
var
  J: TJSONValue;
  Arr: TJSONArray;
  I: Integer;
  A: TAttachment;
  L: TIssueLink;
  Dummy: Boolean;
  Other: string;
begin
  Result := Default(TIssueInfo);
  if AAccount.Kind = pkGitLab then
  begin
    Result.Description := GitLabDescription(AAccount, AToken, AKey);
    Exit;
  end;
  if AAccount.Kind = pkAzure then
  begin
    AzureTitleAndDescription(AAccount, AToken, AKey, Result.Description);
    Exit;
  end;
  if AAccount.Kind = pkGitHub then
  begin
    J := GetJson(AAccount, AToken, GitHubIssuePath(AKey));
    try
      Result.Description := MarkdownToText(J.GetValue<string>('body', ''));
    finally
      J.Free;
    end;
    Exit;
  end;
  J := GetJson(AAccount, AToken, Format('%s/issue/%s?fields=description,attachment,issuelinks',
    [JiraApi(AAccount), Enc(AKey)]));
  try
    if AAccount.Kind = pkJiraCloud then
      Result.Description := AdfToText(J.FindValue('fields.description'), '', Dummy)
    else if J.FindValue('fields.description') is TJSONString then
      Result.Description := CleanCommentText(WikiToText(J.GetValue<string>('fields.description')));
    if J.TryGetValue<TJSONArray>('fields.attachment', Arr) then
      for I := 0 to Arr.Count - 1 do
      begin
        A.Name := Arr.Items[I].GetValue<string>('filename', '');
        A.Url := Arr.Items[I].GetValue<string>('content', '');
        A.Size := Arr.Items[I].GetValue<Int64>('size', 0);
        Result.Attachments := Result.Attachments + [A];
      end;
    if J.TryGetValue<TJSONArray>('fields.issuelinks', Arr) then
      for I := 0 to Arr.Count - 1 do
      begin
        if Arr.Items[I].FindValue('outwardIssue') <> nil then
        begin
          Other := 'outwardIssue';
          L.Kind := Arr.Items[I].GetValue<string>('type.outward', '');
        end
        else
        begin
          Other := 'inwardIssue';
          L.Kind := Arr.Items[I].GetValue<string>('type.inward', '');
        end;
        L.Key := Arr.Items[I].GetValue<string>(Other + '.key', '');
        L.Summary := Arr.Items[I].GetValue<string>(Other + '.fields.summary', '');
        L.Url := TrimSlash(AAccount.BaseUrl) + '/browse/' + L.Key;
        Result.Links := Result.Links + [L];
      end;
  finally
    J.Free;
  end;
end;

procedure FetchWeekHours(const AAccount: TAccount; const AToken: string; out AToday, AWeek: Double);
var
  Me: TIdentity;
  J: TJSONValue;
  Issues, Logs: TJSONArray;
  I, K: Integer;
  Started: TDateTime;
  WeekStart: TDateTime;
  Secs: Double;
begin
  AToday := 0;
  AWeek := 0;
  if not (AAccount.Kind in JiraKinds) then
    Exit;
  Me := WhoAmI(AAccount, AToken);
  WeekStart := StartOfTheWeek(Date);  // segunda-feira
  J := GetJson(AAccount, AToken, Format('%s/search?jql=%s&fields=worklog&maxResults=100',
    [JiraApi(AAccount), Enc(Format('worklogAuthor = currentUser() AND worklogDate >= "%s"',
      [FormatDateTime('yyyy-mm-dd', WeekStart)]))]));
  try
    Issues := J.GetValue<TJSONArray>('issues');
    for I := 0 to Issues.Count - 1 do
      // ponytail: usa os até 20 worklogs que vêm na busca; issue com mais lançamentos
      // na semana fica subcontada (raro no uso pessoal).
      if Issues.Items[I].TryGetValue<TJSONArray>('fields.worklog.worklogs', Logs) then
        for K := 0 to Logs.Count - 1 do
          if SameText(JiraUserId(Logs.Items[K].FindValue('author'), AAccount.Kind = pkJiraCloud), Me.Id) then
          begin
            Started := TTimeZone.Local.ToLocalTime(ParseIsoDate(Logs.Items[K].GetValue<string>('started', '')));
            Secs := Logs.Items[K].GetValue<Double>('timeSpentSeconds', 0);
            if Started >= WeekStart then
              AWeek := AWeek + Secs / 3600;
            if DateOf(Started) = Date then
              AToday := AToday + Secs / 3600;
          end;
  finally
    J.Free;
  end;
end;

function FetchJobLog(const AAccount: TAccount; const AToken, AJobUrl: string): string;
var
  M: TMatch;
  Http: THTTPClient;
  Resp: IHTTPResponse;
begin
  Result := '';
  // https://github.com/dono/repo/actions/runs/1/job/2 -> /repos/dono/repo/actions/jobs/2/logs
  M := TRegEx.Match(AJobUrl, 'github\.com/([^/]+/[^/]+)/actions/runs/\d+/job/(\d+)');
  if (AAccount.Kind <> pkGitHub) or not M.Success then
    Exit;
  Http := THTTPClient.Create;
  try
    Http.HandleRedirects := True;
    Resp := Http.Get(TrimSlash(AAccount.BaseUrl) + Format('/repos/%s/actions/jobs/%s/logs',
      [M.Groups[1].Value, M.Groups[2].Value]), nil, AuthHeaders(AAccount, AToken));
    if Resp.StatusCode = 200 then
      Result := Resp.ContentAsString(TEncoding.UTF8);
  finally
    Http.Free;
  end;
  // O fim do log é onde o erro aparece.
  if Length(Result) > 6000 then
    Result := Copy(Result, Length(Result) - 6000 + 1, 6000);
end;

function FetchItems(const AAccount: TAccount; const AToken: string;
  const AManualKeys: TArray<string>; out AMe: TIdentity): TItems;
begin
  if AToken = '' then
    raise Exception.Create('Token não encontrado no Credential Manager');
  AMe := Default(TIdentity);
  // GitHub dispensa o "quem sou eu": notification nunca vem de ação minha.
  case AAccount.Kind of
    pkGitHub: Result := FetchGitHub(AAccount, AToken, AManualKeys);
    pkGitLab: Result := FetchGitLab(AAccount, AToken, AManualKeys, AMe);
    pkAzure: Result := FetchAzure(AAccount, AToken, AManualKeys, AMe);
  else
    Result := FetchJira(AAccount, AToken, AManualKeys, AMe);
  end;
end;

initialization
  FieldIds := TDictionary<string, string>.Create;
  GitHubCache := TDictionary<string, TCachedResponse>.Create;

finalization
  FieldIds.Free;
  GitHubCache.Free;

end.
