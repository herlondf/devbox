unit Devbox.WebRtcAec;

{ Cancelamento de eco do WebRTC (AEC3, o mesmo do Chrome) pela livekit_ffi.dll
  (Apache 2.0, só 64 bits) de voice\aec. A voz que o Devbox toca vira a
  referência; o microfone sai sem ela, e a IA não se ouve.
  A dll fala protobuf: os poucos campos usados vão codificados aqui à mão.
  Quadros de 10 ms (160 amostras a 16 kHz), processados no lugar. }

interface

uses
  System.SysUtils,
  System.SyncObjs;

type
  { O que está tocando agora: o player avisa, a captura pega no ritmo do relógio. }
  TAecReference = class
  private
    FLock: TCriticalSection;
    FSamples: TArray<SmallInt>;
    FStart: UInt64;
    FCursor: Integer;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Started(const ASamples: TArray<SmallInt>);
    { Mais voz na fila do player (conversa ao vivo): toca logo depois do que já estava. }
    procedure Append(const ASamples: TArray<SmallInt>);
    procedure Stopped;
    { Amostras tocadas desde a última chamada (vazio se nada toca). }
    function Take: TArray<SmallInt>;
  end;

  TWebRtcAec = class
  private
    FApm: UInt64;
    FIn: TArray<SmallInt>;
    FRender: TArray<SmallInt>;
    procedure Frame(const AData: Pointer; AReverse: Boolean);
  public
    destructor Destroy; override;
    { Abre o AEC3 (eco + ruído + passa-alta). False com o motivo. }
    function Open(out AError: string): Boolean;
    { Microfone cru entra, microfone sem eco sai (em múltiplos de 10 ms; o resto espera o
      próximo bloco). ARender: o que tocou no mesmo intervalo (AecReference.Take). }
    function Process(const ASamples, ARender: TArray<SmallInt>): TArray<SmallInt>;
  end;

var
  AecReference: TAecReference;

{ Carrega a dll (uma vez). False com o motivo. }
function WebRtcAecLoad(out AError: string): Boolean;

// Partes puras (self-check)
function PbVarint(AValue: UInt64): TBytes;
function PbField(AField: Integer; AValue: UInt64): TBytes;
function PbMessage(AField: Integer; const ABody: TBytes): TBytes;
{ Valor (varint) ou corpo (len) do campo AField no nível de cima de AData. }
function PbFind(const AData: TBytes; AField: Integer; out AValue: UInt64; out ABody: TBytes): Boolean;

implementation

uses
  Winapi.Windows,
  System.Math,
  System.IOUtils,
  Devbox.Whisper;

const
  CRate = 16000;
  CFrame = CRate div 100;   // 10 ms
  CSamplesPerMs = CRate div 1000;
  // Campos de livekit_ffi (ffi.proto, audio_frame.proto)
  CReqNewApm = 50;
  CReqProcess = 51;
  CReqReverse = 52;
  CRespNewApm = 49;
  CRespProcess = 50;
  CRespReverse = 51;
  CWireVarint = 0;
  CWireLen = 2;

type
  TFfiCallback = procedure(AData: PByte; ALen: NativeUInt); cdecl;
  TFfiInitialize = procedure(ACallback: TFfiCallback; ACaptureLogs: Boolean; ASdk, AVersion: PAnsiChar); cdecl;
  TFfiRequest = function(AData: PByte; ALen: NativeUInt; out AResp: PByte; out ARespLen: NativeUInt): UInt64; cdecl;
  TFfiDropHandle = function(AHandle: UInt64): Boolean; cdecl;

var
  GLock: TCriticalSection;
  GLib: HMODULE;
  GError: string;
  FfiRequest: TFfiRequest;
  FfiDropHandle: TFfiDropHandle;

{ Protobuf mínimo }

function PbVarint(AValue: UInt64): TBytes;
begin
  Result := nil;
  repeat
    if AValue >= $80 then
      Result := Result + [Byte(AValue and $7F) or $80]
    else
      Result := Result + [Byte(AValue)];
    AValue := AValue shr 7;
  until AValue = 0;
end;

function PbField(AField: Integer; AValue: UInt64): TBytes;
begin
  Result := PbVarint(UInt64(AField) shl 3 or CWireVarint) + PbVarint(AValue);
end;

function PbMessage(AField: Integer; const ABody: TBytes): TBytes;
begin
  Result := PbVarint(UInt64(AField) shl 3 or CWireLen) + PbVarint(Length(ABody)) + ABody;
end;

function ReadVarint(const AData: TBytes; var APos: Integer; out AValue: UInt64): Boolean;
var
  LShift: Integer;
begin
  AValue := 0;
  LShift := 0;
  while APos < Length(AData) do
  begin
    AValue := AValue or (UInt64(AData[APos] and $7F) shl LShift);
    Inc(APos);
    if AData[APos - 1] and $80 = 0 then
      Exit(True);
    Inc(LShift, 7);
  end;
  Result := False;
end;

function PbFind(const AData: TBytes; AField: Integer; out AValue: UInt64; out ABody: TBytes): Boolean;
var
  LPos: Integer;
  LKey, LLen: UInt64;
begin
  AValue := 0;
  ABody := nil;
  LPos := 0;
  while ReadVarint(AData, LPos, LKey) do
  begin
    case LKey and 7 of
      CWireVarint:
        begin
          if not ReadVarint(AData, LPos, AValue) then
            Exit(False);
          if Integer(LKey shr 3) = AField then
            Exit(True);
        end;
      CWireLen:
        begin
          if not ReadVarint(AData, LPos, LLen) or (LPos + Integer(LLen) > Length(AData)) then
            Exit(False);
          if Integer(LKey shr 3) = AField then
          begin
            ABody := Copy(AData, LPos, LLen);
            Exit(True);
          end;
          Inc(LPos, LLen);
        end;
      1: Inc(LPos, 8);
      5: Inc(LPos, 4);
    else
      Exit(False);
    end;
  end;
  Result := False;
end;

{ Uma ida e volta à dll; a resposta vem copiada (o buffer é da dll até soltar o handle). }
function Request(const AReq: TBytes): TBytes;
var
  LResp: PByte;
  LLen: NativeUInt;
  LHandle: UInt64;
  LMask: TArithmeticExceptionMask;
begin
  // O AEC3 divide por zero e usa NaN de propósito: com as exceções do Delphi ligadas, cai.
  LMask := SetExceptionMask(exAllArithmeticExceptions);
  try
    LHandle := FfiRequest(@AReq[0], Length(AReq), LResp, LLen);
    SetLength(Result, LLen);
    if LLen > 0 then
      Move(LResp^, Result[0], LLen);
    if LHandle <> 0 then
      FfiDropHandle(LHandle);
  finally
    SetExceptionMask(LMask);
  end;
end;

procedure IgnoreEvent(AData: PByte; ALen: NativeUInt); cdecl;
begin
  // Só o AEC é usado: não há eventos de sala para tratar.
end;

function WebRtcAecLoad(out AError: string): Boolean;
var
  LPath: string;
  LInit: TFfiInitialize;
  LMask: TArithmeticExceptionMask;
begin
  GLock.Enter;
  try
    if GLib <> 0 then
      Exit(True);
    if GError = '' then
    begin
      LPath := TPath.Combine(TPath.Combine(VoiceDir, 'aec'), 'livekit_ffi.dll');
      if not FileExists(LPath) then
        GError := 'cancelamento de eco não está em ' + ExtractFilePath(LPath) + ' (rode tools\voice-deps.ps1)'
      else
      begin
        GLib := LoadLibrary(PChar(LPath));
        if GLib = 0 then
          GError := 'livekit_ffi.dll não carregou: ' + SysErrorMessage(GetLastError)
        else
        begin
          @LInit := GetProcAddress(GLib, 'livekit_ffi_initialize');
          @FfiRequest := GetProcAddress(GLib, 'livekit_ffi_request');
          @FfiDropHandle := GetProcAddress(GLib, 'livekit_ffi_drop_handle');
          if not Assigned(LInit) or not Assigned(FfiRequest) or not Assigned(FfiDropHandle) then
          begin
            GError := 'livekit_ffi.dll de outra versão (falta função)';
            FreeLibrary(GLib);
            GLib := 0;
          end
          else
          begin
            LMask := SetExceptionMask(exAllArithmeticExceptions);
            try
              LInit(IgnoreEvent, False, 'devbox', '1');
            finally
              SetExceptionMask(LMask);
            end;
          end;
        end;
      end;
    end;
    AError := GError;
    Result := GLib <> 0;
  finally
    GLock.Leave;
  end;
end;

{ TAecReference }

constructor TAecReference.Create;
begin
  inherited;
  FLock := TCriticalSection.Create;
end;

destructor TAecReference.Destroy;
begin
  FLock.Free;
  inherited;
end;

procedure TAecReference.Started(const ASamples: TArray<SmallInt>);
begin
  FLock.Enter;
  try
    FSamples := ASamples;
    FStart := GetTickCount64;
    FCursor := 0;
  finally
    FLock.Leave;
  end;
end;

procedure TAecReference.Append(const ASamples: TArray<SmallInt>);
var
  LNow: Int64;
begin
  FLock.Enter;
  try
    LNow := Int64(GetTickCount64 - FStart) * CSamplesPerMs;
    if (FSamples = nil) or (LNow >= Length(FSamples)) then
    begin
      // Fila vazia (ou acabou e o player esperou): recomeça a linha do tempo agora.
      FSamples := ASamples;   // o que sobrou já tocou: atrasado não serve de referência
      FStart := GetTickCount64;
      FCursor := 0;
    end
    else
      FSamples := FSamples + ASamples;
  finally
    FLock.Leave;
  end;
end;

procedure TAecReference.Stopped;
begin
  FLock.Enter;
  try
    FSamples := nil;
  finally
    FLock.Leave;
  end;
end;

function TAecReference.Take: TArray<SmallInt>;
var
  LNow: Integer;
begin
  FLock.Enter;
  try
    Result := nil;
    if FSamples = nil then
      Exit;
    LNow := Integer(GetTickCount64 - FStart) * CSamplesPerMs;
    if LNow > Length(FSamples) then
      LNow := Length(FSamples);
    if LNow > FCursor then
    begin
      Result := Copy(FSamples, FCursor, LNow - FCursor);
      FCursor := LNow;
    end;
    if FCursor >= Length(FSamples) then
      FSamples := nil;
  finally
    FLock.Leave;
  end;
end;

{ TWebRtcAec }

destructor TWebRtcAec.Destroy;
begin
  if FApm <> 0 then
    FfiDropHandle(FApm);
  inherited;
end;

function TWebRtcAec.Open(out AError: string): Boolean;
var
  LResp, LApm, LOwned, LHandle, LBody: TBytes;
  LValue: UInt64;
begin
  if not WebRtcAecLoad(AError) then
    Exit(False);
  // proto2: os quatro campos são obrigatórios, até o falso (eco, ganho, passa-alta, ruído).
  LResp := Request(PbMessage(CReqNewApm, PbField(1, 1) + PbField(2, 0) + PbField(3, 1) + PbField(4, 1)));
  // FfiResponse.new_apm -> NewApmResponse.apm -> OwnedApm.handle -> FfiOwnedHandle.id
  // Cada nível num buffer próprio: o mesmo como entrada e saída (out) zera a entrada.
  Result := PbFind(LResp, CRespNewApm, LValue, LApm) and PbFind(LApm, 1, LValue, LOwned) and
    PbFind(LOwned, 1, LValue, LHandle) and PbFind(LHandle, 1, FApm, LBody) and (FApm <> 0);
  if not Result then
    AError := 'o WebRTC não abriu o cancelamento de eco';
end;

procedure TWebRtcAec.Frame(const AData: Pointer; AReverse: Boolean);
var
  LBody: TBytes;
begin
  LBody := PbField(1, FApm) + PbField(2, UInt64(NativeUInt(AData))) + PbField(3, CFrame * SizeOf(SmallInt)) +
    PbField(4, CRate) + PbField(5, 1);
  if AReverse then
    Request(PbMessage(CReqReverse, LBody))
  else
    Request(PbMessage(CReqProcess, LBody));
end;

function TWebRtcAec.Process(const ASamples, ARender: TArray<SmallInt>): TArray<SmallInt>;
var
  LCount, LIndex: Integer;
begin
  FIn := FIn + ASamples;
  FRender := FRender + ARender;
  LCount := Length(FIn) div CFrame;
  Result := Copy(FIn, 0, LCount * CFrame);
  FIn := Copy(FIn, LCount * CFrame, MaxInt);
  for LIndex := 0 to LCount - 1 do
  begin
    // Referência primeiro (o que tocou neste intervalo), depois o microfone do mesmo intervalo.
    if Length(FRender) >= CFrame then
    begin
      Frame(@FRender[0], True);
      FRender := Copy(FRender, CFrame, MaxInt);
    end;
    Frame(@Result[LIndex * CFrame], False);
  end;
end;

initialization
  GLock := TCriticalSection.Create;
  AecReference := TAecReference.Create;

finalization
  // A dll fica até o processo sair (o runtime dela tem threads próprias).
  AecReference.Free;
  GLock.Free;

end.
