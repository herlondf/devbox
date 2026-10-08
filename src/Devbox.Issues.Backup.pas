unit Devbox.Issues.Backup;

{ Exporta e importa contas, tags, issues acompanhadas à mão e configurações
  num JSON. Tokens vão cifrados com a DPAPI do Windows (só o mesmo usuário do
  Windows decifra); em outra máquina a conta volta sem token e pede de novo.
  Importar mescla: conta com o mesmo nome e provedor é atualizada, o resto entra. }

interface

uses
  Devbox.Issues.Store;

type
  TBackupResult = record
    Accounts, Tags, Settings: Integer;
    TokensRestored, TokensMissing: Integer;
    function Summary: string;
  end;

{ AAiTargets: alvos das chaves de IA no Credential Manager ('Vigia:ai:...'). }
procedure ExportBackup(AStore: TIssueStore; const APath: string; AWithSecrets: Boolean = True;
  const AAiTargets: TArray<string> = nil);
function ImportBackup(AStore: TIssueStore; const APath: string; AWithSecrets: Boolean = True): TBackupResult;

{ DPAPI do usuário atual, em base64. Unprotect devolve '' se não decifrar. }
function ProtectText(const AText: string): string;
function UnprotectText(const ABase64: string): string;

implementation

uses
  Devbox.Model,
  Devbox.I18n,
  Winapi.Windows,
  System.SysUtils,
  System.Classes,
  System.JSON,
  System.IOUtils,
  System.NetEncoding,
  System.Generics.Collections,
  Devbox.Issues.Model,
  Devbox.Secrets;

const
  BackupFormat = 1;
  // Estado de execução, não preferência: não viaja no backup.
  SkippedSettings: array[0..9] of string = ('migr_', 'summary_last', 'update_last', 'ai_risk_last',
    'ai_eod_last', 'ai_eod_draft', 'ai_ci_', 'usd_brl', 'account_filter', 'repo_filter');

type
  TDataBlob = record
    cbData: DWORD;
    pbData: PByte;
  end;
  PDataBlob = ^TDataBlob;

function CryptProtectData(pDataIn: PDataBlob; szDataDescr: PWideChar; pOptionalEntropy: PDataBlob;
  pvReserved: Pointer; pPromptStruct: Pointer; dwFlags: DWORD; pDataOut: PDataBlob): BOOL; stdcall;
  external 'crypt32.dll';
function CryptUnprotectData(pDataIn: PDataBlob; ppszDataDescr: PPWideChar; pOptionalEntropy: PDataBlob;
  pvReserved: Pointer; pPromptStruct: Pointer; dwFlags: DWORD; pDataOut: PDataBlob): BOOL; stdcall;
  external 'crypt32.dll';

const
  CRYPTPROTECT_UI_FORBIDDEN = 1;

function ProtectText(const AText: string): string;
var
  Plain: TBytes;
  InB, OutB: TDataBlob;
  Cipher: TBytes;
begin
  Result := '';
  if AText = '' then
    Exit;
  Plain := TEncoding.UTF8.GetBytes(AText);
  InB.cbData := Length(Plain);
  InB.pbData := @Plain[0];
  if not CryptProtectData(@InB, 'Vigia', nil, nil, nil, CRYPTPROTECT_UI_FORBIDDEN, @OutB) then
    RaiseLastOSError;
  try
    SetLength(Cipher, OutB.cbData);
    Move(OutB.pbData^, Cipher[0], OutB.cbData);
  finally
    LocalFree(HLOCAL(OutB.pbData));
  end;
  Result := TNetEncoding.Base64String.EncodeBytesToString(Cipher).Replace(#13#10, '');
end;

function UnprotectText(const ABase64: string): string;
var
  Cipher: TBytes;
  InB, OutB: TDataBlob;
  Plain: TBytes;
begin
  Result := '';
  if ABase64 = '' then
    Exit;
  try
    Cipher := TNetEncoding.Base64String.DecodeStringToBytes(ABase64);
  except
    on EEncodingError do
      Exit;
  end;
  if Cipher = nil then
    Exit;
  InB.cbData := Length(Cipher);
  InB.pbData := @Cipher[0];
  // Outro usuário ou outra máquina: a DPAPI recusa e o token fica para redigitar.
  if not CryptUnprotectData(@InB, nil, nil, nil, nil, CRYPTPROTECT_UI_FORBIDDEN, @OutB) then
    Exit;
  try
    SetLength(Plain, OutB.cbData);
    Move(OutB.pbData^, Plain[0], OutB.cbData);
  finally
    LocalFree(HLOCAL(OutB.pbData));
  end;
  Result := TEncoding.UTF8.GetString(Plain);
end;

function TBackupResult.Summary: string;
begin
  Result := Format(Tr('%d conta(s), %d tag(s), %d configuração(ões).'), [Accounts, Tags, Settings]);
  if TokensMissing > 0 then
    Result := Result + Format(Tr(' %d token(s) não vieram: edite a conta e cole de novo.'), [TokensMissing]);
end;

function IsAiTarget(const ATarget: string): Boolean;
begin
  // 'Vigia:anthropic' é a chave de antes dos provedores; o app ainda lê.
  Result := ATarget.StartsWith('Vigia:ai:') or SameText(ATarget, 'Vigia:anthropic');
end;

function Skipped(const AName: string): Boolean;
var
  P: string;
begin
  for P in SkippedSettings do
    if AName.StartsWith(P) then
      Exit(True);
  Result := False;
end;

function TagKeyPart(const AManual: string): string;
begin
  // ItemTagKey = 'idconta|CHAVE'
  Result := AManual.Substring(AManual.IndexOf('|') + 1);
end;

procedure ExportBackup(AStore: TIssueStore; const APath: string; AWithSecrets: Boolean;
  const AAiTargets: TArray<string>);
var
  Root, O, Sets, Keys: TJSONObject;
  Arr, Manual: TJSONArray;
  A: TAccount;
  T: TTag;
  K: string;
  S: TPair<string, string>;
  Names: TDictionary<Integer, string>;
begin
  Root := TJSONObject.Create;
  Names := TDictionary<Integer, string>.Create;
  try
    Root.AddPair('vigia_backup', TJSONNumber.Create(BackupFormat));
    Root.AddPair('app_version', AppVersion);
    Root.AddPair('exported_at', FormatDateTime('yyyy-mm-dd"T"hh:nn:ss', Now));

    Arr := TJSONArray.Create;
    Root.AddPair('accounts', Arr);
    for A in AStore.ListAccounts do
    begin
      Names.AddOrSetValue(A.Id, A.Name);
      O := TJSONObject.Create;
      Arr.AddElement(O);
      O.AddPair('name', A.Name);
      O.AddPair('kind', TJSONNumber.Create(Ord(A.Kind)));
      O.AddPair('base_url', A.BaseUrl);
      O.AddPair('login', A.Login);
      O.AddPair('enabled', TJSONBool.Create(A.Enabled));
      O.AddPair('events', TJSONNumber.Create(Word(A.Events)));
      O.AddPair('due_days', TJSONNumber.Create(A.DueDays));
      O.AddPair('due_field', A.DueField);
      O.AddPair('warn_days', TJSONNumber.Create(A.WarnDays));
      O.AddPair('critical_days', TJSONNumber.Create(A.CriticalDays));
      O.AddPair('my_prs', TJSONBool.Create(A.MyPrs));
      O.AddPair('own_repos', TJSONBool.Create(A.OwnRepos));
      O.AddPair('mentions', TJSONBool.Create(A.Mentions));
      O.AddPair('extra_query', A.ExtraQuery);
      O.AddPair('include', A.IncludeList);
      O.AddPair('exclude', A.ExcludeList);
      O.AddPair('poll_minutes', TJSONNumber.Create(A.PollMinutes));
      Manual := TJSONArray.Create;
      for K in AStore.ListManualKeys(A.Id) do
        Manual.Add(K);
      O.AddPair('manual', Manual);
      if AWithSecrets then
        O.AddPair('token_dpapi', ProtectText(LoadSecret(A.SecretTarget)));
    end;

    Arr := TJSONArray.Create;
    Root.AddPair('tags', Arr);
    for T in AStore.ListTags do
    begin
      if not Names.ContainsKey(T.AccountId) then
        Continue;
      O := TJSONObject.Create;
      Arr.AddElement(O);
      O.AddPair('account', Names[T.AccountId]);
      O.AddPair('name', T.Name);
      O.AddPair('keywords', T.Keywords);
      Manual := TJSONArray.Create;
      for K in T.Manual do
        Manual.Add(TagKeyPart(K));
      O.AddPair('manual', Manual);
    end;

    Sets := TJSONObject.Create;
    Root.AddPair('settings', Sets);
    for S in AStore.ListSettings do
      if not Skipped(S.Key) then
        Sets.AddPair(S.Key, S.Value);

    if AWithSecrets then
    begin
      Keys := TJSONObject.Create;
      Root.AddPair('ai_keys_dpapi', Keys);
      for K in AAiTargets do
        if IsAiTarget(K) and (LoadSecret(K) <> '') then
          Keys.AddPair(K, ProtectText(LoadSecret(K)));
    end;

    TFile.WriteAllText(APath, Root.Format(2), TEncoding.UTF8);
  finally
    Names.Free;
    Root.Free;
  end;
end;

function ImportBackup(AStore: TIssueStore; const APath: string; AWithSecrets: Boolean): TBackupResult;
var
  Root: TJSONValue;
  Arr, Manual: TJSONArray;
  O: TJSONObject;
  Existing: TArray<TAccount>;
  A, E: TAccount;
  Ids: TDictionary<string, Integer>;
  T, Found: TTag;
  I, J: Integer;
  Token: string;
  P: TJSONPair;
begin
  Result := Default(TBackupResult);
  Root := TJSONObject.ParseJSONValue(TFile.ReadAllText(APath, TEncoding.UTF8));
  if not (Root is TJSONObject) or (Root.GetValue<Integer>('vigia_backup', 0) <> BackupFormat) then
  begin
    Root.Free;
    raise Exception.Create(Tr('Arquivo não é um backup das issues (nem do Vigia)'));
  end;
  Ids := TDictionary<string, Integer>.Create;
  try
    Existing := AStore.ListAccounts;
    if Root.TryGetValue<TJSONArray>('accounts', Arr) then
      for I := 0 to Arr.Count - 1 do
      begin
        O := Arr.Items[I] as TJSONObject;
        A := Default(TAccount);
        A.Name := O.GetValue<string>('name', '');
        A.Kind := TProviderKind(O.GetValue<Integer>('kind', 0));
        // Mesmo nome e provedor: atualiza a conta que já existe (mantém o id e o token).
        for E in Existing do
          if SameText(E.Name, A.Name) and (E.Kind = A.Kind) then
            A.Id := E.Id;
        A.BaseUrl := O.GetValue<string>('base_url', '');
        A.Login := O.GetValue<string>('login', '');
        A.Enabled := O.GetValue<Boolean>('enabled', True);
        A.Events := TEventKinds(Word(O.GetValue<Integer>('events', 0)));
        A.DueDays := O.GetValue<Integer>('due_days', 2);
        A.DueField := O.GetValue<string>('due_field', '');
        A.WarnDays := O.GetValue<Integer>('warn_days', 5);
        A.CriticalDays := O.GetValue<Integer>('critical_days', 2);
        A.MyPrs := O.GetValue<Boolean>('my_prs', False);
        A.OwnRepos := O.GetValue<Boolean>('own_repos', False);
        A.Mentions := O.GetValue<Boolean>('mentions', False);
        A.ExtraQuery := O.GetValue<string>('extra_query', '');
        A.IncludeList := O.GetValue<string>('include', '');
        A.ExcludeList := O.GetValue<string>('exclude', '');
        A.PollMinutes := O.GetValue<Integer>('poll_minutes', 0);
        AStore.SaveAccount(A);
        Ids.AddOrSetValue(A.Name.ToUpper, A.Id);
        Inc(Result.Accounts);
        if O.TryGetValue<TJSONArray>('manual', Manual) then
          for J := 0 to Manual.Count - 1 do
            AStore.AddManualKey(A.Id, Manual.Items[J].Value);
        if AWithSecrets then
        begin
          Token := UnprotectText(O.GetValue<string>('token_dpapi', ''));
          if Token <> '' then
          begin
            SaveSecret(A.SecretTarget, A.Login, Token);
            Inc(Result.TokensRestored);
          end
          else if LoadSecret(A.SecretTarget) = '' then
            Inc(Result.TokensMissing);
        end;
      end;

    if Root.TryGetValue<TJSONArray>('tags', Arr) then
      for I := 0 to Arr.Count - 1 do
      begin
        O := Arr.Items[I] as TJSONObject;
        if not Ids.ContainsKey(O.GetValue<string>('account', '').ToUpper) then
          Continue;
        T := Default(TTag);
        T.AccountId := Ids[O.GetValue<string>('account', '').ToUpper];
        T.Name := O.GetValue<string>('name', '');
        for Found in AStore.ListTags do
          if (Found.AccountId = T.AccountId) and SameText(Found.Name, T.Name) then
            T.Id := Found.Id;
        T.Keywords := O.GetValue<string>('keywords', '');
        AStore.SaveTag(T);
        if O.TryGetValue<TJSONArray>('manual', Manual) then
          for J := 0 to Manual.Count - 1 do
            AStore.SetItemTag(T.Id, T.AccountId, Manual.Items[J].Value, True);
        Inc(Result.Tags);
      end;

    if Root.FindValue('settings') is TJSONObject then
      for P in TJSONObject(Root.FindValue('settings')) do
        if not Skipped(P.JsonString.Value) then
        begin
          AStore.SetSetting(P.JsonString.Value, P.JsonValue.Value);
          Inc(Result.Settings);
        end;

    if AWithSecrets and (Root.FindValue('ai_keys_dpapi') is TJSONObject) then
      for P in TJSONObject(Root.FindValue('ai_keys_dpapi')) do
        // Só alvos de chave de IA: um arquivo editado não grava credencial qualquer.
        if IsAiTarget(P.JsonString.Value) then
        begin
          Token := UnprotectText(P.JsonValue.Value);
          if Token <> '' then
            SaveSecret(P.JsonString.Value, '', Token);
        end;
  finally
    Ids.Free;
    Root.Free;
  end;
end;

end.
