{ Testes do núcleo de issues, vindos do Vigia (tests/VigiaTests.dpr). Incluído em DevboxTests.dpr. }

function Obj(const S: string): TJSONObject;
begin
  Result := TJSONObject.ParseJSONValue(S) as TJSONObject;
  if Result = nil then
    raise Exception.Create('JSON de teste inválido');
end;

procedure TestDates;
begin
  Check(ParseIsoDate('') = 0, 'data vazia = 0');
  Check(ParseIsoDate('2026-10-03') = EncodeDate(2026, 10, 3), 'duedate do Jira');
  Check(SameDateTime(ParseIsoDate('2026-10-01T12:00:00Z'), EncodeDateTime(2026, 10, 1, 12, 0, 0, 0)),
    'ISO com Z');
  Check(SameDateTime(ParseIsoDate('2026-10-01T09:00:00.000-0300'), EncodeDateTime(2026, 10, 1, 12, 0, 0, 0)),
    'ISO do Jira com -0300 vira UTC');
end;

procedure TestGitHub;
var
  J: TJSONObject;
  It: TItem;
begin
  J := Obj('{"number":12,"title":"Bug X","html_url":"https://github.com/o/r/issues/12",' +
    '"state":"open","repository_url":"https://api.github.com/repos/o/r",' +
    '"assignees":[{"login":"ana"}],"comments":3,"updated_at":"2026-10-01T12:00:00Z",' +
    '"milestone":{"due_on":"2026-10-05T07:00:00Z"}}');
  try
    It := ParseGitHubIssue(J, 7);
    Check((It.Key = 'o/r#12') and (It.AccountId = 7), 'GitHub key');
    Check((It.Assignee = 'ana') and (It.CommentCount = 3) and (It.Status = 'open'), 'GitHub campos');
    Check(Trunc(It.DueDate) = EncodeDate(2026, 10, 5), 'GitHub prazo pelo milestone');
  finally
    J.Free;
  end;
  J := Obj('{"number":1,"title":"t","repository_url":"https://api.github.com/repos/a/b","milestone":null}');
  try
    Check(ParseGitHubIssue(J, 1).DueDate = 0, 'GitHub milestone null = sem prazo');
  finally
    J.Free;
  end;
  Check(GitHubKeyFromApiUrl('https://api.github.com/repos/o/r/pulls/9') = 'o/r#9', 'key da notification (PR)');
end;

procedure TestJiraServer;
var
  J: TJSONObject;
  A: TAccount;
  Me: TIdentity;
  It: TItem;
begin
  A := NewAccount(pkJiraServer);
  A.Id := 2;
  A.BaseUrl := 'https://jira.exemplo.com/';
  Me.Id := 'ana.lima';
  J := Obj('{"key":"APP-10","fields":{"summary":"Nota","status":{"name":"Em andamento"},' +
    '"assignee":{"name":"ana.lima","displayName":"Ana"},"duedate":"2026-10-03",' +
    '"updated":"2026-10-01T09:00:00.000-0300",' +
    '"comment":{"total":2,"comments":[{"author":{"name":"x"},"body":"a"},' +
    '{"author":{"name":"maria"},"body":"oi [~ana.lima], veja"}]}}}');
  try
    It := ParseJiraIssue(J, A, Me);
    Check(It.Url = 'https://jira.exemplo.com/browse/APP-10', 'Jira URL sem barra dupla');
    Check(isAssigned in It.Sources, 'Jira Server: associado a mim');
    Check((It.Status = 'Em andamento') and (It.DueDate = EncodeDate(2026, 10, 3)), 'Jira Server campos');
    Check((It.CommentCount = 2) and (It.LastCommentBy = 'maria'), 'Jira Server último comentário');
    Check(It.MentionsMe, 'Jira Server menção [~usuario]');
  finally
    J.Free;
  end;
end;

procedure TestJiraFlagAndDueField;
var
  J: TJSONObject;
  A: TAccount;
  Me: TIdentity;
  It: TItem;
begin
  A := NewAccount(pkJiraServer);
  A.BaseUrl := 'https://jira.exemplo.com';
  J := Obj('{"key":"P-9","fields":{"summary":"S","status":{"name":"Em Teste",' +
    '"statusCategory":{"key":"indeterminate"}},"duedate":"2026-12-31",' +
    '"customfield_10304":[{"value":"Impediment"}],"customfield_11039":"2026-10-13",' +
    '"updated":"2026-10-01T12:00:00.000+0000"}}');
  try
    It := ParseJiraIssue(J, A, Me, 'customfield_10304', 'customfield_11039');
    Check(It.Flagged and (It.StatusCategory = 'indeterminate'), 'Flagged e categoria do status');
    Check(It.DueDate = EncodeDate(2026, 10, 13), 'prazo vem do campo configurado, não do duedate');
    It := ParseJiraIssue(J, A, Me, '', '');
    Check(not It.Flagged and (It.DueDate = EncodeDate(2026, 12, 31)), 'sem campo: sem flag e usa duedate');
    It := ParseJiraIssue(J, A, Me, 'customfield_10304', 'customfield_99999');
    Check(It.DueDate = 0, 'campo configurado vazio na issue = sem prazo (não cai no duedate)');
  finally
    J.Free;
  end;
end;

procedure TestJiraCloud;
var
  J: TJSONObject;
  A: TAccount;
  Me: TIdentity;
  It: TItem;
begin
  A := NewAccount(pkJiraCloud);
  A.BaseUrl := 'https://x.atlassian.net';
  Me.Id := 'acc-1';
  J := Obj('{"key":"PRJ-5","fields":{"summary":"S","status":{"name":"To Do"},' +
    '"assignee":{"accountId":"acc-2","displayName":"Outro"},"duedate":null,' +
    '"updated":"2026-10-01T12:00:00.000+0000",' +
    '"comment":{"total":1,"comments":[{"author":{"accountId":"acc-2"},"body":' +
    '{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"Olá "},' +
    '{"type":"mention","attrs":{"id":"acc-1","text":"@Ana"}},{"type":"text","text":" pode ver?"}]}]}}]}}}');
  try
    It := ParseJiraIssue(J, A, Me);
    Check(not (isAssigned in It.Sources) and (It.DueDate = 0), 'Jira Cloud: não associado, sem prazo');
    Check(It.LastCommentText = 'Olá @Ana pode ver?', 'ADF vira texto: "' + It.LastCommentText + '"');
    Check(It.MentionsMe and (It.LastCommentBy = 'acc-2'), 'Jira Cloud menção por accountId');
  finally
    J.Free;
  end;
end;

function MkItem(const AKey, AStatus: string; AComments: Integer; const ABy: string;
  ASources: TItemSources; ADue: TDateTime = 0): TItem;
begin
  Result := Default(TItem);
  Result.AccountId := 1;
  Result.Key := AKey;
  Result.Title := 'T ' + AKey;
  Result.Status := AStatus;
  Result.CommentCount := AComments;
  Result.LastCommentBy := ABy;
  Result.Sources := ASources;
  Result.DueDate := ADue;
end;

function Kinds(const AEvents: TIssueEvents): string;
var
  E: TIssueEvent;
begin
  Result := '';
  for E in AEvents do
    Result := Result + E.Key + ':' + EventNames[E.Kind] + ';';
end;

procedure TestCleanComment;
begin
  Check(CleanCommentText('est&aacute; <b>ok</b> &amp; r&aacute;pido &#233;') = 'está ok & rápido é',
    'comentário: entidades e tags');
  Check(WikiToText('h3. Resultado' + sLineBreak + '||Q||tempo||' + sLineBreak + '|Q1|0,05 ms|') =
    'Resultado' + sLineBreak + 'Q · tempo' + sLineBreak + 'Q1 · 0,05 ms', 'wiki: título e tabela');
  Check(WikiToText('índice {{idx_pedido}} *não* seletivo, ver [doc|http://x] e [~joao]') =
    'índice idx_pedido não seletivo, ver doc e @joao', 'wiki: código, negrito, link, menção');
  Check(WikiToText('* um' + sLineBreak + '* dois') = '• um' + sLineBreak + '• dois', 'wiki: lista');
  Check(MarkdownToText('## Erro' + sLineBreak + '- veja **isto** em [doc](http://x) e `cfg`') =
    'Erro' + sLineBreak + '• veja isto em doc e cfg', 'markdown: título, lista, negrito, link, código');
  Check(MarkdownToText('```' + sLineBreak + 'x := 1;' + sLineBreak + '```') = 'x := 1;',
    'markdown: bloco de código sem as cercas');
end;

procedure TestTags;
var
  T: TTag;
  It: TItem;
begin
  T := Default(TTag);
  T.Name := 'Pagamentos';
  T.Keywords := 'pagamento, check-out';
  It := Default(TItem);
  It.AccountId := 1;
  It.Key := 'APP-1';
  It.Title := 'Erro no Check-Out de pedidos pendentes';
  Check(T.Matches(It), 'tag: palavra no título, sem caixa');
  It.Title := 'Tela de configurações';
  Check(not T.Matches(It), 'tag: título sem palavra fica fora');
  T.Manual := [ItemTagKey(1, 'app-1')];
  Check(T.Matches(It), 'tag: marcação manual, chave sem caixa');
  T.Keywords := ' , ';
  T.Manual := nil;
  Check(not T.Matches(It), 'tag: palavra vazia não casa com tudo');
  T.Keywords := 'PIX;configura';
  Check(T.Matches(It), 'tag: ponto e vírgula também separa');
end;

procedure TestPrsAndFilter;
var
  A: TAccount;
  Me: TIdentity;
  Old, New: TItems;
  Ev: TIssueEvents;
begin
  A := NewAccount(pkGitHub);
  A.Id := 2;
  A.Name := 'gh';
  Me.Id := 'eu';
  Old := [MkItem('o/app#1', 'open', 0, '', [isMine])];
  Old[0].ReviewState := 'REVIEW_REQUIRED';
  Old[0].CiState := 'PENDING';
  New := Copy(Old);
  New[0].ReviewState := 'APPROVED';
  New[0].CiState := 'FAILURE';
  Ev := DiffItems(Old, New, A, Me, Date, False);
  Check(Kinds(Ev) = 'o/app#1:PR aprovado;o/app#1:CI falhou;', 'PR: aprovado e CI falhou: ' + Kinds(Ev));
  Old := New;
  New := Copy(Old);
  New[0].ReviewState := 'CHANGES_REQUESTED';
  Ev := DiffItems(Old, New, A, Me, Date, False);
  Check(Kinds(Ev) = 'o/app#1:Mudanças pedidas;', 'PR: mudanças pedidas, CI não repete: ' + Kinds(Ev));

  A.IncludeList := 'o, x/lib';
  A.ExcludeList := 'o/velho';
  Check(ItemAllowed(A, 'o/app#1') and ItemAllowed(A, 'x/lib#2'), 'filtro: dono e repo incluídos');
  Check(not ItemAllowed(A, 'x/outro#3'), 'filtro: fora do incluir');
  Check(not ItemAllowed(A, 'o/velho#4'), 'filtro: ignorar vence o incluir');
  A := NewAccount(pkJiraServer);
  A.ExcludeList := 'ABC';
  Check(ItemAllowed(A, 'APP-1') and not ItemAllowed(A, 'ABC-9'), 'filtro: projeto do Jira');
end;

{ Backup sem tokens (o teste não toca no Credential Manager). }
procedure TestI18n;
begin
  SetLanguage('en');
  Check(Tr('Configurações') = 'Settings', 'i18n: inglês');
  Check(Tr('Conta: ') = 'Account: ', 'i18n: espaço da ponta acompanha a chave');
  Check(Tr('frase sem tradução') = 'frase sem tradução', 'i18n: sem tradução fica o português');
  SetLanguage('pt');
  Check(Tr('Configurações') = 'Configurações', 'i18n: português');
end;

procedure TestGitLabAzure;
var
  J: TJSONObject;
  It: TItem;
  A: TAccount;
  Me: TIdentity;
begin
  J := Obj('{"iid":39956,"title":"Suporte ao Windows 11","state":"opened","due_date":"2026-10-20",' +
    '"updated_at":"2026-10-03T00:10:30.159Z","user_notes_count":2,' +
    '"assignees":[{"username":"ana","name":"Ana Lima"}],' +
    '"web_url":"https://gitlab.com/g/runner/-/work_items/39956",' +
    '"references":{"short":"#39956","full":"g/runner#39956"}}');
  try
    It := ParseGitLabItem(J, 4, False);
    Check((It.Key = 'g/runner#39956') and (It.Status = 'open') and (It.StatusCategory = 'new') and
      (It.Assignee = 'Ana Lima') and (It.CommentCount = 2) and (Trunc(It.DueDate) = EncodeDate(2026, 10, 20)),
      'GitLab: issue');
  finally
    J.Free;
  end;
  J := Obj('{"iid":7511,"title":"Corrige build","state":"opened","draft":true,' +
    '"detailed_merge_status":"requested_changes","references":{"full":"g/runner!7511"}}');
  try
    It := ParseGitLabItem(J, 4, True);
    Check((It.Key = 'g/runner!7511') and (It.Status = 'rascunho') and
      (It.ReviewState = 'CHANGES_REQUESTED'), 'GitLab: MR rascunho com mudanças pedidas');
  finally
    J.Free;
  end;
  Check((RepoOf('g/sub/app!5') = 'g/sub/app') and (RepoOf('Projeto X#9') = 'Projeto X'),
    'repo de MR do GitLab e projeto do Azure');
  A := NewAccount(pkAzure);
  A.Id := 9;
  A.BaseUrl := 'https://dev.azure.com/acme/';
  A.IncludeList := 'Loja';
  Check(ItemAllowed(A, 'Loja#12') and not ItemAllowed(A, 'Outro#3'), 'filtro: projeto do Azure');
  Me.Id := 'ana@acme.com';
  J := Obj('{"id":123,"fields":{"System.TeamProject":"Loja","System.Title":"Pix falha",' +
    '"System.State":"Active","System.AssignedTo":{"displayName":"Ana","uniqueName":"ana@acme.com"},' +
    '"System.ChangedDate":"2026-10-04T10:00:00.00Z","System.CommentCount":3,' +
    '"Microsoft.VSTS.Scheduling.DueDate":"2026-10-09T03:00:00Z","System.Tags":"Pix; Blocked"}}');
  try
    It := ParseAzureItem(J, A, Me);
    Check((It.Key = 'Loja#123') and (It.Title = 'Pix falha') and (It.StatusCategory = 'indeterminate') and
      (isAssigned in It.Sources) and (It.CommentCount = 3) and It.Flagged and
      (It.Url = 'https://dev.azure.com/acme/Loja/_workitems/edit/123'), 'Azure: work item');
  finally
    J.Free;
  end;
end;

procedure TestManualKey;
var
  G: TKeyFamily;
begin
  Check((NormalizeManualKey(' app-12 ', G) = 'APP-12') and (G = kfJira), 'chave Jira normalizada');
  Check((NormalizeManualKey('grupo/sub/app!5', G) = 'grupo/sub/app!5') and (G = kfRepo), 'chave MR do GitLab');
  Check((NormalizeManualKey('Meu Projeto#123', G) = 'Meu Projeto#123') and (G = kfAzure), 'chave Azure');
  Check((NormalizeManualKey('esasse/github-issues-tray#3', G) = 'esasse/github-issues-tray#3') and (G = kfRepo),
    'chave GitHub');
  Check(NormalizeManualKey('qualquer coisa', G) = '', 'chave inválida');
  Check(NormalizeManualKey('o/r#', G) = '', 'GitHub sem número');
end;

procedure TestDiff;
var
  A: TAccount;
  Me: TIdentity;
  Old, New: TItems;
  Ev: TIssueEvents;
  Today: TDateTime;
begin
  A := NewAccount(pkJiraServer);
  A.Id := 1;
  A.Name := 'Acme';
  A.DueDays := 2;
  Me.Id := 'eu';
  Today := EncodeDate(2026, 10, 1);

  // Linha de base: nada além de prazo.
  New := [MkItem('P-1', 'Aberto', 1, 'x', [isAssigned]),
          MkItem('P-2', 'Aberto', 0, '', [isWatching], Today + 1),
          MkItem('P-3', 'Aberto', 0, '', [isWatching], Today - 3)];
  Ev := DiffItems(nil, New, A, Me, Today, True);
  Check(Kinds(Ev) = 'P-2:Prazo chegando;P-3:Prazo vencido;', 'baseline só avisa prazo: ' + Kinds(Ev));
  Check((New[1].DueAlert = 1) and (New[2].DueAlert = 2), 'baseline grava nível de prazo');

  // Mesma busca de novo: silêncio (prazo já avisado não repete).
  Old := New;
  New := [MkItem('P-1', 'Aberto', 1, 'x', [isAssigned]),
          MkItem('P-2', 'Aberto', 0, '', [isWatching], Today + 1),
          MkItem('P-3', 'Aberto', 0, '', [isWatching], Today - 3)];
  Ev := DiffItems(Old, New, A, Me, Today, False);
  Check(Length(Ev) = 0, 'sem mudança, sem evento: ' + Kinds(Ev));

  // Status, comentário de outro, comentário meu, nova associação, menção.
  Old := New;
  New := [MkItem('P-1', 'Em teste', 2, 'maria', [isAssigned]),
          MkItem('P-2', 'Aberto', 1, 'eu', [isWatching], Today + 1),
          MkItem('P-3', 'Aberto', 1, 'joao', [isWatching], Today - 3),
          MkItem('P-4', 'Aberto', 0, '', [isAssigned])];
  New[2].MentionsMe := True;
  Ev := DiffItems(Old, New, A, Me, Today, False);
  Check(Kinds(Ev) = 'P-1:Mudança de status;P-1:Novo comentário;P-3:Menção;P-4:Fui associado;',
    'eventos de mudança: ' + Kinds(Ev));

  // Prazo mudou: avisa de novo.
  Old := New;
  New := Copy(Old);
  New[1].DueDate := Today;
  Ev := DiffItems(Old, New, A, Me, Today, False);
  Check(Kinds(Ev) = 'P-2:Prazo chegando;', 'prazo novo reavisa: ' + Kinds(Ev));

  // Sinalização nova vira evento (snapshot no formato novo, com categoria).
  Old := New;
  Old[0].StatusCategory := 'new';
  New := Copy(Old);
  New[0].Flagged := True;
  Ev := DiffItems(Old, New, A, Me, Today, False);
  Check(Kinds(Ev) = 'P-1:Sinalizada;', 'sinalizada vira evento: ' + Kinds(Ev));

  // Filtro por regra da conta.
  Check(Length(FilterEvents(Ev, [ekComment])) = 0, 'filtro remove tipo desligado');

  // GitHub: comentário só conta com notification nova.
  A.Kind := pkGitHub;
  Old := [MkItem('o/r#1', 'open', 1, '', [isAssigned])];
  New := [MkItem('o/r#1', 'open', 2, '', [isAssigned])];
  Ev := DiffItems(Old, New, A, Me, Today, False);
  Check(Length(Ev) = 0, 'GitHub: comentário sem notification (meu) não avisa');
  New[0].UnreadReason := 'comment';
  Ev := DiffItems(Old, New, A, Me, Today, False);
  Check(Kinds(Ev) = 'o/r#1:Novo comentário;', 'GitHub: comentário com notification avisa');
  New := [MkItem('o/r#2', 'open', 0, '', [isReview])];
  Ev := DiffItems(Old, New, A, Me, Today, False);
  Check(Kinds(Ev) = 'o/r#2:Review de PR pedido;', 'GitHub: review pedido');
end;

{ --lottie <arquivo.json> <saida.png>: folha com 8 quadros do Lottie, para
  conferir as poses do mascote com o mesmo motor do app (Skottie). }

function TempConnection(const APath: string): TFDConnection;
begin
  if TFile.Exists(APath) then
    TFile.Delete(APath);
  Result := TFDConnection.Create(nil);
  Result.DriverName := 'SQLite';
  Result.Params.Values['Database'] := APath;
  Result.Params.Values['LockingMode'] := 'Normal';
  Result.ResourceOptions.SilentMode := True;
  Result.LoginPrompt := False;
  Result.Connected := True;
end;

procedure TestIssueStore;
var
  LRoot, LOldAppData: string;
  LConn, LVigia: TFDConnection;
  S: TIssueStore;
  A: TAccount;
  L: TArray<TAccount>;
begin
  LRoot := TPath.Combine(TPath.GetTempPath, 'devbox-issues-test');
  ForceDirectories(TPath.Combine(LRoot, 'Vigia'));
  // Um vigia.db do jeito do Vigia 0.23 (só o que o teste usa), numa pasta de teste.
  LVigia := TempConnection(TPath.Combine(LRoot, 'Vigia\vigia.db'));
  try
    LVigia.ExecSQL('CREATE TABLE account (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, ' +
      'kind INTEGER NOT NULL, base_url TEXT NOT NULL, login TEXT NOT NULL DEFAULT '''', ' +
      'enabled INTEGER NOT NULL DEFAULT 1, events INTEGER NOT NULL, due_days INTEGER NOT NULL DEFAULT 2, ' +
      'coluna_que_sumiu TEXT)');
    LVigia.ExecSQL('INSERT INTO account (name, kind, base_url, login, events) VALUES (''Empresa'', 1, ' +
      '''https://jira'', ''eu'', 3)');
    LVigia.ExecSQL('CREATE TABLE setting (name TEXT PRIMARY KEY, value TEXT)');
    LVigia.ExecSQL('INSERT INTO setting VALUES (''poll_minutes'', ''7'')');
    LVigia.ExecSQL('CREATE TABLE ai_usage (id INTEGER PRIMARY KEY AUTOINCREMENT, at REAL NOT NULL, ' +
      'provider TEXT, model TEXT, input_tokens INTEGER, output_tokens INTEGER, cost REAL)');
    LVigia.ExecSQL('INSERT INTO ai_usage (at, provider, model, input_tokens, output_tokens, cost) ' +
      'VALUES (1, ''anthropic'', ''claude-opus-5-5'', 10, 20, 0.5)');
  finally
    LVigia.Free;
  end;
  LOldAppData := GetEnvironmentVariable('LOCALAPPDATA');
  SetEnvironmentVariable('LOCALAPPDATA', PChar(LRoot));
  LConn := TempConnection(TPath.Combine(LRoot, 'devbox.db'));
  try
    S := TIssueStore.Create(LConn);
    try
      L := S.ListAccounts;
      Check((Length(L) = 1) and (L[0].Name = 'Empresa') and (L[0].Kind = pkJiraServer), 'issues: importa a conta do Vigia');
      Check(S.GetSetting('poll_minutes') = '7', 'issues: importa as preferências do Vigia');
      Check(LConn.ExecSQLScalar('SELECT COUNT(*) FROM ai_usage WHERE kind = ''assistente''') = 1,
        'issues: uso de IA do Vigia vai para o painel de custos');
    finally
      S.Free;
    end;
    // Segunda abertura não importa de novo.
    S := TIssueStore.Create(LConn);
    try
      Check(Length(S.ListAccounts) = 1, 'issues: importa uma vez só');
      A := NewAccount(pkJiraCloud);
      A.Name := 'Teste';
      A.Login := 'a@b.c';
      A.Events := [ekComment, ekOverdue];
      S.SaveAccount(A);
      Check(A.Id > 0, 'issues: insert devolve id');
      S.AddManualKey(A.Id, 'PRJ-1');
      S.AddManualKey(A.Id, 'prj-1');
      S.AddManualKey(A.Id, 'o/r#2');
      Check(Length(S.ListManualKeys(A.Id)) = 2, 'issues: manual sem duplicar (maiúscula/minúscula)');
      S.Mute(A.Id, 'PRJ-8', 0, 'Aberto');
      Check(S.IsMuted(A.Id, 'PRJ-8', 'Aberto'), 'issues: silenciada enquanto o status não muda');
      Check(not S.IsMuted(A.Id, 'PRJ-8', 'Em teste'), 'issues: status mudou, solta');
      S.DeleteAccount(A.Id);
      Check(Length(S.ListManualKeys(A.Id)) = 0, 'issues: delete leva os manuais junto');
    finally
      S.Free;
    end;
  finally
    LConn.Free;
    SetEnvironmentVariable('LOCALAPPDATA', PChar(LOldAppData));
  end;
end;

procedure TestIssues;
begin
  TestIssueStore;
  TestDates;
  TestGitHub;
  TestJiraServer;
  TestJiraFlagAndDueField;
  TestJiraCloud;
  TestCleanComment;
  TestTags;
  TestPrsAndFilter;
  TestI18n;
  TestGitLabAzure;
  TestManualKey;
  TestDiff;
end;
