unit Devbox.Issues.Store;

{ Issues (vindo do Vigia): contas, snapshot dos itens, avisos, silenciadas, tags e
  preferências, em tabelas issue_* dentro do devbox.db (a mesma conexão do
  Devbox.Store). Na primeira vez, copia os dados de %LOCALAPPDATA%\Vigia\vigia.db
  (o arquivo do Vigia fica intacto). Só usar na thread de UI. }

interface

uses
  System.Generics.Collections,
  FireDAC.Comp.Client,
  Devbox.Issues.Model;

type
  TMuteRule = record
    Until_: Double;
    UntilStatus: string;
    { Ainda vale? Solta com o prazo vencido ou o status diferente do gravado. }
    function Active(const ACurrentStatus: string): Boolean;
  end;

  TIssueStore = class
  private
    FConn: TFDConnection;
    procedure Migrate;
    procedure AddColumn(const ATable, AColumn, ADef: string);
    procedure ImportVigia;
    procedure CopyTable(const AFrom, ATo: string);
  public
    constructor Create(AConn: TFDConnection);
    destructor Destroy; override;
    function ListAccounts: TArray<TAccount>;
    procedure SaveAccount(var AAccount: TAccount);
    procedure DeleteAccount(AId: Integer);
    { Snapshot = último estado visto de cada item da conta. Vazio = conta nunca buscada. }
    function LoadSnapshot(AAccountId: Integer): TItems;
    function HasSnapshot(AAccountId: Integer): Boolean;
    procedure SaveSnapshot(AAccountId: Integer; const AItems: TItems);
    { Issues cadastradas à mão para acompanhar ('PROJ-123' ou 'dono/repo#12'). }
    function ListManualKeys(AAccountId: Integer): TArray<string>;
    procedure AddManualKey(AAccountId: Integer; const AKey: string);
    procedure RemoveManualKey(AAccountId: Integer; const AKey: string);
    { Histórico de avisos gerados (inclusive os filtrados pela regra da conta). }
    procedure AddEvents(const AEvents: TIssueEvents);
    function ListEvents(AAccountId: Integer; const AKey: string): TIssueEvents;
    { Últimos avisos de todas as contas, mais novos primeiro. }
    function ListRecentEvents(ALimit: Integer): TIssueEvents;
    { Avisos por dia nos últimos ADays dias (índice 0 = mais antigo). }
    function EventsPerDay(ADays: Integer; AAccountId: Integer = 0): TArray<Integer>;
    { Avisos por dia da semana (0 = domingo) x faixa de 3 horas (0..7), últimos ADays. }
    { Quantos avisos de um tipo nas últimas AHours horas. }
    function CountEvents(AKind: TEventKind; AHours: Integer; AAccountId: Integer = 0): Integer;
    { Momento da última busca bem-sucedida da conta (0 = nunca). }
    function LastPoll(AAccountId: Integer): TDateTime;
    { Silenciar: sem avisos até AUntil (0 = sem prazo) ou até o status mudar
      (AUntilStatus = status atual). }
    procedure Mute(AAccountId: Integer; const AKey: string; AUntil: TDateTime; const AUntilStatus: string);
    procedure Unmute(AAccountId: Integer; const AKey: string);
    { True se a issue está silenciada agora. Solta sozinha quando passa o prazo
      ou o status deixa de ser o gravado. }
    function IsMuted(AAccountId: Integer; const AKey, ACurrentStatus: string): Boolean;
    { Todas as silenciadas de uma vez ('conta|CHAVE' -> regra), para não ir ao
      banco uma vez por issue. }
    function LoadMuted: TDictionary<string, TMuteRule>;
    { Uso do assistente: uma linha por resposta. }
    procedure AddAiUsage(const AProvider, AModel: string; AInput, AOutput: Integer; ACost: Double);
    { Totais desde AFrom: respostas, tokens de entrada/saída e custo (US$). }
    procedure AiTotals(AFrom: TDateTime; out ACount, AInput, AOutput: Integer; out ACost: Double);
    { Custo por dia nos últimos ADays (índice 0 = mais antigo). }
    function AiCostPerDay(ADays: Integer): TArray<Double>;
    { Tags do usuário, com as issues marcadas à mão de cada uma. }
    function ListTags: TTags;
    procedure SaveTag(var ATag: TTag);
    procedure DeleteTag(AId: Integer);
    procedure SetItemTag(ATagId, AAccountId: Integer; const AKey: string; AOn: Boolean);
    { Preferências do usuário (chave/valor). }
    function GetSetting(const AName: string; const ADefault: string = ''): string;
    procedure SetSetting(const AName, AValue: string);
    { Todas as preferências (para o backup). }
    function ListSettings: TArray<TPair<string, string>>;
  end;

function IssueStore: TIssueStore;
{ Pasta de dados do Vigia antigo (de onde a primeira abertura importa). }
function VigiaDataDir: string;

implementation

uses
  System.SysUtils,
  System.IOUtils,
  System.Variants,
  System.DateUtils,
  Data.DB,
  FireDAC.Stan.Def,
  FireDAC.Stan.Async,
  FireDAC.Stan.Intf,
  FireDAC.DApt,
  FireDAC.Phys.SQLite,
  FireDAC.Phys.SQLiteDef,
  FireDAC.Stan.ExprFuncs,
  FireDAC.VCLUI.Wait,
  Devbox.Store;

var
  GStore: TIssueStore;

function VigiaDataDir: string;
begin
  Result := TPath.Combine(GetEnvironmentVariable('LOCALAPPDATA'), 'Vigia');
end;

function IssueStore: TIssueStore;
begin
  if GStore = nil then
    GStore := TIssueStore.Create(Store.Connection);
  Result := GStore;
end;

function EventsToInt(AEvents: TEventKinds): Integer;
var
  E: TEventKind;
begin
  Result := 0;
  for E in AEvents do
    Result := Result or (1 shl Ord(E));
end;

function IntToEvents(AValue: Integer): TEventKinds;
var
  E: TEventKind;
begin
  Result := [];
  for E := Low(TEventKind) to High(TEventKind) do
    if AValue and (1 shl Ord(E)) <> 0 then
      Include(Result, E);
end;

constructor TIssueStore.Create(AConn: TFDConnection);
begin
  inherited Create;
  FConn := AConn;
  Migrate;
  ImportVigia;
end;

{ Copia as colunas que as duas tabelas têm em comum (a ordem pode ser outra). }
procedure TIssueStore.CopyTable(const AFrom, ATo: string);
var
  Q: TFDQuery;
  LColumns: TArray<string>;
  LTarget: string;
  LIndex: Integer;
begin
  LColumns := nil;
  Q := TFDQuery.Create(nil);
  try
    Q.Connection := FConn;
    Q.Open('PRAGMA vg.table_info(' + AFrom + ')');
    while not Q.Eof do
    begin
      LColumns := LColumns + [Q.FieldByName('name').AsString];
      Q.Next;
    end;
    Q.Close;
    LTarget := '';
    Q.Open('PRAGMA table_info(' + ATo + ')');
    while not Q.Eof do
    begin
      LTarget := LTarget + '|' + LowerCase(Q.FieldByName('name').AsString) + '|';
      Q.Next;
    end;
  finally
    Q.Free;
  end;
  for LIndex := High(LColumns) downto 0 do
    if Pos('|' + LowerCase(LColumns[LIndex]) + '|', LTarget) = 0 then
      Delete(LColumns, LIndex, 1);
  if LColumns = nil then
    Exit;
  FConn.ExecSQL(Format('INSERT OR IGNORE INTO %s (%s) SELECT %s FROM vg.%s',
    [ATo, string.Join(', ', LColumns), string.Join(', ', LColumns), AFrom]));
end;

{ Primeira abertura depois da unificação: traz tudo do vigia.db. Uma vez só. }
procedure TIssueStore.ImportVigia;
const
  CPairs: array[0..7, 0..1] of string = (('account', 'issue_account'), ('item_snapshot', 'issue_snapshot'),
    ('account_poll', 'issue_poll'), ('manual_watch', 'issue_manual'), ('event_log', 'issue_event'),
    ('muted', 'issue_muted'), ('tag', 'issue_tag'), ('item_tag', 'issue_item_tag'));
var
  LPath: string;
  LIndex: Integer;
begin
  if GetSetting('migr_from_vigia') <> '' then
    Exit;
  LPath := TPath.Combine(VigiaDataDir, 'vigia.db');
  if FileExists(LPath) then
  begin
    FConn.ExecSQL('ATTACH DATABASE ' + QuotedStr(LPath) + ' AS vg');
    try
      for LIndex := Low(CPairs) to High(CPairs) do
        CopyTable(CPairs[LIndex, 0], CPairs[LIndex, 1]);
      // Preferências do Vigia ficam na tabela própria; o uso de IA vai para o painel de custos do Devbox.
      FConn.ExecSQL('INSERT OR REPLACE INTO issue_setting (name, value) SELECT name, value FROM vg.setting');
      FConn.ExecSQL('INSERT INTO ai_usage (at, provider, model, kind, input_tokens, output_tokens, cost) ' +
        'SELECT at, provider, model, ''assistente'', input_tokens, output_tokens, cost FROM vg.ai_usage');
    finally
      FConn.ExecSQL('DETACH DATABASE vg');
    end;
  end;
  SetSetting('migr_from_vigia', '1');
end;

destructor TIssueStore.Destroy;
begin
  // A conexão é do Devbox.Store.
  inherited;
end;

procedure TIssueStore.Migrate;
begin
  FConn.ExecSQL(
    'CREATE TABLE IF NOT EXISTS issue_account (' +
    '  id INTEGER PRIMARY KEY AUTOINCREMENT,' +
    '  name TEXT NOT NULL,' +
    '  kind INTEGER NOT NULL,' +
    '  base_url TEXT NOT NULL,' +
    '  login TEXT NOT NULL DEFAULT '''',' +
    '  enabled INTEGER NOT NULL DEFAULT 1,' +
    '  events INTEGER NOT NULL,' +
    '  due_days INTEGER NOT NULL DEFAULT 2)');
  FConn.ExecSQL(
    'CREATE TABLE IF NOT EXISTS issue_snapshot (' +
    '  account_id INTEGER NOT NULL,' +
    '  key TEXT NOT NULL,' +
    '  title TEXT, url TEXT, status TEXT, assignee TEXT,' +
    '  due_date REAL, updated_at REAL,' +
    '  comment_count INTEGER, last_comment_by TEXT,' +
    '  mentions_me INTEGER, unread_reason TEXT,' +
    '  sources INTEGER, due_alert INTEGER,' +
    '  PRIMARY KEY (account_id, key))');
  // Marca de "conta já buscada", para a conta sem itens não virar linha de base de novo.
  FConn.ExecSQL(
    'CREATE TABLE IF NOT EXISTS issue_poll (' +
    '  account_id INTEGER PRIMARY KEY, last_poll REAL NOT NULL)');
  FConn.ExecSQL(
    'CREATE TABLE IF NOT EXISTS issue_manual (' +
    '  account_id INTEGER NOT NULL, key TEXT NOT NULL COLLATE NOCASE,' +
    '  PRIMARY KEY (account_id, key))');
  FConn.ExecSQL(
    'CREATE TABLE IF NOT EXISTS issue_event (' +
    '  id INTEGER PRIMARY KEY AUTOINCREMENT,' +
    '  account_id INTEGER NOT NULL, key TEXT NOT NULL COLLATE NOCASE,' +
    '  kind INTEGER NOT NULL, body TEXT, at REAL NOT NULL)');
  FConn.ExecSQL('CREATE INDEX IF NOT EXISTS ix_issue_event_key ON issue_event (account_id, key)');
  FConn.ExecSQL('CREATE TABLE IF NOT EXISTS issue_setting (name TEXT PRIMARY KEY, value TEXT)');
  // Mesma tabela do painel de custos do Devbox (Devbox.Store cria igual).
  FConn.ExecSQL('CREATE TABLE IF NOT EXISTS ai_usage (id INTEGER PRIMARY KEY AUTOINCREMENT, at REAL NOT NULL, ' +
    'provider TEXT, model TEXT, kind TEXT, input_tokens INTEGER, output_tokens INTEGER, ' +
    'audio_in_tokens INTEGER, audio_out_tokens INTEGER, audio_seconds REAL, cost REAL)');
  FConn.ExecSQL('CREATE TABLE IF NOT EXISTS issue_muted (account_id INTEGER NOT NULL, ' +
    'key TEXT NOT NULL COLLATE NOCASE, until REAL NOT NULL DEFAULT 0, until_status TEXT, ' +
    'PRIMARY KEY (account_id, key))');
  FConn.ExecSQL('CREATE TABLE IF NOT EXISTS issue_tag (id INTEGER PRIMARY KEY AUTOINCREMENT, ' +
    'name TEXT NOT NULL UNIQUE COLLATE NOCASE, keywords TEXT NOT NULL DEFAULT '''')');
  FConn.ExecSQL('CREATE TABLE IF NOT EXISTS issue_item_tag (tag_id INTEGER NOT NULL, ' +
    'account_id INTEGER NOT NULL, key TEXT NOT NULL COLLATE NOCASE, ' +
    'PRIMARY KEY (tag_id, account_id, key))');

  // Colunas que entraram depois da primeira versão do banco.
  AddColumn('issue_account', 'due_field', 'TEXT NOT NULL DEFAULT ''''');
  AddColumn('issue_account', 'warn_days', 'INTEGER NOT NULL DEFAULT 5');
  AddColumn('issue_account', 'critical_days', 'INTEGER NOT NULL DEFAULT 2');
  AddColumn('issue_snapshot', 'status_cat', 'TEXT');
  AddColumn('issue_snapshot', 'flagged', 'INTEGER NOT NULL DEFAULT 0');
  AddColumn('issue_snapshot', 'review_state', 'TEXT');
  AddColumn('issue_snapshot', 'ci_state', 'TEXT');
  AddColumn('issue_snapshot', 'ci_detail', 'TEXT');
  AddColumn('issue_snapshot', 'ci_url', 'TEXT');
  AddColumn('issue_snapshot', 'reviewers', 'TEXT');
  AddColumn('issue_snapshot', 'thread_id', 'TEXT');
  AddColumn('issue_account', 'my_prs', 'INTEGER NOT NULL DEFAULT 0');
  AddColumn('issue_account', 'mentions', 'INTEGER NOT NULL DEFAULT 0');
  AddColumn('issue_account', 'extra_query', 'TEXT NOT NULL DEFAULT ''''');
  AddColumn('issue_account', 'include_list', 'TEXT NOT NULL DEFAULT ''''');
  AddColumn('issue_account', 'exclude_list', 'TEXT NOT NULL DEFAULT ''''');
  AddColumn('issue_account', 'poll_minutes', 'INTEGER NOT NULL DEFAULT 0');
  AddColumn('issue_account', 'own_repos', 'INTEGER NOT NULL DEFAULT 0');
  AddColumn('issue_tag', 'account_id', 'INTEGER NOT NULL DEFAULT 0');
  // Tags viraram por conta: as que já existiam vão para a primeira conta do Jira.
  // GitHub passa a trazer as issues dos meus repositórios.
  if GetSetting('migr_tags_account') = '' then
  begin
    FConn.ExecSQL('UPDATE issue_tag SET account_id = COALESCE((SELECT MIN(id) FROM issue_account ' +
      'WHERE kind <> 0), 0) WHERE account_id = 0');
    FConn.ExecSQL('UPDATE issue_account SET own_repos = 1 WHERE kind = 0');
    // Nome único por conta (antes era no banco todo): recria a tabela.
    FConn.ExecSQL('CREATE TABLE issue_tag_new (id INTEGER PRIMARY KEY AUTOINCREMENT, ' +
      'name TEXT NOT NULL COLLATE NOCASE, keywords TEXT NOT NULL DEFAULT '''', ' +
      'account_id INTEGER NOT NULL DEFAULT 0, UNIQUE (account_id, name))');
    FConn.ExecSQL('INSERT INTO issue_tag_new (id, name, keywords, account_id) ' +
      'SELECT id, name, keywords, account_id FROM issue_tag');
    FConn.ExecSQL('DROP TABLE issue_tag');
    FConn.ExecSQL('ALTER TABLE issue_tag_new RENAME TO issue_tag');
    SetSetting('migr_tags_account', '1');
  end;
  // Avisos novos (PR aprovado, mudanças pedidas, CI falhou) entram ligados nas
  // contas que já existiam; uma vez só. GitHub também passa a trazer meus PRs.
  if GetSetting('migr_events_v2') = '' then
  begin
    FConn.ExecSQL('UPDATE issue_account SET events = events | :b',
      [EventsToInt([ekPrApproved, ekChangesRequested, ekCiFailed])]);
    FConn.ExecSQL('UPDATE issue_account SET my_prs = 1 WHERE kind = 0');
    SetSetting('migr_events_v2', '1');
  end;
end;

procedure TIssueStore.AddColumn(const ATable, AColumn, ADef: string);
var
  Q: TFDQuery;
begin
  // O SQLite do FireDAC não tem pragma_table_info() como tabela; lê o PRAGMA.
  Q := TFDQuery.Create(nil);
  try
    Q.Connection := FConn;
    Q.Open('PRAGMA table_info(' + ATable + ')');
    while not Q.Eof do
    begin
      if SameText(Q.FieldByName('name').AsString, AColumn) then
        Exit;
      Q.Next;
    end;
  finally
    Q.Free;
  end;
  FConn.ExecSQL(Format('ALTER TABLE %s ADD COLUMN %s %s', [ATable, AColumn, ADef]));
end;

function TIssueStore.ListRecentEvents(ALimit: Integer): TIssueEvents;
var
  Q: TFDQuery;
  E: TIssueEvent;
begin
  Result := nil;
  Q := TFDQuery.Create(nil);
  try
    Q.Connection := FConn;
    Q.Open('SELECT account_id, key, kind, body, at FROM issue_event ORDER BY at DESC, id DESC LIMIT ' +
      IntToStr(ALimit));
    while not Q.Eof do
    begin
      E := Default(TIssueEvent);
      E.AccountId := Q.Fields[0].AsInteger;
      E.Key := Q.Fields[1].AsString;
      E.Kind := TEventKind(Q.Fields[2].AsInteger);
      E.Body := Q.Fields[3].AsString;
      E.At := Q.Fields[4].AsFloat;
      Result := Result + [E];
      Q.Next;
    end;
  finally
    Q.Free;
  end;
end;

function TIssueStore.EventsPerDay(ADays: Integer; AAccountId: Integer): TArray<Integer>;
var
  Q: TFDQuery;
  First: TDateTime;
  D: Integer;
begin
  SetLength(Result, ADays);
  First := Trunc(Now) - ADays + 1;
  Q := TFDQuery.Create(nil);
  try
    Q.Connection := FConn;
    Q.Open('SELECT CAST(at AS INTEGER) AS dia, COUNT(*) FROM issue_event WHERE at >= :ini ' +
      'AND (:conta = 0 OR account_id = :conta2) GROUP BY dia', [Double(First), AAccountId, AAccountId]);
    while not Q.Eof do
    begin
      D := Q.Fields[0].AsInteger - Trunc(First);
      if (D >= 0) and (D < ADays) then
        Result[D] := Q.Fields[1].AsInteger;
      Q.Next;
    end;
  finally
    Q.Free;
  end;
end;
function TIssueStore.CountEvents(AKind: TEventKind; AHours: Integer; AAccountId: Integer): Integer;
begin
  Result := FConn.ExecSQLScalar('SELECT COUNT(*) FROM issue_event WHERE kind = :k AND at >= :ini ' +
    'AND (:conta = 0 OR account_id = :conta2)', [Ord(AKind), Double(Now - AHours / 24), AAccountId, AAccountId]);
end;

function TIssueStore.LastPoll(AAccountId: Integer): TDateTime;
var
  V: Variant;
begin
  V := FConn.ExecSQLScalar('SELECT last_poll FROM issue_poll WHERE account_id = :id', [AAccountId]);
  if VarIsNull(V) or VarIsEmpty(V) then
    Result := 0
  else
    Result := V;
end;

procedure TIssueStore.Mute(AAccountId: Integer; const AKey: string; AUntil: TDateTime;
  const AUntilStatus: string);
begin
  FConn.ExecSQL('INSERT OR REPLACE INTO issue_muted (account_id, key, until, until_status) ' +
    'VALUES (:a, :k, :u, :s)', [AAccountId, AKey, Double(AUntil), AUntilStatus]);
end;

procedure TIssueStore.Unmute(AAccountId: Integer; const AKey: string);
begin
  FConn.ExecSQL('DELETE FROM issue_muted WHERE account_id = :a AND key = :k', [AAccountId, AKey]);
end;

function TIssueStore.IsMuted(AAccountId: Integer; const AKey, ACurrentStatus: string): Boolean;
var
  Q: TFDQuery;
  Until_: Double;
  UntilStatus: string;
begin
  Result := False;
  Q := TFDQuery.Create(nil);
  try
    Q.Connection := FConn;
    Q.Open('SELECT until, until_status FROM issue_muted WHERE account_id = :a AND key = :k', [AAccountId, AKey]);
    if Q.Eof then
      Exit;
    Until_ := Q.Fields[0].AsFloat;
    UntilStatus := Q.Fields[1].AsString;
  finally
    Q.Free;
  end;
  Result := ((Until_ = 0) or (Now < Until_)) and
    ((UntilStatus = '') or SameText(UntilStatus, ACurrentStatus));
  if not Result then
    Unmute(AAccountId, AKey);
end;

function TMuteRule.Active(const ACurrentStatus: string): Boolean;
begin
  Result := ((Until_ = 0) or (Now < Until_)) and
    ((UntilStatus = '') or SameText(UntilStatus, ACurrentStatus));
end;

function TIssueStore.LoadMuted: TDictionary<string, TMuteRule>;
var
  Q: TFDQuery;
  R: TMuteRule;
begin
  Result := TDictionary<string, TMuteRule>.Create;
  Q := TFDQuery.Create(nil);
  try
    Q.Connection := FConn;
    Q.Open('SELECT account_id, key, until, until_status FROM issue_muted');
    while not Q.Eof do
    begin
      R.Until_ := Q.Fields[2].AsFloat;
      R.UntilStatus := Q.Fields[3].AsString;
      Result.AddOrSetValue(Q.Fields[0].AsString + '|' + Q.Fields[1].AsString.ToUpper, R);
      Q.Next;
    end;
  finally
    Q.Free;
  end;
end;

procedure TIssueStore.AddAiUsage(const AProvider, AModel: string; AInput, AOutput: Integer; ACost: Double);
begin
  FConn.ExecSQL('INSERT INTO ai_usage (at, provider, model, input_tokens, output_tokens, cost) ' +
    'VALUES (:at, :p, :m, :i, :o, :c)', [Double(Now), AProvider, AModel, AInput, AOutput, ACost]);
end;

procedure TIssueStore.AiTotals(AFrom: TDateTime; out ACount, AInput, AOutput: Integer; out ACost: Double);
var
  Q: TFDQuery;
begin
  Q := TFDQuery.Create(nil);
  try
    Q.Connection := FConn;
    Q.Open('SELECT COUNT(*), COALESCE(SUM(input_tokens), 0), COALESCE(SUM(output_tokens), 0), ' +
      'COALESCE(SUM(cost), 0) FROM ai_usage WHERE at >= :ini', [Double(AFrom)]);
    ACount := Q.Fields[0].AsInteger;
    AInput := Q.Fields[1].AsInteger;
    AOutput := Q.Fields[2].AsInteger;
    ACost := Q.Fields[3].AsFloat;
  finally
    Q.Free;
  end;
end;

function TIssueStore.AiCostPerDay(ADays: Integer): TArray<Double>;
var
  Q: TFDQuery;
  First: TDateTime;
  D: Integer;
begin
  SetLength(Result, ADays);
  First := Trunc(Now) - ADays + 1;
  Q := TFDQuery.Create(nil);
  try
    Q.Connection := FConn;
    Q.Open('SELECT CAST(at AS INTEGER) AS dia, SUM(cost) FROM ai_usage WHERE at >= :ini GROUP BY dia',
      [Double(First)]);
    while not Q.Eof do
    begin
      D := Q.Fields[0].AsInteger - Trunc(First);
      if (D >= 0) and (D < ADays) then
        Result[D] := Q.Fields[1].AsFloat;
      Q.Next;
    end;
  finally
    Q.Free;
  end;
end;

function TIssueStore.GetSetting(const AName, ADefault: string): string;
var
  V: Variant;
begin
  V := FConn.ExecSQLScalar('SELECT value FROM issue_setting WHERE name = :n', [AName]);
  if VarIsNull(V) or VarIsEmpty(V) then
    Result := ADefault
  else
    Result := V;
end;

function TIssueStore.ListSettings: TArray<TPair<string, string>>;
var
  Q: TFDQuery;
begin
  Result := nil;
  Q := TFDQuery.Create(nil);
  try
    Q.Connection := FConn;
    Q.Open('SELECT name, value FROM issue_setting ORDER BY name');
    while not Q.Eof do
    begin
      Result := Result + [TPair<string, string>.Create(Q.Fields[0].AsString, Q.Fields[1].AsString)];
      Q.Next;
    end;
  finally
    Q.Free;
  end;
end;

procedure TIssueStore.SetSetting(const AName, AValue: string);
begin
  FConn.ExecSQL('INSERT OR REPLACE INTO issue_setting (name, value) VALUES (:n, :v)', [AName, AValue]);
end;

function TIssueStore.ListAccounts: TArray<TAccount>;
var
  Q: TFDQuery;
  A: TAccount;
begin
  Result := nil;
  Q := TFDQuery.Create(nil);
  try
    Q.Connection := FConn;
    Q.Open('SELECT id, name, kind, base_url, login, enabled, events, due_days, ' +
      'due_field, warn_days, critical_days, my_prs, mentions, extra_query, include_list, ' +
      'exclude_list, poll_minutes, own_repos FROM issue_account ORDER BY name');
    while not Q.Eof do
    begin
      A.Id := Q.Fields[0].AsInteger;
      A.Name := Q.Fields[1].AsString;
      A.Kind := TProviderKind(Q.Fields[2].AsInteger);
      A.BaseUrl := Q.Fields[3].AsString;
      A.Login := Q.Fields[4].AsString;
      A.Enabled := Q.Fields[5].AsInteger <> 0;
      A.Events := IntToEvents(Q.Fields[6].AsInteger);
      A.DueDays := Q.Fields[7].AsInteger;
      A.DueField := Q.Fields[8].AsString;
      A.WarnDays := Q.Fields[9].AsInteger;
      A.CriticalDays := Q.Fields[10].AsInteger;
      A.MyPrs := Q.Fields[11].AsInteger <> 0;
      A.Mentions := Q.Fields[12].AsInteger <> 0;
      A.ExtraQuery := Q.Fields[13].AsString;
      A.IncludeList := Q.Fields[14].AsString;
      A.ExcludeList := Q.Fields[15].AsString;
      A.PollMinutes := Q.Fields[16].AsInteger;
      A.OwnRepos := Q.Fields[17].AsInteger <> 0;
      Result := Result + [A];
      Q.Next;
    end;
  finally
    Q.Free;
  end;
end;

procedure TIssueStore.SaveAccount(var AAccount: TAccount);
const
  Fields = 'name = :name, kind = :kind, base_url = :url, login = :login, ' +
    'enabled = :enabled, events = :events, due_days = :due, due_field = :df, ' +
    'warn_days = :wd, critical_days = :cd, my_prs = :mp, mentions = :mn, extra_query = :eq, ' +
    'include_list = :il, exclude_list = :el, poll_minutes = :pm, own_repos = :or';
var
  A: TAccount;
begin
  A := AAccount;
  if A.Id = 0 then
  begin
    FConn.ExecSQL('INSERT INTO issue_account (name, kind, base_url, login, enabled, events, due_days, ' +
      'due_field, warn_days, critical_days, my_prs, mentions, extra_query, include_list, ' +
      'exclude_list, poll_minutes, own_repos) ' +
      'VALUES (:name, :kind, :url, :login, :enabled, :events, :due, :df, :wd, :cd, :mp, :mn, ' +
      ':eq, :il, :el, :pm, :or)',
      [A.Name, Ord(A.Kind), A.BaseUrl, A.Login, Ord(A.Enabled), EventsToInt(A.Events), A.DueDays,
       A.DueField, A.WarnDays, A.CriticalDays, Ord(A.MyPrs), Ord(A.Mentions), A.ExtraQuery,
       A.IncludeList, A.ExcludeList, A.PollMinutes, Ord(A.OwnRepos)]);
    AAccount.Id := FConn.GetLastAutoGenValue('');
  end
  else
    FConn.ExecSQL('UPDATE issue_account SET ' + Fields + ' WHERE id = :id',
      [A.Name, Ord(A.Kind), A.BaseUrl, A.Login, Ord(A.Enabled), EventsToInt(A.Events), A.DueDays,
       A.DueField, A.WarnDays, A.CriticalDays, Ord(A.MyPrs), Ord(A.Mentions), A.ExtraQuery,
       A.IncludeList, A.ExcludeList, A.PollMinutes, Ord(A.OwnRepos), A.Id]);
end;

procedure TIssueStore.DeleteAccount(AId: Integer);
begin
  FConn.ExecSQL('DELETE FROM issue_account WHERE id = :id', [AId]);
  FConn.ExecSQL('DELETE FROM issue_snapshot WHERE account_id = :id', [AId]);
  FConn.ExecSQL('DELETE FROM issue_poll WHERE account_id = :id', [AId]);
  FConn.ExecSQL('DELETE FROM issue_manual WHERE account_id = :id', [AId]);
  FConn.ExecSQL('DELETE FROM issue_event WHERE account_id = :id', [AId]);
  FConn.ExecSQL('DELETE FROM issue_muted WHERE account_id = :id', [AId]);
  FConn.ExecSQL('DELETE FROM issue_item_tag WHERE account_id = :id', [AId]);
end;

function TIssueStore.ListTags: TTags;
var
  Q: TFDQuery;
  I: Integer;
begin
  Result := nil;
  Q := TFDQuery.Create(nil);
  try
    Q.Connection := FConn;
    Q.Open('SELECT id, name, keywords, account_id FROM issue_tag ORDER BY name COLLATE NOCASE');
    while not Q.Eof do
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)].Id := Q.Fields[0].AsInteger;
      Result[High(Result)].Name := Q.Fields[1].AsString;
      Result[High(Result)].Keywords := Q.Fields[2].AsString;
      Result[High(Result)].AccountId := Q.Fields[3].AsInteger;
      Q.Next;
    end;
    Q.Close;
    Q.Open('SELECT tag_id, account_id, key FROM issue_item_tag');
    while not Q.Eof do
    begin
      for I := 0 to High(Result) do
        if Result[I].Id = Q.Fields[0].AsInteger then
          Result[I].Manual := Result[I].Manual + [ItemTagKey(Q.Fields[1].AsInteger, Q.Fields[2].AsString)];
      Q.Next;
    end;
  finally
    Q.Free;
  end;
end;

procedure TIssueStore.SaveTag(var ATag: TTag);
begin
  if ATag.Id = 0 then
  begin
    FConn.ExecSQL('INSERT INTO issue_tag (name, keywords, account_id) VALUES (:n, :k, :a)',
      [ATag.Name, ATag.Keywords, ATag.AccountId]);
    ATag.Id := FConn.ExecSQLScalar('SELECT last_insert_rowid()');
  end
  else
    FConn.ExecSQL('UPDATE issue_tag SET name = :n, keywords = :k WHERE id = :id',
      [ATag.Name, ATag.Keywords, ATag.Id]);
end;

procedure TIssueStore.DeleteTag(AId: Integer);
begin
  FConn.ExecSQL('DELETE FROM issue_item_tag WHERE tag_id = :id', [AId]);
  FConn.ExecSQL('DELETE FROM issue_tag WHERE id = :id', [AId]);
end;

procedure TIssueStore.SetItemTag(ATagId, AAccountId: Integer; const AKey: string; AOn: Boolean);
begin
  if AOn then
    FConn.ExecSQL('INSERT OR IGNORE INTO issue_item_tag (tag_id, account_id, key) VALUES (:t, :a, :k)',
      [ATagId, AAccountId, AKey])
  else
    FConn.ExecSQL('DELETE FROM issue_item_tag WHERE tag_id = :t AND account_id = :a AND key = :k',
      [ATagId, AAccountId, AKey]);
end;

procedure TIssueStore.AddEvents(const AEvents: TIssueEvents);
var
  E: TIssueEvent;
  At: Double;
begin
  if AEvents = nil then
    Exit;
  At := Now;
  FConn.StartTransaction;
  try
    for E in AEvents do
      FConn.ExecSQL('INSERT INTO issue_event (account_id, key, kind, body, at) VALUES (:a, :k, :t, :b, :at)',
        [E.AccountId, E.Key, Ord(E.Kind), E.Body, At]);
    // ponytail: guarda só os 90 últimos dias; sem configuração.
    FConn.ExecSQL('DELETE FROM issue_event WHERE at < :limite', [At - 90]);
    FConn.Commit;
  except
    FConn.Rollback;
    raise;
  end;
end;

function TIssueStore.ListEvents(AAccountId: Integer; const AKey: string): TIssueEvents;
var
  Q: TFDQuery;
  E: TIssueEvent;
begin
  Result := nil;
  Q := TFDQuery.Create(nil);
  try
    Q.Connection := FConn;
    Q.Open('SELECT kind, body, at FROM issue_event WHERE account_id = :a AND key = :k ORDER BY at DESC, id DESC',
      [AAccountId, AKey]);
    while not Q.Eof do
    begin
      E := Default(TIssueEvent);
      E.AccountId := AAccountId;
      E.Key := AKey;
      E.Kind := TEventKind(Q.Fields[0].AsInteger);
      E.Body := Q.Fields[1].AsString;
      E.At := Q.Fields[2].AsFloat;
      Result := Result + [E];
      Q.Next;
    end;
  finally
    Q.Free;
  end;
end;

function TIssueStore.ListManualKeys(AAccountId: Integer): TArray<string>;
var
  Q: TFDQuery;
begin
  Result := nil;
  Q := TFDQuery.Create(nil);
  try
    Q.Connection := FConn;
    Q.Open('SELECT key FROM issue_manual WHERE account_id = :id ORDER BY key', [AAccountId]);
    while not Q.Eof do
    begin
      Result := Result + [Q.Fields[0].AsString];
      Q.Next;
    end;
  finally
    Q.Free;
  end;
end;

procedure TIssueStore.AddManualKey(AAccountId: Integer; const AKey: string);
begin
  FConn.ExecSQL('INSERT OR IGNORE INTO issue_manual (account_id, key) VALUES (:id, :k)',
    [AAccountId, AKey]);
end;

procedure TIssueStore.RemoveManualKey(AAccountId: Integer; const AKey: string);
begin
  FConn.ExecSQL('DELETE FROM issue_manual WHERE account_id = :id AND key = :k',
    [AAccountId, AKey]);
end;

function TIssueStore.HasSnapshot(AAccountId: Integer): Boolean;
begin
  Result := FConn.ExecSQLScalar(
    'SELECT COUNT(*) FROM issue_poll WHERE account_id = :id', [AAccountId]) > 0;
end;

function TIssueStore.LoadSnapshot(AAccountId: Integer): TItems;
var
  Q: TFDQuery;
  It: TItem;
  S: Integer;
begin
  Result := nil;
  Q := TFDQuery.Create(nil);
  try
    Q.Connection := FConn;
    Q.Open('SELECT key, title, url, status, assignee, due_date, updated_at, comment_count, ' +
      'last_comment_by, mentions_me, unread_reason, sources, due_alert, status_cat, flagged, ' +
      'review_state, ci_state, ci_detail, ci_url, reviewers, thread_id FROM issue_snapshot ' +
      'WHERE account_id = :id', [AAccountId]);
    while not Q.Eof do
    begin
      It := Default(TItem);
      It.AccountId := AAccountId;
      It.Key := Q.Fields[0].AsString;
      It.Title := Q.Fields[1].AsString;
      It.Url := Q.Fields[2].AsString;
      It.Status := Q.Fields[3].AsString;
      It.Assignee := Q.Fields[4].AsString;
      It.DueDate := Q.Fields[5].AsFloat;
      It.UpdatedAt := Q.Fields[6].AsFloat;
      It.CommentCount := Q.Fields[7].AsInteger;
      It.LastCommentBy := Q.Fields[8].AsString;
      It.MentionsMe := Q.Fields[9].AsInteger <> 0;
      It.UnreadReason := Q.Fields[10].AsString;
      S := Q.Fields[11].AsInteger;
      It.Sources := TItemSources(Byte(S));
      It.DueAlert := Q.Fields[12].AsInteger;
      It.StatusCategory := Q.Fields[13].AsString;
      It.Flagged := Q.Fields[14].AsInteger <> 0;
      It.ReviewState := Q.Fields[15].AsString;
      It.CiState := Q.Fields[16].AsString;
      It.CiDetail := Q.Fields[17].AsString;
      It.CiUrl := Q.Fields[18].AsString;
      It.Reviewers := Q.Fields[19].AsString;
      It.ThreadId := Q.Fields[20].AsString;
      Result := Result + [It];
      Q.Next;
    end;
  finally
    Q.Free;
  end;
end;

procedure TIssueStore.SaveSnapshot(AAccountId: Integer; const AItems: TItems);
var
  It: TItem;
begin
  FConn.StartTransaction;
  try
    FConn.ExecSQL('DELETE FROM issue_snapshot WHERE account_id = :id', [AAccountId]);
    for It in AItems do
      FConn.ExecSQL('INSERT INTO issue_snapshot (account_id, key, title, url, status, assignee, ' +
        'due_date, updated_at, comment_count, last_comment_by, mentions_me, unread_reason, ' +
        'sources, due_alert, status_cat, flagged, review_state, ci_state, ci_detail, ci_url, ' +
        'reviewers, thread_id) ' +
        'VALUES (:a, :k, :t, :u, :s, :as, :d, :up, :c, :lb, :m, :r, :src, :da, :sc, :fl, :rs, :ci, ' +
        ':cd, :cu, :rv, :th)',
        [AAccountId, It.Key, It.Title, It.Url, It.Status, It.Assignee, Double(It.DueDate),
         Double(It.UpdatedAt), It.CommentCount, It.LastCommentBy, Ord(It.MentionsMe),
         It.UnreadReason, Byte(It.Sources), It.DueAlert, It.StatusCategory, Ord(It.Flagged),
         It.ReviewState, It.CiState, It.CiDetail, It.CiUrl, It.Reviewers, It.ThreadId]);
    FConn.ExecSQL('INSERT OR REPLACE INTO issue_poll (account_id, last_poll) VALUES (:id, :t)',
      [AAccountId, Double(Now)]);
    FConn.Commit;
  except
    FConn.Rollback;
    raise;
  end;
end;

initialization

finalization
  GStore.Free;

end.
