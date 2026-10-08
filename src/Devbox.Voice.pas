unit Devbox.Voice;

{ Ouvido do assistente: microfone sempre ligado (TUIAudioCapture) e frase de
  ativação personalizável ("Oi Java"), conferida no começo de cada fala pelo
  Vosk (só conhece a frase) ou, sem ele ou com palavra fora do vocabulário dele,
  pelo whisper local. Depois da frase, grava o pedido até o silêncio.
  A captura só enfileira o áudio; uma thread de trabalho decide (pode esperar o
  whisper sem perder áudio). O tempo conta pelas amostras, não pelo relógio.
  Os avisos chegam na thread de UI pela fila da thread de trabalho (somem quando
  ela para). Nada sai da máquina aqui. }

interface

uses
  System.SysUtils,
  System.Classes,
  System.Generics.Collections,
  UI.Audio.Capture,
  Devbox.WebRtcAec;

type
  TVoiceSamplesProc = reference to procedure(const ASamples: TArray<SmallInt>);

  TVoiceListener = class
  private
    FCapture: TUIAudioCapture;
    FAec: TWebRtcAec;
    FQueue: TThreadedQueue<TArray<SmallInt>>;
    FWorker: TThread;
    FPhrase: string;
    FSimilarity: Single;
    FBusy: Boolean;
    FManual: Boolean;
    FLive: Boolean;
    FEndStream: Boolean;
    FOnStream: TVoiceSamplesProc;
    FDeviceId: Integer;
    FOnWake: TProc;
    FOnRecorded: TVoiceSamplesProc;
    FOnNoSpeech: TProc;
    FOnSpectrum: TUIAudioSpectrumProc;
    procedure StartTestFeed(const APath: string);
  public
    constructor Create;
    destructor Destroy; override;
    { Abre o microfone. False com o motivo. }
    function Start(out AError: string): Boolean;
    procedure Stop;
    function Active: Boolean;
    { Começa a gravar um pedido agora, sem a frase. }
    procedure Trigger;
    property Phrase: string read FPhrase write FPhrase;
    { 0 a 1: quanto o começo da fala precisa parecer com a frase. }
    property Similarity: Single read FSimilarity write FSimilarity;
    property Busy: Boolean read FBusy write FBusy;
    { Conversa ao vivo: depois da frase, em vez de gravar um pedido, todo o áudio
      (a começar pela fala da frase) vai para OnStream, na thread de trabalho, até EndStream. }
    property Live: Boolean read FLive write FLive;
    property OnStream: TVoiceSamplesProc read FOnStream write FOnStream;
    { Microfone: -1 = padrão do Windows; índice em TUIAudioCapture.DeviceNames. Vale no próximo Start. }
    property DeviceId: Integer read FDeviceId write FDeviceId;
    procedure EndStream;
    property OnWake: TProc read FOnWake write FOnWake;
    property OnRecorded: TVoiceSamplesProc read FOnRecorded write FOnRecorded;
    property OnNoSpeech: TProc read FOnNoSpeech write FOnNoSpeech;
    property OnSpectrum: TUIAudioSpectrumProc read FOnSpectrum write FOnSpectrum;
  end;

const
  VoiceDefaultPhrase = 'Oi Java';
  VoiceDefaultSimilarity = 0.72;

// Partes puras (self-check)
{ Minúsculas, sem acento nem pontuação, um espaço entre palavras. }
function NormalizeSpeech(const AText: string): string;
{ 0 a 1 pela distância de edição. }
function TextSimilarity(const A, B: string): Single;
{ O texto começa com a frase (aceita uma palavra antes, como "ah")? ARest = o resto, como foi dito. }
function WakeMatch(const AText, APhrase: string; AMin: Single; out ARest: string): Boolean;
{ Linha no log da voz: memória (últimas linhas, para a tela) e, com DEVBOX_VOICE_LOG, arquivo. }
procedure VoiceLog(const AText: string);
{ As últimas linhas do log e um contador que muda a cada linha nova. Qualquer thread. }
function VoiceLogText(out AVersion: Integer): string;
{ Índice do bloco em que o pedido termina, ou -1. }
function SpeechEndBlock(const ALevels: TArray<Single>; ANoise: Single; ABlockMs: Integer): Integer;

implementation

uses
  Winapi.Windows,
  System.Math,
  System.StrUtils,
  System.IOUtils,
  System.Character,
  System.SyncObjs,
  UI.Audio.Spectrum,
  Devbox.Vosk,
  Devbox.Whisper;

const
  CRate = 16000;
  CSamplesPerMs = CRate div 1000;
  CSpeechMargin = 0.15;       // acima do ruído de fundo = fala (escala de 0 a 1, 60 dB)
  CNoiseAlpha = 0.05;
  CInitialNoise = 0.3;
  CPreRollMs = 300;           // áudio de antes da fala começar (a primeira sílaba)
  CProbeMs = 2200;            // quanto do começo da fala vai para o whisper conferir a frase
  CProbeGapMs = 450;          // pausa que fecha o trecho antes disso
  CMinVoiceMs = 250;          // trecho mais curto é estalo, não fala
  CSilenceEndMs = 1200;
  CNoSpeechMs = 5000;
  CMaxRecordMs = 15000;
  CWakeTailMs = 500;
  CQueueDepth = 4000;
  CPopTimeoutMs = 200;
  CSpectrumMs = 33;
  CSpectrumWindow = 1024;
  CSpectrumBands = 48;

{ Partes puras }

function NormalizeSpeech(const AText: string): string;
var
  LNorm: string;
  LBuf: array of Char;
  LLen, LIndex: Integer;
  LChar: Char;
  LOut: TStringBuilder;
  LSpace: Boolean;
begin
  if AText = '' then
    Exit('');
  // Decompõe e joga fora as marcas de acento: "ação" -> "acao".
  SetLength(LBuf, Length(AText) * 4 + 1);
  LLen := FoldStringW(MAP_COMPOSITE, PChar(AText), Length(AText), @LBuf[0], Length(LBuf));
  SetString(LNorm, PChar(@LBuf[0]), LLen);
  LOut := TStringBuilder.Create;
  try
    LSpace := True;
    for LIndex := 1 to Length(LNorm) do
    begin
      LChar := LNorm[LIndex].ToLower;
      if LChar.GetUnicodeCategory = TUnicodeCategory.ucNonSpacingMark then
        Continue;
      if LChar.IsLetterOrDigit then
      begin
        LOut.Append(LChar);
        LSpace := False;
      end
      else if not LSpace then
      begin
        LOut.Append(' ');
        LSpace := True;
      end;
    end;
    Result := Trim(LOut.ToString);
  finally
    LOut.Free;
  end;
end;

function TextSimilarity(const A, B: string): Single;
var
  LPrev, LCur: TArray<Integer>;
  LI, LJ, LCost: Integer;
begin
  if (A = '') and (B = '') then
    Exit(1);
  SetLength(LPrev, Length(B) + 1);
  SetLength(LCur, Length(B) + 1);
  for LJ := 0 to Length(B) do
    LPrev[LJ] := LJ;
  for LI := 1 to Length(A) do
  begin
    LCur[0] := LI;
    for LJ := 1 to Length(B) do
    begin
      LCost := Ord(A[LI] <> B[LJ]);
      LCur[LJ] := Min(Min(LPrev[LJ] + 1, LCur[LJ - 1] + 1), LPrev[LJ - 1] + LCost);
    end;
    LPrev := Copy(LCur);
  end;
  Result := 1 - LPrev[Length(B)] / Max(Length(A), Length(B));
end;

function WakeMatch(const AText, APhrase: string; AMin: Single; out ARest: string): Boolean;
var
  LWords, LNorm: TArray<string>;
  LPhrase, LJoined: string;
  LCount, LSkip, LTake, LIndex, LBestEnd: Integer;
  LScore, LBest: Single;
begin
  ARest := '';
  LPhrase := NormalizeSpeech(APhrase);
  if LPhrase = '' then
    Exit(False);
  LWords := Trim(AText).Split([' ', #9, #10, #13], TStringSplitOptions.ExcludeEmpty);
  SetLength(LNorm, Length(LWords));
  for LIndex := 0 to High(LWords) do
    LNorm[LIndex] := NormalizeSpeech(LWords[LIndex]);
  LCount := Length(LPhrase.Split([' ']));
  LBest := 0;
  LBestEnd := -1;
  // Uma palavra de sobra antes ("ah, oi java") e o whisper juntando ou separando palavras.
  for LSkip := 0 to 1 do
    for LTake := Max(1, LCount - 1) to LCount + 1 do
    begin
      if LSkip + LTake > Length(LNorm) then
        Continue;
      LJoined := '';
      for LIndex := LSkip to LSkip + LTake - 1 do
        if LNorm[LIndex] <> '' then
          LJoined := LJoined + IfThen(LJoined <> '', ' ', '') + LNorm[LIndex];
      LScore := TextSimilarity(LJoined, LPhrase);
      if LScore > LBest then
      begin
        LBest := LScore;
        LBestEnd := LSkip + LTake;
      end;
    end;
  Result := (LBestEnd > 0) and (LBest >= AMin);
  if Result then
    ARest := Trim(string.Join(' ', Copy(LWords, LBestEnd, MaxInt))).TrimLeft([',', '.', '!', '?', ' ']);
end;

function SpeechEndBlock(const ALevels: TArray<Single>; ANoise: Single; ABlockMs: Integer): Integer;
var
  LIndex, LElapsed, LLastVoice: Integer;
  LStarted: Boolean;
begin
  LStarted := False;
  LLastVoice := 0;
  for LIndex := 0 to High(ALevels) do
  begin
    LElapsed := (LIndex + 1) * ABlockMs;
    if (LElapsed > CWakeTailMs) and (ALevels[LIndex] > ANoise + CSpeechMargin) then
    begin
      LStarted := True;
      LLastVoice := LElapsed;
    end;
    if LStarted and (LElapsed - LLastVoice >= CSilenceEndMs) then
      Exit(LIndex);
    if LElapsed >= CMaxRecordMs then
      Exit(LIndex);
  end;
  Result := -1;
end;

var
  GLogLock: TCriticalSection;
  GLogLines: TArray<string>;
  GLogVersion: Integer;

const
  CLogLines = 300;

function VoiceLogText(out AVersion: Integer): string;
begin
  GLogLock.Enter;
  try
    AVersion := GLogVersion;
    Result := string.Join(sLineBreak, GLogLines);
  finally
    GLogLock.Leave;
  end;
end;

procedure VoiceLog(const AText: string);
var
  LPath: string;
begin
  GLogLock.Enter;
  try
    GLogLines := GLogLines + [FormatDateTime('hh:nn:ss ', Now) + AText];
    if Length(GLogLines) > CLogLines then
      GLogLines := Copy(GLogLines, Length(GLogLines) - CLogLines, MaxInt);
    Inc(GLogVersion);
  finally
    GLogLock.Leave;
  end;
  LPath := GetEnvironmentVariable('DEVBOX_VOICE_LOG');
  if LPath <> '' then
    TFile.AppendAllText(LPath, FormatDateTime('hh:nn:ss.zzz ', Now) + AText + sLineBreak, TEncoding.UTF8);
end;

{ Thread de trabalho }

type
  TWorkState = (wsIdle, wsSegment, wsRejected, wsCommand, wsStream);

  TVoiceWorker = class(TThread)
  private
    FOwner: TVoiceListener;
    FState: TWorkState;
    FNow: Int64;              // ms de áudio já processado
    FNoise: Single;
    FPreRoll: TArray<SmallInt>;
    FAudio: TArray<SmallInt>;
    FSegStart: Int64;
    FLastVoice: Int64;
    FVoiceMs: Int64;
    FCmdStart: Int64;
    FCmdSpeech: Boolean;
    FLastSpectrum: Int64;
    procedure Post(const AProc: TProc);
    procedure Block(const ASamples: TArray<SmallInt>);
    procedure StartCommand(AHasSpeech: Boolean);
    procedure ProbeWake;
    procedure SendSpectrum(const ABlock: TArray<SmallInt>);
  protected
    procedure Execute; override;
  end;

procedure TVoiceWorker.Post(const AProc: TProc);
var
  LProc: TProc;
begin
  LProc := AProc;
  Queue(
    procedure
    begin
      LProc();
    end);
end;

procedure TVoiceWorker.Execute;
var
  LBlock: TArray<SmallInt>;
  LError: string;
begin
  FNoise := CInitialNoise;
  // Carrega o Vosk agora (~1 s): a primeira fala não espera.
  if VoskLoad(LError) then
    VoiceLog('vosk carregado')
  else
    VoiceLog('vosk: ' + LError);
  while not Terminated do
  begin
    if FOwner.FQueue.PopItem(LBlock) <> wrSignaled then
      Continue;
    try
      Block(LBlock);
    except
      // Exceção aqui mataria a escuta sem aviso: registra e segue.
      on E: Exception do
        VoiceLog('erro: ' + E.ClassName + ': ' + E.Message);
    end;
  end;
end;

procedure TVoiceWorker.SendSpectrum(const ABlock: TArray<SmallInt>);
var
  LBands: TArray<Single>;
  LLevel: Single;
  LProc: TUIAudioSpectrumProc;
begin
  LProc := FOwner.FOnSpectrum;
  if not Assigned(LProc) or (FNow - FLastSpectrum < CSpectrumMs) or (Length(FAudio) < CSpectrumWindow) then
    Exit;
  FLastSpectrum := FNow;
  LBands := UISpectrumBands(Copy(FAudio, Length(FAudio) - CSpectrumWindow, CSpectrumWindow), CSpectrumBands, CRate);
  LLevel := UIAudioLevel(ABlock);
  Post(
    procedure
    begin
      LProc(LBands, LLevel);
    end);
end;

procedure TVoiceWorker.StartCommand(AHasSpeech: Boolean);
var
  LStream: TVoiceSamplesProc;
begin
  if FOwner.FLive and Assigned(FOwner.FOnStream) then
  begin
    FState := wsStream;
    FOwner.FEndStream := False;
    if Assigned(FOwner.FOnWake) then
      Post(FOwner.FOnWake);
    // A fala que trouxe a frase vai junto: "Oi chico, qual minha reunião" numa respirada só.
    LStream := FOwner.FOnStream;
    LStream(FAudio);
    Exit;
  end;
  FState := wsCommand;
  FCmdStart := FNow;
  FCmdSpeech := AHasSpeech;
  if AHasSpeech then
    FLastVoice := FNow;
  if Assigned(FOwner.FOnWake) then
    Post(FOwner.FOnWake);
end;

{ Confere a frase no começo da fala: Vosk (~60 ms) ou whisper. Bloqueia (o
  áudio que chega enquanto isso espera na fila). }
procedure TVoiceWorker.ProbeWake;
var
  LText, LError, LRest, LMissing: string;
  LProbe: TArray<SmallInt>;
  LHeard: Boolean;
begin
  LProbe := Copy(FAudio, 0, CProbeMs * CSamplesPerMs);
  LMissing := VoskMissingWords(FOwner.FPhrase);
  LHeard := (LMissing = '') and VoskHear(LProbe, FOwner.FPhrase, LText);
  if LHeard then
    VoiceLog(Format('vosk ouviu "%s" (%.1f s de áudio)', [LText, Length(LProbe) / CRate]));
  if not LHeard then
  begin
    if LMissing <> '' then
      VoiceLog('vosk fora (' + LMissing + '): frase pelo whisper');
    LHeard := WhisperTranscribe(LProbe, LText, LError, FOwner.FPhrase);
    if not LHeard then
    begin
      VoiceLog('whisper: ' + LError);
      FState := wsRejected;
      Exit;
    end;
  end;
  if WakeMatch(LText, FOwner.FPhrase, FOwner.FSimilarity, LRest) then
  begin
    // O Vosk marca o que não é a frase como [unk]: não conta como pedido já começado.
    LRest := Trim(StringReplace(LRest, '[unk]', '', [rfReplaceAll]));
    VoiceLog(Format('frase reconhecida em "%s" (resto "%s")', [LText, LRest]));
    // Pedido já começou junto com a frase ("Oi Java, resuma..."): conta como fala.
    StartCommand(LRest <> '');
  end
  else
  begin
    VoiceLog(Format('não é a frase: "%s"', [LText]));
    FState := wsRejected;
  end;
end;

procedure TVoiceWorker.Block(const ASamples: TArray<SmallInt>);
var
  LLevel: Single;
  LVoiced: Boolean;
  LAudio: TArray<SmallInt>;
  LDone, LNoSpeech: Boolean;
  LBlockMs: Int64;
begin
  LBlockMs := Length(ASamples) div CSamplesPerMs;
  FNow := FNow + LBlockMs;
  LLevel := UIAudioLevel(ASamples);
  LVoiced := LLevel > FNoise + CSpeechMargin;
  case FState of
    wsIdle:
      begin
        if not LVoiced then
          FNoise := FNoise + (LLevel - FNoise) * CNoiseAlpha;
        FPreRoll := FPreRoll + ASamples;
        if Length(FPreRoll) > CPreRollMs * CSamplesPerMs then
          FPreRoll := Copy(FPreRoll, Length(FPreRoll) - CPreRollMs * CSamplesPerMs, MaxInt);
        if FOwner.FManual then
        begin
          FOwner.FManual := False;
          FAudio := nil;
          StartCommand(False);
          Exit;
        end;
        if LVoiced and not FOwner.FBusy then
        begin
          VoiceLog(Format('fala começou: nível %.2f, ruído %.2f', [LLevel, FNoise]));
          FState := wsSegment;
          FAudio := FPreRoll;
          FSegStart := FNow;
          FLastVoice := FNow;
          FVoiceMs := LBlockMs;
        end;
      end;
    wsSegment:
      begin
        FAudio := FAudio + ASamples;
        if LVoiced then
        begin
          FLastVoice := FNow;
          Inc(FVoiceMs, LBlockMs);
        end;
        if FNow - FLastVoice >= CProbeGapMs then
        begin
          if FVoiceMs >= CMinVoiceMs then
            ProbeWake
          else
          begin
            VoiceLog(Format('curta demais: %d ms de voz', [FVoiceMs]));
            FState := wsIdle;
          end;
        end
        else if FNow - FSegStart >= CProbeMs then
          ProbeWake;
      end;
    wsRejected:
      begin
        // Espera a fala acabar para ouvir de novo.
        if LVoiced then
          FLastVoice := FNow
        else if FNow - FLastVoice >= CProbeGapMs then
        begin
          FState := wsIdle;
          FAudio := nil;
        end;
      end;
    wsStream:
      begin
        if FOwner.FEndStream then
        begin
          FState := wsIdle;
          FAudio := nil;
          FPreRoll := nil;
          Exit;
        end;
        // Só a janela do espectro fica guardada.
        FAudio := Copy(FAudio + ASamples, Max(0, Length(FAudio) + Length(ASamples) - CSpectrumWindow), MaxInt);
        SendSpectrum(ASamples);
        FOwner.FOnStream(ASamples);
      end;
    wsCommand:
      begin
        FAudio := FAudio + ASamples;
        SendSpectrum(ASamples);
        if LVoiced and (FCmdSpeech or (FNow - FCmdStart >= CWakeTailMs)) then
        begin
          FCmdSpeech := True;
          FLastVoice := FNow;
        end;
        LNoSpeech := not FCmdSpeech and (FNow - FCmdStart > CNoSpeechMs);
        LDone := (FCmdSpeech and (FNow - FLastVoice >= CSilenceEndMs)) or (FNow - FCmdStart > CMaxRecordMs);
        if not (LDone or LNoSpeech) then
          Exit;
        FState := wsIdle;
        FPreRoll := nil;
        if LNoSpeech then
        begin
          VoiceLog('sem pedido depois da frase');
          FAudio := nil;
          if Assigned(FOwner.FOnNoSpeech) then
            Post(FOwner.FOnNoSpeech);
          Exit;
        end;
        LAudio := FAudio;
        FAudio := nil;
        VoiceLog(Format('pedido gravado: %.1f s', [Length(LAudio) / CRate]));
        if GetEnvironmentVariable('DEVBOX_VOICE_LOG') <> '' then
          TFile.WriteAllBytes(ChangeFileExt(GetEnvironmentVariable('DEVBOX_VOICE_LOG'), '.wav'), PcmToWav(LAudio));
        if Assigned(FOwner.FOnRecorded) then
          Post(
            procedure
            begin
              FOwner.FOnRecorded(LAudio);
            end);
      end;
  end;
end;

{ TVoiceListener }

constructor TVoiceListener.Create;
begin
  inherited Create;
  FPhrase := VoiceDefaultPhrase;
  FSimilarity := VoiceDefaultSimilarity;
  FDeviceId := -1;
end;

destructor TVoiceListener.Destroy;
begin
  Stop;
  inherited;
end;

function TVoiceListener.Active: Boolean;
begin
  Result := FWorker <> nil;
end;

function TVoiceListener.Start(out AError: string): Boolean;
var
  LWorker: TVoiceWorker;
  LAecError: string;
begin
  AError := '';
  if Active then
    Exit(True);
  FQueue := TThreadedQueue<TArray<SmallInt>>.Create(CQueueDepth, INFINITE, CPopTimeoutMs);
  LWorker := TVoiceWorker.Create(True);
  LWorker.FOwner := Self;
  LWorker.FreeOnTerminate := False;
  FWorker := LWorker;
  FWorker.Start;
  // Teste: DEVBOX_VOICE_TEST=arquivo.wav entra no lugar do microfone, no ritmo real.
  if GetEnvironmentVariable('DEVBOX_VOICE_TEST') <> '' then
  begin
    StartTestFeed(GetEnvironmentVariable('DEVBOX_VOICE_TEST'));
    Exit(True);
  end;
  // Cancelamento de eco: a voz do Devbox não volta pelo microfone. Sem a dll, segue cru.
  FAec := TWebRtcAec.Create;
  if not FAec.Open(LAecError) then
  begin
    VoiceLog('sem cancelamento de eco: ' + LAecError);
    FreeAndNil(FAec);
  end;
  FCapture := TUIAudioCapture.Create;
  FCapture.DeviceId := FDeviceId;
  if (FDeviceId >= 0) and (FDeviceId < Length(TUIAudioCapture.DeviceNames)) then
    VoiceLog('microfone: ' + TUIAudioCapture.DeviceNames[FDeviceId])
  else
    VoiceLog('microfone: padrão do Windows');
  VoiceLog(IfThen(FAec <> nil, 'cancelamento de eco ligado', 'cancelamento de eco desligado'));
  FCapture.OnSamples :=
    procedure(const ASamples: TArray<SmallInt>)
    var
      LClean: TArray<SmallInt>;
    begin
      if FAec = nil then
        FQueue.PushItem(ASamples)
      else
      begin
        LClean := FAec.Process(ASamples, AecReference.Take);
        if LClean <> nil then
          FQueue.PushItem(LClean);
      end;
    end;
  Result := FCapture.Start(AError);
  if not Result then
    Stop;
end;

procedure TVoiceListener.StartTestFeed(const APath: string);
const
  CBlock = 640;
  CBlockMs = 40;
  CTailMs = 30000;
var
  LQueue: TThreadedQueue<TArray<SmallInt>>;
begin
  LQueue := FQueue;
  TThread.CreateAnonymousThread(
    procedure
    var
      LBytes: TBytes;
      LSamples, LSilence: TArray<SmallInt>;
      LPos, LIndex, LSize: Integer;
    begin
      LBytes := TFile.ReadAllBytes(APath);
      LPos := 12;
      while LPos + 8 <= Length(LBytes) do
      begin
        LSize := PInteger(@LBytes[LPos + 4])^;
        if (LBytes[LPos] = Ord('d')) and (LBytes[LPos + 1] = Ord('a')) then
        begin
          SetLength(LSamples, Min(LSize, Length(LBytes) - LPos - 8) div 2);
          Move(LBytes[LPos + 8], LSamples[0], Length(LSamples) * 2);
          Break;
        end;
        Inc(LPos, 8 + LSize + (LSize and 1));
      end;
      VoiceLog(Format('teste: %d amostras', [Length(LSamples)]));
      SetLength(LSilence, CBlock);
      LIndex := 0;
      // ponytail: o alimentador de teste não para no Stop; o processo de teste é encerrado pelo PID.
      while LIndex < Length(LSamples) + CTailMs * CSamplesPerMs do
      begin
        if LIndex < Length(LSamples) then
          LQueue.PushItem(Copy(LSamples, LIndex, CBlock))
        else
          LQueue.PushItem(Copy(LSilence));
        Inc(LIndex, CBlock);
        Sleep(CBlockMs);
      end;
    end).Start;
end;

procedure TVoiceListener.Stop;
begin
  FreeAndNil(FCapture);
  FreeAndNil(FAec);
  if FWorker <> nil then
  begin
    FWorker.Terminate;
    FWorker.WaitFor;
    FreeAndNil(FWorker);
  end;
  FreeAndNil(FQueue);
end;

procedure TVoiceListener.Trigger;
begin
  FManual := True;
end;

procedure TVoiceListener.EndStream;
begin
  FEndStream := True;
end;

initialization
  GLogLock := TCriticalSection.Create;

finalization
  GLogLock.Free;

end.
