unit Devbox.AI;

{ IA: uma pergunta, uma resposta. Anthropic (Messages API) ou qualquer
  endpoint compatível com OpenAI (Ollama, gateway próprio). Sem SDK oficial
  para Delphi, vai por HTTP direto. A chave fica no Credential Manager.
  Bloqueia: chamar fora da thread de UI. }

interface

uses
  System.SysUtils;

type
  TAIProvider = (apAnthropic, apOpenAI);

  TAIConfig = record
    Provider: TAIProvider;
    BaseUrl: string;      // OpenAI-compatível: ex. http://localhost:11434/v1
    Model: string;
    Key: string;
    function Ready: Boolean;
  end;

  TAIAction = (aaExplain, aaSummarize, aaTranslate, aaImprove, aaCommit, aaExplainLog, aaCommand);

const
  AIProviderNames: array[TAIProvider] of string = ('Anthropic (Claude)', 'Compatível com OpenAI');
  AIActionNames: array[aaExplain..aaCommit] of string = ('Explicar', 'Resumir', 'Traduzir (pt ↔ en)',
    'Melhorar o texto', 'Mensagem de commit (do diff)');
  DefaultAnthropicModel = 'claude-opus-5-5';

{ Lê provedor, endereço e modelo das preferências e a chave do Credential Manager. }
function LoadAIConfig: TAIConfig;
procedure SaveAIKey(AProvider: TAIProvider; const AKey: string);

{ Pergunta. False com a mensagem de erro em AAnswer. }
function AskAI(const AConfig: TAIConfig; const ASystem, APrompt: string; out AAnswer: string;
  AMaxTokens: Integer = 2048): Boolean;

{ Instrução de sistema e texto do pedido de cada ação. }
function ActionPrompt(AAction: TAIAction; const AText: string; out ASystem: string): string;

// Resposta do "comando": {"shell":"powershell|cmd|wsl","command":"...","explanation":"..."}
function ParseCommandAnswer(const AAnswer: string; out AShell, ACommand, AExplanation: string): Boolean;

implementation

uses
  System.Classes,
  System.JSON,
  System.StrUtils,
  System.Net.HttpClient,
  System.Net.URLClient,
  Devbox.Store,
  Devbox.Usage,
  Devbox.Secrets;

const
  CTimeoutMs = 120000;
  // Texto grande demais custa caro e passa do limite: corta no começo.
  CMaxInput = 60000;

function SecretTarget(AProvider: TAIProvider): string;
begin
  Result := 'Devbox:ai:' + IntToStr(Ord(AProvider));
end;

function TAIConfig.Ready: Boolean;
begin
  // Anthropic precisa de chave; o compatível com OpenAI precisa do endereço
  // (Ollama local roda sem chave).
  if Provider = apAnthropic then
    Result := (Model <> '') and (Key <> '')
  else
    Result := (Model <> '') and (BaseUrl <> '');
end;

function LoadAIConfig: TAIConfig;
begin
  Result.Provider := TAIProvider(StrToIntDef(Store.GetSetting('ai_provider', '0'), 0));
  Result.BaseUrl := Store.GetSetting('ai_base_url');
  Result.Model := Store.GetSetting('ai_model', IfThen(Result.Provider = apAnthropic, DefaultAnthropicModel, ''));
  Result.Key := LoadSecret(SecretTarget(Result.Provider));
  if (Result.Key = '') and (Result.Provider = apAnthropic) then
    Result.Key := GetEnvironmentVariable('ANTHROPIC_API_KEY');
end;

procedure SaveAIKey(AProvider: TAIProvider; const AKey: string);
begin
  if AKey = '' then
    DeleteSecret(SecretTarget(AProvider))
  else
    SaveSecret(SecretTarget(AProvider), 'devbox', AKey);
end;

function Post(const AUrl, ABody: string; const AHeaders: TNetHeaders; out AResponse: string): Integer;
var
  Http: THTTPClient;
  Body: TStringStream;
  Resp: IHTTPResponse;
begin
  Http := THTTPClient.Create;
  Body := TStringStream.Create(ABody, TEncoding.UTF8);
  try
    Http.ConnectionTimeout := 10000;
    Http.ResponseTimeout := CTimeoutMs;
    Resp := Http.Post(AUrl, Body, nil, AHeaders);
    AResponse := Resp.ContentAsString(TEncoding.UTF8);
    Result := Resp.StatusCode;
  finally
    Body.Free;
    Http.Free;
  end;
end;

function ErrorText(const AResponse: string; ACode: Integer): string;
var
  V: TJSONValue;
  Msg: string;
begin
  Result := Format('HTTP %d', [ACode]);
  V := TJSONObject.ParseJSONValue(AResponse);
  try
    if (V <> nil) and (V.TryGetValue<string>('error.message', Msg) or V.TryGetValue<string>('error', Msg)) then
      Result := Result + ': ' + Msg;
  finally
    V.Free;
  end;
end;

function AskAI(const AConfig: TAIConfig; const ASystem, APrompt: string; out AAnswer: string;
  AMaxTokens: Integer): Boolean;
var
  Req, Msg: TJSONObject;
  Msgs, Blocks: TJSONArray;
  V: TJSONValue;
  Block: TJSONValue;
  Resp, Url, Text, Prompt: string;
  Code: Integer;
  Headers: TNetHeaders;
  Usage: TAiUsage;
begin
  Result := False;
  AAnswer := '';
  if not AConfig.Ready then
  begin
    AAnswer := 'Configure a IA em Configurações (provedor, modelo e chave)';
    Exit;
  end;
  Prompt := APrompt;
  if Length(Prompt) > CMaxInput then
    Prompt := '[início cortado]'#10 + Copy(Prompt, Length(Prompt) - CMaxInput + 1, MaxInt);
  Req := TJSONObject.Create;
  try
    Req.AddPair('model', AConfig.Model);
    Req.AddPair('max_tokens', TJSONNumber.Create(AMaxTokens));
    Msgs := TJSONArray.Create;
    if AConfig.Provider = apAnthropic then
      Req.AddPair('system', ASystem)
    else
    begin
      Msg := TJSONObject.Create;
      Msg.AddPair('role', 'system');
      Msg.AddPair('content', ASystem);
      Msgs.Add(Msg);
    end;
    Msg := TJSONObject.Create;
    Msg.AddPair('role', 'user');
    Msg.AddPair('content', Prompt);
    Msgs.Add(Msg);
    Req.AddPair('messages', Msgs);
    if AConfig.Provider = apAnthropic then
    begin
      Url := 'https://api.anthropic.com/v1/messages';
      Headers := [TNetHeader.Create('x-api-key', AConfig.Key), TNetHeader.Create('anthropic-version', '2023-06-01'),
        TNetHeader.Create('content-type', 'application/json')];
    end
    else
    begin
      Url := AConfig.BaseUrl.TrimRight(['/']) + '/chat/completions';
      Headers := [TNetHeader.Create('content-type', 'application/json')];
      if AConfig.Key <> '' then
        Headers := Headers + [TNetHeader.Create('Authorization', 'Bearer ' + AConfig.Key)];
    end;
    try
      Code := Post(Url, Req.ToJSON, Headers, Resp);
    except
      on E: Exception do
      begin
        AAnswer := 'Sem resposta: ' + E.Message;
        Exit;
      end;
    end;
  finally
    Req.Free;
  end;
  if Code <> 200 then
  begin
    AAnswer := ErrorText(Resp, Code);
    Exit;
  end;
  V := TJSONObject.ParseJSONValue(Resp);
  try
    if V = nil then
    begin
      AAnswer := 'Resposta que não é JSON';
      Exit;
    end;
    Text := '';
    if AConfig.Provider = apAnthropic then
    begin
      // A resposta vem em blocos; junta os de texto.
      if V.TryGetValue<TJSONArray>('content', Blocks) then
        for Block in Blocks do
          if Block.GetValue<string>('type', '') = 'text' then
            Text := Text + Block.GetValue<string>('text', '');
    end
    else
      V.TryGetValue<string>('choices[0].message.content', Text);
    // Uso para o painel de custos (Ollama local também responde, mas não cobra).
    Usage := Default(TAiUsage);
    Usage.Model := AConfig.Model;
    Usage.Kind := 'pergunta';
    if AConfig.Provider = apAnthropic then
    begin
      Usage.Provider := 'anthropic';
      Usage.InputTokens := V.GetValue<Int64>('usage.input_tokens', 0);
      Usage.OutputTokens := V.GetValue<Int64>('usage.output_tokens', 0);
    end
    else
    begin
      Usage.Provider := 'openai-compat';
      Usage.InputTokens := V.GetValue<Int64>('usage.prompt_tokens', 0);
      Usage.OutputTokens := V.GetValue<Int64>('usage.completion_tokens', 0);
    end;
    if Usage.InputTokens + Usage.OutputTokens > 0 then
      UsageAdd(Usage);
    AAnswer := Trim(Text);
    Result := AAnswer <> '';
    if not Result then
      AAnswer := 'Resposta vazia';
  finally
    V.Free;
  end;
end;

function ActionPrompt(AAction: TAIAction; const AText: string; out ASystem: string): string;
const
  Base = 'Você ajuda um desenvolvedor no Windows. Responda em português do Brasil, direto e curto, ' +
    'sem introdução nem despedida. ';
begin
  ASystem := Base;
  Result := AText;
  case AAction of
    aaExplain:
      ASystem := Base + 'Explique o que é o texto (erro, código, comando, log ou outro) e, se for um ' +
        'problema, a causa provável e o que fazer. Use no máximo 10 linhas.';
    aaSummarize:
      ASystem := Base + 'Resuma o texto em até 5 tópicos curtos.';
    aaTranslate:
      ASystem := 'Traduza o texto: se estiver em português, para inglês; senão, para português do ' +
        'Brasil. Devolva só a tradução, mantendo formatação e código.';
    aaImprove:
      ASystem := 'Reescreva o texto em português do Brasil, corrigindo gramática e deixando mais ' +
        'claro e direto, sem mudar o sentido. Devolva só o texto novo.';
    aaCommit:
      ASystem := 'Escreva uma mensagem de commit para o diff, em português do Brasil, no formato ' +
        'Conventional Commits: "tipo(escopo): resumo" (até 72 caracteres), linha em branco e até 5 ' +
        'tópicos curtos. Devolva só a mensagem.';
    aaExplainLog:
      ASystem := Base + 'É o log de um container. Diga em até 8 linhas se há erro, a causa provável e o ' +
        'que verificar. Se estiver tudo normal, diga isso em uma linha.';
    aaCommand:
      ASystem := 'Você converte pedidos em UM comando para Windows. Prefira PowerShell; use cmd só se ' +
        'for mais simples; use wsl quando o pedido citar Linux, distro ou container. Nunca apague nada ' +
        'sem que o pedido peça. Responda SÓ com JSON, sem texto fora dele: ' +
        '{"shell":"powershell|cmd|wsl","command":"...","explanation":"uma frase em português"}';
  end;
end;

function ParseCommandAnswer(const AAnswer: string; out AShell, ACommand, AExplanation: string): Boolean;
var
  S: string;
  A, B: Integer;
  V: TJSONValue;
begin
  Result := False;
  // O modelo às vezes embrulha o JSON em ```; pega do primeiro { ao último }.
  A := Pos('{', AAnswer);
  B := LastDelimiter('}', AAnswer);
  if (A = 0) or (B <= A) then
    Exit;
  S := Copy(AAnswer, A, B - A + 1);
  V := TJSONObject.ParseJSONValue(S);
  try
    if V = nil then
      Exit;
    AShell := LowerCase(V.GetValue<string>('shell', 'powershell'));
    ACommand := Trim(V.GetValue<string>('command', ''));
    AExplanation := V.GetValue<string>('explanation', '');
    if IndexStr(AShell, ['powershell', 'cmd', 'wsl']) < 0 then
      AShell := 'powershell';
    Result := ACommand <> '';
  finally
    V.Free;
  end;
end;

end.
