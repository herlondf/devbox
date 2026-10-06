program DevboxTests;

{$APPTYPE CONSOLE}

uses
  Winapi.Windows,
  System.SysUtils,
  System.DateUtils,
  Devbox.Model in '..\src\Devbox.Model.pas',
  Devbox.Sys in '..\src\Devbox.Sys.pas';

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
  if Failures = 0 then
    Writeln('TUDO OK')
  else
    Writeln(Failures, ' FALHA(S)');
  ExitCode := Failures;
end.
