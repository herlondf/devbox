program DevboxTests;

{$APPTYPE CONSOLE}

uses
  Winapi.Windows,
  System.SysUtils,
  System.DateUtils,
  System.IOUtils,
  System.Math,
  System.StrUtils,
  System.Generics.Collections,
  System.JSON,
  FireDAC.Comp.Client,
  Devbox.Model in '..\src\Devbox.Model.pas',
  Devbox.Sys in '..\src\Devbox.Sys.pas',
  Devbox.Convert in '..\src\Devbox.Convert.pas',
  Devbox.Cleanup in '..\src\Devbox.Cleanup.pas',
  Devbox.Jobs in '..\src\Devbox.Jobs.pas',
  Devbox.Net in '..\src\Devbox.Net.pas',
  Devbox.Envs in '..\src\Devbox.Envs.pas',
  Devbox.Tools in '..\src\Devbox.Tools.pas',
  Devbox.Store in '..\src\Devbox.Store.pas',
  Devbox.Secrets in '..\src\Devbox.Secrets.pas',
  Devbox.I18n.En in '..\src\Devbox.I18n.En.pas',
  Devbox.I18n in '..\src\Devbox.I18n.pas',
  Devbox.Issues.Model in '..\src\Devbox.Issues.Model.pas',
  Devbox.Issues.Providers in '..\src\Devbox.Issues.Providers.pas',
  Devbox.Issues.Diff in '..\src\Devbox.Issues.Diff.pas',
  Devbox.Issues.Store in '..\src\Devbox.Issues.Store.pas',
  Devbox.Usage in '..\src\Devbox.Usage.pas',
  Devbox.AI in '..\src\Devbox.AI.pas',
  Devbox.SysInfo in '..\src\Devbox.SysInfo.pas',
  Devbox.Google in '..\src\Devbox.Google.pas',
  Devbox.ICal in '..\src\Devbox.ICal.pas',
  Devbox.Tls in '..\src\Devbox.Tls.pas',
  Devbox.Imap in '..\src\Devbox.Imap.pas',
  Devbox.Whisper in '..\src\Devbox.Whisper.pas',
  Devbox.Vosk in '..\src\Devbox.Vosk.pas',
  Devbox.Voice in '..\src\Devbox.Voice.pas',
  Devbox.MailSource in '..\src\Devbox.MailSource.pas',
  Devbox.Voice.Agent in '..\src\Devbox.Voice.Agent.pas',
  System.SyncObjs,
  UI.Audio.Capture,
  Devbox.Speech in '..\src\Devbox.Speech.pas',
  Devbox.WebRtcAec in '..\src\Devbox.WebRtcAec.pas',
  Devbox.WebSocket in '..\src\Devbox.WebSocket.pas',
  Devbox.Realtime in '..\src\Devbox.Realtime.pas';

var
  Failures: Integer;

procedure Check(ACond: Boolean; const AName: string);
begin
  if ACond then
    Writeln('ok   ', AName)
  else
  begin
    Writeln('FAIL ', AName);
    Inc(Failures);
  end;
end;

procedure TestSecrets;
begin
  Check(LooksSecret('ghp_abcdefghijklmnopqrstuvwxyz0123456789'), 'token GitHub');
  Check(LooksSecret('glpat-xxxxxxxxxxxxxxxxxxxx'), 'token GitLab');
  Check(LooksSecret('sk-ant-api03-abc'), 'chave Anthropic');
  Check(LooksSecret('-----BEGIN OPENSSH PRIVATE KEY-----'#13#10'abc'), 'chave privada');
  Check(LooksSecret('eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.abc_def-123'), 'JWT');
  Check(LooksSecret('DB_PASSWORD=hunter2'), 'senha em env');
  Check(LooksSecret('Tr0ub4dor&3xyz'), 'senha forte');
  Check(not LooksSecret('git status'), 'comando comum');
  Check(not LooksSecret('Vigia.UI.Main2'), 'identificador com ponto');
  Check(not LooksSecret('SELECT * FROM clip WHERE id = 1'), 'SQL');
  Check(not LooksSecret('3f19bfd'), 'hash curto');
  Check(not LooksSecret(''), 'vazio');
end;

procedure TestDocker;
const
  Out =
    '{"ID":"a1","Image":"postgres:16","Names":"pg","Ports":"0.0.0.0:5432->5432/tcp, :::5432->5432/tcp","State":"running","Status":"Up 3 hours"}'#10 +
    'aviso solto'#10 +
    '{"ID":"b2","Image":"redis","Names":"cache","Ports":"","State":"exited","Status":"Exited (0) 2 days ago"}'#10;
var
  C: TContainers;
  P: TArray<Integer>;
begin
  C := ParseDockerPs(Out, Now);
  Check(Length(C) = 2, 'docker ps: 2 containers');
  Check((C[0].Name = 'pg') and C[0].Running, 'docker ps: pg rodando');
  Check(not C[1].Running, 'docker ps: cache parado');
  P := PublishedPorts(C[0].Ports);
  Check((Length(P) = 1) and (P[0] = 5432), 'portas publicadas sem repetir');
  Check(PublishedPorts('5432/tcp') = nil, 'porta sem publicar');
end;

procedure TestPodman;
const
  Out =
    '{"Id":"d6","Names":["sql"],"Image":"mssql","State":"running","Status":"","StartedAt":1790000000,' +
    '"Ports":[{"host_ip":"127.0.0.1","container_port":1433,"host_port":1433,"range":1,"protocol":"tcp"}]}'#10 +
    '{"Id":"b2","Names":["web","web2"],"Image":"nginx","State":"exited","Status":"","ExitedAt":0,"Ports":null}'#10;
var
  C: TContainers;
  P: TArray<Integer>;
begin
  C := ParseDockerPs(Out, Now);
  Check(Length(C) = 2, 'podman: 2 containers');
  Check((C[0].Id = 'd6') and (C[0].Name = 'sql') and C[0].Running, 'podman: nome em lista e Id');
  Check(C[0].Ports = '127.0.0.1:1433->1433/tcp', 'podman: portas no formato do docker');
  P := PublishedPorts(C[0].Ports);
  Check((Length(P) = 1) and (P[0] = 1433), 'podman: porta publicada');
  Check(C[0].Status.StartsWith('ligado '), 'podman: status montado');
  Check((C[1].Name = 'web, web2') and (C[1].Ports = '') and (C[1].Status = ''), 'podman: sem portas nem horário');
  C[0].Distro := 'Ubuntu';
  C[0].Engine := 'podman';
  Check(C[0].Cli = 'wsl.exe -d Ubuntu -e podman', 'podman: comando dentro da distro');
  Check(ContainerListCmd('', 'docker') = 'docker ps -a --no-trunc --format "{{json .}}"', 'docker: comando no Windows');
end;

procedure TestWsl;
var
  D: TDistros;
begin
  // wsl.exe escreve UTF-16: chega com #0 entre as letras quando lido como bytes.
  D := ParseWslLists('U'#0'b'#0'u'#0'n'#0't'#0'u'#0#13#10'docker-desktop'#13#10, 'docker-desktop'#13#10);
  Check(Length(D) = 2, 'wsl: 2 distros');
  Check((D[0].Name = 'Ubuntu') and D[0].IsDefault and not D[0].Running, 'wsl: padrão parada');
  Check(D[1].Running and not D[1].IsDefault, 'wsl: docker-desktop ligada');
end;

procedure TestClipAndAgo;
var
  C: TClip;
  N: TDateTime;
begin
  C.Text := #13#10'   '#13#10'  primeira linha  '#13#10'segunda';
  Check(C.Title = 'primeira linha', 'título do clip');
  N := EncodeDateTime(2026, 10, 5, 15, 0, 0, 0);
  Check(Ago(IncSecond(N, -20), N) = 'agora', 'agora');
  Check(Ago(IncMinute(N, -5), N) = 'há 5 min', 'minutos');
  Check(Ago(IncHour(N, -3), N) = 'há 3 h', 'horas');
  Check(Ago(IncDay(N, -1), N) = 'ontem', 'ontem');
  Check(Ago(IncDay(N, -10), N) = '25/09', 'data');
end;

procedure TestConvert;
var
  R, E: string;
  Ok: Boolean;
begin
  Check(ConvertText(cvJsonPretty, '{"a":1,"b":[1,2]}', R, E) and (Pos(#10, R) > 0) and (Pos('"a": 1', R) > 0), 'JSON formatado');
  Check(ConvertText(cvJsonMin, '{ "a" : 1 }', R, E) and (R = '{"a":1}'), 'JSON numa linha');
  Check(ConvertText(cvJsonMin, '{"u":"a/b"}', R, E) and (R = '{"u":"a/b"}'), 'JSON sem barra escapada');
  Check(not ConvertText(cvJsonPretty, '{a:', R, E) and (E <> ''), 'JSON inválido dá erro');
  Check(ConvertText(cvBase64Enc, 'olá', R, E) and (R = 'b2zDoQ=='), 'Base64 codifica UTF-8');
  Check(ConvertText(cvBase64Dec, 'b2zDoQ==', R, E) and (R = 'olá'), 'Base64 decodifica');
  Check(ConvertText(cvBase64Enc, StringOfChar('x', 200), R, E) and (Pos(#10, R) = 0), 'Base64 sem quebra de linha');
  Check(ConvertText(cvUrlEnc, 'a b&c', R, E) and (R = 'a+b%26c'), 'URL codifica');
  Check(ConvertText(cvUrlDec, 'a+b%26c', R, E) and (R = 'a b&c'), 'URL decodifica');
  Ok := ConvertText(cvJwt, 'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjMiLCJleHAiOjF9.assinatura', R, E);
  Check(Ok and (Pos('"alg": "HS256"', R) > 0) and (Pos('"sub": "123"', R) > 0) and (Pos('já venceu', R) > 0), 'JWT lido com vencimento');
  Check(not ConvertText(cvJwt, 'abc', R, E), 'JWT inválido dá erro');
  Check(ConvertText(cvTimestamp, '0', R, E) and (Pos('1970-01-01T00:00:00Z', R) > 0), 'timestamp em segundos');
  Check(ConvertText(cvTimestamp, '1700000000000', R, E) and (Pos('2023-11-14T22:13:20Z', R) > 0), 'timestamp em milissegundos');
  Check(ConvertText(cvSha256, 'abc', R, E) and (R = 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'), 'SHA-256');
  Check(ConvertText(cvMd5, 'abc', R, E) and (R = '900150983cd24fb0d6963f7d28e17f72'), 'MD5');
  Check(ConvertText(cvUpper, 'ação', R, E) and (R = 'AÇÃO'), 'maiúsculas com acento');
  Check(ConvertText(cvSortLines, 'b'#13#10'a'#13#10'C', R, E) and (R = 'a'#13#10'b'#13#10'C'), 'ordenar linhas');
  Check(ConvertText(cvUniqueLines, 'a'#13#10'b'#13#10'a', R, E) and (R = 'a'#13#10'b'), 'linhas sem repetir, fica a primeira');
  Check(ConvertText(cvGuid, '', R, E) and (Length(R) = 36), 'GUID');
end;

procedure TestClipCaption;
var
  C: TClip;
begin
  C := Default(TClip);
  C.Kind := ckFiles;
  C.Text := 'C:\a\um.exe'#13#10'C:\a\dois.png'#13#10'C:\a\tres.mp4'#13#10'C:\a\quatro.txt';
  Check(Length(ClipFiles(C)) = 4, 'clip de arquivos: 4 caminhos');
  Check(ClipCaption(C) = '4 arquivos: um.exe, dois.png, tres.mp4…', 'clip de arquivos: legenda');
  C.Text := 'C:\a\um.exe';
  Check(ClipCaption(C) = 'C:\a\um.exe', 'clip de um arquivo: caminho');
end;

procedure TestExpander;
var
  F: TArray<string>;
  N: TDateTime;
begin
  Check(ValidAbbrev(';sql') and ValidAbbrev(';log-api') and not ValidAbbrev('sql') and
    not ValidAbbrev(';S') and not ValidAbbrev(';com espaço'), 'atalho válido');
  Check(AbbrevConflict(';sq', [';sql', ';log']) = ';sql', 'conflito: prefixo de outro');
  Check(AbbrevConflict(';sqlx', [';sql']) = ';sql', 'conflito: outro é prefixo');
  Check(AbbrevConflict(';api', [';sql', ';log']) = '', 'sem conflito');
  N := EncodeDateTime(2026, 10, 5, 14, 30, 0, 0);
  Check(BuiltinExpansion(';data', N) = '05/10/2026', 'pronto: data');
  Check(BuiltinExpansion(';agora', N) = '2026-10-05T14:30:00', 'pronto: agora');
  Check(BuiltinExpansion(';nada', N) = '', 'não é pronto');
  F := TemplateFields('docker logs {{ container }} --tail {{n}} && echo {{container}}');
  Check((Length(F) = 2) and (F[0] = 'container') and (F[1] = 'n'), 'campos sem repetir');
  Check(FillTemplate('docker logs {{ container }} --tail {{n}} {{x}}', ['container', 'n'], ['api', '$1']) =
    'docker logs api --tail $1 {{x}}', 'preencher campos, $ literal, campo sem valor fica');
end;

procedure TestAbbrevBuffer;
var
  B, Hit: string;
  C: Char;
  Abbrevs: TArray<string>;
begin
  Abbrevs := [';sql', ';data'];
  B := '';
  Hit := '';
  for C in 'texto ;sq' do
    Hit := FeedAbbrevBuffer(B, C, Abbrevs);
  Check(Hit = '', 'buffer: ainda não bateu');
  Hit := FeedAbbrevBuffer(B, 'l', Abbrevs);
  Check((Hit = ';sql') and (B = ''), 'buffer: bateu e zerou');
  for C in ';datx' do
    FeedAbbrevBuffer(B, C, Abbrevs);
  FeedAbbrevBuffer(B, #8, Abbrevs);
  Check(FeedAbbrevBuffer(B, 'a', Abbrevs) = ';data', 'buffer: backspace corrige');
  for C in ';da' do
    FeedAbbrevBuffer(B, C, Abbrevs);
  FeedAbbrevBuffer(B, #0, Abbrevs);
  Check(FeedAbbrevBuffer(B, 't', Abbrevs) + FeedAbbrevBuffer(B, 'a', Abbrevs) = '', 'buffer: tecla que quebra zera');
end;

procedure TestCleanup;
var
  Root, P: string;
  Junk: TJunkItems;
  Empty: TArray<string>;
  Freed: Int64;
  I: Integer;
  Kinds: string;
begin
  Check(JunkKind('node_modules', ['package.json', 'README.md']) = 'Node (node_modules)', 'lixo: node_modules');
  Check(JunkKind('node_modules', ['README.md']) = '', 'lixo: node_modules sem package.json não');
  Check(JunkKind('bin', ['App.csproj']) <> '', 'lixo: bin de .NET');
  Check(JunkKind('bin', ['Makefile']) = '', 'lixo: bin solto não');
  Check(JunkKind('build', ['src.c']) = '', 'lixo: build sem marcador não');
  Check(JunkKind('target', ['Cargo.toml']) = 'Rust (target)', 'lixo: target do Rust');
  Check(JunkKind('__history', []) <> '', 'lixo: __history sempre');
  Check(ParseSizeText('1.5GB') = 1500000000, 'tamanho: 1.5GB');
  Check(ParseSizeText('350MB') = 350000000, 'tamanho: 350MB');
  Check(ParseSizeText('123456') = 123456, 'tamanho: número do podman');
  Check(SizeText(1536) = Format('%.1f KB', [1.5]), 'tamanho em texto');

  // Árvore de teste: projeto parado com node_modules, projeto novo, pastas vazias.
  Root := TPath.Combine(TPath.GetTempPath, 'devbox-test-' + IntToStr(GetTickCount));
  ForceDirectories(TPath.Combine(Root, 'velho\node_modules\lib'));
  TFile.WriteAllText(TPath.Combine(Root, 'velho\package.json'), '{}');
  TFile.WriteAllText(TPath.Combine(Root, 'velho\node_modules\lib\a.js'), StringOfChar('x', 1000));
  TFile.SetLastWriteTime(TPath.Combine(Root, 'velho\package.json'), IncDay(Now, -90));
  ForceDirectories(TPath.Combine(Root, 'novo\node_modules'));
  TFile.WriteAllText(TPath.Combine(Root, 'novo\package.json'), '{}');
  ForceDirectories(TPath.Combine(Root, 'vazia\dentro\mais'));
  ForceDirectories(TPath.Combine(Root, 'cheia\vazia2'));
  TFile.WriteAllText(TPath.Combine(Root, 'cheia\x.txt'), 'x');
  try
    Junk := ScanBuildJunk([Root], 30, nil, nil);
    Kinds := '';
    for I := 0 to High(Junk) do
      Kinds := Kinds + Junk[I].Path + ';';
    Check((Length(Junk) = 1) and EndsText('velho\node_modules', Junk[0].Path) and (Junk[0].Size = 1000) and
      (Junk[0].IdleDays >= 89), 'varredura: só o node_modules do projeto parado ' + Kinds);
    // Vazias: "vazia" (com subpastas vazias), "novo\node_modules" e "cheia\vazia2".
    Empty := ScanEmptyDirs(Root, nil);
    TArray.Sort<string>(Empty);
    Kinds := string.Join(';', Empty).Replace(Root + '\', '');
    Check(Kinds = 'cheia\vazia2;novo\node_modules;vazia', 'pastas vazias: só as de cima (' + Kinds + ')');
    P := TPath.Combine(Root, 'cheia\x.txt');
    Check((DeletePaths([P], False, Freed) = 0) and (Freed = 1) and not TFile.Exists(P), 'apagar de vez');
  finally
    TDirectory.Delete(Root, True);
  end;
end;

procedure TestJobs;
var
  J: TJob;
  N: TDateTime;
begin
  Check((ParseClock('08:30') = 510) and (ParseClock('8h') = 480) and (ParseClock('24:00') = -1) and
    (ParseClock('x') = -1), 'relógio: ler hh:mm');
  Check(ClockText(510) = '08:30', 'relógio: escrever');
  // Segunda-feira, 05/10/2026, 10:00.
  N := EncodeDateTime(2026, 10, 5, 10, 0, 0, 0);
  J := Default(TJob);
  J.Kind := jkInterval;
  J.EveryMin := 15;
  Check(NextRunAfter(J, N) = IncMinute(N, 15), 'intervalo: +15 min');
  Check(J.WhenText = 'a cada 15 min', 'intervalo: texto');
  J.Kind := jkDaily;
  J.AtMin := 9 * 60;
  Check(SameDateTime(NextRunAfter(J, N), EncodeDateTime(2026, 10, 6, 9, 0, 0, 0)), 'diário: horário passou, amanhã');
  J.AtMin := 18 * 60;
  Check(SameDateTime(NextRunAfter(J, N), EncodeDateTime(2026, 10, 5, 18, 0, 0, 0)), 'diário: ainda hoje');
  J.Kind := jkWeekly;
  J.Weekdays := (1 shl 3) or (1 shl 5);  // quarta e sexta
  J.AtMin := 8 * 60;
  Check(SameDateTime(NextRunAfter(J, N), EncodeDateTime(2026, 10, 7, 8, 0, 0, 0)), 'semanal: próxima quarta');
  Check(J.WhenText = 'qua, sex às 08:00', 'semanal: texto');
  J.Weekdays := 1 shl 1;  // segunda, 08:00 já passou hoje
  Check(SameDateTime(NextRunAfter(J, N), EncodeDateTime(2026, 10, 12, 8, 0, 0, 0)), 'semanal: semana que vem');
  J.Weekdays := 0;
  Check(NextRunAfter(J, N) = 0, 'semanal: sem dia, nunca');
  Check(TailLines('a'#13#10'b'#13#10'c'#13#10#13#10, 2) = 'b'#13#10'c', 'últimas linhas');
end;

procedure TestEnvs;
var
  S, Stop: TEnvSteps;
  E: string;
begin
  Check(ParseEnvScript(
    '# api do projeto'#13#10 +
    'distro: Ubuntu'#13#10 +
    'container: api-db @Ubuntu'#13#10 +
    'container: cache'#13#10 +
    'esperar: localhost:5432'#13#10 +
    'esperar: 3'#13#10 +
    'terminal: D:\proj | npm run dev'#13#10 +
    'abrir: http://localhost:5173'#13#10 +
    'parar: npm run stop'#13#10, S, E), 'ambiente: lê o roteiro ' + E);
  Check(Length(S) = 8, 'ambiente: 8 passos (comentário fora)');
  Check((S[1].Kind = eskContainer) and (S[1].Target = 'api-db') and (S[1].Distro = 'Ubuntu'), 'ambiente: container com distro');
  Check((S[2].Target = 'cache') and (S[2].Distro = ''), 'ambiente: container do Windows');
  Check((S[3].Kind = eskWait) and (S[3].Target = 'localhost') and (S[3].Extra = '5432'), 'ambiente: esperar porta');
  Check((S[4].Kind = eskWait) and (S[4].Extra = ''), 'ambiente: esperar segundos');
  Check((S[5].Target = 'D:\proj') and (S[5].Extra = 'npm run dev'), 'ambiente: terminal com comando');
  Stop := StopSteps(S);
  Check((Length(Stop) = 4) and (Stop[0].Kind = eskStop) and (Stop[1].Target = 'cache') and
    (Stop[2].Target = 'api-db') and (Stop[3].Kind = eskDistro), 'ambiente: desligar na ordem inversa');
  Check(not ParseEnvScript('subir: x', S, E) and (Pos('Linha 1', E) = 1), 'ambiente: tipo errado dá erro');
  Check(not ParseEnvScript('esperar: abc', S, E), 'ambiente: esperar inválido dá erro');
end;

procedure TestTools;
var
  A, B: TEnvEntries;
  Rows: TEnvRows;
  F: string;
  Pos_: Int64;
  Trunc: Boolean;
begin
  A := ParseEnvText('# banco'#13#10'DB_HOST=localhost'#13#10'export DB_PASS="segredo"'#13#10'VAZIA='#13#10'lixo'#13#10);
  Check((Length(A) = 3) and (A[1].Key = 'DB_PASS') and (A[1].Value = 'segredo') and (A[2].Value = ''),
    '.env: lê chave, export, aspas e vazia');
  B := ParseEnvText('DB_HOST=db'#13#10'API_KEY=x'#13#10);
  Rows := CompareEnvs([A, B]);
  Check((Length(Rows) = 4) and (Rows[0].Key = 'API_KEY') and (Rows[0].States[0] = esMissing) and
    (Rows[0].States[1] = esSet), '.env: comparar, falta no primeiro');
  Check((Rows[1].Key = 'DB_HOST') and not Rows[1].MissingSomewhere, '.env: chave nos dois');
  Check((Rows[3].Key = 'VAZIA') and (Rows[3].States[0] = esEmpty) and (Rows[3].States[1] = esMissing), '.env: vazia e faltando');

  F := TPath.Combine(TPath.GetTempPath, 'devbox-log-' + IntToStr(GetTickCount) + '.log');
  TFile.WriteAllText(F, 'linha 1'#13#10);
  try
    Pos_ := 0;
    Check(ReadNewText(F, Pos_, Trunc) = 'linha 1'#13#10, 'log: primeira leitura');
    TFile.AppendAllText(F, 'linha 2'#13#10);
    Check(ReadNewText(F, Pos_, Trunc) = 'linha 2'#13#10, 'log: só o novo');
    Check(ReadNewText(F, Pos_, Trunc) = '', 'log: nada novo');
    TFile.WriteAllText(F, 'x'#13#10);
    Check((ReadNewText(F, Pos_, Trunc) = 'x'#13#10) and Trunc, 'log: arquivo truncado volta do começo');
  finally
    TFile.Delete(F);
  end;
end;

procedure TestAI;
var
  Shell, Cmd, Expl, Sys_: string;
  C: TAIConfig;
begin
  Check(ParseCommandAnswer('```json'#10'{"shell":"wsl","command":"docker ps","explanation":"lista"}'#10'```',
    Shell, Cmd, Expl) and (Shell = 'wsl') and (Cmd = 'docker ps') and (Expl = 'lista'), 'IA: comando dentro de ```');
  Check(ParseCommandAnswer('{"shell":"bash","command":"ls"}', Shell, Cmd, Expl) and (Shell = 'powershell'),
    'IA: shell desconhecido vira powershell');
  Check(not ParseCommandAnswer('não sei', Shell, Cmd, Expl), 'IA: sem JSON dá falso');
  Check(not ParseCommandAnswer('{"shell":"cmd","command":""}', Shell, Cmd, Expl), 'IA: comando vazio dá falso');
  Check((ActionPrompt(aaCommit, 'diff', Sys_) = 'diff') and (Pos('Conventional Commits', Sys_) > 0), 'IA: instrução do commit');
  C := Default(TAIConfig);
  C.Provider := apAnthropic;
  C.Model := 'x';
  Check(not C.Ready, 'IA: Anthropic sem chave não está pronta');
  C.Provider := apOpenAI;
  C.BaseUrl := 'http://localhost:11434/v1';
  Check(C.Ready, 'IA: compatível sem chave, com endereço, está pronta');
end;

procedure TestICal;
const
  CRLF = #13#10;
var
  Ev: TCalEvents;
  E: TCalEvent;
  Titles: string;
  Daily, Moved, Feriado, Longa: TCalEvent;
begin
  Ev := ParseICal('BEGIN:VCALENDAR' + CRLF +
    'BEGIN:VEVENT' + CRLF + 'UID:a' + CRLF + 'DTSTART:20261005T120000Z' + CRLF + 'DTEND:20261005T121500Z' + CRLF +
    'RRULE:FREQ=WEEKLY;BYDAY=MO,WE;COUNT=4' + CRLF + 'EXDATE:20261007T120000Z' + CRLF +
    'SUMMARY:Daily\, time' + CRLF + 'DESCRIPTION:Entrar: https://meet.google.com/abc-defg-hij\nObrigado' + CRLF +
    'END:VEVENT' + CRLF +
    'BEGIN:VEVENT' + CRLF + 'UID:a' + CRLF + 'RECURRENCE-ID:20261012T120000Z' + CRLF +
    'DTSTART:20261012T150000Z' + CRLF + 'DTEND:20261012T151500Z' + CRLF + 'SUMMARY:Daily movida' + CRLF +
    'END:VEVENT' + CRLF +
    'BEGIN:VEVENT' + CRLF + 'UID:b' + CRLF + 'DTSTART;VALUE=DATE:20261009' + CRLF + 'DTEND;VALUE=DATE:20261010' + CRLF +
    'SUMMARY:Feriado' + CRLF + 'END:VEVENT' + CRLF +
    'BEGIN:VEVENT' + CRLF + 'UID:c' + CRLF + 'DTSTART:20261008T100000' + CRLF + 'DURATION:PT1H30M' + CRLF +
    'SUMMARY:Long' + CRLF + ' a linha dobrada' + CRLF + 'END:VEVENT' + CRLF +
    'BEGIN:VEVENT' + CRLF + 'UID:d' + CRLF + 'STATUS:CANCELLED' + CRLF + 'DTSTART:20261008T100000' + CRLF +
    'SUMMARY:x' + CRLF + 'END:VEVENT' + CRLF + 'END:VCALENDAR', EncodeDate(2026, 10, 1), EncodeDate(2026, 11, 1));
  Titles := '';
  Daily := Default(TCalEvent);
  Moved := Daily;
  Feriado := Daily;
  Longa := Daily;
  for E in Ev do
  begin
    Titles := Titles + E.Title + ';';
    if (E.Title = 'Daily, time') and (Daily.Title = '') then Daily := E;
    if E.Title = 'Daily movida' then Moved := E;
    if E.Title = 'Feriado' then Feriado := E;
    if E.Title = 'Longa linha dobrada' then Longa := E;
  end;
  Check(Length(Ev) = 5, 'ical: 5 eventos (repetição, exceção, movida, cancelado) ' + Titles);
  Check(Daily.MeetUrl = 'https://meet.google.com/abc-defg-hij', 'ical: link do Meet na descrição');
  Check(Daily.Start = TTimeZone.Local.ToLocalTime(EncodeDateTime(2026, 10, 5, 12, 0, 0, 0)), 'ical: hora UTC vira local');
  Check(Moved.Start = TTimeZone.Local.ToLocalTime(EncodeDateTime(2026, 10, 12, 15, 0, 0, 0)), 'ical: ocorrência movida');
  Check(Feriado.AllDay and (Feriado.Start = EncodeDate(2026, 10, 9)), 'ical: dia todo');
  Check(MinutesBetween(Longa.Start, Longa.Finish) = 90, 'ical: DURATION e linha dobrada');
end;

procedure TestImap;
const
  CRLF = #13#10;
var
  M: TMailMsg;
  F, S: string;
begin
  Check(MUtf7Encode('Relatórios') = 'Relat&APM-rios', 'imap: pasta com acento em UTF-7');
  Check(MUtf7Decode('Relat&APM-rios') = 'Relatórios', 'imap: UTF-7 de volta');
  Check((MUtf7Encode('P&D') = 'P&-D') and (MUtf7Decode('P&-D') = 'P&D'), 'imap: & na pasta');
  Check(ImapQuote('a"b\c') = '"a\"b\\c"', 'imap: aspas e barra');
  Check(ParseImapDate('06-Oct-2026 13:00:00 +0000') = TTimeZone.Local.ToLocalTime(EncodeDateTime(2026, 10, 6, 13, 0, 0, 0)),
    'imap: INTERNALDATE para hora local');
  ParseHeaderFields('From: =?UTF-8?B?Sm/Do28gU2lsdmE=?= <joao@ex.com>' + CRLF + 'Subject: =?UTF-8?Q?Reuni=C3=A3o?=' + CRLF +
    ' amanha' + CRLF, F, S);
  Check((F = 'João Silva <joao@ex.com>') and (S = 'Reunião amanha'), 'imap: cabeçalho codificado e dobrado: ' + F + ' / ' + S);
  Check(ParseRawMail(TEncoding.UTF8.GetBytes(
    'From: =?UTF-8?B?Sm/Do28gU2lsdmE=?= <joao@ex.com>' + CRLF +
    'Subject: =?UTF-8?Q?Reuni=C3=A3o_amanh=C3=A3?=' + CRLF +
    'Date: Tue, 06 Oct 2026 10:00:00 -0300' + CRLF + 'MIME-Version: 1.0' + CRLF +
    'Content-Type: multipart/alternative; boundary="b1"' + CRLF + CRLF +
    '--b1' + CRLF + 'Content-Type: text/plain; charset=UTF-8' + CRLF +
    'Content-Transfer-Encoding: quoted-printable' + CRLF + CRLF + 'Ol=C3=A1, tudo bem?' + CRLF + 'Linha 2' + CRLF +
    '--b1' + CRLF + 'Content-Type: text/html; charset=UTF-8' + CRLF + CRLF + '<p>Ol&aacute;</p>' + CRLF +
    '--b1--' + CRLF), M), 'imap: e-mail multipart lido');
  Check((M.Subject = 'Reunião amanhã') and (M.FromName = 'João Silva') and (M.FromEmail = 'joao@ex.com'),
    'imap: assunto e remetente: ' + M.Subject + ' / ' + M.FromName + ' / ' + M.FromEmail);
  Check(M.Body = 'Olá, tudo bem?'#10'Linha 2', 'imap: corpo quoted-printable: ' + M.Body.Replace(#10, '|'));
end;

{ DevboxTests -tls host porta: aperto de mão TLS real e CAPABILITY (sem login). }
procedure RunTlsProbe;
var
  T: TTlsSocket;
begin
  T := TTlsSocket.Create;
  try
    T.Connect(ParamStr(2), StrToInt(ParamStr(3)), True);
    Writeln('saudação: ', T.ReadLine);
    T.SendText('a1 CAPABILITY'#13#10);
    Writeln(T.ReadLine);
    Writeln(T.ReadLine);
    T.SendText('a2 LOGIN "naoexiste@exemplo.com" "senhaerrada"'#13#10);
    Writeln(T.ReadLine);
  finally
    T.Free;
  end;
end;

{ DevboxTests -vosk arquivo.wav "frase": o que o Vosk ouviu, se bate com a frase e quanto levou. }
procedure RunVoskProbe;
var
  LBytes: TBytes;
  LSamples: TArray<SmallInt>;
  LText, LRest, LError: string;
  LStart: UInt64;
begin
  if not VoskLoad(LError) then
  begin
    Writeln('vosk: ', LError);
    Exit;
  end;
  Writeln('fora do vocabulário: "', VoskMissingWords(ParamStr(3)), '"');
  LBytes := TFile.ReadAllBytes(ParamStr(2));
  SetLength(LSamples, (Length(LBytes) - 44) div 2);
  Move(LBytes[44], LSamples[0], Length(LSamples) * 2);
  LSamples := Copy(LSamples, 0, 2200 * 16);
  LStart := GetTickCount64;
  VoskHear(LSamples, ParamStr(3), LText);
  Writeln(Format('ouviu "%s" em %d ms; frase: %s', [LText, GetTickCount64 - LStart,
    BoolToStr(WakeMatch(LText, ParamStr(3), VoiceDefaultSimilarity, LRest), True)]));
end;

{ DevboxTests -echo pasta: toca uma frase nas caixas e grava o microfone cru e,
  ao mesmo tempo, passado pelo WebRTC (eco-0 cru, eco-1 com cancelamento, eco-ref o
  que tocou). Toca som: só com o usuário sabendo. }
procedure RunEchoTest;
const
  CText = 'Esta é a voz do Devbox testando o eco. Se o assistente entender esta frase, o cancelamento falhou.';
  CBaselineMs = 1500;
  CTailMs = 700;
var
  LPcm, LRaw, LClean: TArray<SmallInt>;
  LError: string;
  LPlayer: TPcmPlayer;
  LLock: TCriticalSection;
  LCapture: TUIAudioCapture;
  LAec: TWebRtcAec;
begin
  if not Synthesize(CText, LPcm, LError) then
  begin
    Writeln('voz: ', LError);
    Exit;
  end;
  TFile.WriteAllBytes(TPath.Combine(ParamStr(2), 'eco-ref.wav'), PcmToWav(LPcm));
  LAec := TWebRtcAec.Create;
  LLock := TCriticalSection.Create;
  LPlayer := TPcmPlayer.Create;
  LCapture := TUIAudioCapture.Create;
  try
    if not LAec.Open(LError) then
    begin
      Writeln(LError);
      Exit;
    end;
    LCapture.OnSamples :=
      procedure(const ASamples: TArray<SmallInt>)
      begin
        LLock.Enter;
        try
          LRaw := LRaw + ASamples;
          LClean := LClean + LAec.Process(ASamples, AecReference.Take);
        finally
          LLock.Leave;
        end;
      end;
    if not LCapture.Start(LError) then
    begin
      Writeln('microfone: ', LError);
      Exit;
    end;
    Sleep(CBaselineMs);
    LPlayer.Play(LPcm);
    while LPlayer.Playing do
      Sleep(50);
    Sleep(CTailMs);
    FreeAndNil(LCapture);
    TFile.WriteAllBytes(TPath.Combine(ParamStr(2), 'eco-0.wav'), PcmToWav(LRaw));
    TFile.WriteAllBytes(TPath.Combine(ParamStr(2), 'eco-1.wav'), PcmToWav(LClean));
    Writeln(Format('gravado: %.1f s cru, %.1f s com cancelamento', [Length(LRaw) / 16000, Length(LClean) / 16000]));
  finally
    LCapture.Free;
    LPlayer.Free;
    LLock.Free;
    LAec.Free;
  end;
end;

function ReadWav(const APath: string): TArray<SmallInt>;
var
  LBytes: TBytes;
begin
  LBytes := TFile.ReadAllBytes(APath);
  SetLength(Result, (Length(LBytes) - 44) div 2);
  Move(LBytes[44], Result[0], Length(Result) * 2);
end;

{ DevboxTests -aecfile mic.wav tocado.wav saida.wav inicio_ms: o WebRTC sem tocar som, com a
  gravação do microfone e o que tocou começando em inicio_ms. }
procedure RunAecFile;
const
  CBlock = 640;
var
  LMic, LRef, LOut, LRender: TArray<SmallInt>;
  LAec: TWebRtcAec;
  LError: string;
  LPos, LStart: Integer;
begin
  LMic := ReadWav(ParamStr(2));
  LRef := ReadWav(ParamStr(3));
  LStart := StrToIntDef(ParamStr(5), 0) * 16;
  LAec := TWebRtcAec.Create;
  try
    if not LAec.Open(LError) then
    begin
      Writeln(LError);
      Exit;
    end;
    LPos := 0;
    while LPos < Length(LMic) do
    begin
      if (LPos + CBlock > LStart) and (LPos - LStart < Length(LRef)) then
        LRender := Copy(LRef, Max(LPos - LStart, 0), CBlock - Max(LStart - LPos, 0))
      else
        LRender := nil;
      LOut := LOut + LAec.Process(Copy(LMic, LPos, CBlock), LRender);
      Inc(LPos, CBlock);
    end;
    TFile.WriteAllBytes(ParamStr(4), PcmToWav(LOut));
    Writeln(Format('ok: %.1f s', [Length(LOut) / 16000]));
  finally
    LAec.Free;
  end;
end;

{$I IssuesTests.inc}

procedure TestUsage;
var
  LPrice: TAiPrice;
  LUsage: TAiUsage;
begin
  Check(ParsePrice('32;64', LPrice) and (LPrice.Input = 32) and (LPrice.Output = 64) and (LPrice.PerMinute = 0),
    'custo: preço do Vigia (entrada;saída)');
  Check(ParsePrice(PriceText(LPrice), LPrice) and (LPrice.Output = 64), 'custo: preço ida e volta');
  Check(not ParsePrice('', LPrice), 'custo: preço vazio');
  LPrice := Default(TAiPrice);
  LPrice.Input := 4;
  LPrice.Output := 24;
  LPrice.AudioIn := 32;
  LPrice.AudioOut := 64;
  LPrice.PerMinute := 0.006;
  LUsage := Default(TAiUsage);
  LUsage.InputTokens := 1000;
  LUsage.AudioInTokens := 10000;
  LUsage.AudioOutTokens := 5000;
  LUsage.AudioSeconds := 60;
  // 1000*4 + 10000*32 + 5000*64 = 644000 por milhão = 0,644; + 1 min * 0,006
  Check(Abs(UsageCost(LUsage, LPrice) - 0.65) < 1E-9, 'custo: tokens de texto e áudio e minuto');
end;

procedure TestLive;
var
  LFrame, LBody: TBytes;
  LValue: UInt64;
  LPcm, LBack: TArray<SmallInt>;
begin
  // RFC 6455, seção 1.3
  Check(WsAcceptKey('dGhlIHNhbXBsZSBub25jZQ==') = 's3pPLMBiTxaQ9kYGzzhZRbK+xOo=', 'ws: chave de aceite do RFC');
  LFrame := WsFrame(1, TEncoding.UTF8.GetBytes('Hello'), [$37, $FA, $21, $3D]);
  Check((Length(LFrame) = 11) and (LFrame[0] = $81) and (LFrame[1] = $85) and (LFrame[6] = $7F) and
    (LFrame[7] = $9F) and (LFrame[10] = $58), 'ws: quadro mascarado do RFC');
  LFrame := WsFrame(1, nil, [1, 2, 3, 4]);
  Check((Length(LFrame) = 6) and (LFrame[1] = $80), 'ws: quadro vazio');
  SetLength(LBody, 300);
  LFrame := WsFrame(2, LBody, [0, 0, 0, 0]);
  Check((LFrame[1] = $FE) and (LFrame[2] = 1) and (LFrame[3] = 44), 'ws: tamanho de 16 bits');
  Check((Length(PbVarint(300)) = 2) and (PbVarint(300)[0] = $AC) and (PbVarint(300)[1] = 2), 'protobuf: varint 300');
  // FfiResponse.new_apm -> apm -> handle -> id = 1 (bytes reais da livekit_ffi)
  LFrame := [$8A, $03, $06, $0A, $04, $0A, $02, $08, $01];
  Check(PbFind(LFrame, 49, LValue, LBody) and (Length(LBody) = 6), 'protobuf: acha o campo 49');
  Check(Length(PbMessage(50, PbField(1, 1) + PbField(2, 0) + PbField(3, 1) + PbField(4, 1))) = 11,
    'protobuf: new_apm do tamanho do Python');
  SetLength(LPcm, 1600);
  Check(Length(ResamplePcm(LPcm, 16000, 24000)) = 2400, 'reamostra 16k -> 24k');
  Check(Length(ResamplePcm(LPcm, 24000, 16000)) = 1066, 'reamostra 24k -> 16k');
  LPcm := [1, -2, 32767, -32768];
  LBack := Base64ToPcm(PcmToBase64(LPcm));
  Check((Length(LBack) = 4) and (LBack[2] = 32767) and (LBack[3] = -32768), 'pcm base64 ida e volta');
end;

procedure TestVoice;
var
  Levels: TArray<Single>;
  I: Integer;
  R: TVoiceReply;
  Ev: TCalEvents;
  E: TCalEvent;
  Wav: TBytes;
  Rest: string;
begin
  // 40 ms por bloco: cauda da palavra (alto, 400 ms), pausa de 800 ms, pedido de 1 s, silêncio.
  SetLength(Levels, 100);
  for I := 0 to High(Levels) do
    if (I < 10) or ((I >= 30) and (I < 55)) then
      Levels[I] := 0.7
    else
      Levels[I] := 0.05;
  Check(SpeechEndBlock(Levels, 0.05, 40) = 54 + 30, 'voz: fim do pedido 1,2 s depois da fala (cauda da palavra ignorada)');
  for I := 0 to High(Levels) do
    Levels[I] := 0.05;
  Check(SpeechEndBlock(Levels, 0.05, 40) = -1, 'voz: sem fala não termina');
  Check(ParseVoiceIntent('```json'#10'{"acao":"abrir","tela":"Email","fala":"Abrindo"}'#10'```', R) and
    (R.Action = vaAbrir) and (R.Page = 'mail') and (R.Speech = 'Abrindo'), 'voz: intenção abrir e-mail');
  Check(ParseVoiceIntent('{"acao":"xpto"}', R) and (R.Action = vaConversa), 'voz: ação desconhecida vira conversa');
  Check(not ParseVoiceIntent('sem json', R), 'voz: resposta sem JSON');
  Check(SpokenTime(EncodeTime(9, 30, 0, 0)) + '|' + SpokenTime(EncodeTime(14, 0, 0, 0)) = '9 e 30|14 horas', 'voz: hora falada');
  Check(AgendaSpeech(nil) = 'Você não tem compromissos hoje.', 'voz: agenda vazia');
  E := Default(TCalEvent);
  E.Title := 'Daily';
  E.Start := Date + EncodeTime(9, 30, 0, 0);
  E.Finish := E.Start + 15 / 1440;
  Ev := [E];
  E.Title := 'Revisão';
  E.Start := Date + EncodeTime(16, 0, 0, 0);
  E.Finish := E.Start + 1 / 24;
  E.MeetUrl := 'https://meet.google.com/x';
  Ev := Ev + [E];
  Check(AgendaSpeech(Ev) = 'Hoje você tem 2 compromissos: às 9 e 30, Daily; às 16 horas, Revisão.', 'voz: agenda falada');
  Check(NextMeetingSpeech(Ev, Date + EncodeTime(15, 0, 0, 0)) =
    'Sua próxima reunião é Revisão, às 16 horas, daqui a 61 minutos. Tem link do Meet na agenda.', 'voz: próxima reunião');
  Check(NextMeetingSpeech(Ev, Date + EncodeTime(9, 40, 0, 0)) = 'Você está em Daily agora, até 9 e 45.', 'voz: reunião em andamento');
  Check(NormalizeSpeech('Oi, Java!') + '|' + NormalizeSpeech('Ação  Já.') = 'oi java|acao ja', 'voz: texto normalizado');
  Check(WakeMatch('Oi Java, resuma meus e-mails.', 'Oi Java', 0.72, Rest) and (Rest = 'resuma meus e-mails.'),
    'voz: frase e pedido na mesma fala: ' + Rest);
  Check(WakeMatch('Oi, jaba. Qual a minha reunião?', 'Oi Java', 0.72, Rest) and (Rest = 'Qual a minha reunião?'),
    'voz: frase parecida (jaba): ' + Rest);
  Check(WakeMatch('Ah, oi java abre a agenda', 'Oi Java', 0.72, Rest) and (Rest = 'abre a agenda'),
    'voz: palavra de sobra antes: ' + Rest);
  Check(WakeMatch('Oijava resuma', 'Oi Java', 0.72, Rest) and (Rest = 'resuma'), 'voz: palavras juntas: ' + Rest);
  Check(not WakeMatch('Hoje vou programar em Java', 'Oi Java', 0.72, Rest), 'voz: Java no meio não ativa');
  Check(WakeMatch('Oi Java.', 'Oi Java', 0.72, Rest) and (Rest = ''), 'voz: só a frase, sem pedido');
  Wav := PcmToWav([1, -1, 2]);
  Check((Length(Wav) = 50) and (Wav[0] = Ord('R')) and (PInteger(@Wav[24])^ = 16000) and (PInteger(@Wav[40])^ = 6),
    'voz: cabeçalho WAV');
end;

procedure TestGoogle;
var
  M: TMailMsg;
  N, E: string;
  Ev: TCalEvents;
  Sg: TMailSuggestions;
begin
  Check(TEncoding.UTF8.GetString(Base64UrlDecode('T2zDoSwgbXVuZG8NCmxpbmhhIDI')) = 'Olá, mundo'#13#10'linha 2',
    'google: base64url');
  Check(Base64UrlEncode(TEncoding.UTF8.GetBytes('Olá, mundo'#13#10'linha 2')) = 'T2zDoSwgbXVuZG8NCmxpbmhhIDI',
    'google: base64url de volta');
  Check(JwtEmail('x.eyJlbWFpbCI6ICJldUBleGVtcGxvLmNvbSJ9.y') = 'eu@exemplo.com', 'google: e-mail do id_token');
  SplitFrom('"Ana Souza" <ana@ex.com>', N, E);
  Check((N = 'Ana Souza') and (E = 'ana@ex.com'), 'google: remetente com nome');
  SplitFrom('bot@ex.com', N, E);
  Check((N = 'bot') and (E = 'bot@ex.com'), 'google: remetente só e-mail');
  Check(HtmlToText('<p>Oi &amp; tchau</p><style>x{}</style><br>fim') = 'Oi & tchau'#10#10'fim', 'google: html vira texto');
  Check(ParseMailJson('{"id":"m1","threadId":"t1","snippet":"Ol&#225; &amp; c","internalDate":"1759700000000",' +
    '"labelIds":["INBOX","UNREAD","IMPORTANT"],"payload":{"mimeType":"multipart/alternative","headers":[' +
    '{"name":"From","value":"Ana <ana@ex.com>"},{"name":"Subject","value":"Deploy"}],"parts":[' +
    '{"mimeType":"text/html","headers":[],"body":{"data":"PHA-T2kgJmFtcDsgdGNoYXU8L3A-PHN0eWxlPnh7fTwvc3R5bGU-PGJyPmZpbQ"}},' +
    '{"mimeType":"text/plain","headers":[{"name":"Content-Type","value":"text/plain; charset=\"UTF-8\""}],' +
    '"body":{"data":"T2zDoSwgbXVuZG8NCmxpbmhhIDI"}}]}}', M), 'google: e-mail lido');
  Check((M.Subject = 'Deploy') and (M.FromName = 'Ana') and M.Unread and M.Important and M.InInbox,
    'google: cabeçalhos e rótulos');
  Check(M.Body = 'Olá, mundo'#10'linha 2', 'google: corpo prefere text/plain');
  Check(M.Snippet = 'Olá & c', 'google: trecho sem entidades');
  Check(YearOf(M.Date) = 2025, 'google: data do e-mail');
  Check(ParseMailJson('{"id":"m2","payload":{"mimeType":"text/html","headers":[],' +
    '"body":{"data":"PHA-T2kgJmFtcDsgdGNoYXU8L3A-PHN0eWxlPnh7fTwvc3R5bGU-PGJyPmZpbQ"}}}', M) and
    (M.Body = 'Oi & tchau'#10#10'fim') and (M.Subject = '(sem assunto)'), 'google: só html');
  Ev := ParseEventsJson('{"items":[{"id":"e1","summary":"Daily","start":{"dateTime":"2026-10-06T09:00:00-03:00"},' +
    '"end":{"dateTime":"2026-10-06T09:15:00-03:00"},"hangoutLink":"https://meet.google.com/abc"},' +
    '{"id":"e2","status":"cancelled","summary":"x"},{"id":"e3","summary":"Feriado","start":{"date":"2026-10-12"},' +
    '"end":{"date":"2026-10-13"},"conferenceData":{"entryPoints":[{"entryPointType":"video","uri":"https://z"}]}}]}');
  Check(Length(Ev) = 2, 'agenda: cancelado fica de fora');
  Check((Ev[0].Title = 'Daily') and (Ev[0].MeetUrl = 'https://meet.google.com/abc') and not Ev[0].AllDay and
    (MinutesBetween(Ev[0].Start, Ev[0].Finish) = 15), 'agenda: evento com hora e Meet');
  Check(Ev[1].AllDay and (Ev[1].Start = EncodeDate(2026, 10, 12)) and (Ev[1].MeetUrl = 'https://z'),
    'agenda: dia todo e link de vídeo');
  Sg := ParseSuggestions('```json'#10'[{"id":"m1","action":"label","label":"Deploy","reason":"build"},' +
    '{"id":"m2","action":"archive"},{"id":"m3","action":"label","label":""},{"id":"m4","action":"xyz"}]'#10'```');
  Check((Length(Sg) = 4) and (Sg[0].Action = maLabel) and (Sg[0].LabelName = 'Deploy') and
    (Sg[1].Action = maArchive) and (Sg[2].Action = maKeep) and (Sg[3].Action = maKeep), 'ia: sugestões do e-mail');
  Check(ParseSuggestions('nada aqui') = nil, 'ia: resposta sem JSON');
end;

procedure TestPath;
var
  E: TPathEntries;
  Exists: TFunc<string, Boolean>;
begin
  Exists :=
    function(ADir: string): Boolean
    begin
      Result := not ContainsText(ADir, 'sumiu');
    end;
  E := AnalyzePath('C:\bin;c:\BIN\;;C:\sumiu;%SystemRoot%\system32;', Exists);
  Check(Length(E) = 5, 'PATH: 5 partes (o ; do fim não conta)');
  Check((E[0].State = psOk) and (E[1].State = psDuplicate), 'PATH: repetida mesmo com caixa e barra diferentes');
  Check((E[2].State = psEmpty) and (E[3].State = psMissing), 'PATH: vazia e que não existe');
  Check((E[4].State = psOk) and not ContainsText(E[4].Expanded, '%'), 'PATH: %VAR% expandida');
  Check(CleanPath(E, True) = 'C:\bin;%SystemRoot%\system32', 'PATH: limpo, guarda %VAR% como estava');
  Check(CleanPath(E, False) = 'C:\bin;C:\sumiu;%SystemRoot%\system32', 'PATH: limpo mantendo a que não existe');
end;

procedure Bench(const ACmd: string);
var
  Output: string;
  T: UInt64;
  Code: Integer;
begin
  T := GetTickCount64;
  Code := RunCapture(ACmd, Output);
  Writeln(Format('%d ms  saída %d  %d caracteres', [GetTickCount64 - T, Code, Length(Output)]));
  Writeln(Copy(Output, 1, 300));
end;

begin
  // DevboxTests -bench "<comando>": mede o RunCapture com o comando dado.
  if FindCmdLineSwitch('tls') then
  begin
    RunTlsProbe;
    Exit;
  end;
  if FindCmdLineSwitch('aecfile') then
  begin
    RunAecFile;
    Exit;
  end;
  if FindCmdLineSwitch('echo') then
  begin
    RunEchoTest;
    Exit;
  end;
  if FindCmdLineSwitch('vosk') then
  begin
    RunVoskProbe;
    Exit;
  end;
  if FindCmdLineSwitch('bench') then
  begin
    Bench(ParamStr(2));
    Exit;
  end;
  Failures := 0;
  TestSecrets;
  TestDocker;
  TestPodman;
  TestWsl;
  TestClipAndAgo;
  TestConvert;
  TestClipCaption;
  TestExpander;
  TestAbbrevBuffer;
  TestCleanup;
  TestJobs;
  TestEnvs;
  TestTools;
  TestAI;
  TestPath;
  TestGoogle;
  TestICal;
  TestImap;
  TestVoice;
  TestLive;
  TestUsage;
  TestIssues;
  if Failures = 0 then
    Writeln('TUDO OK')
  else
    Writeln(Failures, ' FALHA(S)');
  ExitCode := Failures;
end.
