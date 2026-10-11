unit Devbox.Health;

{ Manutenção do Windows: uma varredura rápida que diz quanto dá para liberar e o
  que vale ajustar, para o aviso de 2 ou 3 vezes por dia. Só lê: apagar e
  desligar continuam na tela Limpeza, com confirmação.
  - Liberar: temporários e caches (ScanCleanSpots) e lixo de build de projetos
    parados (ScanBuildJunk nas pastas da Limpeza).
  - Ajustar: disco com pouco espaço, entradas quebradas ou repetidas no PATH do
    usuário e programas ligados na inicialização.
  RunHealthScan bloqueia e não usa o banco: chamar fora da thread de UI, com as
  preferências lidas antes. }

interface

uses
  System.SysUtils;

type
  THealthReport = record
    TempBytes: Int64;
    JunkBytes: Int64;
    JunkProjects: Integer;
    LowDisks: TArray<string>;   // 'C: 7% livre'
    PathIssues: Integer;
    StartupOn: Integer;
    { Itens a liberar + ajustes (o que o aviso conta). }
    function Findings: Integer;
    function FreeableBytes: Int64;
    { Título e texto do aviso. }
    function Title: string;
    function Text: string;
  end;

  THealthSchedule = (hs2PerDay, hs3PerDay);

const
  HealthScheduleNames: array[THealthSchedule] of string = ('2 vezes por dia (10h e 16h)',
    '3 vezes por dia (9h, 13h e 17h)');
  HealthMinFreePct = 10;      // disco abaixo disso entra no aviso
  HealthMinFreeable = 500 * 1024 * 1024;  // liberar menos que isso não vale aviso
  HealthMaxStartup = 8;       // mais programas ligados que isso entra no aviso

{ Horários do dia (hh, em horas) de cada agenda. }
function HealthHours(ASchedule: THealthSchedule): TArray<Integer>;
{ Último horário da agenda que já passou hoje; -1 = nenhum ainda. }
function HealthDueHour(ASchedule: THealthSchedule; ANow: TDateTime): Integer;

function RunHealthScan(const AJunkRoots: TArray<string>; AJunkIdleDays: Integer): THealthReport;

implementation

uses
  System.DateUtils,
  System.StrUtils,
  System.Math,
  System.IOUtils,
  Devbox.Cleanup,
  Devbox.SysInfo;

function HealthHours(ASchedule: THealthSchedule): TArray<Integer>;
begin
  if ASchedule = hs3PerDay then
    Result := [9, 13, 17]
  else
    Result := [10, 16];
end;

function HealthDueHour(ASchedule: THealthSchedule; ANow: TDateTime): Integer;
var
  LHour: Integer;
begin
  Result := -1;
  for LHour in HealthHours(ASchedule) do
    if HourOf(ANow) >= LHour then
      Result := LHour;
end;

function THealthReport.FreeableBytes: Int64;
begin
  Result := TempBytes + JunkBytes;
end;

function THealthReport.Findings: Integer;
begin
  Result := Length(LowDisks) + Ord(PathIssues > 0) + Ord(StartupOn > HealthMaxStartup);
  if FreeableBytes >= HealthMinFreeable then
    Inc(Result);
end;

function THealthReport.Title: string;
begin
  if FreeableBytes >= HealthMinFreeable then
    Result := 'Manutenção: ' + SizeText(FreeableBytes) + ' para liberar'
  else
    Result := 'Manutenção do Windows';
end;

function THealthReport.Text: string;
var
  LParts: TArray<string>;
begin
  LParts := nil;
  if FreeableBytes >= HealthMinFreeable then
    LParts := LParts + [Format('temporários %s, lixo de build %s em %d projetos', [SizeText(TempBytes),
      SizeText(JunkBytes), JunkProjects])];
  if LowDisks <> nil then
    LParts := LParts + ['pouco espaço: ' + string.Join(', ', LowDisks)];
  if PathIssues > 0 then
    LParts := LParts + [Format('%d entradas quebradas ou repetidas no PATH', [PathIssues])];
  if StartupOn > HealthMaxStartup then
    LParts := LParts + [Format('%d programas iniciam com o Windows', [StartupOn])];
  Result := string.Join('; ', LParts) + '. Clique para ver na Limpeza.';
end;

function RunHealthScan(const AJunkRoots: TArray<string>; AJunkIdleDays: Integer): THealthReport;
var
  LSpot: TCleanSpot;
  LJunk: TJunkItem;
  LProjects: TArray<string>;
  LDisk: TDiskInfo;
  LEntry: TPathEntry;
  LItem: TStartupItem;
begin
  Result := Default(THealthReport);
  for LSpot in ScanCleanSpots do
    Inc(Result.TempBytes, LSpot.Size);
  LProjects := nil;
  for LJunk in ScanBuildJunk(AJunkRoots, AJunkIdleDays, nil, nil) do
  begin
    Inc(Result.JunkBytes, LJunk.Size);
    if IndexText(LJunk.Project, LProjects) < 0 then
      LProjects := LProjects + [LJunk.Project];
  end;
  Result.JunkProjects := Length(LProjects);
  for LDisk in ListDisks do
    if (LDisk.Total > 0) and (100 - LDisk.UsedPct < HealthMinFreePct) then
      Result.LowDisks := Result.LowDisks + [Format('%s %d%% livre', [LDisk.Drive, 100 - LDisk.UsedPct])];
  for LEntry in AnalyzePath(ReadUserPath,
    function(ADir: string): Boolean
    begin
      Result := TDirectory.Exists(ADir);
    end) do
    if LEntry.State in [psMissing, psDuplicate] then
      Inc(Result.PathIssues);
  for LItem in ListStartup do
    if LItem.Enabled then
      Inc(Result.StartupOn);
end;

end.
