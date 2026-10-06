unit Devbox.Jobs;

{ Agendador e avisos de fim: tipos, próxima execução (puro, testado) e as
  checagens dos avisos (processo, porta, container). }

interface

uses
  System.SysUtils;

type
  TJobKind = (jkInterval, jkDaily, jkWeekly);

  TJob = record
    Id: Integer;
    Name: string;
    Command: string;       // roda com cmd.exe /c: pipe e comando interno funcionam
    WorkDir: string;
    Kind: TJobKind;
    EveryMin: Integer;     // jkInterval
    AtMin: Integer;        // jkDaily/jkWeekly: minuto do dia (0..1439)
    Weekdays: Integer;     // jkWeekly: bit 0 = domingo ... bit 6 = sábado
    Enabled: Boolean;
    NotifyOk: Boolean;     // avisa também quando dá certo (falha sempre avisa)
    NextRun: TDateTime;
    LastRun: TDateTime;
    LastExit: Integer;     // -1 = nunca rodou
    { "a cada 15 min", "todo dia às 08:30", "seg, qua, sex às 18:00" }
    function WhenText: string;
  end;
  TJobs = TArray<TJob>;

  TJobRun = record
    JobId: Integer;
    Started: TDateTime;
    DurationMs: Int64;
    ExitCode: Integer;
    Output: string;        // últimas linhas
  end;
  TJobRuns = TArray<TJobRun>;

  TWatchKind = (wkProcess, wkPort, wkContainer);

  { Aviso de fim: dispara uma vez quando o alvo some e depois sai da lista. }
  TWatch = record
    Id: Integer;
    Kind: TWatchKind;
    Target: string;        // processo: nome ou pid:123; porta: número; container: id
    Cli: string;           // container: comando do motor (docker, wsl -d X -e podman)
    Caption: string;       // como aparece na lista e no aviso
    CreatedAt: TDateTime;
  end;
  TWatches = TArray<TWatch>;

const
  WeekdayNames: array[0..6] of string = ('dom', 'seg', 'ter', 'qua', 'qui', 'sex', 'sáb');
  WatchKindNames: array[TWatchKind] of string = ('Processo', 'Porta', 'Container');

{ Próxima execução depois de AFrom. 0 = nunca (semanal sem dia marcado). }
function NextRunAfter(const AJob: TJob; AFrom: TDateTime): TDateTime;

{ "08:30" -> 510; -1 se inválido. }
function ParseClock(const AText: string): Integer;
function ClockText(AMinutes: Integer): string;

{ Últimas ALines linhas de AText. }
function TailLines(const AText: string; ALines: Integer): string;

{ True enquanto o alvo existe (processo vivo, porta escutando, container ligado).
  Bloqueia (container chama o motor): rodar fora da thread de UI. }
function WatchAlive(const AWatch: TWatch): Boolean;

implementation

uses
  Winapi.Windows,
  Winapi.TlHelp32,
  System.Classes,
  System.DateUtils,
  System.StrUtils,
  System.Math,
  Devbox.Model,
  Devbox.Sys;

function ClockText(AMinutes: Integer): string;
begin
  Result := Format('%.2d:%.2d', [AMinutes div 60, AMinutes mod 60]);
end;

function ParseClock(const AText: string): Integer;
var
  Parts: TArray<string>;
  H, M: Integer;
begin
  Result := -1;
  Parts := Trim(AText).Split([':', 'h']);
  if (Length(Parts) < 1) or (Length(Parts) > 2) or not TryStrToInt(Parts[0], H) then
    Exit;
  M := 0;
  if (Length(Parts) = 2) and (Parts[1] <> '') and not TryStrToInt(Parts[1], M) then
    Exit;
  if InRange(H, 0, 23) and InRange(M, 0, 59) then
    Result := H * 60 + M;
end;

function TJob.WhenText: string;
var
  I: Integer;
  Days: string;
begin
  case Kind of
    jkInterval:
      if EveryMin mod 60 = 0 then
        Result := Format('a cada %d h', [EveryMin div 60])
      else
        Result := Format('a cada %d min', [EveryMin]);
    jkDaily:
      Result := 'todo dia às ' + ClockText(AtMin);
  else
    Days := '';
    for I := 0 to 6 do
      if Weekdays and (1 shl I) <> 0 then
        Days := Days + IfThen(Days <> '', ', ') + WeekdayNames[I];
    Result := IfThen(Days = '', 'nenhum dia', Days) + ' às ' + ClockText(AtMin);
  end;
end;

function NextRunAfter(const AJob: TJob; AFrom: TDateTime): TDateTime;
var
  Day: TDateTime;
  I: Integer;
begin
  case AJob.Kind of
    jkInterval:
      Result := IncMinute(AFrom, Max(AJob.EveryMin, 1));
    jkDaily:
      begin
        Result := DateOf(AFrom) + AJob.AtMin / MinsPerDay;
        if Result <= AFrom then
          Result := Result + 1;
      end;
  else
    Result := 0;
    if AJob.Weekdays and $7F = 0 then
      Exit;
    // Hoje ainda vale se o horário não passou; depois, os próximos 7 dias.
    for I := 0 to 7 do
    begin
      Day := DateOf(AFrom) + I;
      // DayOfWeek: 1 = domingo.
      if (AJob.Weekdays and (1 shl (DayOfWeek(Day) - 1)) <> 0) and
        (Day + AJob.AtMin / MinsPerDay > AFrom) then
        Exit(Day + AJob.AtMin / MinsPerDay);
    end;
  end;
end;

function TailLines(const AText: string; ALines: Integer): string;
var
  L: TStringList;
  I: Integer;
begin
  L := TStringList.Create;
  try
    L.Text := AText;
    while (L.Count > 0) and (Trim(L[L.Count - 1]) = '') do
      L.Delete(L.Count - 1);
    Result := '';
    for I := Max(0, L.Count - ALines) to L.Count - 1 do
      Result := Result + L[I] + IfThen(I < L.Count - 1, #13#10);
  finally
    L.Free;
  end;
end;

function ProcessAlive(const ATarget: string): Boolean;
var
  Snap: THandle;
  E: TProcessEntry32;
  Pid: Integer;
  ByPid: Boolean;
begin
  Result := False;
  ByPid := StartsText('pid:', ATarget) and TryStrToInt(Copy(ATarget, 5, MaxInt), Pid);
  Snap := CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  if Snap = INVALID_HANDLE_VALUE then
    Exit(True);  // sem como olhar: não dispara aviso falso
  try
    E.dwSize := SizeOf(E);
    if Process32First(Snap, E) then
      repeat
        if (ByPid and (Integer(E.th32ProcessID) = Pid)) or
          (not ByPid and SameText(E.szExeFile, ATarget)) then
          Exit(True);
      until not Process32Next(Snap, E);
  finally
    CloseHandle(Snap);
  end;
end;

function PortAlive(const ATarget: string): Boolean;
var
  P: TListenPort;
begin
  for P in ListListenPorts do
    if IntToStr(P.Port) = ATarget then
      Exit(True);
  Result := False;
end;

function ContainerAlive(const AWatch: TWatch): Boolean;
var
  Output: string;
  Code: Integer;
begin
  Code := RunCapture(AWatch.Cli + ' inspect -f "{{.State.Running}}" ' + AWatch.Target, Output);
  // Motor fora do ar ou container apagado contam como "parou"; erro de
  // tempo esgotado não (o motor pode só estar lento).
  if Code = -2 then
    Exit(True);
  Result := (Code = 0) and SameText(Trim(Output), 'true');
end;

function WatchAlive(const AWatch: TWatch): Boolean;
begin
  case AWatch.Kind of
    wkProcess: Result := ProcessAlive(AWatch.Target);
    wkPort: Result := PortAlive(AWatch.Target);
  else
    Result := ContainerAlive(AWatch);
  end;
end;

end.
