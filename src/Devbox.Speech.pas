unit Devbox.Speech;

{ Voz do Devbox: texto para fala pela voz pt-BR do Windows (SAPI, "Maria"),
  gerada na memória em PCM 16 kHz mono, e um player (waveOut) que diz em que
  amostra está, para o visualizador animar com o espectro do que está tocando.
  Synthesize bloqueia (rodar fora da thread de UI); o player é da thread de UI. }

interface

uses
  System.SysUtils,
  Winapi.Windows,
  Winapi.MMSystem;

var
  { Saída da voz (player e conversa ao vivo): -1 = padrão do Windows; senão o índice em OutputDeviceNames. }
  VoiceOutputDevice: Integer = -1;

{ Nomes das saídas de áudio; o índice é o VoiceOutputDevice. }
function OutputDeviceNames: TArray<string>;
{ Índice do aparelho com esse nome em ANames, ou -1 (padrão). }
function DeviceIndexByName(const ANames: TArray<string>; const AName: string): Integer;

{ PCM 16 kHz mono do texto falado. False com o motivo. }
function Synthesize(const AText: string; out ASamples: TArray<SmallInt>; out AError: string): Boolean;

type
  TPcmPlayer = class
  private
    FWave: HWAVEOUT;
    FHeader: TWaveHdr;
    FSamples: TArray<SmallInt>;
    procedure Close;
  public
    destructor Destroy; override;
    procedure Play(const ASamples: TArray<SmallInt>);
    procedure Stop;
    function Playing: Boolean;
    { Amostra tocando agora. }
    function Position: Integer;
    { As últimas ACount amostras até a posição atual (para o espectro). }
    function Window(ACount: Integer): TArray<SmallInt>;
  end;

  { Voz que chega em pedaços (conversa ao vivo): cada Write entra na fila do
    waveOut e toca em seguida do anterior. Clear corta na hora (o usuário
    interrompeu). Da thread de UI. }
  TPcmStream = class
  private
    FWave: HWAVEOUT;
    FChunks: TArray<PWaveHdr>;
    FWritten: TArray<SmallInt>;   // tudo o que entrou desde o último Clear (para o espectro)
    procedure Recycle;
  public
    destructor Destroy; override;
    procedure Write(const ASamples: TArray<SmallInt>);
    procedure Clear;
    function Playing: Boolean;
    function Window(ACount: Integer): TArray<SmallInt>;
  end;

implementation

uses
  System.Variants,
  System.Math,
  System.Win.ComObj,
  Winapi.ActiveX,
  Devbox.WebRtcAec,
  Devbox.Voice;

const
  CSampleRate = 16000;
  CFormat16kMono = 18;   // SAFT16kHz16BitMono
  CPortugueseLang = 'Language=416';
  CRate = 1;

{ AudioOutputStream e Voice são "propputref" na automação do SAPI: a atribuição comum não serve. }
procedure PutRef(const AObject: OleVariant; const AName: string; const AValue: OleVariant);
var
  LDisp: IDispatch;
  LName: WideString;
  LId: Integer;
  LParams: TDispParams;
  LNamed: Integer;
  LArg: OleVariant;
begin
  LDisp := IDispatch(AObject);
  LName := AName;
  OleCheck(LDisp.GetIDsOfNames(GUID_NULL, @LName, 1, LOCALE_USER_DEFAULT, @LId));
  LArg := AValue;
  LNamed := DISPID_PROPERTYPUT;
  LParams.rgvarg := @LArg;
  LParams.cArgs := 1;
  LParams.rgdispidNamedArgs := @LNamed;
  LParams.cNamedArgs := 1;
  OleCheck(LDisp.Invoke(LId, GUID_NULL, LOCALE_USER_DEFAULT, DISPATCH_PROPERTYPUTREF, LParams, nil, nil, nil));
end;

function Synthesize(const AText: string; out ASamples: TArray<SmallInt>; out AError: string): Boolean;
var
  LVoice, LStream, LVoices, LData: OleVariant;
  LBytes: Integer;
  LPtr: Pointer;
begin
  ASamples := nil;
  AError := '';
  Result := False;
  CoInitializeEx(nil, COINIT_APARTMENTTHREADED);
  try
    try
      LVoice := CreateOleObject('SAPI.SpVoice');
      LVoices := LVoice.GetVoices(CPortugueseLang, '');
      if LVoices.Count > 0 then
        PutRef(LVoice, 'Voice', LVoices.Item(0));
      LStream := CreateOleObject('SAPI.SpMemoryStream');
      LStream.Format.Type := CFormat16kMono;
      PutRef(LVoice, 'AudioOutputStream', LStream);
      LVoice.Rate := CRate;
      LVoice.Speak(AText, 0);
      LData := LStream.GetData;
      if VarIsArray(LData) then
      begin
        LBytes := VarArrayHighBound(LData, 1) - VarArrayLowBound(LData, 1) + 1;
        SetLength(ASamples, LBytes div SizeOf(SmallInt));
        LPtr := VarArrayLock(LData);
        try
          if Length(ASamples) > 0 then
            Move(LPtr^, ASamples[0], Length(ASamples) * SizeOf(SmallInt));
        finally
          VarArrayUnlock(LData);
        end;
      end;
      Result := Length(ASamples) > 0;
      if not Result then
        AError := 'A voz não gerou áudio';
    except
      on E: Exception do
        AError := 'Voz do Windows: ' + E.Message;
    end;
  finally
    LVoice := Unassigned;
    LStream := Unassigned;
    LVoices := Unassigned;
    LData := Unassigned;
    CoUninitialize;
  end;
end;

{ TPcmPlayer }

destructor TPcmPlayer.Destroy;
begin
  Close;
  inherited;
end;

function OutputDeviceNames: TArray<string>;
var
  LIndex: Integer;
  LCaps: TWaveOutCaps;
begin
  Result := nil;
  for LIndex := 0 to Integer(waveOutGetNumDevs) - 1 do
    if waveOutGetDevCaps(LIndex, @LCaps, SizeOf(LCaps)) = MMSYSERR_NOERROR then
      Result := Result + [string(LCaps.szPname)]
    else
      Result := Result + [''];
end;

function DeviceIndexByName(const ANames: TArray<string>; const AName: string): Integer;
begin
  if AName <> '' then
    for Result := 0 to High(ANames) do
      if SameText(ANames[Result], AName) then
        Exit;
  Result := -1;
end;

function OutputDevice: UINT;
begin
  if (VoiceOutputDevice >= 0) and (VoiceOutputDevice < Integer(waveOutGetNumDevs)) then
    Result := VoiceOutputDevice
  else
    Result := WAVE_MAPPER;
end;

function OutputDeviceName: string;
var
  LNames: TArray<string>;
begin
  LNames := OutputDeviceNames;
  if (VoiceOutputDevice >= 0) and (VoiceOutputDevice < Length(LNames)) then
    Result := LNames[VoiceOutputDevice]
  else
    Result := 'padrão do Windows';
end;

{ Abre a saída da voz e diz no log da voz onde (ou por que não abriu). }
function OpenOutput(var AWave: HWAVEOUT; const AFormat: TWaveFormatEx): Boolean;
var
  LRes: MMRESULT;
begin
  LRes := waveOutOpen(@AWave, OutputDevice, @AFormat, 0, 0, CALLBACK_NULL);
  Result := LRes = MMSYSERR_NOERROR;
  if Result then
  begin
    VoiceLog('voz saindo em: ' + OutputDeviceName);
    if GetEnvironmentVariable('DEVBOX_VOICE_MUTE') <> '' then
      VoiceLog('voz sem som: DEVBOX_VOICE_MUTE ligado');
  end
  else
  begin
    AWave := 0;
    VoiceLog(Format('saída de voz não abriu (erro %d) em %s', [LRes, OutputDeviceName]));
  end;
end;

procedure TPcmPlayer.Close;
begin
  if FWave = 0 then
    Exit;
  AecReference.Stopped;
  waveOutReset(FWave);
  waveOutUnprepareHeader(FWave, @FHeader, SizeOf(FHeader));
  waveOutClose(FWave);
  FWave := 0;
end;

procedure TPcmPlayer.Play(const ASamples: TArray<SmallInt>);
var
  LFormat: TWaveFormatEx;
begin
  Close;
  FSamples := ASamples;
  if Length(FSamples) = 0 then
    Exit;
  FillChar(LFormat, SizeOf(LFormat), 0);
  LFormat.wFormatTag := WAVE_FORMAT_PCM;
  LFormat.nChannels := 1;
  LFormat.nSamplesPerSec := CSampleRate;
  LFormat.wBitsPerSample := 16;
  LFormat.nBlockAlign := SizeOf(SmallInt);
  LFormat.nAvgBytesPerSec := CSampleRate * SizeOf(SmallInt);
  if not OpenOutput(FWave, LFormat) then
    Exit;
  // O cancelamento de eco tira do microfone o que tocar daqui.
  AecReference.Started(FSamples);
  FillChar(FHeader, SizeOf(FHeader), 0);
  FHeader.lpData := PAnsiChar(@FSamples[0]);
  FHeader.dwBufferLength := Length(FSamples) * SizeOf(SmallInt);
  // Teste: DEVBOX_VOICE_MUTE toca com volume zero (a posição anda igual).
  if GetEnvironmentVariable('DEVBOX_VOICE_MUTE') <> '' then
    waveOutSetVolume(FWave, 0);
  waveOutPrepareHeader(FWave, @FHeader, SizeOf(FHeader));
  waveOutWrite(FWave, @FHeader, SizeOf(FHeader));
end;

procedure TPcmPlayer.Stop;
begin
  Close;
end;

function TPcmPlayer.Playing: Boolean;
begin
  Result := (FWave <> 0) and ((FHeader.dwFlags and WHDR_DONE) = 0);
end;

function TPcmPlayer.Position: Integer;
var
  LTime: TMMTime;
begin
  Result := 0;
  if FWave = 0 then
    Exit;
  LTime.wType := TIME_SAMPLES;
  if waveOutGetPosition(FWave, @LTime, SizeOf(LTime)) = MMSYSERR_NOERROR then
    Result := LTime.sample;
end;

function TPcmPlayer.Window(ACount: Integer): TArray<SmallInt>;
var
  LEnd: Integer;
begin
  LEnd := Min(Position, Length(FSamples));
  Result := Copy(FSamples, Max(0, LEnd - ACount), Min(ACount, LEnd));
end;

{ TPcmStream }

destructor TPcmStream.Destroy;
begin
  Clear;
  if FWave <> 0 then
    waveOutClose(FWave);
  inherited;
end;

procedure TPcmStream.Recycle;
var
  LIndex: Integer;
begin
  LIndex := 0;
  while LIndex < Length(FChunks) do
    if FChunks[LIndex].dwFlags and WHDR_DONE <> 0 then
    begin
      waveOutUnprepareHeader(FWave, FChunks[LIndex], SizeOf(TWaveHdr));
      FreeMem(FChunks[LIndex].lpData);
      Dispose(FChunks[LIndex]);
      Delete(FChunks, LIndex, 1);
    end
    else
      Inc(LIndex);
end;

procedure TPcmStream.Write(const ASamples: TArray<SmallInt>);
var
  LFormat: TWaveFormatEx;
  LChunk: PWaveHdr;
begin
  if Length(ASamples) = 0 then
    Exit;
  if FWave = 0 then
  begin
    FillChar(LFormat, SizeOf(LFormat), 0);
    LFormat.wFormatTag := WAVE_FORMAT_PCM;
    LFormat.nChannels := 1;
    LFormat.nSamplesPerSec := CSampleRate;
    LFormat.wBitsPerSample := 16;
    LFormat.nBlockAlign := SizeOf(SmallInt);
    LFormat.nAvgBytesPerSec := CSampleRate * SizeOf(SmallInt);
    if not OpenOutput(FWave, LFormat) then
      Exit;
    if GetEnvironmentVariable('DEVBOX_VOICE_MUTE') <> '' then
      waveOutSetVolume(FWave, 0);
  end;
  Recycle;
  New(LChunk);
  FillChar(LChunk^, SizeOf(TWaveHdr), 0);
  LChunk.dwBufferLength := Length(ASamples) * SizeOf(SmallInt);
  GetMem(LChunk.lpData, LChunk.dwBufferLength);
  Move(ASamples[0], LChunk.lpData^, LChunk.dwBufferLength);
  waveOutPrepareHeader(FWave, LChunk, SizeOf(TWaveHdr));
  waveOutWrite(FWave, LChunk, SizeOf(TWaveHdr));
  FChunks := FChunks + [LChunk];
  FWritten := FWritten + ASamples;
  AecReference.Append(ASamples);
end;

procedure TPcmStream.Clear;
begin
  AecReference.Stopped;
  if FWave <> 0 then
  begin
    waveOutReset(FWave);   // marca todos como prontos
    Recycle;
  end;
  FWritten := nil;
end;

function TPcmStream.Playing: Boolean;
begin
  Recycle;
  Result := Length(FChunks) > 0;
end;

function TPcmStream.Window(ACount: Integer): TArray<SmallInt>;
var
  LTime: TMMTime;
  LEnd: Integer;
begin
  Result := nil;
  if FWave = 0 then
    Exit;
  LTime.wType := TIME_SAMPLES;
  if waveOutGetPosition(FWave, @LTime, SizeOf(LTime)) <> MMSYSERR_NOERROR then
    Exit;
  // A posição conta desde que o aparelho abriu; FWritten só desde o último Clear: usa o fim.
  LEnd := Min(Integer(LTime.sample), Length(FWritten));
  Result := Copy(FWritten, Max(0, LEnd - ACount), Min(ACount, LEnd));
end;

end.
