unit Devbox.Wsl;

{ WSL: distros com o disco de cada uma, .wslconfig, backup e manutenção.
  - Distros: registro HKCU\Software\Microsoft\Windows\CurrentVersion\Lxss (uma subchave
    por distro: DistributionName, BasePath, Version; DefaultDistribution na chave mãe).
    O disco é BasePath\ext4.vhdx (ou VhdFileName, quando existir).
  - .wslconfig (%USERPROFILE%): só a seção [wsl2]; as outras linhas ficam como estão.
  - Compactar o disco: wsl --shutdown e diskpart (compact vdisk) elevado. Pede admin.
  Tudo aqui bloqueia (processo externo): chamar fora da thread de UI, menos as funções
  puras de texto (WslConfigGet/WslConfigSet) e ListWslDistros (só registro e um wsl -l). }

interface

uses
  System.SysUtils;

type
  TWslDistro = record
    Name: string;
    BasePath: string;
    VhdxPath: string;
    Version: Integer;
    IsDefault: Boolean;
    Running: Boolean;
    VhdxSize: Int64;       // 0 = não achou o arquivo
  end;
  TWslDistros = TArray<TWslDistro>;

function ListWslDistros: TWslDistros;
function WslConfigPath: string;
{ Valor de AKey na seção [wsl2] de AText ('' = não tem). }
function WslConfigGet(const AText, AKey: string): string;
{ AText com AKey=AValue na seção [wsl2] (cria a seção se faltar). AValue '' tira a chave. }
function WslConfigSet(const AText, AKey, AValue: string): string;

function WslShutdown(out AError: string): Boolean;
function WslSetDefault(const AName: string; out AError: string): Boolean;
function WslTerminate(const AName: string; out AError: string): Boolean;
{ Exporta para ADir\<nome>_aaaa-mm-dd_hhnn.tar. AFile = arquivo criado. }
function WslExport(const AName, ADir: string; out AFile, AError: string): Boolean;
{ Desliga o WSL e compacta o VHDX pelo diskpart elevado (UAC). }
function WslCompact(const AVhdx: string; out AError: string): Boolean;
{ Roda ACmd como root em cada distro ligada. Devolve o resumo por distro. }
function WslRunAsRootInRunning(const ACmd: string): string;
function WslRestartService(out AError: string): Boolean;
function WslUpdate(out AOutput: string): Boolean;
function WslVersionText: string;

implementation

uses
  Winapi.Windows,
  Winapi.ShellAPI,
  System.Win.Registry,
  System.Classes,
  System.IOUtils,
  System.StrUtils,
  Devbox.Sys;

const
  CLxssKey = 'Software\Microsoft\Windows\CurrentVersion\Lxss';
  CSection = '[wsl2]';
  CExportTimeoutMs = 60 * 60 * 1000;
  CCommandTimeoutMs = 120 * 1000;

function CleanPath(const APath: string): string;
begin
  Result := APath;
  if Result.StartsWith('\\?\') then
    Result := Result.Substring(4);
end;

function RunningNames: TArray<string>;
var
  LOut, LLine: string;
begin
  Result := nil;
  if RunCapture('wsl.exe -l --running -q', LOut) <> 0 then
    Exit;
  for LLine in LOut.Split([#10, #13], TStringSplitOptions.ExcludeEmpty) do
    if Trim(LLine) <> '' then
      Result := Result + [Trim(LLine)];
end;

function ListWslDistros: TWslDistros;
var
  LReg: TRegistry;
  LKeys: TStringList;
  LKey, LDefault, LFile: string;
  LDistro: TWslDistro;
  LRunning: TArray<string>;
begin
  Result := nil;
  LRunning := RunningNames;
  LReg := TRegistry.Create(KEY_READ);
  LKeys := TStringList.Create;
  try
    LReg.RootKey := HKEY_CURRENT_USER;
    if not LReg.OpenKeyReadOnly(CLxssKey) then
      Exit;
    LDefault := '';
    if LReg.ValueExists('DefaultDistribution') then
      LDefault := LReg.ReadString('DefaultDistribution');
    LReg.GetKeyNames(LKeys);
    LReg.CloseKey;
    for LKey in LKeys do
      if LReg.OpenKeyReadOnly(CLxssKey + '\' + LKey) then
      try
        if not LReg.ValueExists('DistributionName') then
          Continue;
        LDistro := Default(TWslDistro);
        LDistro.Name := LReg.ReadString('DistributionName');
        if LReg.ValueExists('BasePath') then
          LDistro.BasePath := CleanPath(LReg.ReadString('BasePath'));
        if LReg.ValueExists('Version') then
          LDistro.Version := LReg.ReadInteger('Version');
        LFile := 'ext4.vhdx';
        if LReg.ValueExists('VhdFileName') then
          LFile := LReg.ReadString('VhdFileName');
        LDistro.VhdxPath := TPath.Combine(LDistro.BasePath, LFile);
        if TFile.Exists(LDistro.VhdxPath) then
          LDistro.VhdxSize := TFile.GetSize(LDistro.VhdxPath)
        else
          LDistro.VhdxPath := '';
        LDistro.IsDefault := SameText(LKey, LDefault);
        LDistro.Running := IndexText(LDistro.Name, LRunning) >= 0;
        Result := Result + [LDistro];
      finally
        LReg.CloseKey;
      end;
  finally
    LKeys.Free;
    LReg.Free;
  end;
end;

function WslConfigPath: string;
begin
  Result := TPath.Combine(GetEnvironmentVariable('USERPROFILE'), '.wslconfig');
end;

{ Linhas da seção [wsl2]: ASectionStart (linha do cabeçalho, -1 se não tem) e ASectionEnd
  (primeira linha da próxima seção ou o fim). }
procedure FindSection(const ALines: TArray<string>; out ASectionStart, ASectionEnd: Integer);
var
  LIndex: Integer;
  LLine: string;
begin
  ASectionStart := -1;
  ASectionEnd := Length(ALines);
  for LIndex := 0 to High(ALines) do
  begin
    LLine := Trim(ALines[LIndex]);
    if LLine.StartsWith('[') then
      if ASectionStart < 0 then
      begin
        if SameText(LLine, CSection) then
          ASectionStart := LIndex;
      end
      else
      begin
        ASectionEnd := LIndex;
        Exit;
      end;
  end;
end;

function KeyOf(const ALine: string): string;
var
  LEq: Integer;
begin
  Result := '';
  LEq := Pos('=', ALine);
  if (LEq > 0) and not Trim(ALine).StartsWith('#') then
    Result := Trim(Copy(ALine, 1, LEq - 1));
end;

function WslConfigGet(const AText, AKey: string): string;
var
  LLines: TArray<string>;
  LStart, LEnd, LIndex: Integer;
begin
  Result := '';
  LLines := AText.Replace(#13, '').Split([#10]);
  FindSection(LLines, LStart, LEnd);
  if LStart < 0 then
    Exit;
  for LIndex := LStart + 1 to LEnd - 1 do
    if SameText(KeyOf(LLines[LIndex]), AKey) then
      Exit(Trim(Copy(LLines[LIndex], Pos('=', LLines[LIndex]) + 1, MaxInt)));
end;

function WslConfigSet(const AText, AKey, AValue: string): string;
var
  LLines: TArray<string>;
  LStart, LEnd, LIndex: Integer;
  LFound: Boolean;
begin
  LLines := AText.Replace(#13, '').Split([#10]);
  if (Length(LLines) = 1) and (LLines[0] = '') then
    LLines := nil;
  FindSection(LLines, LStart, LEnd);
  if LStart < 0 then
  begin
    if AValue = '' then
      Exit(AText);
    if (LLines <> nil) and (Trim(LLines[High(LLines)]) <> '') then
      LLines := LLines + [''];
    LLines := LLines + [CSection, AKey + '=' + AValue];
    Exit(string.Join(sLineBreak, LLines) + sLineBreak);
  end;
  LFound := False;
  for LIndex := LEnd - 1 downto LStart + 1 do
    if SameText(KeyOf(LLines[LIndex]), AKey) then
    begin
      LFound := True;
      if AValue = '' then
        Delete(LLines, LIndex, 1)
      else
        LLines[LIndex] := AKey + '=' + AValue;
    end;
  if not LFound and (AValue <> '') then
  begin
    // Depois da última linha com conteúdo da seção.
    LIndex := LEnd;
    while (LIndex > LStart + 1) and (Trim(LLines[LIndex - 1]) = '') do
      Dec(LIndex);
    Insert(AKey + '=' + AValue, LLines, LIndex);
  end;
  Result := string.Join(sLineBreak, LLines);
  if not Result.EndsWith(sLineBreak) then
    Result := Result + sLineBreak;
end;

function RunWsl(const AArgs: string; out AError: string; ATimeoutMs: Cardinal = CCommandTimeoutMs): Boolean;
var
  LOut: string;
begin
  Result := RunCapture('wsl.exe ' + AArgs, LOut, ATimeoutMs) = 0;
  AError := IfThen(Result, '', Trim(LOut));
end;

function WslShutdown(out AError: string): Boolean;
begin
  Result := RunWsl('--shutdown', AError);
end;

function WslSetDefault(const AName: string; out AError: string): Boolean;
begin
  Result := RunWsl('--set-default "' + AName + '"', AError);
end;

function WslTerminate(const AName: string; out AError: string): Boolean;
begin
  Result := RunWsl('--terminate "' + AName + '"', AError);
end;

function WslExport(const AName, ADir: string; out AFile, AError: string): Boolean;
begin
  ForceDirectories(ADir);
  AFile := TPath.Combine(ADir, Format('%s_%s.tar', [AName, FormatDateTime('yyyy-mm-dd_hhnn', Now)]));
  Result := RunWsl(Format('--export "%s" "%s"', [AName, AFile]), AError, CExportTimeoutMs);
end;

{ Roda AExe elevado (UAC) e espera. False se o usuário negou ou o código de saída não foi 0. }
function RunElevated(const AExe, AParams: string; out AError: string): Boolean;
var
  LInfo: TShellExecuteInfo;
  LCode: DWORD;
begin
  FillChar(LInfo, SizeOf(LInfo), 0);
  LInfo.cbSize := SizeOf(LInfo);
  LInfo.fMask := SEE_MASK_NOCLOSEPROCESS;
  LInfo.lpVerb := 'runas';
  LInfo.lpFile := PChar(AExe);
  LInfo.lpParameters := PChar(AParams);
  LInfo.nShow := SW_HIDE;
  if not ShellExecuteEx(@LInfo) then
  begin
    AError := 'Permissão de administrador negada.';
    Exit(False);
  end;
  try
    WaitForSingleObject(LInfo.hProcess, INFINITE);
    GetExitCodeProcess(LInfo.hProcess, LCode);
  finally
    CloseHandle(LInfo.hProcess);
  end;
  Result := LCode = 0;
  AError := IfThen(Result, '', Format('saiu com código %d', [LCode]));
end;

function WslCompact(const AVhdx: string; out AError: string): Boolean;
var
  LScript: string;
begin
  if not TFile.Exists(AVhdx) then
  begin
    AError := 'Disco não encontrado: ' + AVhdx;
    Exit(False);
  end;
  if not WslShutdown(AError) then
    Exit(False);
  LScript := TPath.Combine(TPath.GetTempPath, 'devbox-compact-vhdx.txt');
  TFile.WriteAllText(LScript, Format('select vdisk file="%s"'#13#10'attach vdisk readonly'#13#10 +
    'compact vdisk'#13#10'detach vdisk'#13#10, [AVhdx]), TEncoding.ASCII);
  try
    Result := RunElevated('diskpart.exe', '/s "' + LScript + '"', AError);
  finally
    TFile.Delete(LScript);
  end;
end;

function WslRunAsRootInRunning(const ACmd: string): string;
var
  LName, LOut: string;
  LCode: Integer;
begin
  Result := '';
  for LName in RunningNames do
  begin
    LCode := RunCapture(Format('wsl.exe -d "%s" -u root -- sh -c "%s"', [LName, ACmd]), LOut, CCommandTimeoutMs);
    Result := Result + Format('%s: %s', [LName, IfThen(LCode = 0, 'ok', 'falhou')]);
    if Trim(LOut) <> '' then
      Result := Result + ' (' + Copy(Trim(LOut).Replace(#13, '').Replace(#10, ' '), 1, 200) + ')';
    Result := Result + sLineBreak;
  end;
  if Result = '' then
    Result := 'Nenhuma distro ligada.';
end;

function WslRestartService(out AError: string): Boolean;
begin
  Result := RunElevated('powershell.exe', '-NoProfile -Command "Restart-Service LxssManager -Force"', AError);
end;

function WslUpdate(out AOutput: string): Boolean;
begin
  Result := RunCapture('wsl.exe --update', AOutput, 10 * 60 * 1000) = 0;
end;

function WslVersionText: string;
begin
  if RunCapture('wsl.exe --version', Result) <> 0 then
    Result := 'wsl --version não respondeu (WSL antigo ou ausente).';
  Result := Trim(Result.Replace(#13, ''));
end;

end.
