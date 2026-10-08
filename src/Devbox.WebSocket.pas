unit Devbox.WebSocket;

{ Cliente WebSocket (RFC 6455) sobre o TTlsSocket (SChannel). Uma thread lê
  (ReadMessage bloqueia) e qualquer outra envia (SendText): o socket trava o
  contexto TLS. ws:// só para 127.0.0.1 (servidor falso de teste). }

interface

uses
  System.SysUtils,
  System.SyncObjs,
  Devbox.Tls;

type
  EWebSocket = class(Exception);

  TWsClient = class
  private
    FSocket: TTlsSocket;
    FSendLock: TCriticalSection;
    FOpen: Boolean;
    procedure SendFrame(AOpcode: Byte; const APayload: TBytes);
  public
    constructor Create;
    destructor Destroy; override;
    { AUrl: wss://host[:porta]/caminho?consulta. AHeaders: 'Nome: valor'. Bloqueia. }
    procedure Connect(const AUrl: string; const AHeaders: TArray<string>; ATimeoutMs: Integer = 15000);
    procedure SendText(const AText: string);
    { Próxima mensagem (texto ou binária, lida como UTF-8). False quando o servidor fecha;
      AReason traz o motivo do fechamento, se veio. }
    function ReadMessage(out AText: string; out AReason: string): Boolean;
    procedure Close;
    { Destrava o ReadMessage de outra thread (ele levanta exceção). Close depois. }
    procedure Abort;
    property Open: Boolean read FOpen;
  end;

// Partes puras (self-check)
function WsFrame(AOpcode: Byte; const APayload: TBytes; const AMask: TBytes): TBytes;
function WsAcceptKey(const AKey: string): string;

implementation

uses
  System.NetEncoding,
  System.Hash,
  System.Math;

const
  COpText = 1;
  COpBinary = 2;
  COpClose = 8;
  COpPing = 9;
  COpPong = 10;
  COpContinuation = 0;
  CFin = $80;
  CMaskBit = $80;
  CLen16 = 126;
  CLen64 = 127;
  CWsGuid = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';
  CKeyBytes = 16;
  CMaskBytes = 4;
  CHttpsPort = 443;
  CHttpPort = 80;

function WsFrame(AOpcode: Byte; const APayload: TBytes; const AMask: TBytes): TBytes;
var
  LLen, LIndex, LHead: Integer;
begin
  LLen := Length(APayload);
  if LLen < CLen16 then
    LHead := 2
  else if LLen <= $FFFF then
    LHead := 4
  else
    LHead := 10;
  SetLength(Result, LHead + CMaskBytes + LLen);
  Result[0] := CFin or AOpcode;
  if LLen < CLen16 then
    Result[1] := CMaskBit or LLen
  else if LLen <= $FFFF then
  begin
    Result[1] := CMaskBit or CLen16;
    Result[2] := Byte(LLen shr 8);
    Result[3] := Byte(LLen);
  end
  else
  begin
    Result[1] := CMaskBit or CLen64;
    for LIndex := 0 to 7 do
      Result[2 + LIndex] := Byte(UInt64(LLen) shr (8 * (7 - LIndex)));
  end;
  Move(AMask[0], Result[LHead], CMaskBytes);
  // Cliente sempre mascara (o servidor recusa quadro sem máscara).
  for LIndex := 0 to LLen - 1 do
    Result[LHead + CMaskBytes + LIndex] := APayload[LIndex] xor AMask[LIndex mod CMaskBytes];
end;

function WsAcceptKey(const AKey: string): string;
begin
  Result := TNetEncoding.Base64.EncodeBytesToString(THashSHA1.GetHashBytes(AKey + CWsGuid));
end;

function RandomBytes(ACount: Integer): TBytes;
var
  LIndex: Integer;
begin
  SetLength(Result, ACount);
  for LIndex := 0 to ACount - 1 do
    Result[LIndex] := Random(256);
end;

{ TWsClient }

constructor TWsClient.Create;
begin
  inherited;
  FSocket := TTlsSocket.Create;
  FSendLock := TCriticalSection.Create;
end;

destructor TWsClient.Destroy;
begin
  Close;
  FSocket.Free;
  FSendLock.Free;
  inherited;
end;

procedure TWsClient.Connect(const AUrl: string; const AHeaders: TArray<string>; ATimeoutMs: Integer);
var
  LTls: Boolean;
  LRest, LHost, LPath, LKey, LLine, LRequest, LAccept, LHeader: string;
  LPort, LSlash, LColon: Integer;
begin
  LTls := AUrl.StartsWith('wss://', True);
  if not LTls and not AUrl.StartsWith('ws://', True) then
    raise EWebSocket.Create('Endereço WebSocket inválido: ' + AUrl);
  LRest := Copy(AUrl, IfThen(LTls, 7, 6), MaxInt);
  LSlash := Pos('/', LRest);
  if LSlash = 0 then
  begin
    LHost := LRest;
    LPath := '/';
  end
  else
  begin
    LHost := Copy(LRest, 1, LSlash - 1);
    LPath := Copy(LRest, LSlash, MaxInt);
  end;
  LPort := IfThen(LTls, CHttpsPort, CHttpPort);
  LColon := Pos(':', LHost);
  if LColon > 0 then
  begin
    LPort := StrToInt(Copy(LHost, LColon + 1, MaxInt));
    LHost := Copy(LHost, 1, LColon - 1);
  end;
  FSocket.Connect(LHost, LPort, LTls, ATimeoutMs);
  LKey := TNetEncoding.Base64.EncodeBytesToString(RandomBytes(CKeyBytes));
  LRequest := 'GET ' + LPath + ' HTTP/1.1'#13#10 + 'Host: ' + LHost + #13#10 + 'Upgrade: websocket'#13#10 +
    'Connection: Upgrade'#13#10 + 'Sec-WebSocket-Key: ' + LKey + #13#10 + 'Sec-WebSocket-Version: 13'#13#10;
  for LHeader in AHeaders do
    LRequest := LRequest + LHeader + #13#10;
  FSocket.SendText(LRequest + #13#10);
  LLine := FSocket.ReadLine;
  if Pos(' 101 ', LLine + ' ') = 0 then
  begin
    // O corpo da recusa (401, 404...) costuma dizer o motivo: lê umas linhas.
    LRequest := LLine;
    repeat
      LHeader := FSocket.ReadLine;
    until LHeader = '';
    raise EWebSocket.Create('O servidor recusou a conexão: ' + LRequest);
  end;
  LAccept := '';
  repeat
    LLine := FSocket.ReadLine;
    if LLine.StartsWith('Sec-WebSocket-Accept:', True) then
      LAccept := Trim(Copy(LLine, 22, MaxInt));
  until LLine = '';
  if LAccept <> WsAcceptKey(LKey) then
    raise EWebSocket.Create('Resposta WebSocket inválida');
  FOpen := True;
end;

procedure TWsClient.SendFrame(AOpcode: Byte; const APayload: TBytes);
begin
  FSendLock.Enter;
  try
    FSocket.Send(WsFrame(AOpcode, APayload, RandomBytes(CMaskBytes)));
  finally
    FSendLock.Leave;
  end;
end;

procedure TWsClient.SendText(const AText: string);
begin
  if not FOpen then
    raise EWebSocket.Create('WebSocket fechado');
  SendFrame(COpText, TEncoding.UTF8.GetBytes(AText));
end;

function TWsClient.ReadMessage(out AText: string; out AReason: string): Boolean;
var
  LHead, LExt, LMask, LPayload, LMessage: TBytes;
  LOpcode: Byte;
  LFin, LMasked: Boolean;
  LLen: UInt64;
  LIndex: Integer;
begin
  AText := '';
  AReason := '';
  LMessage := nil;
  while True do
  begin
    LHead := FSocket.ReadBytes(2);
    LFin := LHead[0] and CFin <> 0;
    LOpcode := LHead[0] and $0F;
    LMasked := LHead[1] and CMaskBit <> 0;
    LLen := LHead[1] and $7F;
    if LLen = CLen16 then
    begin
      LExt := FSocket.ReadBytes(2);
      LLen := (LExt[0] shl 8) or LExt[1];
    end
    else if LLen = CLen64 then
    begin
      LExt := FSocket.ReadBytes(8);
      LLen := 0;
      for LIndex := 0 to 7 do
        LLen := (LLen shl 8) or LExt[LIndex];
    end;
    if LMasked then
      LMask := FSocket.ReadBytes(CMaskBytes);
    LPayload := FSocket.ReadBytes(LLen);
    if LMasked then
      for LIndex := 0 to High(LPayload) do
        LPayload[LIndex] := LPayload[LIndex] xor LMask[LIndex mod CMaskBytes];
    case LOpcode of
      COpPing:
        SendFrame(COpPong, LPayload);
      COpPong:
        ;
      COpClose:
        begin
          FOpen := False;
          if Length(LPayload) > 2 then
            AReason := TEncoding.UTF8.GetString(LPayload, 2, Length(LPayload) - 2);
          Exit(False);
        end;
      COpText, COpBinary, COpContinuation:
        begin
          LMessage := LMessage + LPayload;
          if LFin then
          begin
            AText := TEncoding.UTF8.GetString(LMessage);
            Exit(True);
          end;
        end;
    end;
  end;
end;

procedure TWsClient.Abort;
begin
  FOpen := False;
  FSocket.Abort;
end;

procedure TWsClient.Close;
begin
  if FOpen then
  begin
    FOpen := False;
    try
      SendFrame(COpClose, nil);
    except
      // Já caiu: fechar o socket basta.
    end;
  end;
  FSocket.Close;
end;

end.
