unit Devbox.Git;

{ Repositórios Git locais: acha as pastas com .git e lê branch, mudanças e quanto está
  à frente ou atrás do remoto (um "git status --porcelain=v2 --branch" por repositório). }

interface

type
  TGitRepo = record
    Path: string;
    Name: string;
    Branch: string;
    Upstream: string;     // vazio: branch sem remoto
    Ahead, Behind: Integer;
    Changed: Integer;     // arquivos mudados ou novos
    Error: string;
  end;
  TGitRepos = TArray<TGitRepo>;

{ Pastas com .git debaixo de ARoots (separadas por ;), até ADepth níveis. Pula pastas
  ocultas, AppData, node_modules e afins. }
function FindGitRepos(const ARoots: string; ADepth: Integer = 3): TArray<string>;

{ Lê a saída do "git status --porcelain=v2 --branch" no repositório. }
procedure ParseGitStatus(const AOutput: string; var ARepo: TGitRepo);

{ Roda o git no repositório (fora da tela: demora). }
function ReadGitRepo(const APath: string): TGitRepo;

{ Diff para a IA escrever commit ou PR: o que está no stage; sem stage, tudo que mudou.
  Corta em AMaxChars. }
function GitDiffText(const APath: string; AMaxChars: Integer = 12000): string;

implementation

uses
  System.SysUtils,
  System.StrUtils,
  System.Classes,
  System.IOUtils,
  Devbox.Sys;

const
  CSkipDirs: array[0..8] of string = ('node_modules', 'AppData', 'vendor', 'bin', 'obj', 'dist', 'build',
    'target', '__pycache__');
  CGitTimeoutMs = 15000;

function FindGitRepos(const ARoots: string; ADepth: Integer): TArray<string>;
var
  LFound: TArray<string>;

  procedure Walk(const ADir: string; ALevel: Integer);
  var
    LSub, LName: string;
  begin
    if TDirectory.Exists(TPath.Combine(ADir, '.git')) then
    begin
      LFound := LFound + [ExcludeTrailingPathDelimiter(ADir)];
      Exit;  // repositório dentro de repositório: fica o de fora
    end;
    if ALevel >= ADepth then
      Exit;
    try
      for LSub in TDirectory.GetDirectories(ADir) do
      begin
        LName := ExtractFileName(LSub);
        if LName.StartsWith('.') or MatchText(LName, CSkipDirs) or
          (faHidden and FileGetAttr(LSub) <> 0) then
          Continue;
        Walk(LSub, ALevel + 1);
      end;
    except
      // Pasta sem permissão: segue com as outras.
    end;
  end;

var
  LRoot: string;
begin
  LFound := nil;
  for LRoot in ARoots.Split([';'], TStringSplitOptions.ExcludeEmpty) do
    if TDirectory.Exists(Trim(LRoot)) then
      Walk(Trim(LRoot), 0);
  Result := LFound;
end;

procedure ParseGitStatus(const AOutput: string; var ARepo: TGitRepo);
var
  LLine: string;
  LParts: TArray<string>;
begin
  ARepo.Changed := 0;
  for LLine in AOutput.Split([#10]) do
  begin
    if LLine.StartsWith('# branch.head ') then
      ARepo.Branch := Trim(Copy(LLine, 15, MaxInt))
    else if LLine.StartsWith('# branch.upstream ') then
      ARepo.Upstream := Trim(Copy(LLine, 19, MaxInt))
    else if LLine.StartsWith('# branch.ab ') then
    begin
      // "# branch.ab +2 -1"
      LParts := Trim(LLine).Split([' ']);
      if Length(LParts) = 4 then
      begin
        ARepo.Ahead := StrToIntDef(Copy(LParts[2], 2, MaxInt), 0);
        ARepo.Behind := StrToIntDef(Copy(LParts[3], 2, MaxInt), 0);
      end;
    end
    else if (Length(LLine) > 2) and CharInSet(LLine[1], ['1', '2', 'u', '?']) and (LLine[2] = ' ') then
      Inc(ARepo.Changed);
  end;
end;

function ReadGitRepo(const APath: string): TGitRepo;
var
  LOutput: string;
begin
  Result := Default(TGitRepo);
  Result.Path := APath;
  Result.Name := ExtractFileName(APath);
  if RunCapture('git status --porcelain=v2 --branch', LOutput, CGitTimeoutMs, APath) <> 0 then
    Result.Error := Trim(LOutput)
  else
    ParseGitStatus(LOutput, Result);
end;

function GitDiffText(const APath: string; AMaxChars: Integer): string;
var
  LStat, LDiff: string;
begin
  RunCapture('git diff --cached --stat', LStat, CGitTimeoutMs, APath);
  if Trim(LStat) <> '' then
    RunCapture('git diff --cached', LDiff, CGitTimeoutMs, APath)
  else
  begin
    RunCapture('git status --short', LStat, CGitTimeoutMs, APath);
    RunCapture('git diff', LDiff, CGitTimeoutMs, APath);
  end;
  Result := Trim(LStat) + sLineBreak + sLineBreak + LDiff;
  if Length(Result) > AMaxChars then
    Result := Copy(Result, 1, AMaxChars) + sLineBreak + '[... diff cortado]';
end;

end.
