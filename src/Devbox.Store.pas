unit Devbox.Store;

{ SQLite em %LOCALAPPDATA%\Devbox\devbox.db: clips (histórico e snippets) e
  preferências. Só usar na thread de UI. }

interface

uses
  System.SysUtils,
  FireDAC.Comp.Client,
  Devbox.Model,
  Devbox.Jobs,
  Devbox.Usage;

type
  TGoogleAccount = record
    Email: string;
    Enabled: Boolean;
  end;
  TGoogleAccounts = TArray<TGoogleAccount>;

  { Conta de e-mail por IMAP. A senha de app fica no Credential Manager. }
  TImapAccount = record
    Email: string;
    Host: string;
    Port: Integer;
    User: string;
    Enabled: Boolean;
  end;
  TImapAccounts = TArray<TImapAccount>;

  TStore = class
  private
    FConn: TFDConnection;
    function HasColumn(const ATable, AColumn: string): Boolean;
  public
    constructor Create(const ADbPath: string);
    destructor Destroy; override;
    { Texto repetido sobe para o topo em vez de duplicar. Corta o histórico
      (não os snippets) em HistoryLimit. }
    procedure AddClip(const AText: string; AKind: TClipKind = ckText; const AData: TBytes = nil);
    { PNG de um clip de imagem (vazio nos outros). }
    function ClipData(AId: Integer): TBytes;
    { Snippets primeiro, depois o histórico, mais novos no topo. }
    function ListClips: TClips;
    procedure SetPinned(AId: Integer; APinned: Boolean);
    { Atalho do expansor ('' tira). Só faz sentido em snippet. }
    procedure SetAbbrev(AId: Integer; const AAbbrev: string);
    procedure DeleteClip(AId: Integer);
    { Cria (AId = 0) ou altera um snippet. Texto igual a um item do histórico
      transforma esse item em snippet. }
    procedure SaveSnippet(AId: Integer; const AText, AAbbrev: string);
    { Apaga o histórico; snippets ficam. }
    procedure ClearHistory;
    // Agendador
    function ListJobs: TJobs;
    procedure SaveJob(var AJob: TJob);
    procedure DeleteJob(AId: Integer);
    procedure SetJobRunInfo(AId: Integer; ANextRun, ALastRun: TDateTime; ALastExit: Integer);
    procedure AddJobRun(const ARun: TJobRun);
    { Execuções mais novas primeiro. AJobId = 0: de todas as tarefas. }
    function ListJobRuns(AJobId, ALimit: Integer): TJobRuns;
    // Ambientes de projeto
    function ListEnvs: TEnvs;
    procedure SaveEnv(var AEnv: TEnv);
    procedure DeleteEnv(AId: Integer);
    // Monitor de URLs
    function ListUrlChecks: TUrlChecks;
    procedure SaveUrlCheck(var ACheck: TUrlCheck);
    procedure DeleteUrlCheck(AId: Integer);
    // Foco (Pomodoro)
    procedure AddFocusSession(AStart: TDateTime; AMinutes: Integer);
    { Minutos de foco por dia, dos últimos ADays dias (índice 0 = mais antigo). }
    function FocusMinutesPerDay(ADays: Integer): TArray<Integer>;
    // Avisos de fim
    function ListWatches: TWatches;
    procedure AddWatch(var AWatch: TWatch);
    procedure DeleteWatch(AId: Integer);
    // Contas Google (o refresh token fica no Credential Manager)
    function ListGoogleAccounts: TGoogleAccounts;
    procedure SaveGoogleAccount(const AEmail: string; AEnabled: Boolean);
    procedure DeleteGoogleAccount(const AEmail: string);
    function ListImapAccounts: TImapAccounts;
    procedure SaveImapAccount(const AAccount: TImapAccount);
    procedure DeleteImapAccount(const AEmail: string);
    { E-mails que já geraram aviso. False em AFirst = conta sem nenhum ainda. }
    function MailSeen(const AAccount, AId: string): Boolean;
    function MailSeenAny(const AAccount: string): Boolean;
    procedure MarkMailSeen(const AAccount, AId: string);
    { Uso de IA: grava com o custo pelo preço de agora. }
    procedure AddUsage(const AUsage: TAiUsage);
    { Somas por modelo desde AFrom, do mais caro ao mais barato. }
    function UsageTotals(AFrom: TDateTime): TUsageTotals;
    function GetSetting(const AName: string; const ADefault: string = ''): string;
    { A mesma conexão serve às issues (Devbox.Issues.Store). Só na thread de UI. }
    property Connection: TFDConnection read FConn;
    procedure SetSetting(const AName, AValue: string);
  end;

function Store: TStore;
function DataDir: string;

implementation

uses
  System.Classes,
  System.IOUtils,
  System.Variants,
  Data.DB,
  FireDAC.Stan.Def,
  FireDAC.Stan.Async,
  FireDAC.Stan.Intf,
  FireDAC.DApt,
  FireDAC.Phys.SQLite,
  FireDAC.Phys.SQLiteDef,
  FireDAC.Stan.ExprFuncs,
  FireDAC.VCLUI.Wait;

var
  GStore: TStore;

function DataDir: string;
begin
  Result := TPath.Combine(GetEnvironmentVariable('LOCALAPPDATA'), 'Devbox');
  ForceDirectories(Result);
end;

function Store: TStore;
begin
  if GStore = nil then
    GStore := TStore.Create(TPath.Combine(DataDir, 'devbox.db'));
  Result := GStore;
end;

// O SQLite do FireDAC é antigo: pragma_table_info() como tabela não existe.
function TStore.HasColumn(const ATable, AColumn: string): Boolean;
var
  Q: TFDQuery;
begin
  Result := False;
  Q := TFDQuery.Create(nil);
  try
    Q.Connection := FConn;
    Q.Open('PRAGMA table_info(' + ATable + ')');
    while not Q.Eof and not Result do
    begin
      Result := SameText(Q.FieldByName('name').AsString, AColumn);
      Q.Next;
    end;
  finally
    Q.Free;
  end;
end;

constructor TStore.Create(const ADbPath: string);
begin
  inherited Create;
  FConn := TFDConnection.Create(nil);
  FConn.DriverName := 'SQLite';
  FConn.Params.Values['Database'] := ADbPath;
  FConn.Params.Values['LockingMode'] := 'Normal';
  // Devbox e DevboxHelper abrem o mesmo banco: no WAL a leitura de um não trava a escrita do outro
  // (sem isto, criar tabela na abertura dava "database is locked" com o ajudante lendo).
  FConn.Params.Values['JournalMode'] := 'WAL';
  FConn.Params.Values['BusyTimeout'] := '10000';
  FConn.ResourceOptions.SilentMode := True;
  FConn.LoginPrompt := False;
  FConn.Connected := True;
  FConn.ExecSQL('CREATE TABLE IF NOT EXISTS clip (id INTEGER PRIMARY KEY AUTOINCREMENT, ' +
    'text TEXT NOT NULL UNIQUE, pinned INTEGER NOT NULL DEFAULT 0, created_at REAL NOT NULL)');
  FConn.ExecSQL('CREATE TABLE IF NOT EXISTS setting (name TEXT PRIMARY KEY, value TEXT)');
  if not HasColumn('clip', 'kind') then
  begin
    FConn.ExecSQL('ALTER TABLE clip ADD COLUMN kind INTEGER NOT NULL DEFAULT 0');
    FConn.ExecSQL('ALTER TABLE clip ADD COLUMN data BLOB');
  end;
  FConn.ExecSQL('CREATE TABLE IF NOT EXISTS job (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, ' +
    'command TEXT NOT NULL, workdir TEXT, kind INTEGER NOT NULL, every_min INTEGER, at_min INTEGER, ' +
    'weekdays INTEGER, enabled INTEGER NOT NULL DEFAULT 1, notify_ok INTEGER NOT NULL DEFAULT 0, ' +
    'next_run REAL, last_run REAL, last_exit INTEGER NOT NULL DEFAULT -1)');
  FConn.ExecSQL('CREATE TABLE IF NOT EXISTS job_run (id INTEGER PRIMARY KEY AUTOINCREMENT, job_id INTEGER NOT NULL, ' +
    'started REAL NOT NULL, duration_ms INTEGER, exit_code INTEGER, output TEXT)');
  FConn.ExecSQL('CREATE INDEX IF NOT EXISTS ix_job_run ON job_run (job_id, started)');
  FConn.ExecSQL('CREATE TABLE IF NOT EXISTS focus_log (id INTEGER PRIMARY KEY AUTOINCREMENT, ' +
    'started REAL NOT NULL, minutes INTEGER NOT NULL)');
  FConn.ExecSQL('CREATE TABLE IF NOT EXISTS env (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, ' +
    'script TEXT NOT NULL)');
  FConn.ExecSQL('CREATE TABLE IF NOT EXISTS url_check (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, ' +
    'url TEXT NOT NULL, interval_sec INTEGER NOT NULL DEFAULT 60, enabled INTEGER NOT NULL DEFAULT 1)');
  FConn.ExecSQL('CREATE TABLE IF NOT EXISTS watch (id INTEGER PRIMARY KEY AUTOINCREMENT, kind INTEGER NOT NULL, ' +
    'target TEXT NOT NULL, cli TEXT, caption TEXT, created_at REAL NOT NULL)');
  if not HasColumn('clip', 'abbrev') then
    FConn.ExecSQL('ALTER TABLE clip ADD COLUMN abbrev TEXT');
  FConn.ExecSQL('CREATE TABLE IF NOT EXISTS google_account (email TEXT PRIMARY KEY, ' +
    'enabled INTEGER NOT NULL DEFAULT 1, added_at REAL NOT NULL)');
  FConn.ExecSQL('CREATE TABLE IF NOT EXISTS mail_seen (account TEXT NOT NULL, id TEXT NOT NULL, ' +
    'seen_at REAL NOT NULL, PRIMARY KEY (account, id))');
  FConn.ExecSQL('CREATE TABLE IF NOT EXISTS imap_account (email TEXT PRIMARY KEY, host TEXT NOT NULL, ' +
    'port INTEGER NOT NULL, user TEXT, enabled INTEGER NOT NULL DEFAULT 1, added_at REAL NOT NULL)');
  // Mesmas colunas do Vigia (at, provider, model, input_tokens, output_tokens, cost) e o áudio a mais.
  FConn.ExecSQL('CREATE TABLE IF NOT EXISTS ai_usage (id INTEGER PRIMARY KEY AUTOINCREMENT, at REAL NOT NULL, ' +
    'provider TEXT, model TEXT, kind TEXT, input_tokens INTEGER, output_tokens INTEGER, ' +
    'audio_in_tokens INTEGER, audio_out_tokens INTEGER, audio_seconds REAL, cost REAL)');
end;

destructor TStore.Destroy;
begin
  FConn.Free;
  inherited;
end;

procedure TStore.AddClip(const AText: string; AKind: TClipKind; const AData: TBytes);
var
  Q: TFDQuery;
  Stream: TBytesStream;
begin
  // O SQLite do FireDAC não tem upsert (ON CONFLICT): atualiza e, se não achou, insere.
  if FConn.ExecSQL('UPDATE clip SET created_at = :d WHERE text = :t', [Double(Now), AText]) = 0 then
  begin
    Q := TFDQuery.Create(nil);
    try
      Q.Connection := FConn;
      Q.SQL.Text := 'INSERT INTO clip (text, kind, data, created_at) VALUES (:t, :k, :b, :d)';
      Q.ParamByName('t').AsString := AText;
      Q.ParamByName('k').AsInteger := Ord(AKind);
      if AData <> nil then
      begin
        Stream := TBytesStream.Create(AData);
        try
          Q.ParamByName('b').LoadFromStream(Stream, ftBlob);
        finally
          Stream.Free;
        end;
      end
      else
      begin
        Q.ParamByName('b').DataType := ftBlob;
        Q.ParamByName('b').Clear;
      end;
      Q.ParamByName('d').AsFloat := Now;  // REAL, igual ao que a lista lê
      Q.ExecSQL;
    finally
      Q.Free;
    end;
  end;
  FConn.ExecSQL('DELETE FROM clip WHERE pinned = 0 AND id NOT IN ' +
    '(SELECT id FROM clip WHERE pinned = 0 ORDER BY created_at DESC LIMIT :n)', [HistoryLimit]);
end;

function TStore.ListClips: TClips;
var
  Q: TFDQuery;
  C: TClip;
begin
  Result := nil;
  Q := TFDQuery.Create(nil);
  try
    Q.Connection := FConn;
    Q.Open('SELECT id, text, pinned, created_at, kind, abbrev FROM clip ORDER BY pinned DESC, created_at DESC');
    while not Q.Eof do
    begin
      C.Id := Q.Fields[0].AsInteger;
      C.Text := Q.Fields[1].AsString;
      C.Pinned := Q.Fields[2].AsInteger <> 0;
      C.CreatedAt := Q.Fields[3].AsFloat;
      C.Kind := TClipKind(Q.Fields[4].AsInteger);
      C.Abbrev := Q.Fields[5].AsString;
      Result := Result + [C];
      Q.Next;
    end;
  finally
    Q.Free;
  end;
end;

function TStore.ClipData(AId: Integer): TBytes;
var
  Q: TFDQuery;
begin
  Result := nil;
  Q := TFDQuery.Create(nil);
  try
    Q.Connection := FConn;
    Q.Open('SELECT data FROM clip WHERE id = :i', [AId]);
    if not Q.Eof and not Q.Fields[0].IsNull then
      Result := Q.Fields[0].AsBytes;
  finally
    Q.Free;
  end;
end;

procedure TStore.SetPinned(AId: Integer; APinned: Boolean);
begin
  FConn.ExecSQL('UPDATE clip SET pinned = :p WHERE id = :i', [Ord(APinned), AId]);
end;

procedure TStore.SetAbbrev(AId: Integer; const AAbbrev: string);
begin
  FConn.ExecSQL('UPDATE clip SET abbrev = :a WHERE id = :i', [AAbbrev, AId]);
end;

procedure TStore.SaveSnippet(AId: Integer; const AText, AAbbrev: string);
var
  Existing: Variant;
begin
  Existing := FConn.ExecSQLScalar('SELECT id FROM clip WHERE text = :t', [AText]);
  if not VarIsNull(Existing) and (Existing <> AId) then
  begin
    // Já existe item com este texto: ele vira o snippet e o antigo some.
    if AId <> 0 then
      DeleteClip(AId);
    AId := Existing;
  end;
  if AId = 0 then
    FConn.ExecSQL('INSERT INTO clip (text, kind, pinned, abbrev, created_at) VALUES (:t, 0, 1, :a, :d)',
      [AText, AAbbrev, Double(Now)])
  else
    FConn.ExecSQL('UPDATE clip SET text = :t, pinned = 1, abbrev = :a WHERE id = :i', [AText, AAbbrev, AId]);
end;

procedure TStore.DeleteClip(AId: Integer);
begin
  FConn.ExecSQL('DELETE FROM clip WHERE id = :i', [AId]);
end;

procedure TStore.ClearHistory;
begin
  FConn.ExecSQL('DELETE FROM clip WHERE pinned = 0');
end;

function TStore.ListJobs: TJobs;
var
  Q: TFDQuery;
  J: TJob;
begin
  Result := nil;
  Q := TFDQuery.Create(nil);
  try
    Q.Connection := FConn;
    Q.Open('SELECT id, name, command, workdir, kind, every_min, at_min, weekdays, enabled, notify_ok, ' +
      'next_run, last_run, last_exit FROM job ORDER BY name COLLATE NOCASE');
    while not Q.Eof do
    begin
      J.Id := Q.Fields[0].AsInteger;
      J.Name := Q.Fields[1].AsString;
      J.Command := Q.Fields[2].AsString;
      J.WorkDir := Q.Fields[3].AsString;
      J.Kind := TJobKind(Q.Fields[4].AsInteger);
      J.EveryMin := Q.Fields[5].AsInteger;
      J.AtMin := Q.Fields[6].AsInteger;
      J.Weekdays := Q.Fields[7].AsInteger;
      J.Enabled := Q.Fields[8].AsInteger <> 0;
      J.NotifyOk := Q.Fields[9].AsInteger <> 0;
      J.NextRun := Q.Fields[10].AsFloat;
      J.LastRun := Q.Fields[11].AsFloat;
      J.LastExit := Q.Fields[12].AsInteger;
      Result := Result + [J];
      Q.Next;
    end;
  finally
    Q.Free;
  end;
end;

procedure TStore.SaveJob(var AJob: TJob);
begin
  if AJob.Id = 0 then
  begin
    FConn.ExecSQL('INSERT INTO job (name, command, workdir, kind, every_min, at_min, weekdays, enabled, notify_ok, ' +
      'next_run) VALUES (:n, :c, :w, :k, :e, :a, :d, :on, :ok, :nx)', [AJob.Name, AJob.Command, AJob.WorkDir,
      Ord(AJob.Kind), AJob.EveryMin, AJob.AtMin, AJob.Weekdays, Ord(AJob.Enabled), Ord(AJob.NotifyOk),
      Double(AJob.NextRun)]);
    AJob.Id := FConn.GetLastAutoGenValue('');
  end
  else
    FConn.ExecSQL('UPDATE job SET name = :n, command = :c, workdir = :w, kind = :k, every_min = :e, at_min = :a, ' +
      'weekdays = :d, enabled = :on, notify_ok = :ok, next_run = :nx WHERE id = :i', [AJob.Name, AJob.Command,
      AJob.WorkDir, Ord(AJob.Kind), AJob.EveryMin, AJob.AtMin, AJob.Weekdays, Ord(AJob.Enabled),
      Ord(AJob.NotifyOk), Double(AJob.NextRun), AJob.Id]);
end;

procedure TStore.DeleteJob(AId: Integer);
begin
  FConn.ExecSQL('DELETE FROM job_run WHERE job_id = :i', [AId]);
  FConn.ExecSQL('DELETE FROM job WHERE id = :i', [AId]);
end;

procedure TStore.SetJobRunInfo(AId: Integer; ANextRun, ALastRun: TDateTime; ALastExit: Integer);
begin
  FConn.ExecSQL('UPDATE job SET next_run = :n, last_run = :l, last_exit = :e WHERE id = :i',
    [Double(ANextRun), Double(ALastRun), ALastExit, AId]);
end;

procedure TStore.AddJobRun(const ARun: TJobRun);
const
  CKeepRuns = 50;
begin
  FConn.ExecSQL('INSERT INTO job_run (job_id, started, duration_ms, exit_code, output) VALUES (:j, :s, :d, :e, :o)',
    [ARun.JobId, Double(ARun.Started), ARun.DurationMs, ARun.ExitCode, ARun.Output]);
  // Guarda só as últimas execuções de cada tarefa.
  FConn.ExecSQL('DELETE FROM job_run WHERE job_id = :j AND id NOT IN ' +
    '(SELECT id FROM job_run WHERE job_id = :j2 ORDER BY started DESC LIMIT :n)', [ARun.JobId, ARun.JobId, CKeepRuns]);
end;

function TStore.ListJobRuns(AJobId, ALimit: Integer): TJobRuns;
var
  Q: TFDQuery;
  R: TJobRun;
begin
  Result := nil;
  Q := TFDQuery.Create(nil);
  try
    Q.Connection := FConn;
    if AJobId = 0 then
      Q.Open('SELECT job_id, started, duration_ms, exit_code, output FROM job_run ORDER BY started DESC LIMIT :n',
        [ALimit])
    else
      Q.Open('SELECT job_id, started, duration_ms, exit_code, output FROM job_run WHERE job_id = :j ' +
        'ORDER BY started DESC LIMIT :n', [AJobId, ALimit]);
    while not Q.Eof do
    begin
      R.JobId := Q.Fields[0].AsInteger;
      R.Started := Q.Fields[1].AsFloat;
      R.DurationMs := Q.Fields[2].AsLargeInt;
      R.ExitCode := Q.Fields[3].AsInteger;
      R.Output := Q.Fields[4].AsString;
      Result := Result + [R];
      Q.Next;
    end;
  finally
    Q.Free;
  end;
end;

procedure TStore.AddFocusSession(AStart: TDateTime; AMinutes: Integer);
begin
  if AMinutes > 0 then
    FConn.ExecSQL('INSERT INTO focus_log (started, minutes) VALUES (:s, :m)', [Double(AStart), AMinutes]);
end;

function TStore.FocusMinutesPerDay(ADays: Integer): TArray<Integer>;
var
  Q: TFDQuery;
  First: TDateTime;
  I: Integer;
begin
  SetLength(Result, ADays);
  First := Date - ADays + 1;
  Q := TFDQuery.Create(nil);
  try
    Q.Connection := FConn;
    Q.Open('SELECT started, minutes FROM focus_log WHERE started >= :f', [Double(First)]);
    while not Q.Eof do
    begin
      I := Trunc(Q.Fields[0].AsFloat) - Trunc(First);
      if (I >= 0) and (I < ADays) then
        Inc(Result[I], Q.Fields[1].AsInteger);
      Q.Next;
    end;
  finally
    Q.Free;
  end;
end;

function TStore.ListEnvs: TEnvs;
var
  Q: TFDQuery;
  E: TEnv;
begin
  Result := nil;
  Q := TFDQuery.Create(nil);
  try
    Q.Connection := FConn;
    Q.Open('SELECT id, name, script FROM env ORDER BY name COLLATE NOCASE');
    while not Q.Eof do
    begin
      E.Id := Q.Fields[0].AsInteger;
      E.Name := Q.Fields[1].AsString;
      E.Script := Q.Fields[2].AsString;
      Result := Result + [E];
      Q.Next;
    end;
  finally
    Q.Free;
  end;
end;

procedure TStore.SaveEnv(var AEnv: TEnv);
begin
  if AEnv.Id = 0 then
  begin
    FConn.ExecSQL('INSERT INTO env (name, script) VALUES (:n, :s)', [AEnv.Name, AEnv.Script]);
    AEnv.Id := FConn.GetLastAutoGenValue('');
  end
  else
    FConn.ExecSQL('UPDATE env SET name = :n, script = :s WHERE id = :i', [AEnv.Name, AEnv.Script, AEnv.Id]);
end;

procedure TStore.DeleteEnv(AId: Integer);
begin
  FConn.ExecSQL('DELETE FROM env WHERE id = :i', [AId]);
end;

function TStore.ListUrlChecks: TUrlChecks;
var
  Q: TFDQuery;
  C: TUrlCheck;
begin
  Result := nil;
  Q := TFDQuery.Create(nil);
  try
    Q.Connection := FConn;
    Q.Open('SELECT id, name, url, interval_sec, enabled FROM url_check ORDER BY name COLLATE NOCASE');
    while not Q.Eof do
    begin
      C.Id := Q.Fields[0].AsInteger;
      C.Name := Q.Fields[1].AsString;
      C.Url := Q.Fields[2].AsString;
      C.IntervalSec := Q.Fields[3].AsInteger;
      C.Enabled := Q.Fields[4].AsInteger <> 0;
      Result := Result + [C];
      Q.Next;
    end;
  finally
    Q.Free;
  end;
end;

procedure TStore.SaveUrlCheck(var ACheck: TUrlCheck);
begin
  if ACheck.Id = 0 then
  begin
    FConn.ExecSQL('INSERT INTO url_check (name, url, interval_sec, enabled) VALUES (:n, :u, :i, :e)',
      [ACheck.Name, ACheck.Url, ACheck.IntervalSec, Ord(ACheck.Enabled)]);
    ACheck.Id := FConn.GetLastAutoGenValue('');
  end
  else
    FConn.ExecSQL('UPDATE url_check SET name = :n, url = :u, interval_sec = :i, enabled = :e WHERE id = :id',
      [ACheck.Name, ACheck.Url, ACheck.IntervalSec, Ord(ACheck.Enabled), ACheck.Id]);
end;

procedure TStore.DeleteUrlCheck(AId: Integer);
begin
  FConn.ExecSQL('DELETE FROM url_check WHERE id = :i', [AId]);
end;

function TStore.ListWatches: TWatches;
var
  Q: TFDQuery;
  W: TWatch;
begin
  Result := nil;
  Q := TFDQuery.Create(nil);
  try
    Q.Connection := FConn;
    Q.Open('SELECT id, kind, target, cli, caption, created_at FROM watch ORDER BY created_at');
    while not Q.Eof do
    begin
      W.Id := Q.Fields[0].AsInteger;
      W.Kind := TWatchKind(Q.Fields[1].AsInteger);
      W.Target := Q.Fields[2].AsString;
      W.Cli := Q.Fields[3].AsString;
      W.Caption := Q.Fields[4].AsString;
      W.CreatedAt := Q.Fields[5].AsFloat;
      Result := Result + [W];
      Q.Next;
    end;
  finally
    Q.Free;
  end;
end;

procedure TStore.AddWatch(var AWatch: TWatch);
begin
  AWatch.CreatedAt := Now;
  FConn.ExecSQL('INSERT INTO watch (kind, target, cli, caption, created_at) VALUES (:k, :t, :c, :p, :d)',
    [Ord(AWatch.Kind), AWatch.Target, AWatch.Cli, AWatch.Caption, Double(AWatch.CreatedAt)]);
  AWatch.Id := FConn.GetLastAutoGenValue('');
end;

procedure TStore.DeleteWatch(AId: Integer);
begin
  FConn.ExecSQL('DELETE FROM watch WHERE id = :i', [AId]);
end;

function HasValue(const V: Variant): Boolean;
begin
  Result := not (VarIsNull(V) or VarIsEmpty(V));
end;

function TStore.ListGoogleAccounts: TGoogleAccounts;
var
  Q: TFDQuery;
  A: TGoogleAccount;
begin
  Result := nil;
  Q := TFDQuery.Create(nil);
  try
    Q.Connection := FConn;
    Q.Open('SELECT email, enabled FROM google_account ORDER BY added_at');
    while not Q.Eof do
    begin
      A.Email := Q.Fields[0].AsString;
      A.Enabled := Q.Fields[1].AsInteger <> 0;
      Result := Result + [A];
      Q.Next;
    end;
  finally
    Q.Free;
  end;
end;

procedure TStore.SaveGoogleAccount(const AEmail: string; AEnabled: Boolean);
begin
  if FConn.ExecSQL('UPDATE google_account SET enabled = :e WHERE email = :m', [Ord(AEnabled), AEmail]) = 0 then
    FConn.ExecSQL('INSERT INTO google_account (email, enabled, added_at) VALUES (:m, :e, :d)',
      [AEmail, Ord(AEnabled), Double(Now)]);
end;

procedure TStore.DeleteGoogleAccount(const AEmail: string);
begin
  FConn.ExecSQL('DELETE FROM google_account WHERE email = :m', [AEmail]);
  FConn.ExecSQL('DELETE FROM mail_seen WHERE account = :m', [AEmail]);
end;

function TStore.ListImapAccounts: TImapAccounts;
var
  Q: TFDQuery;
  A: TImapAccount;
begin
  Result := nil;
  Q := TFDQuery.Create(nil);
  try
    Q.Connection := FConn;
    Q.Open('SELECT email, host, port, user, enabled FROM imap_account ORDER BY added_at');
    while not Q.Eof do
    begin
      A.Email := Q.Fields[0].AsString;
      A.Host := Q.Fields[1].AsString;
      A.Port := Q.Fields[2].AsInteger;
      A.User := Q.Fields[3].AsString;
      A.Enabled := Q.Fields[4].AsInteger <> 0;
      Result := Result + [A];
      Q.Next;
    end;
  finally
    Q.Free;
  end;
end;

procedure TStore.SaveImapAccount(const AAccount: TImapAccount);
begin
  if FConn.ExecSQL('UPDATE imap_account SET host = :h, port = :p, user = :u, enabled = :e WHERE email = :m',
    [AAccount.Host, AAccount.Port, AAccount.User, Ord(AAccount.Enabled), AAccount.Email]) = 0 then
    FConn.ExecSQL('INSERT INTO imap_account (email, host, port, user, enabled, added_at) ' +
      'VALUES (:m, :h, :p, :u, :e, :d)', [AAccount.Email, AAccount.Host, AAccount.Port, AAccount.User,
      Ord(AAccount.Enabled), Double(Now)]);
end;

procedure TStore.DeleteImapAccount(const AEmail: string);
begin
  FConn.ExecSQL('DELETE FROM imap_account WHERE email = :m', [AEmail]);
  FConn.ExecSQL('DELETE FROM mail_seen WHERE account = :m', [AEmail]);
end;

function TStore.MailSeen(const AAccount, AId: string): Boolean;
begin
  Result := HasValue(FConn.ExecSQLScalar('SELECT 1 FROM mail_seen WHERE account = :a AND id = :i',
    [AAccount, AId]));
end;

function TStore.MailSeenAny(const AAccount: string): Boolean;
begin
  Result := HasValue(FConn.ExecSQLScalar('SELECT 1 FROM mail_seen WHERE account = :a LIMIT 1', [AAccount]));
end;

procedure TStore.MarkMailSeen(const AAccount, AId: string);
begin
  FConn.ExecSQL('INSERT OR IGNORE INTO mail_seen (account, id, seen_at) VALUES (:a, :i, :d)',
    [AAccount, AId, Double(Now)]);
  // Guarda só o último mês: o Gmail não devolve nada mais velho na busca do aviso.
  FConn.ExecSQL('DELETE FROM mail_seen WHERE seen_at < :d', [Double(Now - 30)]);
end;

procedure TStore.AddUsage(const AUsage: TAiUsage);
begin
  FConn.ExecSQL('INSERT INTO ai_usage (at, provider, model, kind, input_tokens, output_tokens, audio_in_tokens, ' +
    'audio_out_tokens, audio_seconds, cost) VALUES (:at, :p, :m, :k, :i, :o, :ai, :ao, :s, :c)',
    [Double(AUsage.At), AUsage.Provider, AUsage.Model, AUsage.Kind, AUsage.InputTokens, AUsage.OutputTokens,
    AUsage.AudioInTokens, AUsage.AudioOutTokens, AUsage.AudioSeconds,
    UsageCost(AUsage, PriceFor(AUsage.Model))]);
end;

function TStore.UsageTotals(AFrom: TDateTime): TUsageTotals;
var
  Q: TFDQuery;
  T: TUsageTotal;
begin
  Result := nil;
  Q := TFDQuery.Create(nil);
  try
    Q.Connection := FConn;
    Q.Open('SELECT model, COUNT(*), SUM(input_tokens), SUM(output_tokens), ' +
      'SUM(COALESCE(audio_in_tokens, 0) + COALESCE(audio_out_tokens, 0)), SUM(COALESCE(audio_seconds, 0)), ' +
      'SUM(cost) FROM ai_usage WHERE at >= :f GROUP BY model ORDER BY SUM(cost) DESC', [Double(AFrom)]);
    while not Q.Eof do
    begin
      T.Model := Q.Fields[0].AsString;
      T.Calls := Q.Fields[1].AsInteger;
      T.InputTokens := Q.Fields[2].AsLargeInt;
      T.OutputTokens := Q.Fields[3].AsLargeInt;
      T.AudioTokens := Q.Fields[4].AsLargeInt;
      T.AudioSeconds := Q.Fields[5].AsFloat;
      T.Cost := Q.Fields[6].AsFloat;
      Result := Result + [T];
      Q.Next;
    end;
  finally
    Q.Free;
  end;
end;

function TStore.GetSetting(const AName, ADefault: string): string;
var
  V: Variant;
begin
  V := FConn.ExecSQLScalar('SELECT value FROM setting WHERE name = :n', [AName]);
  if VarIsNull(V) or VarIsEmpty(V) then
    Result := ADefault
  else
    Result := V;
end;

procedure TStore.SetSetting(const AName, AValue: string);
begin
  FConn.ExecSQL('INSERT OR REPLACE INTO setting (name, value) VALUES (:n, :v)', [AName, AValue]);
end;

initialization

finalization
  GStore.Free;

end.
