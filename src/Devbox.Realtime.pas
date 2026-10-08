unit Devbox.Realtime;

{ Conversa por voz direto com a IA, por WebSocket: OpenAI Realtime ou Gemini
  Live. O microfone entra (16 kHz, já sem eco), a voz da IA sai (convertida para
  16 kHz) e a IA chama ferramentas do Devbox. Os avisos chegam na thread de
  leitura: quem recebe joga para a tela (QueueUI).
  Os nomes de evento seguem a documentação de out/2026 (gpt-realtime-2.1,
  gemini-3.8-live); os dois nomes antigos de áudio da OpenAI também valem. }

interface

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  System.JSON,
  Devbox.WebSocket;

type
  TRealtimeProvider = (rpOpenAI, rpGemini);

  TRealtimeTool = record
    Name: string;
    Description: string;
    Params: string;   // JSON Schema do objeto de argumentos
  end;

  TRealtimeConfig = record
    Provider: TRealtimeProvider;
    Key: string;
    Model: string;
    Voice: string;
    Instructions: string;
    Tools: TArray<TRealtimeTool>;
    Url: string;      // teste: troca o endereço (ws://127.0.0.1:4086)
  end;

  TRtAudioProc = reference to procedure(const ASamples: TArray<SmallInt>);
  TRtTextProc = reference to procedure(const AText: string);
  TRtToolProc = reference to procedure(const ACallId, AName, AArgs: string);

  TRealtimeSession = class
  private
    FConfig: TRealtimeConfig;
    FWs: TWsClient;
    FReader: TThread;
    FReady: TEvent;
    FUserText, FAssistantText: string;
    FOnAudio: TRtAudioProc;
    FOnSpeechStarted: TProc;
    FOnUserText: TRtTextProc;
    FOnAssistantText: TRtTextProc;
    FOnToolCall: TRtToolProc;
    FOnError: TRtTextProc;
    FOnClosed: TRtTextProc;
    procedure ReadLoop;
    procedure Handle(const AJson: TJSONObject);
    procedure HandleOpenAI(const AJson: TJSONObject);
    procedure HandleGemini(const AJson: TJSONObject);
    procedure AddGeminiUsage(const AMeta: TJSONValue);
    function SetupMessage: string;
    function Url: string;
  public
    constructor Create(const AConfig: TRealtimeConfig);
    destructor Destroy; override;
    { Conecta e configura. Bloqueia (fora da thread de UI). False com o motivo. }
    function Start(out AError: string): Boolean;
    { Áudio do microfone, 16 kHz mono. Qualquer thread. }
    procedure SendAudio(const ASamples: TArray<SmallInt>);
    { Resultado de uma ferramenta (AResult: JSON). Qualquer thread. }
    procedure SendToolResult(const ACallId, AName, AResult: string);
    procedure Stop;
    property OnAudio: TRtAudioProc read FOnAudio write FOnAudio;
    { O usuário começou a falar: pare a voz que está tocando. }
    property OnSpeechStarted: TProc read FOnSpeechStarted write FOnSpeechStarted;
    property OnUserText: TRtTextProc read FOnUserText write FOnUserText;
    property OnAssistantText: TRtTextProc read FOnAssistantText write FOnAssistantText;
    property OnToolCall: TRtToolProc read FOnToolCall write FOnToolCall;
    property OnError: TRtTextProc read FOnError write FOnError;
    { A conexão acabou ('' = fechada por nós). }
    property OnClosed: TRtTextProc read FOnClosed write FOnClosed;
  end;

const
  RealtimeDefaultModels: array[TRealtimeProvider] of string = ('gpt-realtime-2.1', 'gemini-3.8-live');
  RealtimeDefaultVoices: array[TRealtimeProvider] of string = ('marin', 'Kore');

// Partes puras (self-check)
{ Reamostra PCM mono por interpolação linear (com média de 3 pontos ao diminuir). }
function ResamplePcm(const ASamples: TArray<SmallInt>; AFrom, ATo: Integer): TArray<SmallInt>;
function PcmToBase64(const ASamples: TArray<SmallInt>): string;
function Base64ToPcm(const AText: string): TArray<SmallInt>;

implementation

uses
  System.NetEncoding,
  System.Math,
  Devbox.Usage;

const
  CRate = 16000;
  COpenAIRate = 24000;
  CGeminiOutRate = 24000;
  COpenAIUrl = 'wss://api.openai.com/v1/realtime?model=';
  CGeminiUrl = 'wss://generativelanguage.googleapis.com/ws/' +
    'google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent?key=';
  CSetupTimeoutMs = 15000;
  CReaderWaitMs = 3000;

{ Partes puras }

function ResamplePcm(const ASamples: TArray<SmallInt>; AFrom, ATo: Integer): TArray<SmallInt>;
var
  LSource: TArray<SmallInt>;
  LIndex, LBase, LCount: Integer;
  LPos, LFrac: Double;
begin
  if (AFrom = ATo) or (Length(ASamples) = 0) then
    Exit(Copy(ASamples));
  LSource := ASamples;
  if ATo < AFrom then
  begin
    // Suaviza antes de descer a taxa: tira parte do agudo que viraria chiado.
    SetLength(LSource, Length(ASamples));
    for LIndex := 0 to High(ASamples) do
      LSource[LIndex] := (ASamples[Max(LIndex - 1, 0)] + 2 * ASamples[LIndex] +
        ASamples[Min(LIndex + 1, High(ASamples))]) div 4;
  end;
  LCount := Int64(Length(LSource)) * ATo div AFrom;
  SetLength(Result, LCount);
  for LIndex := 0 to LCount - 1 do
  begin
    LPos := LIndex * AFrom / ATo;
    LBase := Trunc(LPos);
    LFrac := LPos - LBase;
    if LBase >= High(LSource) then
      Result[LIndex] := LSource[High(LSource)]
    else
      Result[LIndex] := Round(LSource[LBase] * (1 - LFrac) + LSource[LBase + 1] * LFrac);
  end;
end;

function PcmToBase64(const ASamples: TArray<SmallInt>): string;
var
  LBytes: TBytes;
begin
  SetLength(LBytes, Length(ASamples) * SizeOf(SmallInt));
  if Length(LBytes) > 0 then
    Move(ASamples[0], LBytes[0], Length(LBytes));
  Result := TNetEncoding.Base64String.EncodeBytesToString(LBytes);
end;

function Base64ToPcm(const AText: string): TArray<SmallInt>;
var
  LBytes: TBytes;
begin
  LBytes := TNetEncoding.Base64String.DecodeStringToBytes(AText);
  SetLength(Result, Length(LBytes) div SizeOf(SmallInt));
  if Length(Result) > 0 then
    Move(LBytes[0], Result[0], Length(Result) * SizeOf(SmallInt));
end;

{ TRealtimeSession }

type
  TReaderThread = class(TThread)
  private
    FSession: TRealtimeSession;
  protected
    procedure Execute; override;
  end;

procedure TReaderThread.Execute;
begin
  FSession.ReadLoop;
end;

constructor TRealtimeSession.Create(const AConfig: TRealtimeConfig);
begin
  inherited Create;
  FConfig := AConfig;
  if FConfig.Model = '' then
    FConfig.Model := RealtimeDefaultModels[FConfig.Provider];
  if FConfig.Voice = '' then
    FConfig.Voice := RealtimeDefaultVoices[FConfig.Provider];
  FWs := TWsClient.Create;
  FReady := TEvent.Create(nil, True, False, '');
end;

destructor TRealtimeSession.Destroy;
begin
  Stop;
  FWs.Free;
  FReady.Free;
  inherited;
end;

function TRealtimeSession.Url: string;
begin
  if FConfig.Url <> '' then
    Exit(FConfig.Url);
  if FConfig.Provider = rpOpenAI then
    Result := COpenAIUrl + FConfig.Model
  else
    Result := CGeminiUrl + FConfig.Key;
end;

function ToolsJson(const ATools: TArray<TRealtimeTool>; AOpenAI: Boolean): TJSONArray;
var
  LTool: TRealtimeTool;
  LItem: TJSONObject;
begin
  Result := TJSONArray.Create;
  for LTool in ATools do
  begin
    LItem := TJSONObject.Create;
    if AOpenAI then
      LItem.AddPair('type', 'function');
    LItem.AddPair('name', LTool.Name);
    LItem.AddPair('description', LTool.Description);
    LItem.AddPair('parameters', TJSONObject.ParseJSONValue(LTool.Params));
    Result.AddElement(LItem);
  end;
end;

function ArgText(const AArg: TVarRec): string;
begin
  case AArg.VType of
    vtUnicodeString: Result := string(AArg.VUnicodeString);
    vtWideChar: Result := AArg.VWideChar;
    vtChar: Result := string(AArg.VChar);
    vtPWideChar: Result := AArg.VPWideChar;
    vtAnsiString: Result := string(AnsiString(AArg.VAnsiString));
    vtWideString: Result := WideString(AArg.VWideString);
  else
    Result := '';
  end;
end;

function Obj(const APairs: array of const): TJSONObject;
var
  LIndex: Integer;
begin
  // Pares nome/valor; valor TJSONValue entra como está, o resto vira texto.
  Result := TJSONObject.Create;
  LIndex := 0;
  while LIndex < High(APairs) do
  begin
    if (APairs[LIndex + 1].VType = vtObject) and (APairs[LIndex + 1].VObject is TJSONValue) then
      Result.AddPair(ArgText(APairs[LIndex]), TJSONValue(APairs[LIndex + 1].VObject))
    else if APairs[LIndex + 1].VType = vtBoolean then
      Result.AddPair(ArgText(APairs[LIndex]), TJSONBool.Create(APairs[LIndex + 1].VBoolean))
    else if APairs[LIndex + 1].VType = vtInteger then
      Result.AddPair(ArgText(APairs[LIndex]), TJSONNumber.Create(APairs[LIndex + 1].VInteger))
    else
      Result.AddPair(ArgText(APairs[LIndex]), ArgText(APairs[LIndex + 1]));
    Inc(LIndex, 2);
  end;
end;

function Arr(const AValues: array of string): TJSONArray;
var
  LValue: string;
begin
  Result := TJSONArray.Create;
  for LValue in AValues do
    Result.Add(LValue);
end;

function TRealtimeSession.SetupMessage: string;
var
  LRoot, LTools: TJSONObject;
begin
  if FConfig.Provider = rpOpenAI then
    LRoot := Obj(['type', 'session.update', 'session', Obj([
      'type', 'realtime',
      'model', FConfig.Model,
      'instructions', FConfig.Instructions,
      'output_modalities', Arr(['audio']),
      'audio', Obj([
        'input', Obj([
          'format', Obj(['type', 'audio/pcm', 'rate', COpenAIRate]),
          'noise_reduction', Obj(['type', 'far_field']),
          'transcription', Obj(['model', 'whisper-1', 'language', 'pt']),
          'turn_detection', Obj(['type', 'semantic_vad', 'create_response', True, 'interrupt_response', True])]),
        'output', Obj([
          'format', Obj(['type', 'audio/pcm', 'rate', COpenAIRate]),
          'voice', FConfig.Voice])]),
      'tools', ToolsJson(FConfig.Tools, True),
      'tool_choice', 'auto'])])
  else
  begin
    LTools := Obj(['functionDeclarations', ToolsJson(FConfig.Tools, False)]);
    LRoot := Obj(['setup', Obj([
      'model', 'models/' + FConfig.Model,
      'generationConfig', Obj([
        'responseModalities', Arr(['AUDIO']),
        'speechConfig', Obj([
          'voiceConfig', Obj(['prebuiltVoiceConfig', Obj(['voiceName', FConfig.Voice])])])]),
      'systemInstruction', Obj(['parts', TJSONArray.Create(Obj(['text', FConfig.Instructions]))]),
      'tools', TJSONArray.Create(LTools),
      'inputAudioTranscription', TJSONObject.Create,
      'outputAudioTranscription', TJSONObject.Create])]);
  end;
  try
    Result := LRoot.ToJSON;
  finally
    LRoot.Free;
  end;
end;

function TRealtimeSession.Start(out AError: string): Boolean;
var
  LHeaders: TArray<string>;
  LReader: TReaderThread;
begin
  AError := '';
  LHeaders := nil;
  if FConfig.Provider = rpOpenAI then
    LHeaders := ['Authorization: Bearer ' + FConfig.Key];
  try
    FWs.Connect(Url, LHeaders);
    FWs.SendText(SetupMessage);
  except
    on E: Exception do
    begin
      AError := E.Message;
      Exit(False);
    end;
  end;
  LReader := TReaderThread.Create(True);
  LReader.FSession := Self;
  LReader.FreeOnTerminate := False;
  FReader := LReader;
  FReader.Start;
  // Gemini: só manda áudio depois do setupComplete. OpenAI: depois do session.updated.
  if FReady.WaitFor(CSetupTimeoutMs) <> wrSignaled then
  begin
    AError := 'A IA não confirmou a configuração em 15 s';
    Exit(False);
  end;
  Result := FWs.Open;
  if not Result then
    AError := 'A conexão caiu ao configurar';
end;

procedure TRealtimeSession.ReadLoop;
var
  LText, LReason, LError: string;
  LJson: TJSONValue;
begin
  LError := '';
  try
    while FWs.ReadMessage(LText, LReason) do
    begin
      LJson := TJSONObject.ParseJSONValue(LText);
      try
        if LJson is TJSONObject then
          Handle(TJSONObject(LJson));
      finally
        LJson.Free;
      end;
    end;
    LError := LReason;
  except
    on E: Exception do
      if FWs.Open then
        LError := E.Message;
  end;
  FReady.SetEvent;
  if Assigned(FOnClosed) then
    FOnClosed(LError);
end;

procedure TRealtimeSession.Handle(const AJson: TJSONObject);
begin
  if FConfig.Provider = rpOpenAI then
    HandleOpenAI(AJson)
  else
    HandleGemini(AJson);
end;

procedure TRealtimeSession.HandleOpenAI(const AJson: TJSONObject);
var
  LType: string;
  LUsage: TAiUsage;
begin
  LType := AJson.GetValue<string>('type', '');
  if LType = 'session.updated' then
    FReady.SetEvent
  else if (LType = 'response.output_audio.delta') or (LType = 'response.audio.delta') then
  begin
    if Assigned(FOnAudio) then
      FOnAudio(ResamplePcm(Base64ToPcm(AJson.GetValue<string>('delta', '')), COpenAIRate, CRate));
  end
  else if LType = 'input_audio_buffer.speech_started' then
  begin
    if Assigned(FOnSpeechStarted) then
      FOnSpeechStarted();
  end
  else if (LType = 'response.output_audio_transcript.delta') or (LType = 'response.audio_transcript.delta') then
  begin
    FAssistantText := FAssistantText + AJson.GetValue<string>('delta', '');
    if Assigned(FOnAssistantText) then
      FOnAssistantText(FAssistantText);
  end
  else if LType = 'response.done' then
  begin
    FAssistantText := '';
    LUsage := Default(TAiUsage);
    LUsage.Provider := 'openai';
    LUsage.Model := FConfig.Model;
    LUsage.Kind := 'conversa';
    LUsage.InputTokens := AJson.GetValue<Int64>('response.usage.input_token_details.text_tokens', 0);
    LUsage.AudioInTokens := AJson.GetValue<Int64>('response.usage.input_token_details.audio_tokens', 0);
    LUsage.OutputTokens := AJson.GetValue<Int64>('response.usage.output_token_details.text_tokens', 0);
    LUsage.AudioOutTokens := AJson.GetValue<Int64>('response.usage.output_token_details.audio_tokens', 0);
    if LUsage.InputTokens + LUsage.AudioInTokens + LUsage.OutputTokens + LUsage.AudioOutTokens > 0 then
      UsageAdd(LUsage);
  end
  else if LType = 'conversation.item.input_audio_transcription.completed' then
  begin
    if Assigned(FOnUserText) then
      FOnUserText(AJson.GetValue<string>('transcript', ''));
  end
  else if LType = 'response.function_call_arguments.done' then
  begin
    if Assigned(FOnToolCall) then
      FOnToolCall(AJson.GetValue<string>('call_id', ''), AJson.GetValue<string>('name', ''),
        AJson.GetValue<string>('arguments', '{}'));
  end
  else if LType = 'error' then
  begin
    FReady.SetEvent;
    if Assigned(FOnError) then
      FOnError(AJson.GetValue<string>('error.message', 'erro da OpenAI'));
  end;
end;

{ usageMetadata do Gemini: tokens por tipo (TEXT, AUDIO) em promptTokensDetails e responseTokensDetails. }
procedure TRealtimeSession.AddGeminiUsage(const AMeta: TJSONValue);
var
  LUsage: TAiUsage;
  LDetails: TJSONArray;
  LItem: TJSONValue;
  LAudio: Boolean;
begin
  LUsage := Default(TAiUsage);
  LUsage.Provider := 'gemini';
  LUsage.Model := FConfig.Model;
  LUsage.Kind := 'conversa';
  if AMeta.TryGetValue<TJSONArray>('promptTokensDetails', LDetails) then
    for LItem in LDetails do
    begin
      LAudio := SameText(LItem.GetValue<string>('modality', ''), 'AUDIO');
      if LAudio then
        Inc(LUsage.AudioInTokens, LItem.GetValue<Int64>('tokenCount', 0))
      else
        Inc(LUsage.InputTokens, LItem.GetValue<Int64>('tokenCount', 0));
    end
  else
    LUsage.InputTokens := AMeta.GetValue<Int64>('promptTokenCount', 0);
  if AMeta.TryGetValue<TJSONArray>('responseTokensDetails', LDetails) then
    for LItem in LDetails do
    begin
      LAudio := SameText(LItem.GetValue<string>('modality', ''), 'AUDIO');
      if LAudio then
        Inc(LUsage.AudioOutTokens, LItem.GetValue<Int64>('tokenCount', 0))
      else
        Inc(LUsage.OutputTokens, LItem.GetValue<Int64>('tokenCount', 0));
    end
  else
    LUsage.OutputTokens := AMeta.GetValue<Int64>('responseTokenCount', 0);
  if LUsage.InputTokens + LUsage.AudioInTokens + LUsage.OutputTokens + LUsage.AudioOutTokens > 0 then
    UsageAdd(LUsage);
end;

function ArgsJson(const ACall: TJSONValue): string;
var
  LArgs: TJSONValue;
begin
  LArgs := ACall.FindValue('args');
  if LArgs = nil then
    Result := '{}'
  else
    Result := LArgs.ToJSON;
end;

procedure TRealtimeSession.HandleGemini(const AJson: TJSONObject);
var
  LContent, LCall: TJSONValue;
  LParts, LCalls: TJSONArray;
  LPart: TJSONValue;
  LMime, LText: string;
  LRate: Integer;
begin
  if AJson.GetValue('setupComplete') <> nil then
    FReady.SetEvent;
  LContent := AJson.GetValue('serverContent');
  if LContent <> nil then
  begin
    if LContent.GetValue<Boolean>('interrupted', False) and Assigned(FOnSpeechStarted) then
      FOnSpeechStarted();
    if LContent.TryGetValue<TJSONArray>('modelTurn.parts', LParts) and Assigned(FOnAudio) then
      for LPart in LParts do
        if LPart.GetValue<string>('inlineData.data', '') <> '' then
        begin
          LMime := LPart.GetValue<string>('inlineData.mimeType', '');
          LRate := StrToIntDef(Copy(LMime, Pos('rate=', LMime) + 5, MaxInt), CGeminiOutRate);
          FOnAudio(ResamplePcm(Base64ToPcm(LPart.GetValue<string>('inlineData.data', '')), LRate, CRate));
        end;
    LText := LContent.GetValue<string>('inputTranscription.text', '');
    if LText <> '' then
    begin
      FUserText := FUserText + LText;
      if Assigned(FOnUserText) then
        FOnUserText(FUserText);
    end;
    LText := LContent.GetValue<string>('outputTranscription.text', '');
    if LText <> '' then
    begin
      FAssistantText := FAssistantText + LText;
      if Assigned(FOnAssistantText) then
        FOnAssistantText(FAssistantText);
    end;
    if LContent.GetValue<Boolean>('turnComplete', False) then
    begin
      FUserText := '';
      FAssistantText := '';
    end;
  end;
  if AJson.GetValue('usageMetadata') <> nil then
    AddGeminiUsage(AJson.GetValue('usageMetadata'));
  if AJson.TryGetValue<TJSONArray>('toolCall.functionCalls', LCalls) and Assigned(FOnToolCall) then
    for LCall in LCalls do
      FOnToolCall(LCall.GetValue<string>('id', ''), LCall.GetValue<string>('name', ''),
        ArgsJson(LCall));
end;

procedure TRealtimeSession.SendAudio(const ASamples: TArray<SmallInt>);
var
  LMessage: TJSONObject;
begin
  if not FWs.Open or (Length(ASamples) = 0) then
    Exit;
  if FConfig.Provider = rpOpenAI then
    LMessage := Obj(['type', 'input_audio_buffer.append',
      'audio', PcmToBase64(ResamplePcm(ASamples, CRate, COpenAIRate))])
  else
    LMessage := Obj(['realtimeInput', Obj(['audio', Obj(['data', PcmToBase64(ASamples),
      'mimeType', 'audio/pcm;rate=16000'])])]);
  try
    try
      FWs.SendText(LMessage.ToJSON);
    except
      // A leitura percebe a queda e avisa em OnClosed.
    end;
  finally
    LMessage.Free;
  end;
end;

procedure TRealtimeSession.SendToolResult(const ACallId, AName, AResult: string);
var
  LMessage: TJSONObject;
  LValue: TJSONValue;
begin
  if not FWs.Open then
    Exit;
  try
    if FConfig.Provider = rpOpenAI then
    begin
      LMessage := Obj(['type', 'conversation.item.create',
        'item', Obj(['type', 'function_call_output', 'call_id', ACallId, 'output', AResult])]);
      try
        FWs.SendText(LMessage.ToJSON);
      finally
        LMessage.Free;
      end;
      FWs.SendText('{"type":"response.create"}');
    end
    else
    begin
      LValue := TJSONObject.ParseJSONValue(AResult);
      if LValue = nil then
        LValue := TJSONString.Create(AResult);
      LMessage := Obj(['toolResponse', Obj(['functionResponses', TJSONArray.Create(
        Obj(['id', ACallId, 'name', AName, 'response', Obj(['result', LValue])]))])]);
      try
        FWs.SendText(LMessage.ToJSON);
      finally
        LMessage.Free;
      end;
    end;
  except
    // A leitura percebe a queda e avisa em OnClosed.
  end;
end;

procedure TRealtimeSession.Stop;
begin
  if FReader = nil then
  begin
    FWs.Close;
    Exit;
  end;
  // Para a leitura antes de soltar o TLS.
  FWs.Abort;
  FReader.WaitFor;
  FreeAndNil(FReader);
  FWs.Close;
end;

end.
