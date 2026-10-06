unit Devbox.SysInfo;

{ Recursos da máquina (CPU, memória, discos, processos que mais gastam) e o
  PATH do usuário (análise, limpeza e gravação com cópia para desfazer). }

interface

uses
  System.SysUtils,
  System.Generics.Collections;

type
  TPathState = (psOk, psMissing, psDuplicate, psEmpty);

  TPathEntry = record
    Raw: string;           // como está no PATH (pode ter %VAR%)
    Expanded: string;
    State: TPathState;
  end;
  TPathEntries = TArray<TPathEntry>;

  TDiskInfo = record
    Drive: string;
    Total, Free: Int64;
    function UsedPct: Integer;
  end;
  TDisks = TArray<TDiskInfo>;

  TProcInfo = record
    Pid: Cardinal;
    Name: string;
    CpuPct: Double;
    MemBytes: Int64;
  end;
  TProcInfos = TArray<TProcInfo>;

  { Mede CPU entre uma chamada e a próxima (o Windows dá tempos acumulados). }
  TCpuSampler = class
  private
    FLastIdle, FLastKernel, FLastUser: UInt64;
    FLastProc: TDictionary<Cardinal, UInt64>;
    FLastTick: UInt64;
  public
    constructor Create;
    destructor Destroy; override;
    { CPU total em % desde a última chamada. }
    function TotalCpu: Double;
    { Processos com CPU (% da máquina) e memória, os que mais gastam primeiro. }
    function TopProcesses(ALimit: Integer): TProcInfos;
  end;

{ Divide o PATH, expande %VAR% e marca: pasta que não existe, repetida (mesma
  pasta escrita diferente conta) e vazia. AExists decide se a pasta existe. }
function AnalyzePath(const APath: string; const AExists: TFunc<string, Boolean>): TPathEntries;

{ PATH limpo: sem vazias, sem repetidas e (se ADropMissing) sem as que não existem. }
function CleanPath(const AEntries: TPathEntries; ADropMissing: Boolean): string;

function ReadUserPath: string;
function ReadMachinePath: string;
{ Grava o PATH do usuário e avisa os programas abertos. }
procedure WriteUserPath(const APath: string);

{ Memória: usada e total em bytes. }
procedure MemoryInfo(out AUsed, ATotal: Int64);
function ListDisks: TDisks;

implementation

uses
  Winapi.Windows,
  Winapi.Messages,
  Winapi.TlHelp32,
  Winapi.PsAPI,
  System.Classes,
  System.StrUtils,
  System.Math,
  System.IOUtils,
  System.Win.Registry,
  System.Generics.Defaults;

function NormalizeDir(const ADir: string): string;
begin
  Result := LowerCase(ExcludeTrailingPathDelimiter(Trim(ADir)));
end;

function ExpandVars(const AText: string): string;
var
  Buf: array[0..32767] of Char;
  N: DWORD;
begin
  N := ExpandEnvironmentStrings(PChar(AText), Buf, Length(Buf));
  if (N > 0) and (N <= DWORD(Length(Buf))) then
    Result := Buf
  else
    Result := AText;
end;

function AnalyzePath(const APath: string; const AExists: TFunc<string, Boolean>): TPathEntries;
var
  Parts: TArray<string>;
  P: string;
  I: Integer;
  E: TPathEntry;
  Seen: TDictionary<string, Boolean>;
begin
  Result := nil;
  Seen := TDictionary<string, Boolean>.Create;
  try
    Parts := APath.Split([';']);
    for I := 0 to High(Parts) do
    begin
      P := Parts[I];
      E.Raw := P;
      E.Expanded := ExpandVars(Trim(P));
      if Trim(P) = '' then
        E.State := psEmpty
      else if Seen.ContainsKey(NormalizeDir(E.Expanded)) then
        E.State := psDuplicate
      else
      begin
        Seen.Add(NormalizeDir(E.Expanded), True);
        if AExists(E.Expanded) then
          E.State := psOk
        else
          E.State := psMissing;
      end;
      // Um ";" sobrando no fim é comum e inofensivo: não vira linha.
      if (E.State = psEmpty) and (I = High(Parts)) then
        Continue;
      Result := Result + [E];
    end;
  finally
    Seen.Free;
  end;
end;

function CleanPath(const AEntries: TPathEntries; ADropMissing: Boolean): string;
var
  E: TPathEntry;
begin
  Result := '';
  for E in AEntries do
    if (E.State = psOk) or ((E.State = psMissing) and not ADropMissing) then
      Result := Result + IfThen(Result <> '', ';') + Trim(E.Raw);
end;

function ReadEnvPath(ARoot: HKEY; const AKey: string): string;
var
  R: TRegistry;
begin
  Result := '';
  R := TRegistry.Create(KEY_READ);
  try
    R.RootKey := ARoot;
    if R.OpenKeyReadOnly(AKey) and R.ValueExists('Path') then
      Result := R.ReadString('Path');
  finally
    R.Free;
  end;
end;

function ReadUserPath: string;
begin
  Result := ReadEnvPath(HKEY_CURRENT_USER, 'Environment');
end;

function ReadMachinePath: string;
begin
  Result := ReadEnvPath(HKEY_LOCAL_MACHINE, 'SYSTEM\CurrentControlSet\Control\Session Manager\Environment');
end;

procedure WriteUserPath(const APath: string);
var
  R: TRegistry;
  Res: DWORD_PTR;
begin
  R := TRegistry.Create;
  try
    R.RootKey := HKEY_CURRENT_USER;
    if R.OpenKey('Environment', True) then
      // ExpandString: guarda %VAR% sem expandir, como o Windows faz.
      R.WriteExpandString('Path', APath);
  finally
    R.Free;
  end;
  SendMessageTimeout(HWND_BROADCAST, WM_SETTINGCHANGE, 0, LPARAM(PChar('Environment')), SMTO_ABORTIFHUNG, 2000, @Res);
end;

procedure MemoryInfo(out AUsed, ATotal: Int64);
var
  M: TMemoryStatusEx;
begin
  M.dwLength := SizeOf(M);
  GlobalMemoryStatusEx(M);
  ATotal := M.ullTotalPhys;
  AUsed := M.ullTotalPhys - M.ullAvailPhys;
end;

function TDiskInfo.UsedPct: Integer;
begin
  if Total <= 0 then
    Exit(0);
  Result := Round(100 * (Total - Free) / Total);
end;

function ListDisks: TDisks;
var
  Mask: DWORD;
  I: Integer;
  Root: string;
  D: TDiskInfo;
  FreeAvail, Total, Free: Int64;
begin
  Result := nil;
  Mask := GetLogicalDrives;
  for I := 0 to 25 do
    if Mask and (1 shl I) <> 0 then
    begin
      Root := Char(Ord('A') + I) + ':\';
      if GetDriveType(PChar(Root)) <> DRIVE_FIXED then
        Continue;
      if GetDiskFreeSpaceEx(PChar(Root), FreeAvail, Total, @Free) then
      begin
        D.Drive := Copy(Root, 1, 2);
        D.Total := Total;
        D.Free := Free;
        Result := Result + [D];
      end;
    end;
end;

{ TCpuSampler }

function FileTimeToU64(const F: TFileTime): UInt64;
begin
  Result := UInt64(F.dwHighDateTime) shl 32 or F.dwLowDateTime;
end;

constructor TCpuSampler.Create;
begin
  inherited Create;
  FLastProc := TDictionary<Cardinal, UInt64>.Create;
  TotalCpu;  // primeira leitura só guarda a base
end;

destructor TCpuSampler.Destroy;
begin
  FLastProc.Free;
  inherited;
end;

function TCpuSampler.TotalCpu: Double;
var
  Idle, Kernel, User: TFileTime;
  I, K, U, Busy, Total: UInt64;
begin
  Result := 0;
  if not GetSystemTimes(Idle, Kernel, User) then
    Exit;
  I := FileTimeToU64(Idle);
  K := FileTimeToU64(Kernel);
  U := FileTimeToU64(User);
  // Tempo de kernel inclui o ocioso.
  Total := (K - FLastKernel) + (U - FLastUser);
  Busy := Total - (I - FLastIdle);
  if (FLastKernel > 0) and (Total > 0) then
    Result := EnsureRange(100 * Busy / Total, 0, 100);
  FLastIdle := I;
  FLastKernel := K;
  FLastUser := U;
end;

function TCpuSampler.TopProcesses(ALimit: Integer): TProcInfos;
const
  PROCESS_QUERY_LIMITED_INFORMATION = $1000;
var
  Snap, H: THandle;
  E: TProcessEntry32;
  Creation, ExitT, Kernel, User: TFileTime;
  Mem: TProcessMemoryCounters;
  Now_, Elapsed, Cpu, Last: UInt64;
  Cores: Integer;
  Info: TProcInfo;
  List: TList<TProcInfo>;
  Seen: TDictionary<Cardinal, UInt64>;
  SysInfo: TSystemInfo;
begin
  GetSystemInfo(SysInfo);
  Cores := Max(1, SysInfo.dwNumberOfProcessors);
  Now_ := GetTickCount64;
  Elapsed := Now_ - FLastTick;
  List := TList<TProcInfo>.Create;
  Seen := TDictionary<Cardinal, UInt64>.Create;
  Snap := CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  try
    if Snap = INVALID_HANDLE_VALUE then
      Exit(nil);
    E.dwSize := SizeOf(E);
    if Process32First(Snap, E) then
      repeat
        if E.th32ProcessID = 0 then
          Continue;
        H := OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, False, E.th32ProcessID);
        if H = 0 then
          Continue;  // processo protegido (sistema, antivírus): fica de fora
        try
          Info.Pid := E.th32ProcessID;
          Info.Name := E.szExeFile;
          Info.CpuPct := 0;
          Info.MemBytes := 0;
          if GetProcessTimes(H, Creation, ExitT, Kernel, User) then
          begin
            Cpu := FileTimeToU64(Kernel) + FileTimeToU64(User);
            Seen.AddOrSetValue(Info.Pid, Cpu);
            // FileTime é em 100 ns; Elapsed em ms (1 ms = 10.000 unidades).
            if (FLastTick > 0) and (Elapsed > 0) and FLastProc.TryGetValue(Info.Pid, Last) and (Cpu >= Last) then
              Info.CpuPct := 100 * (Cpu - Last) / (Elapsed * 10000 * UInt64(Cores));
          end;
          FillChar(Mem, SizeOf(Mem), 0);
          Mem.cb := SizeOf(Mem);
          if GetProcessMemoryInfo(H, @Mem, SizeOf(Mem)) then
            Info.MemBytes := Mem.WorkingSetSize;
          List.Add(Info);
        finally
          CloseHandle(H);
        end;
      until not Process32Next(Snap, E);
  finally
    if Snap <> INVALID_HANDLE_VALUE then
      CloseHandle(Snap);
    FLastProc.Free;
    FLastProc := Seen;
    FLastTick := Now_;
  end;
  try
    List.Sort(TComparer<TProcInfo>.Construct(
      function(const A, B: TProcInfo): Integer
      begin
        Result := CompareValue(B.CpuPct, A.CpuPct);
        if Result = 0 then
          Result := CompareValue(B.MemBytes, A.MemBytes);
      end));
    Result := Copy(List.ToArray, 0, ALimit);
  finally
    List.Free;
  end;
end;

end.
