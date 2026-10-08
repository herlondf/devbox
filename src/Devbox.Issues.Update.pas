unit Devbox.Issues.Update;

{ Atualização automática pela release do GitHub. Só a cópia instalada
  (%LOCALAPPDATA%\Programs\Devbox) se atualiza; build de desenvolvimento nunca.
  Fluxo: FetchLatest (API pública) -> DownloadUpdate (confere SHA-256 do
  GitHub) -> RunInstaller (Inno Setup silencioso, reabre o Devbox no fim). }

interface

type
  TUpdateInfo = record
    Version: string;    // sem o "v"
    Url: string;        // download do instalador
    Sha256: string;     // hash informado pelo GitHub (minúsculo)
    Notes: string;
  end;

{ -1 se A < B, 0 se iguais, 1 se A > B. Aceita "v" na frente e partes faltando. }
function CompareVersions(const A, B: string): Integer;

{ True quando o exe roda da pasta do instalador. }
function IsInstalledCopy: Boolean;

{ Bloqueante. True e AInfo preenchido quando a última release é mais nova que
  AppVersion e tem o instalador. Levanta exceção em erro de rede. }
function FetchLatest(out AInfo: TUpdateInfo): Boolean;

{ Bloqueante. Baixa para a pasta temporária e confere o hash. Devolve o caminho. }
function DownloadUpdate(const AInfo: TUpdateInfo): string;

{ Roda o instalador silencioso. AShow = reabrir com a janela à mostra.
  O chamador sai do app logo depois. }
procedure RunInstaller(const APath: string; AShow: Boolean);

implementation

uses
  Devbox.Model,
  Devbox.I18n,
  Winapi.Windows,
  Winapi.ShellAPI,
  System.SysUtils,
  System.Classes,
  System.JSON,
  System.Hash,
  System.IOUtils,
  System.Net.URLClient,
  System.Net.HttpClient,
  Devbox.Issues.Model;

const
  LatestUrl = 'https://api.github.com/repos/herlondf/devbox/releases/latest';

function CompareVersions(const A, B: string): Integer;
var
  PA, PB: TArray<string>;
  I, X, Y: Integer;
begin
  PA := A.Trim.TrimLeft(['v', 'V']).Split(['.']);
  PB := B.Trim.TrimLeft(['v', 'V']).Split(['.']);
  for I := 0 to 2 do
  begin
    X := 0;
    Y := 0;
    if I < Length(PA) then
      X := StrToIntDef(PA[I], 0);
    if I < Length(PB) then
      Y := StrToIntDef(PB[I], 0);
    if X <> Y then
      Exit(Ord(X > Y) * 2 - 1);
  end;
  Result := 0;
end;

function IsInstalledCopy: Boolean;
begin
  Result := SameText(ExtractFilePath(ParamStr(0)),
    IncludeTrailingPathDelimiter(TPath.Combine(GetEnvironmentVariable('LOCALAPPDATA'), 'Programs\Devbox')));
end;

function NewClient: THTTPClient;
begin
  Result := THTTPClient.Create;
  Result.ConnectionTimeout := 15000;
  Result.ResponseTimeout := 120000;
  Result.HandleRedirects := True;
  Result.UserAgent := 'Devbox/' + AppVersion;
end;

function FetchLatest(out AInfo: TUpdateInfo): Boolean;
var
  Http: THTTPClient;
  Resp: IHTTPResponse;
  J: TJSONValue;
  Assets: TJSONArray;
  I: Integer;
  Name: string;
begin
  AInfo := Default(TUpdateInfo);
  Http := NewClient;
  try
    Resp := Http.Get(LatestUrl, nil, [TNameValuePair.Create('Accept', 'application/vnd.github+json')]);
    if Resp.StatusCode = 404 then
      Exit(False);  // ainda sem release
    if Resp.StatusCode <> 200 then
      raise Exception.CreateFmt(Tr('GitHub respondeu %d'), [Resp.StatusCode]);
    J := TJSONObject.ParseJSONValue(Resp.ContentAsString(TEncoding.UTF8));
  finally
    Http.Free;
  end;
  try
    AInfo.Version := J.GetValue<string>('tag_name', '').TrimLeft(['v', 'V']);
    AInfo.Notes := J.GetValue<string>('body', '');
    if J.TryGetValue<TJSONArray>('assets', Assets) then
      for I := 0 to Assets.Count - 1 do
      begin
        Name := Assets.Items[I].GetValue<string>('name', '');
        if Name.StartsWith('Devbox-Setup-', True) and Name.EndsWith('.exe', True) then
        begin
          AInfo.Url := Assets.Items[I].GetValue<string>('browser_download_url', '');
          AInfo.Sha256 := Assets.Items[I].GetValue<string>('digest', '').Replace('sha256:', '').ToLower;
        end;
      end;
  finally
    J.Free;
  end;
  Result := (AInfo.Url <> '') and (CompareVersions(AInfo.Version, AppVersion) > 0);
end;

function DownloadUpdate(const AInfo: TUpdateInfo): string;
var
  Http: THTTPClient;
  Resp: IHTTPResponse;
  F: TFileStream;
begin
  // Sem hash não instala: o arquivo poderia ser qualquer coisa.
  if AInfo.Sha256 = '' then
    raise Exception.Create(Tr('A release não informa o hash do instalador'));
  Result := TPath.Combine(TPath.GetTempPath, Format('Devbox-Setup-%s.exe', [AInfo.Version]));
  Http := NewClient;
  F := TFileStream.Create(Result, fmCreate);
  try
    Resp := Http.Get(AInfo.Url, F);
    if Resp.StatusCode <> 200 then
      raise Exception.CreateFmt(Tr('Download respondeu %d'), [Resp.StatusCode]);
  finally
    F.Free;
    Http.Free;
  end;
  if not SameText(THashSHA2.GetHashStringFromFile(Result), AInfo.Sha256) then
  begin
    TFile.Delete(Result);
    raise Exception.Create(Tr('O instalador baixado não confere com o hash da release'));
  end;
end;

procedure RunInstaller(const APath: string; AShow: Boolean);
var
  Args: string;
begin
  Args := '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /RELAUNCH=1';
  if AShow then
    Args := Args + ' /SHOW=1';
  if ShellExecute(0, 'open', PChar(APath), PChar(Args), nil, SW_SHOWNORMAL) <= 32 then
    RaiseLastOSError;
end;

end.
