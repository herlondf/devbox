program DevboxTests;

{$APPTYPE CONSOLE}

uses
  Winapi.Windows,
  System.SysUtils,
  System.DateUtils,
  System.IOUtils,
  System.StrUtils,
  System.Generics.Collections,
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
  Devbox.AI in '..\src\Devbox.AI.pas',
  Devbox.SysInfo in '..\src\Devbox.SysInfo.pas';

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
  if Failures = 0 then
    Writeln('TUDO OK')
  else
    Writeln(Failures, ' FALHA(S)');
  ExitCode := Failures;
end.
