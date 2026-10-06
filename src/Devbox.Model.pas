unit Devbox.Model;

{ Tipos e regras sem I/O: dá para testar no console (tests\DevboxTests.dpr). }

interface

uses
  System.SysUtils;

const
  AppVersion = '0.1.0';
  // Segunda instância avisa a primeira por esta mensagem registrada.
  ShowMessageName = 'Devbox.Show';
  // Histórico que não é snippet some do mais velho para o mais novo depois disto.
  HistoryLimit = 200;

type
  TClip = record
    Id: Integer;
    Text: string;
    Pinned: Boolean;     // snippet: fica para sempre e aparece no filtro Snippets
    CreatedAt: TDateTime;
    { Primeira linha não vazia, sem espaços sobrando. }
    function Title: string;
  end;
  TClips = TArray<TClip>;

  TContainer = record
    Id: string;
    Name: string;
    Image: string;
    State: string;       // running, exited, paused, created...
    Status: string;      // texto do docker: "Up 3 hours", "Exited (0) 2 days ago"
    Ports: string;       // sempre no formato do docker: "0.0.0.0:5432->5432/tcp, ..."
    Distro: string;      // '' = motor do Windows; senão, a distro WSL onde ele roda
    Engine: string;      // docker ou podman
    function Running: Boolean;
    { Linha de comando do motor certo, pronta para receber o subcomando. }
    function Cli: string;
  end;
  TContainers = TArray<TContainer>;

  TDistro = record
    Name: string;
    Running: Boolean;
    IsDefault: Boolean;
  end;
  TDistros = TArray<TDistro>;

  TListenPort = record
    Port: Integer;
    Address: string;
    Pid: Cardinal;
    Process: string;
    Container: string;   // container do Docker que publica a porta, se houver
  end;
  TListenPorts = TArray<TListenPort>;

{ Texto que parece segredo (token, chave privada, JWT, senha forte numa linha só).
  Não vai para o histórico. }
function LooksSecret(const AText: string): Boolean;

// Saída de "docker ps -a --format {{json .}}" ou do mesmo comando no podman:
// um objeto JSON por linha. O podman manda Names e Ports como lista e Status vazio.
function ParseDockerPs(const AOutput: string; ANow: TDateTime): TContainers;

{ Linha de comando que lista os containers: no Windows ou dentro da distro. }
function ContainerListCmd(const ADistro, AEngine: string): string;

{ Portas do host publicadas no campo Ports do docker ps
  ("0.0.0.0:5432->5432/tcp, :::5432->5432/tcp" -> [5432]). }
function PublishedPorts(const APorts: string): TArray<Integer>;

{ Nomes de "wsl -l -q" (todas) e "wsl -l --running -q" (ligadas). A primeira da
  lista completa é a padrão. Saída por nome evita a tabela traduzida do wsl -l -v. }
function ParseWslLists(const AAll, ARunning: string): TDistros;

{ "há 3 min", "há 2 h", "ontem", "12/03". }
function Ago(AWhen, ANow: TDateTime): string;

implementation

uses
  System.Classes,
  System.JSON,
  System.StrUtils,
  System.DateUtils,
  System.RegularExpressions;

function TClip.Title: string;
var
  L: TStringList;
  S: string;
begin
  Result := '';
  L := TStringList.Create;
  try
    L.Text := Text;
    for S in L do
      if Trim(S) <> '' then
        Exit(Trim(S));
  finally
    L.Free;
  end;
end;

function TContainer.Running: Boolean;
begin
  Result := SameText(State, 'running');
end;

function LooksSecret(const AText: string): Boolean;
const
  CMinStrong = 12;
  CMaxStrong = 128;
  CSymbols = '!@#$%^&*+=?~';
var
  S: string;
  C: Char;
  HasUpper, HasLower, HasDigit, HasSymbol: Boolean;
begin
  S := Trim(AText);
  if S = '' then
    Exit(False);
  // Prefixos de token conhecidos e blocos de chave.
  if TRegEx.IsMatch(S, '(^|\s)(ghp_|gho_|ghu_|ghs_|github_pat_|glpat-|sk-ant-|sk-|xox[abpr]-|AKIA[0-9A-Z]{16})') or
    ContainsText(S, 'PRIVATE KEY-----') or
    TRegEx.IsMatch(S, '^eyJ[\w-]+\.eyJ[\w-]+\.[\w-]+$') or
    TRegEx.IsMatch(S, '(?i)(password|senha|passwd|secret|api[_-]?key)\s*[=:]\s*\S+') then
    Exit(True);
  // Uma linha só, sem espaço, com maiúscula, minúscula, dígito e símbolo: cara de senha.
  if (Length(S) < CMinStrong) or (Length(S) > CMaxStrong) or (Pos(' ', S) > 0) or
    (Pos(#10, S) > 0) then
    Exit(False);
  HasUpper := False;
  HasLower := False;
  HasDigit := False;
  HasSymbol := False;
  for C in S do
    if CharInSet(C, ['A'..'Z']) then
      HasUpper := True
    else if CharInSet(C, ['a'..'z']) then
      HasLower := True
    else if CharInSet(C, ['0'..'9']) then
      HasDigit := True
    else if Pos(C, CSymbols) > 0 then
      HasSymbol := True;
  Result := HasUpper and HasLower and HasDigit and HasSymbol;
end;

function ContainerListCmd(const ADistro, AEngine: string): string;
begin
  Result := AEngine + ' ps -a --no-trunc --format "{{json .}}"';
  if ADistro <> '' then
    Result := Format('wsl.exe -d %s -e %s', [ADistro, Result]);
end;

function TContainer.Cli: string;
begin
  if Distro = '' then
    Result := Engine
  else
    Result := Format('wsl.exe -d %s -e %s', [Distro, Engine]);
end;

// Lista do podman (["a","b"] ou objetos com host_ip, host_port, container_port,
// protocol) vira o texto do docker.
function JoinNames(AValue: TJSONValue): string;
var
  Item: TJSONValue;
begin
  if not (AValue is TJSONArray) then
    Exit(AValue.Value);
  Result := '';
  for Item in TJSONArray(AValue) do
    Result := Result + IfThen(Result <> '', ', ') + Item.Value;
end;

function JoinPorts(AValue: TJSONValue): string;
var
  Item: TJSONValue;
  Ip: string;
begin
  if not (AValue is TJSONArray) then
    Exit(AValue.Value);
  Result := '';
  for Item in TJSONArray(AValue) do
  begin
    Ip := Item.GetValue<string>('host_ip', '');
    if Ip = '' then
      Ip := '0.0.0.0';
    Result := Result + IfThen(Result <> '', ', ') + Format('%s:%d->%d/%s', [Ip,
      Item.GetValue<Integer>('host_port', 0), Item.GetValue<Integer>('container_port', 0),
      Item.GetValue<string>('protocol', 'tcp')]);
  end;
end;

function ParseDockerPs(const AOutput: string; ANow: TDateTime): TContainers;
var
  L: TStringList;
  Line: string;
  V, F: TJSONValue;
  C: TContainer;
  At: Int64;
begin
  Result := nil;
  L := TStringList.Create;
  try
    L.Text := AOutput;
    for Line in L do
    begin
      if not Trim(Line).StartsWith('{') then
        Continue;
      V := TJSONObject.ParseJSONValue(Line);
      if V = nil then
        Continue;
      try
        C := Default(TContainer);
        C.Id := V.GetValue<string>('ID', V.GetValue<string>('Id', ''));
        F := V.FindValue('Names');
        if F <> nil then
          C.Name := JoinNames(F);
        C.Image := V.GetValue<string>('Image', '');
        C.State := V.GetValue<string>('State', '');
        C.Status := V.GetValue<string>('Status', '');
        F := V.FindValue('Ports');
        if (F <> nil) and not (F is TJSONNull) then
          C.Ports := JoinPorts(F);
        // Podman: sem Status; monta com o horário de início ou de saída.
        if C.Status = '' then
        begin
          if C.Running then
            At := V.GetValue<Int64>('StartedAt', 0)
          else
            At := V.GetValue<Int64>('ExitedAt', 0);
          if At > 0 then
            C.Status := IfThen(C.Running, 'ligado ', 'saiu ') + Ago(UnixToDateTime(At, False), ANow);
        end;
        Result := Result + [C];
      finally
        V.Free;
      end;
    end;
  finally
    L.Free;
  end;
end;

function PublishedPorts(const APorts: string): TArray<Integer>;
var
  M: TMatch;
  P, Q: Integer;
  Seen: Boolean;
begin
  Result := nil;
  for M in TRegEx.Matches(APorts, ':(\d+)->') do
  begin
    P := StrToInt(M.Groups[1].Value);
    Seen := False;
    for Q in Result do
      Seen := Seen or (Q = P);
    if not Seen then
      Result := Result + [P];
  end;
end;

function CleanLines(const AText: string): TArray<string>;
var
  L: TStringList;
  S: string;
begin
  Result := nil;
  L := TStringList.Create;
  try
    L.Text := StringReplace(AText, #0, '', [rfReplaceAll]);
    for S in L do
      if Trim(S) <> '' then
        Result := Result + [Trim(S)];
  finally
    L.Free;
  end;
end;

function ParseWslLists(const AAll, ARunning: string): TDistros;
var
  Running: TArray<string>;
  S: string;
  D: TDistro;
begin
  Result := nil;
  Running := CleanLines(ARunning);
  for S in CleanLines(AAll) do
  begin
    D.Name := S;
    D.Running := IndexText(S, Running) >= 0;
    D.IsDefault := Result = nil;
    Result := Result + [D];
  end;
end;

function Ago(AWhen, ANow: TDateTime): string;
var
  Mins: Int64;
begin
  Mins := MinutesBetween(ANow, AWhen);
  if Mins < 1 then
    Result := 'agora'
  else if Mins < 60 then
    Result := Format('há %d min', [Mins])
  else if (Mins < 24 * 60) and (DateOf(AWhen) = DateOf(ANow)) then
    Result := Format('há %d h', [Mins div 60])
  else if DateOf(AWhen) = DateOf(ANow) - 1 then
    Result := 'ontem'
  else
    Result := FormatDateTime('dd/mm', AWhen);
end;

end.
