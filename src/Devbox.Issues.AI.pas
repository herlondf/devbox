unit Devbox.Issues.AI;

{ Provedor de IA do assistente escolhido nas Configurações. Anthropic usa o
  provedor da ComponentesUI; os demais (OpenAI, Grok, DeepSeek, Groq,
  OpenRouter, Gemini, Ollama, URL própria) usam a API compatível com OpenAI
  (/chat/completions), só texto: o assistente do Vigia responde sobre os dados
  que estão no prompt de sistema, sem ferramentas.
  Toda resposta passa pela fábrica do Vigia, que grava tokens e custo. }

interface

uses
  System.SysUtils,
  UI.Assistant.Provider;

type
  TAiProviderKind = (apAnthropic, apOpenAI, apGrok, apDeepSeek, apGroq, apOpenRouter, apGemini, apOllama, apCustom);

  TAiConfig = record
    Kind: TAiProviderKind;
    BaseUrl: string;
    Model: string;
    ApiKey: string;
  end;

const
  AiProviderNames: array[TAiProviderKind] of string = (
    'Anthropic (Claude)', 'OpenAI', 'xAI (Grok)', 'DeepSeek', 'Groq', 'OpenRouter', 'Google (Gemini)',
    'Ollama (local)', 'Outro compatível com OpenAI');
  AiProviderIds: array[TAiProviderKind] of string = (
    'anthropic', 'openai', 'grok', 'deepseek', 'groq', 'openrouter', 'gemini', 'ollama', 'custom');
  // Endpoints públicos de cada provedor; editáveis na tela.
  AiDefaultBaseUrls: array[TAiProviderKind] of string = (
    'https://api.anthropic.com', 'https://api.openai.com/v1', 'https://api.x.ai/v1',
    'https://api.deepseek.com/v1', 'https://api.groq.com/openai/v1', 'https://openrouter.ai/api/v1',
    'https://generativelanguage.googleapis.com/v1beta/openai', 'http://localhost:11434/v1', '');
  AiDefaultModel = 'claude-sonnet-5-5';

{ Configuração atual (preferências + chave do Credential Manager). }
function CurrentAiConfig: TAiConfig;
function AiSecretTarget(AKind: TAiProviderKind): string;

{ Modelos que o provedor oferece (GET /models). Bloqueante; levanta exceção. }
function ListAiModels(const AConfig: TAiConfig): TArray<string>;

{ US$ por milhão de tokens. Preferência do usuário; sem ela, tabela da
  Anthropic (preços públicos, set/2026). False se não há preço conhecido. }
function AiPriceFor(const AModel: string; out AInput, AOutput: Double): Boolean;
procedure SetAiPrice(const AModel: string; AInput, AOutput: Double);

{ Cotação do dólar em reais (compra), da AwesomeAPI pública. Bloqueante;
  levanta exceção. }
function FetchUsdBrl: Double;

{ Registra a fábrica do Vigia no lugar da padrão da suíte. Chamar uma vez. }
procedure RegisterVigiaAiProvider;

{ Teto mensal em US$ (0 = sem teto) e se o gasto do mês já chegou nele. }
function AiMonthCap: Double;
function AiOverCap: Boolean;

{ Modelo das tarefas automáticas (barato). Vazio = o modelo do chat. }
function AiCheapModel: string;

{ Pergunta única, fora do chat (resumos, alertas). Callbacks na thread de UI.
  ACheap = usa o modelo barato. Respeita o teto do mês e grava o custo. }
procedure AiAsk(const ASystem, APrompt: string; ACheap: Boolean;
  const AOnDone: TProc<string>; const AOnFail: TProc<string> = nil);

implementation

uses
  Devbox.UI.Kit,
  Devbox.AI,
  System.StrUtils,
  System.DateUtils,
  System.Generics.Collections,
  System.Classes,
  System.JSON,
  System.Threading,
  System.Net.URLClient,
  System.Net.HttpClient,
  UI.Assistant.Types,
  Devbox.Issues.Store,
  Devbox.Secrets;

const
  // Preços públicos da Anthropic por milhão de tokens (entrada, saída), set/2026.
  ClaudePrices: array[0..9] of record
    Model: string;
    Input, Output: Double;
  end = (
    (Model: 'claude-fable-5-1'; Input: 10; Output: 50),
    (Model: 'claude-fable-5'; Input: 10; Output: 50),
    (Model: 'claude-opus-5-5'; Input: 4; Output: 20),
    (Model: 'claude-opus-5'; Input: 5; Output: 25),
    (Model: 'claude-opus-4-8'; Input: 5; Output: 25),
    (Model: 'claude-opus-4-7'; Input: 5; Output: 25),
    (Model: 'claude-sonnet-5-5'; Input: 2; Output: 10),
    (Model: 'claude-sonnet-5'; Input: 2; Output: 10),
    (Model: 'claude-sonnet-4-6'; Input: 3; Output: 15),
    (Model: 'claude-haiku-4-5'; Input: 1; Output: 5));

var
  GSuiteFactory: TUIAIProviderFactory;  // a da ComponentesUI (Anthropic)

function AiSecretTarget(AKind: TAiProviderKind): string;
begin
  Result := 'Vigia:ai:' + AiProviderIds[AKind];
end;

function CurrentAiConfig: TAiConfig;
var
  K: TAiProviderKind;
begin
  Result.Kind := apAnthropic;
  for K := Low(TAiProviderKind) to High(TAiProviderKind) do
    if IssueStore.GetSetting('ai_provider', 'anthropic') = AiProviderIds[K] then
      Result.Kind := K;
  Result.BaseUrl := IssueStore.GetSetting('ai_base_' + AiProviderIds[Result.Kind], AiDefaultBaseUrls[Result.Kind]);
  Result.Model := IssueStore.GetSetting('ai_model_' + AiProviderIds[Result.Kind],
    IfThen(Result.Kind = apAnthropic, AiDefaultModel, ''));
  Result.ApiKey := LoadSecret(AiSecretTarget(Result.Kind));
  // Anthropic: a chave antiga (antes dos provedores) continua valendo.
  if (Result.Kind = apAnthropic) and (Result.ApiKey = '') then
    Result.ApiKey := LoadSecret('Vigia:anthropic');
  // Mesma reserva do chat: chave na variável de ambiente.
  if (Result.Kind = apAnthropic) and (Result.ApiKey = '') then
    Result.ApiKey := GetEnvironmentVariable('ANTHROPIC_API_KEY');
end;

function TrimSlash(const S: string): string;
begin
  Result := S.Trim;
  while Result.EndsWith('/') do
    Result := Result.Substring(0, Result.Length - 1);
end;

function HttpJson(const AMethod, AUrl, ABody: string; const AHeaders: TNetHeaders): TJSONValue;
var
  Http: THTTPClient;
  Resp: IHTTPResponse;
  Src: TStringStream;
  Text: string;
begin
  Http := THTTPClient.Create;
  Src := nil;
  try
    Http.ConnectionTimeout := 15000;
    Http.ResponseTimeout := 120000;
    if AMethod = 'POST' then
    begin
      Src := TStringStream.Create(ABody, TEncoding.UTF8);
      Resp := Http.Post(AUrl, Src, nil, AHeaders + [TNameValuePair.Create('Content-Type', 'application/json')]);
    end
    else
      Resp := Http.Get(AUrl, nil, AHeaders);
    Text := Resp.ContentAsString(TEncoding.UTF8);
    if (Resp.StatusCode < 200) or (Resp.StatusCode > 299) then
      raise Exception.CreateFmt('HTTP %d %s: %s', [Resp.StatusCode, Resp.StatusText, Copy(Text, 1, 300)]);
    Result := TJSONObject.ParseJSONValue(Text);
    if Result = nil then
      raise Exception.Create('Resposta não é JSON');
  finally
    Src.Free;
    Http.Free;
  end;
end;

function ListAiModels(const AConfig: TAiConfig): TArray<string>;
var
  J: TJSONValue;
  Arr: TJSONArray;
  I: Integer;
  Headers: TNetHeaders;
  Url: string;
begin
  Result := nil;
  if AConfig.Kind = apAnthropic then
  begin
    // Models API da Anthropic: x-api-key + anthropic-version.
    Url := TrimSlash(IfThen(AConfig.BaseUrl <> '', AConfig.BaseUrl, AiDefaultBaseUrls[apAnthropic])) +
      '/v1/models?limit=100';
    Headers := [TNameValuePair.Create('x-api-key', AConfig.ApiKey),
      TNameValuePair.Create('anthropic-version', '2023-06-01')];
  end
  else
  begin
    Url := TrimSlash(AConfig.BaseUrl) + '/models';
    Headers := [];
    if AConfig.ApiKey <> '' then
      Headers := [TNameValuePair.Create('Authorization', 'Bearer ' + AConfig.ApiKey)];
  end;
  J := HttpJson('GET', Url, '', Headers);
  try
    if J.TryGetValue<TJSONArray>('data', Arr) then
      for I := 0 to Arr.Count - 1 do
        Result := Result + [Arr.Items[I].GetValue<string>('id', '')];
  finally
    J.Free;
  end;
  TArray.Sort<string>(Result);
end;

function AiPriceFor(const AModel: string; out AInput, AOutput: Double): Boolean;
var
  S: string;
  Parts: TArray<string>;
  I: Integer;
  Fmt: TFormatSettings;
begin
  Fmt := TFormatSettings.Invariant;
  S := IssueStore.GetSetting('ai_price_' + AModel);
  Parts := S.Split([';']);
  if Length(Parts) = 2 then
  begin
    AInput := StrToFloatDef(Parts[0], 0, Fmt);
    AOutput := StrToFloatDef(Parts[1], 0, Fmt);
    Exit(True);
  end;
  for I := Low(ClaudePrices) to High(ClaudePrices) do
    if SameText(ClaudePrices[I].Model, AModel) then
    begin
      AInput := ClaudePrices[I].Input;
      AOutput := ClaudePrices[I].Output;
      Exit(True);
    end;
  AInput := 0;
  AOutput := 0;
  Result := False;
end;

procedure SetAiPrice(const AModel: string; AInput, AOutput: Double);
var
  Fmt: TFormatSettings;
begin
  Fmt := TFormatSettings.Invariant;
  IssueStore.SetSetting('ai_price_' + AModel, FloatToStr(AInput, Fmt) + ';' + FloatToStr(AOutput, Fmt));
end;

{ ── Provedor compatível com OpenAI ─────────────────────────────────────── }

type
  TOpenAiCompatProvider = class(TInterfacedObject, IUIAIProvider)
  private
    FBusy: Boolean;
    FCancelled: Boolean;
  public
    function ProviderName: string;
    function IsBusy: Boolean;
    procedure Send(const ARequest: TUIAssistantRequest; const ACallbacks: TUIAssistantCallbacks);
    procedure Cancel;
  end;

function TOpenAiCompatProvider.ProviderName: string;
begin
  Result := 'openai-compat';
end;

function TOpenAiCompatProvider.IsBusy: Boolean;
begin
  Result := FBusy;
end;

procedure TOpenAiCompatProvider.Cancel;
begin
  FCancelled := True;
  FBusy := False;
end;

procedure TOpenAiCompatProvider.Send(const ARequest: TUIAssistantRequest;
  const ACallbacks: TUIAssistantCallbacks);
var
  Body: TJSONObject;
  Msgs: TJSONArray;
  M: TUIAssistantMessage;
  Msg: TJSONObject;
  Payload, Url, Key: string;
  Self_: IUIAIProvider;
begin
  // Mensagens só de texto; resultados de ferramenta (sem texto) ficam de fora.
  Body := TJSONObject.Create;
  try
    Body.AddPair('model', ARequest.Model);
    Msgs := TJSONArray.Create;
    Body.AddPair('messages', Msgs);
    if ARequest.SystemPrompt <> '' then
    begin
      Msg := TJSONObject.Create;
      Msg.AddPair('role', 'system');
      Msg.AddPair('content', ARequest.SystemPrompt);
      Msgs.AddElement(Msg);
    end;
    for M in ARequest.Messages do
    begin
      if (M.Text.Trim = '') or not (M.Role in [arUser, arAssistant]) then
        Continue;
      Msg := TJSONObject.Create;
      if M.Role = arUser then
        Msg.AddPair('role', 'user')
      else
        Msg.AddPair('role', 'assistant');
      Msg.AddPair('content', M.Text);
      Msgs.AddElement(Msg);
    end;
    Payload := Body.ToJSON;
  finally
    Body.Free;
  end;
  Url := TrimSlash(ARequest.BaseUrl) + '/chat/completions';
  Key := ARequest.ApiKey;
  FBusy := True;
  FCancelled := False;
  Self_ := Self;  // mantém vivo enquanto a thread roda
  RunTask(
    procedure
    var
      J: TJSONValue;
      Turn: TUIAssistantTurn;
      Err: string;
      Headers: TNetHeaders;
    begin
      Turn.Reset;
      try
        Headers := [];
        if Key <> '' then
          Headers := [TNameValuePair.Create('Authorization', 'Bearer ' + Key)];
        J := HttpJson('POST', Url, Payload, Headers);
        try
          Turn.Text := J.GetValue<string>('choices[0].message.content', '');
          Turn.Model := J.GetValue<string>('model', '');
          Turn.Usage.InputTokens := J.GetValue<Integer>('usage.prompt_tokens', 0);
          Turn.Usage.OutputTokens := J.GetValue<Integer>('usage.completion_tokens', 0);
          if J.GetValue<string>('choices[0].finish_reason', 'stop') = 'length' then
            Turn.StopReason := UIAssistantParseStopReason('max_tokens')
          else
            Turn.StopReason := UIAssistantParseStopReason('end_turn');
        finally
          J.Free;
        end;
      except
        on E: Exception do
          Err := E.Message;
      end;
      QueueUI(
        procedure
        begin
          FBusy := False;
          if FCancelled then
            Exit;
          if Err <> '' then
          begin
            if Assigned(ACallbacks.OnFail) then
              ACallbacks.OnFail(Err);
          end
          else if Assigned(ACallbacks.OnDone) then
            ACallbacks.OnDone(Turn);
          Self_ := nil;
        end);
    end);
end;

{ ── Fábrica do Vigia: escolhe o provedor e grava o uso ─────────────────── }

type
  TVigiaAiProvider = class(TInterfacedObject, IUIAIProvider)
  private
    FInner: IUIAIProvider;
    FConfig: TAiConfig;
  public
    constructor Create;
    function ProviderName: string;
    function IsBusy: Boolean;
    procedure Send(const ARequest: TUIAssistantRequest; const ACallbacks: TUIAssistantCallbacks);
    procedure Cancel;
  end;

constructor TVigiaAiProvider.Create;
begin
  inherited Create;
  FConfig := CurrentAiConfig;
  if (FConfig.Kind = apAnthropic) and Assigned(GSuiteFactory) then
    FInner := GSuiteFactory()
  else
    FInner := TOpenAiCompatProvider.Create;
end;

function TVigiaAiProvider.ProviderName: string;
begin
  Result := AiProviderIds[FConfig.Kind];
end;

function TVigiaAiProvider.IsBusy: Boolean;
begin
  Result := FInner.IsBusy;
end;

procedure TVigiaAiProvider.Cancel;
begin
  FInner.Cancel;
end;

procedure RecordUsage(AKind: TAiProviderKind; const AReqModel: string; const ATurn: TUIAssistantTurn);
var
  PIn, POut, Cost: Double;
  Model: string;
begin
  Model := ATurn.Model;
  if Model = '' then
    Model := AReqModel;
  Cost := 0;
  if AiPriceFor(Model, PIn, POut) or AiPriceFor(AReqModel, PIn, POut) then
    Cost := (ATurn.Usage.InputTokens + ATurn.Usage.CacheCreationInputTokens) * PIn / 1e6 +
      ATurn.Usage.CacheReadInputTokens * PIn * 0.1 / 1e6 + ATurn.Usage.OutputTokens * POut / 1e6;
  IssueStore.AddAiUsage(AiProviderIds[AKind], Model,
    ATurn.Usage.InputTokens + ATurn.Usage.CacheReadInputTokens + ATurn.Usage.CacheCreationInputTokens,
    ATurn.Usage.OutputTokens, Cost);
end;

procedure TVigiaAiProvider.Send(const ARequest: TUIAssistantRequest;
  const ACallbacks: TUIAssistantCallbacks);
var
  Req: TUIAssistantRequest;
  Cb: TUIAssistantCallbacks;
  Cfg: TAiConfig;
begin
  // Lê a configuração a cada pergunta: trocar o provedor vale na próxima.
  Cfg := CurrentAiConfig;
  if Cfg.Kind <> FConfig.Kind then
  begin
    FConfig := Cfg;
    if (Cfg.Kind = apAnthropic) and Assigned(GSuiteFactory) then
      FInner := GSuiteFactory()
    else
      FInner := TOpenAiCompatProvider.Create;
  end;
  Req := ARequest;
  if Cfg.ApiKey <> '' then
    Req.ApiKey := Cfg.ApiKey;
  if Cfg.Model <> '' then
    Req.Model := Cfg.Model;
  if Cfg.Kind <> apAnthropic then
    Req.BaseUrl := Cfg.BaseUrl;
  if (Cfg.Kind <> apAnthropic) and (Cfg.ApiKey = '') and (Cfg.Kind <> apOllama) then
  begin
    if Assigned(ACallbacks.OnFail) then
      ACallbacks.OnFail('Sem chave para ' + AiProviderNames[Cfg.Kind] + '. Configure em Configurações > Assistente.');
    Exit;
  end;
  if AiOverCap then
  begin
    if Assigned(ACallbacks.OnFail) then
      ACallbacks.OnFail(Format('Limite de US$ %.2f do mês atingido. Mude em Configurações > IA automática.',
        [AiMonthCap]));
    Exit;
  end;
  Cb := ACallbacks;
  Cb.OnDone :=
    procedure(const ATurn: TUIAssistantTurn)
    begin
      RecordUsage(Cfg.Kind, Req.Model, ATurn);
      if Assigned(ACallbacks.OnDone) then
        ACallbacks.OnDone(ATurn);
    end;
  FInner.Send(Req, Cb);
end;

function CreateVigiaAiProvider: IUIAIProvider;
begin
  Result := TVigiaAiProvider.Create;
end;

function AiMonthCap: Double;
begin
  Result := StrToFloatDef(IssueStore.GetSetting('ai_month_cap'), 0, TFormatSettings.Invariant);
end;

function AiOverCap: Boolean;
var
  Count, TIn, TOut: Integer;
  Cost: Double;
begin
  if AiMonthCap <= 0 then
    Exit(False);
  IssueStore.AiTotals(StartOfTheMonth(Now), Count, TIn, TOut, Cost);
  Result := Cost >= AiMonthCap;
end;

function AiCheapModel: string;
var
  Cfg: TAiConfig;
begin
  Cfg := CurrentAiConfig;
  Result := IssueStore.GetSetting('ai_cheap_model_' + AiProviderIds[Cfg.Kind],
    IfThen(Cfg.Kind = apAnthropic, 'claude-haiku-4-5', ''));
end;

procedure AiAsk(const ASystem, APrompt: string; ACheap: Boolean;
  const AOnDone: TProc<string>; const AOnFail: TProc<string>);
var
  Cfg: TAiConfig;
  Req: TUIAssistantRequest;
  Cb: TUIAssistantCallbacks;
  P: IUIAIProvider;
begin
  Cfg := CurrentAiConfig;
  if AiOverCap then
  begin
    if Assigned(AOnFail) then
      AOnFail(Format('Limite de US$ %.2f do mês atingido', [AiMonthCap]));
    Exit;
  end;
  if (Cfg.ApiKey = '') and (Cfg.Kind <> apOllama) then
  begin
    if Assigned(AOnFail) then
      AOnFail('Sem chave de IA. Configure em Configurações > Assistente.');
    Exit;
  end;
  Req := Default(TUIAssistantRequest);
  Req.ApiKey := Cfg.ApiKey;
  if Cfg.Kind <> apAnthropic then
    Req.BaseUrl := Cfg.BaseUrl;
  Req.Model := Cfg.Model;
  if ACheap and (AiCheapModel <> '') then
    Req.Model := AiCheapModel;
  Req.MaxTokens := 1024;
  Req.TimeoutMs := 90000;
  Req.SystemPrompt := ASystem;
  Req.Messages := [TUIAssistantMessage.CreateText(arUser, APrompt)];
  if (Cfg.Kind = apAnthropic) and Assigned(GSuiteFactory) then
    P := GSuiteFactory()
  else
    P := TOpenAiCompatProvider.Create;
  // P fica preso nos callbacks até a resposta chegar.
  Cb.OnDelta := nil;
  Cb.OnDone :=
    procedure(const ATurn: TUIAssistantTurn)
    begin
      RecordUsage(Cfg.Kind, Req.Model, ATurn);
      P := nil;
      AOnDone(ATurn.Text.Trim);
    end;
  Cb.OnFail :=
    procedure(const AMessage: string)
    begin
      P := nil;
      if Assigned(AOnFail) then
        AOnFail(AMessage);
    end;
  P.Send(Req, Cb);
end;


function FetchUsdBrl: Double;
var
  Http: THTTPClient;
  J: TJSONValue;
begin
  Http := THTTPClient.Create;
  try
    Http.ConnectionTimeout := 8000;
    Http.ResponseTimeout := 8000;
    J := TJSONObject.ParseJSONValue(
      Http.Get('https://economia.awesomeapi.com.br/json/last/USD-BRL').ContentAsString(TEncoding.UTF8));
    try
      if J = nil then
        raise Exception.Create('Cotação: resposta não é JSON');
      Result := StrToFloat(J.GetValue<string>('USDBRL.bid'), TFormatSettings.Invariant);
    finally
      J.Free;
    end;
  finally
    Http.Free;
  end;
end;

procedure RegisterVigiaAiProvider;
begin
  if HasUIAIProviderFactory and not Assigned(GSuiteFactory) then
    GSuiteFactory := GetUIAIProviderFactory();
  RegisterUIAIProviderFactory(CreateVigiaAiProvider);
  // A mesma config vale para as ações de texto (Devbox.AI); pronta ou não, decide lá.
  Devbox.AI.AIConfigSource :=
    function(out AConfig: Devbox.AI.TAIConfig): Boolean
    var
      LCfg: TAiConfig;
    begin
      LCfg := CurrentAiConfig;
      if LCfg.Kind = apAnthropic then
        AConfig.Provider := Devbox.AI.apAnthropic
      else
        AConfig.Provider := Devbox.AI.apOpenAI;
      AConfig.BaseUrl := LCfg.BaseUrl;
      AConfig.Model := LCfg.Model;
      AConfig.Key := LCfg.ApiKey;
      Result := AConfig.Ready and ((AConfig.Key <> '') or (LCfg.Kind = apOllama));
    end;
end;

end.
