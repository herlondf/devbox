unit Devbox.Cleanup;

{ Varreduras da tela de Limpeza: lixo de build de projetos parados, arquivos
  grandes ou sem uso, pastas vazias, temporários e caches, imagens órfãs de
  container e programas que iniciam com o Windows. Bloqueiam: rodar em thread. }

interface

uses
  System.SysUtils,
  System.Classes;

type
  TCancelFunc = TFunc<Boolean>;

  TJunkItem = record
    Path: string;
    Project: string;     // pasta do projeto dono do lixo
    Kind: string;        // node_modules, bin/obj (.NET), dcu (Delphi)...
    Size: Int64;
    IdleDays: Integer;   // dias desde a última mudança no código do projeto
  end;
  TJunkItems = TArray<TJunkItem>;

  TBigFile = record
    Path: string;
    Size: Int64;
    Modified: TDateTime;
  end;
  TBigFiles = TArray<TBigFile>;

  TCleanSpot = record
    Name: string;
    Paths: TArray<string>;
    Size: Int64;
    Files: Integer;
    Note: string;
  end;
  TCleanSpots = TArray<TCleanSpot>;

  TStartupSource = (ssUserRun, ssMachineRun, ssUserFolder, ssCommonFolder);

  TStartupItem = record
    Name: string;
    Command: string;
    Source: TStartupSource;
    Enabled: Boolean;
    function ReadOnly: Boolean;     // da máquina: só com admin
    function SourceText: string;
  end;
  TStartupItems = TArray<TStartupItem>;

  TDangling = record
    Distro, Engine: string;   // como TContainer: Distro '' = Windows
    Images: Integer;
    ImagesSize: Int64;
    Volumes: Integer;
    function Cli: string;
    function Where: string;
  end;
  TDanglings = TArray<TDangling>;

{ Tipo de lixo de build de uma pasta chamada ADirName, olhando os arquivos do
  pai (AParentFiles, só nomes). '' = não é lixo. Sem marcador do projeto, bin,
  build e target ficam de fora: podem ser código. }
function JunkKind(const ADirName: string; const AParentFiles: TArray<string>): string;

{ Tamanho de tudo dentro de APath. Não segue junção nem link simbólico. }
function DirSize(const APath: string; const ACancel: TCancelFunc = nil): Int64;

{ Lixo de build nas pastas de projeto dentro de ARoots, só de projetos sem
  mudança há AMinIdleDays dias ou mais. }
function ScanBuildJunk(const ARoots: TArray<string>; AMinIdleDays: Integer;
  const ACancel: TCancelFunc; const AProgress: TProc<string>): TJunkItems;

{ Arquivos a partir de AMinSize bytes sem mudança há AMinIdleDays dias (0 = qualquer
  data), os maiores primeiro, no máximo ALimit. }
function ScanBigFiles(const ARoot: string; AMinSize: Int64; AMinIdleDays, ALimit: Integer;
  const ACancel: TCancelFunc; const AProgress: TProc<string>): TBigFiles;

{ Pastas sem nenhum arquivo dentro (nem em subpastas). Só a de cima de cada
  árvore vazia entra. ARoot nunca entra. }
function ScanEmptyDirs(const ARoot: string; const ACancel: TCancelFunc): TArray<string>;

{ %TEMP% (arquivos de mais de um dia), caches do Chrome, Edge e Firefox e a Lixeira. }
function ScanCleanSpots: TCleanSpots;

{ Apaga. ARecycle = manda para a Lixeira. Devolve quantos não deu para apagar
  (em uso, sem permissão); AFreed soma o que saiu. }
function DeletePaths(const APaths: TArray<string>; ARecycle: Boolean; out AFreed: Int64): Integer;

{ Esvazia a Lixeira sem perguntar (quem chama já confirmou). }
function EmptyRecycleBin: Boolean;

function ListStartup: TStartupItems;
{ Liga ou desliga como o Gerenciador de Tarefas faz (StartupApproved), sem
  apagar a entrada. False = sem permissão (itens da máquina). }
function SetStartupEnabled(const AItem: TStartupItem; AEnabled: Boolean): Boolean;

{ Imagens sem tag e volumes sem uso em cada motor que responde. }
function ScanDangling: TDanglings;

{ "1,2 GB" ou "350 MB" do docker; número puro do podman. }
function ParseSizeText(const AText: string): Int64;

function SizeText(ABytes: Int64): string;

implementation

uses
  Winapi.Windows,
  Winapi.ShellAPI,
  Winapi.ShlObj,
  Winapi.KnownFolders,
  Winapi.ActiveX,
  System.IOUtils,
  System.StrUtils,
  System.Math,
  System.DateUtils,
  System.JSON,
  System.Win.Registry,
  System.Generics.Collections,
  System.Generics.Defaults,
  Devbox.Model,
  Devbox.Sys;

function SizeText(ABytes: Int64): string;
begin
  if ABytes < 1024 then
    Result := Format('%d B', [ABytes])
  else if ABytes < 1024 * 1024 then
    Result := Format('%.1f KB', [ABytes / 1024])
  else if ABytes < Int64(1024) * 1024 * 1024 then
    Result := Format('%.1f MB', [ABytes / (1024 * 1024)])
  else
    Result := Format('%.2f GB', [ABytes / (1024 * 1024 * 1024)]);
end;

function Cancelled(const ACancel: TCancelFunc): Boolean;
begin
  Result := Assigned(ACancel) and ACancel();
end;

function HasFile(const AFiles: TArray<string>; const AMasks: array of string): Boolean;
var
  F, M: string;
begin
  for F in AFiles do
    for M in AMasks do
      if M.StartsWith('*') then
      begin
        if EndsText(Copy(M, 2, MaxInt), F) then
          Exit(True);
      end
      else if SameText(F, M) then
        Exit(True);
  Result := False;
end;

function JunkKind(const ADirName: string; const AParentFiles: TArray<string>): string;
const
  DotNet: array[0..4] of string = ('*.csproj', '*.fsproj', '*.vbproj', '*.sln', '*.dproj');
  Gradle: array[0..3] of string = ('build.gradle', 'build.gradle.kts', 'settings.gradle', 'settings.gradle.kts');
begin
  Result := '';
  case IndexText(ADirName, ['node_modules', '.next', '.nuxt', 'bin', 'obj', 'dcu', '__history',
    '__recovery', 'target', 'build', '.gradle', '__pycache__', '.pytest_cache', '.mypy_cache',
    'Win32', 'Win64']) of
    0, 1, 2:
      if HasFile(AParentFiles, ['package.json']) then
        Result := 'Node (' + ADirName + ')';
    3, 4:
      if HasFile(AParentFiles, DotNet) then
        Result := '.NET/Delphi (' + ADirName + ')';
    5, 14, 15:
      if HasFile(AParentFiles, ['*.dproj']) then
        Result := 'Delphi (' + ADirName + ')';
    6, 7:
      Result := 'Delphi IDE (' + ADirName + ')';
    8:
      if HasFile(AParentFiles, ['Cargo.toml']) then
        Result := 'Rust (target)'
      else if HasFile(AParentFiles, ['pom.xml']) then
        Result := 'Maven (target)';
    9:
      if HasFile(AParentFiles, Gradle) then
        Result := 'Gradle (build)'
      else if HasFile(AParentFiles, ['CMakeLists.txt']) then
        Result := 'CMake (build)';
    10:
      if HasFile(AParentFiles, Gradle) then
        Result := 'Gradle (.gradle)';
    11, 12, 13:
      Result := 'Python (' + ADirName + ')';
  end;
end;

{ Junção, link simbólico e pasta do sistema: não entra (evita laço e lixo alheio). }
function SkipDir(const ASr: TSearchRec): Boolean;
begin
  Result := (ASr.Attr and faSymLink <> 0) or (ASr.Attr and FILE_ATTRIBUTE_REPARSE_POINT <> 0) or
    (ASr.Attr and faSysFile <> 0) or SameText(ASr.Name, '.git') or SameText(ASr.Name, '$RECYCLE.BIN') or
    SameText(ASr.Name, 'System Volume Information');
end;

function DirSize(const APath: string; const ACancel: TCancelFunc): Int64;
var
  Sr: TSearchRec;
begin
  Result := 0;
  if Cancelled(ACancel) then
    Exit;
  if FindFirst(IncludeTrailingPathDelimiter(APath) + '*', faAnyFile, Sr) <> 0 then
    Exit;
  try
    repeat
      if (Sr.Name = '.') or (Sr.Name = '..') then
        Continue;
      if Sr.Attr and faDirectory <> 0 then
      begin
        if (Sr.Attr and FILE_ATTRIBUTE_REPARSE_POINT) = 0 then
          Inc(Result, DirSize(IncludeTrailingPathDelimiter(APath) + Sr.Name, ACancel));
      end
      else
        Inc(Result, Sr.Size);
    until FindNext(Sr) <> 0;
  finally
    System.SysUtils.FindClose(Sr);
  end;
end;

{ Arquivos e pastas direto em APath, sem descer. }
procedure ListDir(const APath: string; out AFiles, ADirs: TArray<string>; out ANewest: TDateTime);
var
  Sr: TSearchRec;
begin
  AFiles := nil;
  ADirs := nil;
  ANewest := 0;
  if FindFirst(IncludeTrailingPathDelimiter(APath) + '*', faAnyFile, Sr) <> 0 then
    Exit;
  try
    repeat
      if (Sr.Name = '.') or (Sr.Name = '..') then
        Continue;
      if Sr.Attr and faDirectory <> 0 then
      begin
        if not SkipDir(Sr) then
          ADirs := ADirs + [Sr.Name];
      end
      else
      begin
        AFiles := AFiles + [Sr.Name];
        ANewest := Max(ANewest, Sr.TimeStamp);
      end;
    until FindNext(Sr) <> 0;
  finally
    System.SysUtils.FindClose(Sr);
  end;
end;

{ Última mudança no código: arquivo mais novo fora das pastas de lixo e do
  .git, até 4 níveis (fundo o bastante para src/, rápido o bastante). }
function NewestSource(const APath: string; ADepth: Integer): TDateTime;
var
  Files, Dirs: TArray<string>;
  D: string;
begin
  ListDir(APath, Files, Dirs, Result);
  if ADepth <= 0 then
    Exit;
  for D in Dirs do
    if JunkKind(D, Files) = '' then
      Result := Max(Result, NewestSource(TPath.Combine(APath, D), ADepth - 1));
end;

function ScanBuildJunk(const ARoots: TArray<string>; AMinIdleDays: Integer;
  const ACancel: TCancelFunc; const AProgress: TProc<string>): TJunkItems;
const
  CMaxDepth = 8;
var
  Found: TJunkItems;
  Idle: TDictionary<string, Integer>;

  function ProjectIdle(const AProject: string): Integer;
  begin
    if not Idle.TryGetValue(AProject, Result) then
    begin
      Result := DaysBetween(Now, NewestSource(AProject, 4));
      Idle.Add(AProject, Result);
    end;
  end;

  procedure Walk(const APath: string; ADepth: Integer);
  var
    Files, Dirs: TArray<string>;
    Newest: TDateTime;
    D, Kind: string;
    Item: TJunkItem;
  begin
    if Cancelled(ACancel) or (ADepth > CMaxDepth) then
      Exit;
    if Assigned(AProgress) then
      AProgress(APath);
    ListDir(APath, Files, Dirs, Newest);
    for D in Dirs do
    begin
      Kind := JunkKind(D, Files);
      if Kind = '' then
      begin
        Walk(TPath.Combine(APath, D), ADepth + 1);
        Continue;
      end;
      if ProjectIdle(APath) < AMinIdleDays then
        Continue;
      Item.Path := TPath.Combine(APath, D);
      Item.Project := APath;
      Item.Kind := Kind;
      Item.IdleDays := ProjectIdle(APath);
      Item.Size := DirSize(Item.Path, ACancel);
      Found := Found + [Item];
    end;
  end;

var
  R: string;
begin
  Found := nil;
  Idle := TDictionary<string, Integer>.Create;
  try
    for R in ARoots do
      if TDirectory.Exists(R) then
        Walk(ExcludeTrailingPathDelimiter(R), 0);
  finally
    Idle.Free;
  end;
  TArray.Sort<TJunkItem>(Found, TComparer<TJunkItem>.Construct(
    function(const A, B: TJunkItem): Integer
    begin
      Result := CompareValue(B.Size, A.Size);
    end));
  Result := Found;
end;

function ScanBigFiles(const ARoot: string; AMinSize: Int64; AMinIdleDays, ALimit: Integer;
  const ACancel: TCancelFunc; const AProgress: TProc<string>): TBigFiles;
var
  Found: TList<TBigFile>;
  Limit: TDateTime;

  procedure Walk(const APath: string);
  var
    Sr: TSearchRec;
    F: TBigFile;
  begin
    if Cancelled(ACancel) then
      Exit;
    if FindFirst(IncludeTrailingPathDelimiter(APath) + '*', faAnyFile, Sr) <> 0 then
      Exit;
    try
      repeat
        if (Sr.Name = '.') or (Sr.Name = '..') then
          Continue;
        if Sr.Attr and faDirectory <> 0 then
        begin
          if not SkipDir(Sr) then
          begin
            if Assigned(AProgress) then
              AProgress(IncludeTrailingPathDelimiter(APath) + Sr.Name);
            Walk(IncludeTrailingPathDelimiter(APath) + Sr.Name);
          end;
        end
        else if (Sr.Size >= AMinSize) and ((AMinIdleDays <= 0) or (Sr.TimeStamp <= Limit)) then
        begin
          F.Path := IncludeTrailingPathDelimiter(APath) + Sr.Name;
          F.Size := Sr.Size;
          F.Modified := Sr.TimeStamp;
          Found.Add(F);
        end;
      until FindNext(Sr) <> 0;
    finally
      System.SysUtils.FindClose(Sr);
    end;
  end;

begin
  Limit := IncDay(Now, -AMinIdleDays);
  Found := TList<TBigFile>.Create;
  try
    Walk(ExcludeTrailingPathDelimiter(ARoot));
    Found.Sort(TComparer<TBigFile>.Construct(
      function(const A, B: TBigFile): Integer
      begin
        Result := CompareValue(B.Size, A.Size);
      end));
    Result := Copy(Found.ToArray, 0, ALimit);
  finally
    Found.Free;
  end;
end;

function ScanEmptyDirs(const ARoot: string; const ACancel: TCancelFunc): TArray<string>;
var
  Found: TArray<string>;

  { True = APath não tem arquivo nenhum, nem nas subpastas. Quem tem conteúdo
    põe na lista as filhas vazias: cada uma é a raiz de uma árvore vazia. }
  function Empty(const APath: string): Boolean;
  var
    Sr: TSearchRec;
    Subs: TArray<string>;
    SubEmpty: TArray<Boolean>;
    I: Integer;
  begin
    Result := not Cancelled(ACancel);
    Subs := nil;
    if FindFirst(IncludeTrailingPathDelimiter(APath) + '*', faAnyFile, Sr) = 0 then
      try
        repeat
          if (Sr.Name = '.') or (Sr.Name = '..') then
            Continue;
          if (Sr.Attr and faDirectory <> 0) and not SkipDir(Sr) then
            Subs := Subs + [IncludeTrailingPathDelimiter(APath) + Sr.Name]
          else
            Result := False;  // arquivo, ou pasta que não se mexe (.git, junção)
        until FindNext(Sr) <> 0;
      finally
        System.SysUtils.FindClose(Sr);
      end;
    SetLength(SubEmpty, Length(Subs));
    for I := 0 to High(Subs) do
    begin
      SubEmpty[I] := Empty(Subs[I]);
      if not SubEmpty[I] then
        Result := False;
    end;
    if not Result then
      for I := 0 to High(Subs) do
        if SubEmpty[I] then
          Found := Found + [Subs[I]];
  end;

var
  Root: string;
  Sr: TSearchRec;
begin
  Found := nil;
  Root := ExcludeTrailingPathDelimiter(ARoot);
  // Raiz toda vazia: a raiz não entra, mas as filhas sim.
  if Empty(Root) and (FindFirst(Root + '\*', faDirectory, Sr) = 0) then
    try
      repeat
        if (Sr.Name <> '.') and (Sr.Name <> '..') and (Sr.Attr and faDirectory <> 0) then
          Found := Found + [Root + '\' + Sr.Name];
      until FindNext(Sr) <> 0;
    finally
      System.SysUtils.FindClose(Sr);
    end;
  Result := Found;
end;

function KnownFolder(const AId: TGUID): string;
var
  P: PWideChar;
begin
  Result := '';
  if Succeeded(SHGetKnownFolderPath(AId, 0, 0, P)) then
  begin
    Result := P;
    CoTaskMemFree(P);
  end;
end;

function ScanCleanSpots: TCleanSpots;
const
  COldTempDays = 1;

  procedure AddSpot(const AName, ANote: string; const APaths: TArray<string>);
  var
    S: TCleanSpot;
    P: string;
  begin
    S.Name := AName;
    S.Note := ANote;
    S.Paths := nil;
    S.Size := 0;
    S.Files := 0;
    for P in APaths do
      if TDirectory.Exists(P) then
      begin
        S.Paths := S.Paths + [P];
        Inc(S.Size, DirSize(P));
      end;
    if S.Paths <> nil then
      Result := Result + [S];
  end;

var
  Local, Temp, F, Profile: string;
  Old: TArray<string>;
  Spot: TCleanSpot;
  Info: TSHQueryRBInfo;
begin
  Result := nil;
  Local := GetEnvironmentVariable('LOCALAPPDATA');
  // Temporários: só arquivos de mais de um dia (os novos podem estar em uso).
  Temp := TPath.GetTempPath;
  Old := nil;
  Spot := Default(TCleanSpot);
  Spot.Name := 'Temporários do usuário';
  Spot.Note := 'arquivos com mais de 1 dia em ' + Temp;
  for F in TDirectory.GetFiles(Temp, '*', TSearchOption.soTopDirectoryOnly) do
    if DaysBetween(Now, TFile.GetLastWriteTime(F)) >= COldTempDays then
    begin
      Old := Old + [F];
      Inc(Spot.Size, TFile.GetSize(F));
    end;
  for F in TDirectory.GetDirectories(Temp) do
    if DaysBetween(Now, TDirectory.GetLastWriteTime(F)) >= COldTempDays then
    begin
      Old := Old + [F];
      Inc(Spot.Size, DirSize(F));
    end;
  Spot.Paths := Old;
  Spot.Files := Length(Old);
  if Old <> nil then
    Result := Result + [Spot];
  AddSpot('Cache do Chrome', 'feche o Chrome antes',
    [TPath.Combine(Local, 'Google\Chrome\User Data\Default\Cache'),
     TPath.Combine(Local, 'Google\Chrome\User Data\Default\Code Cache')]);
  AddSpot('Cache do Edge', 'feche o Edge antes',
    [TPath.Combine(Local, 'Microsoft\Edge\User Data\Default\Cache'),
     TPath.Combine(Local, 'Microsoft\Edge\User Data\Default\Code Cache')]);
  if TDirectory.Exists(TPath.Combine(Local, 'Mozilla\Firefox\Profiles')) then
    for Profile in TDirectory.GetDirectories(TPath.Combine(Local, 'Mozilla\Firefox\Profiles')) do
      AddSpot('Cache do Firefox (' + ExtractFileName(Profile) + ')', 'feche o Firefox antes',
        [TPath.Combine(Profile, 'cache2')]);
  AddSpot('Cache do npm', 'o npm baixa de novo quando precisar', [TPath.Combine(Local, 'npm-cache')]);
  AddSpot('Cache do pip', 'o pip baixa de novo quando precisar', [TPath.Combine(Local, 'pip\Cache')]);
  AddSpot('Cache do NuGet', 'o NuGet baixa de novo quando precisar', [TPath.Combine(Local, 'NuGet\v3-cache')]);
  // Lixeira: tamanho pela API; esvaziar é um caso à parte.
  FillChar(Info, SizeOf(Info), 0);
  Info.cbSize := SizeOf(Info);
  if Succeeded(SHQueryRecycleBin(nil, @Info)) and (Info.i64NumItems > 0) then
  begin
    Spot := Default(TCleanSpot);
    Spot.Name := 'Lixeira';
    Spot.Note := 'esvaziar não tem volta';
    Spot.Size := Info.i64Size;
    Spot.Files := Info.i64NumItems;
    Result := Result + [Spot];
  end;
end;

function EmptyRecycleBin: Boolean;
begin
  Result := Succeeded(SHEmptyRecycleBin(0, nil, SHERB_NOCONFIRMATION or SHERB_NOPROGRESSUI or SHERB_NOSOUND));
end;

function DeletePaths(const APaths: TArray<string>; ARecycle: Boolean; out AFreed: Int64): Integer;
var
  P: string;
  Op: TSHFileOpStruct;
  Size: Int64;
begin
  Result := 0;
  AFreed := 0;
  for P in APaths do
  begin
    if TDirectory.Exists(P) then
      Size := DirSize(P)
    else if TFile.Exists(P) then
      Size := TFile.GetSize(P)
    else
      Continue;
    FillChar(Op, SizeOf(Op), 0);
    Op.wFunc := FO_DELETE;
    Op.pFrom := PChar(P + #0);
    Op.fFlags := FOF_NOCONFIRMATION or FOF_SILENT or FOF_NOERRORUI;
    if ARecycle then
      Op.fFlags := Op.fFlags or FOF_ALLOWUNDO;
    if (SHFileOperation(Op) = 0) and not Op.fAnyOperationsAborted and
      not TDirectory.Exists(P) and not TFile.Exists(P) then
      Inc(AFreed, Size)
    else
      Inc(Result);
  end;
end;

{ Programas que iniciam com o Windows }

const
  RunKey = 'Software\Microsoft\Windows\CurrentVersion\Run';
  ApprovedRun = 'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run';
  ApprovedFolder = 'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder';

function TStartupItem.ReadOnly: Boolean;
begin
  Result := Source in [ssMachineRun, ssCommonFolder];
end;

function TStartupItem.SourceText: string;
const
  Names: array[TStartupSource] of string = ('Registro do usuário', 'Registro da máquina',
    'Pasta Inicializar', 'Pasta Inicializar (todos)');
begin
  Result := Names[Source];
end;

function ApprovalRoot(ASource: TStartupSource; out AKey: string): HKEY;
begin
  if ASource in [ssUserRun, ssMachineRun] then
    AKey := ApprovedRun
  else
    AKey := ApprovedFolder;
  if ASource in [ssUserRun, ssUserFolder] then
    Result := HKEY_CURRENT_USER
  else
    Result := HKEY_LOCAL_MACHINE;
end;

{ Primeiro byte do valor em StartupApproved: par = ligado, ímpar = desligado.
  Sem valor = ligado. }
function ApprovedEnabled(ASource: TStartupSource; const AName: string): Boolean;
var
  R: TRegistry;
  Key: string;
  B: TBytes;
begin
  Result := True;
  R := TRegistry.Create(KEY_READ);
  try
    R.RootKey := ApprovalRoot(ASource, Key);
    if R.OpenKeyReadOnly(Key) and R.ValueExists(AName) then
    begin
      SetLength(B, R.GetDataSize(AName));
      if Length(B) > 0 then
      begin
        R.ReadBinaryData(AName, B[0], Length(B));
        Result := not Odd(B[0]);
      end;
    end;
  finally
    R.Free;
  end;
end;

function ListStartup: TStartupItems;

  procedure FromRegistry(ARoot: HKEY; ASource: TStartupSource);
  var
    R: TRegistry;
    Names: TStringList;
    N: string;
    It: TStartupItem;
  begin
    R := TRegistry.Create(KEY_READ);
    Names := TStringList.Create;
    try
      R.RootKey := ARoot;
      if not R.OpenKeyReadOnly(RunKey) then
        Exit;
      R.GetValueNames(Names);
      for N in Names do
      begin
        It.Name := N;
        It.Command := R.ReadString(N);
        It.Source := ASource;
        It.Enabled := ApprovedEnabled(ASource, N);
        Result := Result + [It];
      end;
    finally
      Names.Free;
      R.Free;
    end;
  end;

  procedure FromFolder(const APath: string; ASource: TStartupSource);
  var
    F: string;
    It: TStartupItem;
  begin
    if not TDirectory.Exists(APath) then
      Exit;
    for F in TDirectory.GetFiles(APath) do
    begin
      if SameText(ExtractFileName(F), 'desktop.ini') then
        Continue;
      It.Name := ExtractFileName(F);
      It.Command := F;
      It.Source := ASource;
      It.Enabled := ApprovedEnabled(ASource, It.Name);
      Result := Result + [It];
    end;
  end;

begin
  Result := nil;
  FromRegistry(HKEY_CURRENT_USER, ssUserRun);
  FromRegistry(HKEY_LOCAL_MACHINE, ssMachineRun);
  FromFolder(KnownFolder(FOLDERID_Startup), ssUserFolder);
  FromFolder(KnownFolder(FOLDERID_CommonStartup), ssCommonFolder);
end;

function SetStartupEnabled(const AItem: TStartupItem; AEnabled: Boolean): Boolean;
var
  R: TRegistry;
  Key: string;
  B: array[0..11] of Byte;
  Ft: TFileTime;
begin
  Result := False;
  if AItem.ReadOnly then
    Exit;
  FillChar(B, SizeOf(B), 0);
  if AEnabled then
    B[0] := 2
  else
  begin
    // Desligado: 3 e a hora em que desligou (é o que o Gerenciador de Tarefas grava).
    B[0] := 3;
    GetSystemTimeAsFileTime(Ft);
    Move(Ft, B[4], SizeOf(Ft));
  end;
  R := TRegistry.Create;
  try
    R.RootKey := ApprovalRoot(AItem.Source, Key);
    if R.OpenKey(Key, True) then
    begin
      R.WriteBinaryData(AItem.Name, B, SizeOf(B));
      Result := True;
    end;
  finally
    R.Free;
  end;
end;

{ Imagens órfãs }

function TDangling.Cli: string;
begin
  if Distro = '' then
    Result := Engine
  else
    Result := Format('wsl.exe -d %s -e %s', [Distro, Engine]);
end;

function TDangling.Where: string;
begin
  Result := IfThen(Distro = '', 'Windows', Distro) + ' · ' + Engine;
end;

function ParseSizeText(const AText: string): Int64;
const
  Units: array[0..4] of string = ('B', 'KB', 'MB', 'GB', 'TB');
var
  S, NumPart, UnitPart: string;
  I: Integer;
  V: Double;
  Fmt: TFormatSettings;
begin
  S := Trim(AText);
  if TryStrToInt64(S, Result) then
    Exit;
  Result := 0;
  I := 1;
  while (I <= Length(S)) and CharInSet(S[I], ['0'..'9', '.', ',']) do
    Inc(I);
  NumPart := StringReplace(Copy(S, 1, I - 1), ',', '.', []);
  UnitPart := UpperCase(Trim(Copy(S, I, MaxInt)));
  Fmt := TFormatSettings.Invariant;
  if not TryStrToFloat(NumPart, V, Fmt) then
    Exit;
  for I := 0 to High(Units) do
    if UnitPart = Units[I] then
      Exit(Round(V * Power(1000, I)));  // docker usa potência de 10
end;

function ScanDangling: TDanglings;

  function Try_(const ADistro, AEngine: string; out D: TDangling): Boolean;
  var
    Output, Line: string;
    V: TJSONValue;
    Lines: TStringList;
  begin
    D := Default(TDangling);
    D.Distro := ADistro;
    D.Engine := AEngine;
    Result := RunCapture(D.Cli + ' images -f dangling=true --format "{{json .}}"', Output) = 0;
    if not Result then
      Exit;
    Lines := TStringList.Create;
    try
      Lines.Text := Output;
      for Line in Lines do
      begin
        if not Trim(Line).StartsWith('{') then
          Continue;
        V := TJSONObject.ParseJSONValue(Line);
        if V = nil then
          Continue;
        try
          Inc(D.Images);
          Inc(D.ImagesSize, ParseSizeText(V.GetValue<string>('Size', '0')));
        finally
          V.Free;
        end;
      end;
      if RunCapture(D.Cli + ' volume ls -q -f dangling=true', Output) = 0 then
      begin
        Lines.Text := Output;
        for Line in Lines do
          if Trim(Line) <> '' then
            Inc(D.Volumes);
      end;
    finally
      Lines.Free;
    end;
  end;

var
  Out1, Out2: string;
  Dist: TDistro;
  D: TDangling;
begin
  Result := nil;
  if Try_('', 'docker', D) then
    Result := Result + [D];
  if RunCapture('wsl.exe -l -q', Out1) <> 0 then
    Exit;
  RunCapture('wsl.exe -l --running -q', Out2);
  for Dist in ParseWslLists(Out1, Out2) do
    if Dist.Running and not StartsText('docker-desktop', Dist.Name) then
      if Try_(Dist.Name, 'podman', D) or Try_(Dist.Name, 'docker', D) then
        Result := Result + [D];
end;

end.
