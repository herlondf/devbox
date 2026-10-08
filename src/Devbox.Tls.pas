unit Devbox.Tls;

{ Conexão TCP com TLS pelo SChannel do Windows (sem OpenSSL). O Windows valida
  o certificado e o nome do servidor e escolhe a versão do TLS. Bloqueia: usar
  fora da thread de UI. Sem TLS só para 127.0.0.1 (servidor falso de teste). }

interface

uses
  System.SysUtils,
  System.SyncObjs;

type
  ETls = class(Exception);

  TTlsSocket = class
  private
    FSock: NativeUInt;
    FHost: string;
    FTls: Boolean;
    FCred: record Lower, Upper: NativeUInt; end;
    FCtx: record Lower, Upper: NativeUInt; end;
    FHasCred, FHasCtx: Boolean;
    FHeader, FTrailer, FMaxMsg: Cardinal;
    FEnc: TBytes;      // cifrado recebido e ainda não aberto
    FPlain: TBytes;    // aberto e ainda não lido
    FLock: TCriticalSection;   // o contexto do SChannel não aceita cifrar e abrir ao mesmo tempo
    procedure RawSend(const AData: Pointer; ALen: Integer);
    function RawRecv(var ABuf: TBytes): Integer;
    procedure Handshake(const AInitial: TBytes);
    procedure FillPlain;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Connect(const AHost: string; APort: Integer; AUseTls: Boolean; ATimeoutMs: Integer = 30000);
    procedure Close;
    { Derruba a conexão sem soltar o TLS: destrava quem está lendo em outra thread. Close depois. }
    procedure Abort;
    procedure Send(const AData: TBytes);
    procedure SendText(const AText: string);
    { Até CRLF (sem ele). Texto em UTF-8 (IMAP usa ASCII nas linhas). }
    function ReadLine: string;
    function ReadBytes(ACount: Integer): TBytes;
  end;

implementation

uses
  Winapi.Windows,
  Winapi.Winsock2,
  System.Math;

type
  TSecHandle = record
    Lower, Upper: NativeUInt;
  end;
  PSecHandle = ^TSecHandle;

  TSecBuffer = record
    cbBuffer: Cardinal;
    BufferType: Cardinal;
    pvBuffer: Pointer;
  end;
  PSecBuffer = ^TSecBuffer;

  TSecBufferDesc = record
    ulVersion: Cardinal;
    cBuffers: Cardinal;
    pBuffers: PSecBuffer;
  end;
  PSecBufferDesc = ^TSecBufferDesc;

  TSchannelCred = record
    dwVersion: DWORD;
    cCreds: DWORD;
    paCred: Pointer;
    hRootStore: Pointer;
    cMappers: DWORD;
    aphMappers: Pointer;
    cSupportedAlgs: DWORD;
    palgSupportedAlgs: Pointer;
    grbitEnabledProtocols: DWORD;
    dwMinimumCipherStrength: DWORD;
    dwMaximumCipherStrength: DWORD;
    dwSessionLifespan: DWORD;
    dwFlags: DWORD;
    dwCredFormat: DWORD;
  end;

  TStreamSizes = record
    cbHeader, cbTrailer, cbMaximumMessage, cBuffers, cbBlockSize: Cardinal;
  end;

const
  UNISP_NAME = 'Microsoft Unified Security Protocol Provider';
  SECPKG_CRED_OUTBOUND = 2;
  SCHANNEL_CRED_VERSION = 4;
  SCH_CRED_NO_DEFAULT_CREDS = $10;
  SCH_CRED_AUTO_CRED_VALIDATION = $20;
  SCH_USE_STRONG_CRYPTO = $00400000;
  ISC_REQ_REPLAY_DETECT = $4;
  ISC_REQ_SEQUENCE_DETECT = $8;
  ISC_REQ_CONFIDENTIALITY = $10;
  ISC_REQ_ALLOCATE_MEMORY = $100;
  ISC_REQ_EXTENDED_ERROR = $4000;
  ISC_REQ_STREAM = $8000;
  SECBUFFER_EMPTY = 0;
  SECBUFFER_DATA = 1;
  SECBUFFER_TOKEN = 2;
  SECBUFFER_EXTRA = 5;
  SECBUFFER_STREAM_TRAILER = 6;
  SECBUFFER_STREAM_HEADER = 7;
  SECPKG_ATTR_STREAM_SIZES = 4;
  SEC_E_OK = 0;
  SEC_I_CONTINUE_NEEDED = $00090312;
  SEC_I_CONTEXT_EXPIRED = $00090317;
  SEC_I_INCOMPLETE_CREDENTIALS = $00090320;
  SEC_I_RENEGOTIATE = $00090321;
  SEC_E_INCOMPLETE_MESSAGE = Integer($80090318);
  CReqFlags = ISC_REQ_SEQUENCE_DETECT or ISC_REQ_REPLAY_DETECT or ISC_REQ_CONFIDENTIALITY or
    ISC_REQ_ALLOCATE_MEMORY or ISC_REQ_EXTENDED_ERROR or ISC_REQ_STREAM;
  CRecvChunk = 16384;

function AcquireCredentialsHandleW(pszPrincipal, pszPackage: PWideChar; fCredentialUse: Cardinal; pvLogonID,
  pAuthData, pGetKeyFn, pvGetKeyArgument: Pointer; phCredential: PSecHandle; ptsExpiry: PInt64): Integer; stdcall;
  external 'secur32.dll';
function FreeCredentialsHandle(phCredential: PSecHandle): Integer; stdcall; external 'secur32.dll';
function InitializeSecurityContextW(phCredential, phContext: PSecHandle; pszTargetName: PWideChar;
  fContextReq, Reserved1, TargetDataRep: Cardinal; pInput: PSecBufferDesc; Reserved2: Cardinal;
  phNewContext: PSecHandle; pOutput: PSecBufferDesc; pfContextAttr: PCardinal; ptsExpiry: PInt64): Integer;
  stdcall; external 'secur32.dll';
function DeleteSecurityContext(phContext: PSecHandle): Integer; stdcall; external 'secur32.dll';
function FreeContextBuffer(pvContextBuffer: Pointer): Integer; stdcall; external 'secur32.dll';
function QueryContextAttributesW(phContext: PSecHandle; ulAttribute: Cardinal; pBuffer: Pointer): Integer;
  stdcall; external 'secur32.dll';
function EncryptMessage(phContext: PSecHandle; fQOP: Cardinal; pMessage: PSecBufferDesc;
  MessageSeqNo: Cardinal): Integer; stdcall; external 'secur32.dll';
function DecryptMessage(phContext: PSecHandle; pMessage: PSecBufferDesc; MessageSeqNo: Cardinal;
  pfQOP: PCardinal): Integer; stdcall; external 'secur32.dll';

var
  GWsaReady: Boolean;

procedure Fail(const AWhat: string; ACode: Integer);
begin
  raise ETls.CreateFmt('%s (0x%.8x)', [AWhat, Cardinal(ACode)]);
end;

{ TTlsSocket }

constructor TTlsSocket.Create;
var
  Wsa: TWSAData;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FSock := INVALID_SOCKET;
  if not GWsaReady then
  begin
    if WSAStartup($0202, Wsa) <> 0 then
      raise ETls.Create('Winsock não iniciou');
    GWsaReady := True;
  end;
end;

destructor TTlsSocket.Destroy;
begin
  Close;
  FLock.Free;
  inherited;
end;

procedure TTlsSocket.Abort;
begin
  if FSock <> INVALID_SOCKET then
    shutdown(FSock, 2);   // SD_BOTH
end;

procedure TTlsSocket.Close;
begin
  if FHasCtx then
    DeleteSecurityContext(@FCtx);
  if FHasCred then
    FreeCredentialsHandle(@FCred);
  FHasCtx := False;
  FHasCred := False;
  if FSock <> INVALID_SOCKET then
    closesocket(FSock);
  FSock := INVALID_SOCKET;
  FEnc := nil;
  FPlain := nil;
end;

procedure TTlsSocket.Connect(const AHost: string; APort: Integer; AUseTls: Boolean; ATimeoutMs: Integer);
var
  Hints: addrinfoW;
  Res, P: PaddrinfoW;
  Rc: Integer;
  Cred: TSchannelCred;
begin
  Close;
  FHost := AHost;
  FTls := AUseTls;
  if not FTls and (AHost <> '127.0.0.1') then
    raise ETls.Create('Sem TLS só para 127.0.0.1');
  FillChar(Hints, SizeOf(Hints), 0);
  Hints.ai_family := AF_UNSPEC;
  Hints.ai_socktype := SOCK_STREAM;
  Hints.ai_protocol := IPPROTO_TCP;
  Res := nil;
  Rc := GetAddrInfoW(PChar(AHost), PChar(IntToStr(APort)), Hints, Res);
  if Rc <> 0 then
    raise ETls.CreateFmt('Servidor não encontrado: %s', [AHost]);
  try
    P := Res;
    while P <> nil do
    begin
      FSock := socket(P.ai_family, P.ai_socktype, P.ai_protocol);
      if FSock <> INVALID_SOCKET then
      begin
        setsockopt(FSock, SOL_SOCKET, SO_RCVTIMEO, MarshaledAString(@ATimeoutMs), SizeOf(ATimeoutMs));
        setsockopt(FSock, SOL_SOCKET, SO_SNDTIMEO, MarshaledAString(@ATimeoutMs), SizeOf(ATimeoutMs));
        if Winapi.Winsock2.connect(FSock, P.ai_addr^, P.ai_addrlen) = 0 then
          Break;
        closesocket(FSock);
        FSock := INVALID_SOCKET;
      end;
      P := PaddrinfoW(P.ai_next);
    end;
  finally
    FreeAddrInfoW(Res^);
  end;
  if FSock = INVALID_SOCKET then
    raise ETls.CreateFmt('Não conectou em %s:%d', [AHost, APort]);
  if not FTls then
    Exit;
  FillChar(Cred, SizeOf(Cred), 0);
  Cred.dwVersion := SCHANNEL_CRED_VERSION;
  // Validação automática: certificado e nome conferidos pelo Windows.
  Cred.dwFlags := SCH_CRED_NO_DEFAULT_CREDS or SCH_CRED_AUTO_CRED_VALIDATION or SCH_USE_STRONG_CRYPTO;
  Rc := AcquireCredentialsHandleW(nil, UNISP_NAME, SECPKG_CRED_OUTBOUND, nil, @Cred, nil, nil, @FCred, nil);
  if Rc <> SEC_E_OK then
    Fail('TLS: credencial do SChannel', Rc);
  FHasCred := True;
  Handshake(nil);
end;

procedure TTlsSocket.RawSend(const AData: Pointer; ALen: Integer);
var
  Sent, N: Integer;
begin
  Sent := 0;
  while Sent < ALen do
  begin
    N := Winapi.Winsock2.send(FSock, PByte(AData)[Sent], ALen - Sent, 0);
    if N <= 0 then
      raise ETls.Create('Conexão caiu ao enviar');
    Inc(Sent, N);
  end;
end;

{ Acrescenta o que chegar a ABuf. 0 = conexão fechada. }
function TTlsSocket.RawRecv(var ABuf: TBytes): Integer;
var
  Old: Integer;
begin
  Old := Length(ABuf);
  SetLength(ABuf, Old + CRecvChunk);
  Result := recv(FSock, ABuf[Old], CRecvChunk, 0);
  if Result < 0 then
  begin
    SetLength(ABuf, Old);
    raise ETls.Create('Sem resposta do servidor (tempo esgotado)');
  end;
  SetLength(ABuf, Old + Result);
end;

procedure TTlsSocket.Handshake(const AInitial: TBytes);
var
  InBufs: array[0..1] of TSecBuffer;
  OutBuf: TSecBuffer;
  InDesc, OutDesc: TSecBufferDesc;
  Attrs: Cardinal;
  Rc: Integer;
  Buf, Extra: TBytes;
  First: Boolean;
  Sizes: TStreamSizes;
begin
  Buf := AInitial;
  First := not FHasCtx;
  while True do
  begin
    OutBuf.cbBuffer := 0;
    OutBuf.BufferType := SECBUFFER_TOKEN;
    OutBuf.pvBuffer := nil;
    OutDesc.ulVersion := 0;
    OutDesc.cBuffers := 1;
    OutDesc.pBuffers := @OutBuf;
    if First then
      Rc := InitializeSecurityContextW(@FCred, nil, PChar(FHost), CReqFlags, 0, 0, nil, 0, @FCtx, @OutDesc,
        @Attrs, nil)
    else
    begin
      if Length(Buf) = 0 then
      begin
        if RawRecv(Buf) = 0 then
          raise ETls.Create('O servidor fechou no aperto de mão do TLS');
      end;
      InBufs[0].cbBuffer := Length(Buf);
      InBufs[0].BufferType := SECBUFFER_TOKEN;
      InBufs[0].pvBuffer := @Buf[0];
      InBufs[1].cbBuffer := 0;
      InBufs[1].BufferType := SECBUFFER_EMPTY;
      InBufs[1].pvBuffer := nil;
      InDesc.ulVersion := 0;
      InDesc.cBuffers := 2;
      InDesc.pBuffers := @InBufs[0];
      Rc := InitializeSecurityContextW(@FCred, @FCtx, PChar(FHost), CReqFlags, 0, 0, @InDesc, 0, nil, @OutDesc,
        @Attrs, nil);
    end;
    if First then
    begin
      First := False;
      FHasCtx := True;
    end;
    if Rc = SEC_E_INCOMPLETE_MESSAGE then
    begin
      // Falta pedaço da mensagem do servidor: lê mais e tenta de novo.
      if RawRecv(Buf) = 0 then
        raise ETls.Create('O servidor fechou no aperto de mão do TLS');
      Continue;
    end;
    if (OutBuf.cbBuffer > 0) and (OutBuf.pvBuffer <> nil) then
    begin
      RawSend(OutBuf.pvBuffer, OutBuf.cbBuffer);
      FreeContextBuffer(OutBuf.pvBuffer);
    end;
    // O que sobrou além da mensagem lida volta para a próxima volta (ou para os dados).
    Extra := nil;
    if (Length(Buf) > 0) and (InBufs[1].BufferType = SECBUFFER_EXTRA) and (InBufs[1].cbBuffer > 0) then
      Extra := Copy(Buf, Length(Buf) - Integer(InBufs[1].cbBuffer), InBufs[1].cbBuffer);
    if Rc = SEC_E_OK then
    begin
      FEnc := FEnc + Extra;
      Break;
    end;
    if (Rc = SEC_I_CONTINUE_NEEDED) or (Rc = SEC_I_INCOMPLETE_CREDENTIALS) then
    begin
      Buf := Extra;
      InBufs[1].BufferType := SECBUFFER_EMPTY;
      Continue;
    end;
    Fail('TLS: aperto de mão recusado (certificado ou protocolo)', Rc);
  end;
  Rc := QueryContextAttributesW(@FCtx, SECPKG_ATTR_STREAM_SIZES, @Sizes);
  if Rc <> SEC_E_OK then
    Fail('TLS: tamanhos do fluxo', Rc);
  FHeader := Sizes.cbHeader;
  FTrailer := Sizes.cbTrailer;
  FMaxMsg := Sizes.cbMaximumMessage;
end;

procedure TTlsSocket.Send(const AData: TBytes);
var
  Pos_, Len: Integer;
  Msg: TBytes;
  Bufs: array[0..3] of TSecBuffer;
  Desc: TSecBufferDesc;
  Rc: Integer;
begin
  if not FTls then
  begin
    if Length(AData) > 0 then
      RawSend(@AData[0], Length(AData));
    Exit;
  end;
  FLock.Enter;
  try
    Pos_ := 0;
    while Pos_ < Length(AData) do
    begin
      Len := Min(Integer(FMaxMsg), Length(AData) - Pos_);
      SetLength(Msg, Integer(FHeader) + Len + Integer(FTrailer));
      Move(AData[Pos_], Msg[FHeader], Len);
      Bufs[0].cbBuffer := FHeader;
      Bufs[0].BufferType := SECBUFFER_STREAM_HEADER;
      Bufs[0].pvBuffer := @Msg[0];
      Bufs[1].cbBuffer := Len;
      Bufs[1].BufferType := SECBUFFER_DATA;
      Bufs[1].pvBuffer := @Msg[FHeader];
      Bufs[2].cbBuffer := FTrailer;
      Bufs[2].BufferType := SECBUFFER_STREAM_TRAILER;
      Bufs[2].pvBuffer := @Msg[Integer(FHeader) + Len];
      Bufs[3].cbBuffer := 0;
      Bufs[3].BufferType := SECBUFFER_EMPTY;
      Bufs[3].pvBuffer := nil;
      Desc.ulVersion := 0;
      Desc.cBuffers := 4;
      Desc.pBuffers := @Bufs[0];
      Rc := EncryptMessage(@FCtx, 0, @Desc, 0);
      if Rc <> SEC_E_OK then
        Fail('TLS: cifrar', Rc);
      RawSend(@Msg[0], Bufs[0].cbBuffer + Bufs[1].cbBuffer + Bufs[2].cbBuffer);
      Inc(Pos_, Len);
    end;
  finally
    FLock.Leave;
  end;
end;

procedure TTlsSocket.SendText(const AText: string);
begin
  Send(TEncoding.UTF8.GetBytes(AText));
end;

{ Traz mais texto aberto para FPlain (bloqueia até chegar algo). }
procedure TTlsSocket.FillPlain;
var
  Bufs: array[0..3] of TSecBuffer;
  Desc: TSecBufferDesc;
  Rc, I: Integer;
  Extra, Data: TBytes;
begin
  if not FTls then
  begin
    if RawRecv(FPlain) = 0 then
      raise ETls.Create('O servidor fechou a conexão');
    Exit;
  end;
  while True do
  begin
    if Length(FEnc) = 0 then
      if RawRecv(FEnc) = 0 then
        raise ETls.Create('O servidor fechou a conexão');
    Bufs[0].cbBuffer := Length(FEnc);
    Bufs[0].BufferType := SECBUFFER_DATA;
    Bufs[0].pvBuffer := @FEnc[0];
    for I := 1 to 3 do
    begin
      Bufs[I].cbBuffer := 0;
      Bufs[I].BufferType := SECBUFFER_EMPTY;
      Bufs[I].pvBuffer := nil;
    end;
    Desc.ulVersion := 0;
    Desc.cBuffers := 4;
    Desc.pBuffers := @Bufs[0];
    FLock.Enter;
    try
      Rc := DecryptMessage(@FCtx, @Desc, 0, nil);
    finally
      FLock.Leave;
    end;
    if Rc = SEC_E_INCOMPLETE_MESSAGE then
    begin
      if RawRecv(FEnc) = 0 then
        raise ETls.Create('O servidor fechou a conexão');
      Continue;
    end;
    if Rc = SEC_I_CONTEXT_EXPIRED then
      raise ETls.Create('O servidor encerrou o TLS');
    if (Rc <> SEC_E_OK) and (Rc <> SEC_I_RENEGOTIATE) then
      Fail('TLS: abrir dados', Rc);
    Data := nil;
    Extra := nil;
    // DecryptMessage abre no próprio buffer: copia antes de mexer em FEnc.
    for I := 0 to 3 do
      if (Bufs[I].BufferType = SECBUFFER_DATA) and (Bufs[I].cbBuffer > 0) then
      begin
        SetLength(Data, Bufs[I].cbBuffer);
        Move(Bufs[I].pvBuffer^, Data[0], Bufs[I].cbBuffer);
      end
      else if (Bufs[I].BufferType = SECBUFFER_EXTRA) and (Bufs[I].cbBuffer > 0) then
      begin
        SetLength(Extra, Bufs[I].cbBuffer);
        Move(Bufs[I].pvBuffer^, Extra[0], Bufs[I].cbBuffer);
      end;
    FEnc := Extra;
    FPlain := FPlain + Data;
    if Rc = SEC_I_RENEGOTIATE then
    begin
      // TLS 1.3 manda mensagem de sessão depois do aperto de mão: volta ao contexto.
      Extra := FEnc;
      FEnc := nil;
      FLock.Enter;
      try
        Handshake(Extra);
      finally
        FLock.Leave;
      end;
    end;
    if Length(Data) > 0 then
      Exit;
  end;
end;

function TTlsSocket.ReadLine: string;
var
  I: Integer;
begin
  while True do
  begin
    for I := 0 to Length(FPlain) - 2 do
      if (FPlain[I] = 13) and (FPlain[I + 1] = 10) then
      begin
        Result := TEncoding.UTF8.GetString(FPlain, 0, I);
        FPlain := Copy(FPlain, I + 2, MaxInt);
        Exit;
      end;
    FillPlain;
  end;
end;

function TTlsSocket.ReadBytes(ACount: Integer): TBytes;
begin
  while Length(FPlain) < ACount do
    FillPlain;
  Result := Copy(FPlain, 0, ACount);
  FPlain := Copy(FPlain, ACount, MaxInt);
end;

end.
