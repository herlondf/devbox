unit Devbox.Whisper;

{ Fala para texto. Local: whisper.cpp (whisper-server x64 de voice\whisper, ou
  o de voice\whisper-cuda com o modelo grande na placa NVIDIA), um processo à
  parte com o modelo carregado uma vez, ouvindo só em 127.0.0.1:4085. O processo
  entra num job do Windows que o mata junto com o Devbox (inclusive se o Devbox
  cair). Nuvem: Groq ou OpenAI (/audio/transcriptions), o áudio do pedido sai do
  PC. Tudo bloqueia: fora da thread de UI. }

interface

uses
  System.SysUtils;

type
  TSttEngine = (stLocal, stLocalGpu, stGroq, stOpenAI);

const
  WhisperPort = 4085;
  WhisperDefaultModel = 'ggml-base-q5_1.bin';
  WhisperGpuModel = 'ggml-large-v3-turbo-q5_0.bin';
  SttEngineNames: array[TSttEngine] of string = ('Local rápido (whisper base, processador)',
    'Local preciso (whisper large-v3-turbo, placa NVIDIA)', 'Nuvem: Groq (whisper-large-v3-turbo)',
    'Nuvem: OpenAI (gpt-4o-transcribe)');

{ Motor que transcreve o pedido e a chave da nuvem (vazia nos locais). Trocar o
  local derruba o servidor; o certo sobe no próximo uso. }
procedure SttConfigure(AEngine: TSttEngine; const AKey: string);
function SttEngine: TSttEngine;
function SttIsCloud(AEngine: TSttEngine): Boolean;
{ Onde fica a chave de cada nuvem no Credential Manager. }
function SttSecretTarget(AEngine: TSttEngine): string;
{ Pedido para texto pelo motor escolhido. APrompt: palavras que devem sair certas. }
function SttTranscribe(const ASamples: TArray<SmallInt>; out AText, AError: string; const APrompt: string = ''): Boolean;

{ Sobe o servidor local (o do motor escolhido) se ainda não subiu. False com o motivo. Pode bloquear uns segundos. }
function WhisperStart(out AError: string): Boolean;
procedure WhisperStop;
{ Pasta com o whisper.cpp e o modelo (voice ao lado do exe; DEVBOX_VOICE_DIR troca). }
function VoiceDir: string;
{ Texto falado em ASamples (PCM 16 kHz mono). Idioma português. APrompt: palavras que devem sair certas (a frase de ativação). }
function WhisperTranscribe(const ASamples: TArray<SmallInt>; out AText, AError: string; const APrompt: string = ''): Boolean;
{ WAV (cabeçalho de 44 bytes) com as amostras. Puro. }
function PcmToWav(const ASamples: TArray<SmallInt>; ASampleRate: Integer = 16000): TBytes;

implementation

uses
  Winapi.Windows,
  System.Classes,
  System.Math,
  System.StrUtils,
  System.IOUtils,
  System.JSON,
  System.SyncObjs,
  System.Net.HttpClient,
  System.Net.Mime,
  System.Net.URLClient,
  Devbox.Usage;

const
  CStartTimeoutMs = 30000;
  CPollMs = 200;
  CMaxThreads = 8;
  CCloudTimeoutMs = 30000;
  CSampleRate = 16000;
  CCloudUrls: array[stGroq..stOpenAI] of string = ('https://api.groq.com/openai/v1/audio/transcriptions',
    'https://api.openai.com/v1/audio/transcriptions');
  CCloudModels: array[stGroq..stOpenAI] of string = ('whisper-large-v3-turbo', 'gpt-4o-transcribe');
  JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = $2000;
  JobObjectExtendedLimitInformation = 9;

type
  TJobBasicLimit = record
    PerProcessUserTimeLimit: Int64;
    PerJobUserTimeLimit: Int64;
    LimitFlags: DWORD;
    MinimumWorkingSetSize: NativeUInt;
    MaximumWorkingSetSize: NativeUInt;
    ActiveProcessLimit: DWORD;
    Affinity: NativeUInt;
    PriorityClass: DWORD;
    SchedulingClass: DWORD;
  end;
  TIoCounters = record
    ReadOperationCount, WriteOperationCount, OtherOperationCount: UInt64;
    ReadTransferCount, WriteTransferCount, OtherTransferCount: UInt64;
  end;
  TJobExtendedLimit = record
    BasicLimitInformation: TJobBasicLimit;
    IoInfo: TIoCounters;
    ProcessMemoryLimit: NativeUInt;
    JobMemoryLimit: NativeUInt;
    PeakProcessMemoryUsed: NativeUInt;
    PeakJobMemoryUsed: NativeUInt;
  end;

function CreateJobObjectW(lpJobAttributes: Pointer; lpName: PWideChar): THandle; stdcall; external kernel32;
function SetInformationJobObject(hJob: THandle; JobObjectInfoClass: Integer; lpJobObjectInfo: Pointer;
  cbJobObjectInfoLength: DWORD): BOOL; stdcall; external kernel32;
function AssignProcessToJobObject(hJob, hProcess: THandle): BOOL; stdcall; external kernel32;

var
  GLock: TCriticalSection;
  GJob: THandle;
  GProcess: THandle;
  GRunningGpu: Boolean;
  GEngine: TSttEngine;
  GKey: string;

function BaseUrl: string;
begin
  Result := Format('http://127.0.0.1:%d', [WhisperPort]);
end;

function VoiceDir: string;
begin
  // DEVBOX_VOICE_DIR: outra pasta (o self-check fica longe do exe).
  Result := GetEnvironmentVariable('DEVBOX_VOICE_DIR');
  if Result = '' then
    Result := TPath.Combine(ExtractFilePath(ParamStr(0)), 'voice');
end;

procedure SttConfigure(AEngine: TSttEngine; const AKey: string);
begin
  GLock.Enter;
  try
    GEngine := AEngine;
    GKey := AKey;
  finally
    GLock.Leave;
  end;
end;

function SttEngine: TSttEngine;
begin
  GLock.Enter;
  try
    Result := GEngine;
  finally
    GLock.Leave;
  end;
end;

function SttIsCloud(AEngine: TSttEngine): Boolean;
begin
  Result := AEngine in [stGroq, stOpenAI];
end;

function SttSecretTarget(AEngine: TSttEngine): string;
begin
  Result := 'Devbox:stt:' + IntToStr(Ord(AEngine));
end;

function ServerUp: Boolean;
var
  LHttp: THTTPClient;
begin
  LHttp := THTTPClient.Create;
  try
    LHttp.ConnectionTimeout := 1000;
    LHttp.ResponseTimeout := 1000;
    try
      Result := LHttp.Get(BaseUrl + '/').StatusCode = 200;
    except
      Result := False;
    end;
  finally
    LHttp.Free;
  end;
end;

function WhisperStart(out AError: string): Boolean;
var
  LExe, LModel, LCmd: string;
  LSi: TStartupInfo;
  LPi: TProcessInformation;
  LLimit: TJobExtendedLimit;
  LStart: UInt64;
  LGpu: Boolean;
begin
  AError := '';
  GLock.Enter;
  try
    LGpu := GEngine = stLocalGpu;
    if (GProcess <> 0) and (WaitForSingleObject(GProcess, 0) = WAIT_TIMEOUT) then
    begin
      if GRunningGpu = LGpu then
        Exit(True);
      TerminateProcess(GProcess, 0);
      WaitForSingleObject(GProcess, CStartTimeoutMs);
      CloseHandle(GProcess);
      GProcess := 0;
    end;
    // Os modelos ficam em voice\whisper; o executável com CUDA, em voice\whisper-cuda.
    LExe := TPath.Combine(TPath.Combine(VoiceDir, IfThen(LGpu, 'whisper-cuda', 'whisper')), 'whisper-server.exe');
    LModel := TPath.Combine(TPath.Combine(VoiceDir, 'whisper'), IfThen(LGpu, WhisperGpuModel, WhisperDefaultModel));
    if not FileExists(LExe) or not FileExists(LModel) then
    begin
      AError := 'whisper.cpp ou o modelo não estão em ' + VoiceDir + ' (rode tools\voice-deps.ps1' +
        IfThen(LGpu, ' -Gpu', '') + ')';
      Exit(False);
    end;
    if GJob = 0 then
    begin
      // Job que mata o servidor quando o Devbox fecha (ou cai).
      GJob := CreateJobObjectW(nil, nil);
      FillChar(LLimit, SizeOf(LLimit), 0);
      LLimit.BasicLimitInformation.LimitFlags := JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
      SetInformationJobObject(GJob, JobObjectExtendedLimitInformation, @LLimit, SizeOf(LLimit));
    end;
    LCmd := Format('"%s" -m "%s" --host 127.0.0.1 --port %d -l pt -t %d -bs 1 -bo 1',
      [LExe, LModel, WhisperPort, Min(CMaxThreads, TThread.ProcessorCount)]);
    FillChar(LSi, SizeOf(LSi), 0);
    LSi.cb := SizeOf(LSi);
    LSi.dwFlags := STARTF_USESHOWWINDOW;
    LSi.wShowWindow := SW_HIDE;
    UniqueString(LCmd);
    if not CreateProcess(nil, PChar(LCmd), nil, nil, False, CREATE_NO_WINDOW or CREATE_SUSPENDED, nil,
      PChar(ExtractFilePath(LExe)), LSi, LPi) then
    begin
      AError := 'whisper-server não abriu: ' + SysErrorMessage(GetLastError);
      Exit(False);
    end;
    AssignProcessToJobObject(GJob, LPi.hProcess);
    ResumeThread(LPi.hThread);
    CloseHandle(LPi.hThread);
    GProcess := LPi.hProcess;
    GRunningGpu := LGpu;
  finally
    GLock.Leave;
  end;
  // Espera o modelo carregar.
  LStart := GetTickCount64;
  while GetTickCount64 - LStart < CStartTimeoutMs do
  begin
    if ServerUp then
      Exit(True);
    if WaitForSingleObject(GProcess, 0) <> WAIT_TIMEOUT then
    begin
      AError := 'whisper-server fechou ao abrir (porta ' + IntToStr(WhisperPort) + ' em uso?)';
      Exit(False);
    end;
    Sleep(CPollMs);
  end;
  AError := 'whisper-server não respondeu em 30 s';
  Result := False;
end;

procedure WhisperStop;
begin
  GLock.Enter;
  try
    if GProcess <> 0 then
    begin
      TerminateProcess(GProcess, 0);
      CloseHandle(GProcess);
      GProcess := 0;
    end;
  finally
    GLock.Leave;
  end;
end;

function PcmToWav(const ASamples: TArray<SmallInt>; ASampleRate: Integer): TBytes;
const
  CHeader = 44;
var
  LData: Integer;

  procedure Put32(AAt: Integer; AValue: Cardinal);
  begin
    PCardinal(@Result[AAt])^ := AValue;
  end;

  procedure Put16(AAt: Integer; AValue: Word);
  begin
    PWord(@Result[AAt])^ := AValue;
  end;

  procedure PutTag(AAt: Integer; const ATag: AnsiString);
  begin
    Move(ATag[1], Result[AAt], 4);
  end;

begin
  LData := Length(ASamples) * SizeOf(SmallInt);
  SetLength(Result, CHeader + LData);
  PutTag(0, 'RIFF');
  Put32(4, 36 + LData);
  PutTag(8, 'WAVE');
  PutTag(12, 'fmt ');
  Put32(16, 16);
  Put16(20, 1);
  Put16(22, 1);
  Put32(24, ASampleRate);
  Put32(28, ASampleRate * SizeOf(SmallInt));
  Put16(32, SizeOf(SmallInt));
  Put16(34, 16);
  PutTag(36, 'data');
  Put32(40, LData);
  if LData > 0 then
    Move(ASamples[0], Result[CHeader], LData);
end;

{ Manda o WAV e lê "text" da resposta. AModel e AKey vazios no servidor local. }
function PostAudio(const AUrl, AModel, AKey: string; ATimeoutMs: Integer; const ASamples: TArray<SmallInt>;
  const APrompt: string; out AText, AError: string): Boolean;
var
  LHttp: THTTPClient;
  LForm: TMultipartFormData;
  LWav: TBytesStream;
  LResp: IHTTPResponse;
  LJson: TJSONValue;
  LBody: string;
begin
  AText := '';
  AError := '';
  Result := False;
  LHttp := THTTPClient.Create;
  LForm := TMultipartFormData.Create;
  LWav := TBytesStream.Create(PcmToWav(ASamples));
  try
    LHttp.ConnectionTimeout := 5000;
    LHttp.ResponseTimeout := ATimeoutMs;
    LForm.AddStream('file', LWav, 'pedido.wav', 'audio/wav');
    LForm.AddField('response_format', 'json');
    LForm.AddField('temperature', '0');
    if AModel <> '' then
    begin
      LForm.AddField('model', AModel);
      LForm.AddField('language', 'pt');
    end;
    if APrompt <> '' then
      LForm.AddField('prompt', APrompt);
    try
      if AKey <> '' then
        LResp := LHttp.Post(AUrl, LForm, nil, [TNetHeader.Create('Authorization', 'Bearer ' + AKey)])
      else
        LResp := LHttp.Post(AUrl, LForm);
    except
      on E: Exception do
      begin
        AError := E.Message;
        Exit;
      end;
    end;
    LBody := LResp.ContentAsString(TEncoding.UTF8);
    LJson := TJSONObject.ParseJSONValue(LBody);
    try
      if LResp.StatusCode <> 200 then
      begin
        AError := Format('HTTP %d', [LResp.StatusCode]);
        if (LJson <> nil) and (LJson.GetValue<string>('error.message', '') <> '') then
          AError := AError + ': ' + LJson.GetValue<string>('error.message', '');
        Exit;
      end;
      if LJson <> nil then
        AText := Trim(LJson.GetValue<string>('text', ''));
    finally
      LJson.Free;
    end;
    Result := True;
  finally
    LWav.Free;
    LForm.Free;
    LHttp.Free;
  end;
end;

function WhisperTranscribe(const ASamples: TArray<SmallInt>; out AText, AError: string; const APrompt: string): Boolean;
begin
  AText := '';
  if not WhisperStart(AError) then
    Exit(False);
  Result := PostAudio(BaseUrl + '/inference', '', '', CCloudTimeoutMs * 2, ASamples, APrompt, AText, AError);
  if not Result then
    AError := 'whisper: ' + AError;
end;

function SttTranscribe(const ASamples: TArray<SmallInt>; out AText, AError: string; const APrompt: string): Boolean;
var
  LEngine: TSttEngine;
  LKey: string;
  LUsage: TAiUsage;
begin
  GLock.Enter;
  try
    LEngine := GEngine;
    LKey := GKey;
  finally
    GLock.Leave;
  end;
  if not SttIsCloud(LEngine) then
    Exit(WhisperTranscribe(ASamples, AText, AError, APrompt));
  AText := '';
  if LKey = '' then
  begin
    AError := 'Falta a chave da nuvem em Configurações › Voz';
    Exit(False);
  end;
  Result := PostAudio(CCloudUrls[LEngine], CCloudModels[LEngine], LKey, CCloudTimeoutMs, ASamples, APrompt, AText,
    AError);
  if not Result then
  begin
    AError := IfThen(LEngine = stGroq, 'Groq: ', 'OpenAI: ') + AError;
    Exit;
  end;
  LUsage := Default(TAiUsage);
  LUsage.Provider := IfThen(LEngine = stGroq, 'groq', 'openai');
  LUsage.Model := CCloudModels[LEngine];
  LUsage.Kind := 'transcrição';
  LUsage.AudioSeconds := Length(ASamples) / CSampleRate;
  UsageAdd(LUsage);
end;

initialization
  GLock := TCriticalSection.Create;

finalization
  WhisperStop;
  GLock.Free;

end.
