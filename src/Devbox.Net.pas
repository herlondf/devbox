unit Devbox.Net;

{ Rede: checar URL (código, tempo, vencimento do certificado), testar porta TCP,
  achar adaptador de VPN ligado e o receptor de webhook local. As checagens
  bloqueiam: rodar fora da thread de UI. }

interface

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  IdContext,
  IdCustomHTTPServer,
  IdHTTPServer;

type
  TUrlResult = record
    Code: Integer;           // 0 = não respondeu
    Ms: Integer;
    Error: string;
    CertExpiry: TDateTime;   // 0 = sem https ou não leu
    function Up: Boolean;    // 2xx ou 3xx
  end;

  TWebhookHit = record
    At: TDateTime;
    Method: string;
    Path: string;
    Remote: string;
    Headers: string;
    Body: string;
  end;

  TWebhookEvent = reference to procedure(const AHit: TWebhookHit);

  { Servidor HTTP local: responde AResponseCode a tudo e avisa cada chamada. }
  TWebhookServer = class
  private
    FServer: TIdHTTPServer;
    FOnHit: TWebhookEvent;
    FResponseCode: Integer;
    procedure CommandGet(AContext: TIdContext; ARequestInfo: TIdHTTPRequestInfo;
      AResponseInfo: TIdHTTPResponseInfo);
    function GetActive: Boolean;
  public
    constructor Create(const AOnHit: TWebhookEvent);
    destructor Destroy; override;
    procedure Start(APort: Integer);
    procedure Stop;
    property Active: Boolean read GetActive;
    property ResponseCode: Integer read FResponseCode write FResponseCode;
  end;

function CheckUrl(const AUrl: string): TUrlResult;

{ Conecta em AHost:APort em até ATimeoutMs. Serve para "a VPN está ligada?"
  apontando para um servidor que só responde dentro dela. }
function TcpReachable(const AHost: string; APort, ATimeoutMs: Integer): Boolean;

{ Adaptadores de VPN ligados agora (Cisco, Forti, GlobalProtect, WireGuard...). }
function ActiveVpnAdapters: TArray<string>;

{ "host:porta" -> partes. False se não der para ler. }
function ParseHostPort(const AText: string; out AHost: string; out APort: Integer): Boolean;

implementation

uses
  Winapi.Windows,
  Winapi.Winsock2,
  Winapi.IpHlpApi,
  Winapi.IpTypes,
  System.StrUtils,
  System.Math,
  System.Net.HttpClient,
  System.Net.URLClient,
  IdTCPClient;

function TUrlResult.Up: Boolean;
begin
  Result := (Code >= 200) and (Code < 400);
end;

threadvar
  CertExpiry: TDateTime;

{ Só lê a data; quem decide se aceita é o Windows. Roda na thread do pedido,
  que é a da checagem: a threadvar não mistura duas checagens ao mesmo tempo. }
procedure ReadCertExpiry(const Sender: TObject; const ARequest: TURLRequest; const Certificate: TCertificate;
  var Accepted: Boolean);
begin
  CertExpiry := Certificate.Expiry;
end;

function CheckUrl(const AUrl: string): TUrlResult;
const
  CConnectMs = 5000;
  CResponseMs = 10000;
var
  Http: THTTPClient;
  Resp: IHTTPResponse;
  Start: UInt64;
begin
  Result := Default(TUrlResult);
  Http := THTTPClient.Create;
  try
    Http.ConnectionTimeout := CConnectMs;
    Http.ResponseTimeout := CResponseMs;
    Http.HandleRedirects := True;
    Http.UserAgent := 'Devbox/monitor';
    CertExpiry := 0;
    Http.ValidateServerCertificateCallback := ReadCertExpiry;
    Start := GetTickCount64;
    try
      // HEAD mede a resposta sem baixar a página (o GET do github.com levava 29 s).
      // Servidor que não aceita HEAD responde 405/501: aí vai de GET.
      Resp := Http.Head(AUrl);
      if (Resp.StatusCode = 405) or (Resp.StatusCode = 501) then
        Resp := Http.Get(AUrl);
      Result.Code := Resp.StatusCode;
    except
      on E: Exception do
        Result.Error := E.Message;
    end;
    Result.Ms := GetTickCount64 - Start;
    Result.CertExpiry := CertExpiry;
  finally
    Http.Free;
  end;
end;

function ParseHostPort(const AText: string; out AHost: string; out APort: Integer): Boolean;
var
  I: Integer;
begin
  I := LastDelimiter(':', Trim(AText));
  Result := (I > 1) and TryStrToInt(Copy(Trim(AText), I + 1, MaxInt), APort) and InRange(APort, 1, 65535);
  if Result then
    AHost := Copy(Trim(AText), 1, I - 1);
end;

function TcpReachable(const AHost: string; APort, ATimeoutMs: Integer): Boolean;
var
  C: TIdTCPClient;
begin
  C := TIdTCPClient.Create(nil);
  try
    C.Host := AHost;
    C.Port := APort;
    C.ConnectTimeout := ATimeoutMs;
    try
      C.Connect;
      Result := C.Connected;
      C.Disconnect;
    except
      Result := False;  // recusou, sem rota ou tempo esgotado: tudo é "não alcança"
    end;
  finally
    C.Free;
  end;
end;

function ActiveVpnAdapters: TArray<string>;
const
  Keys: array[0..16] of string = ('vpn', 'anyconnect', 'cisco', 'fortinet', 'forticlient', 'globalprotect',
    'palo alto', 'pangp', 'wireguard', 'tailscale', 'openvpn', 'tap-windows', 'zerotier', 'pulse secure',
    'juniper', 'check point', 'nordlynx');
  IfOperStatusUp = 1;
var
  Size: ULONG;
  Buf: TBytes;
  P: PIP_ADAPTER_ADDRESSES;
  Desc, Name, K: string;
begin
  Result := nil;
  Size := 16 * 1024;
  SetLength(Buf, Size);
  if GetAdaptersAddresses(AF_UNSPEC, 0, nil, PIP_ADAPTER_ADDRESSES(@Buf[0]), @Size) = ERROR_BUFFER_OVERFLOW then
  begin
    SetLength(Buf, Size);
    if GetAdaptersAddresses(AF_UNSPEC, 0, nil, PIP_ADAPTER_ADDRESSES(@Buf[0]), @Size) <> ERROR_SUCCESS then
      Exit;
  end;
  P := PIP_ADAPTER_ADDRESSES(@Buf[0]);
  while P <> nil do
  begin
    if Integer(P.OperStatus) = IfOperStatusUp then
    begin
      Desc := P.Description;
      Name := P.FriendlyName;
      for K in Keys do
        if ContainsText(Desc, K) or ContainsText(Name, K) then
        begin
          Result := Result + [Desc];
          Break;
        end;
    end;
    P := P.Next;
  end;
end;

{ TWebhookServer }

constructor TWebhookServer.Create(const AOnHit: TWebhookEvent);
begin
  inherited Create;
  FOnHit := AOnHit;
  FResponseCode := 200;
  FServer := TIdHTTPServer.Create(nil);
  FServer.OnCommandGet := CommandGet;
  // POST, PUT, DELETE... caem no mesmo evento (OnCommandOther padrão chama o Get).
  FServer.OnCommandOther := CommandGet;
end;

destructor TWebhookServer.Destroy;
begin
  Stop;
  FServer.Free;
  inherited;
end;

function TWebhookServer.GetActive: Boolean;
begin
  Result := FServer.Active;
end;

procedure TWebhookServer.Start(APort: Integer);
begin
  Stop;
  FServer.Bindings.Clear;
  // Só na máquina: o receptor é para teste local, não para a rede.
  with FServer.Bindings.Add do
  begin
    IP := '127.0.0.1';
    Port := APort;
  end;
  FServer.Active := True;
end;

procedure TWebhookServer.Stop;
begin
  if FServer.Active then
    FServer.Active := False;
end;

{ Roda na thread da conexão do Indy: monta o registro e passa adiante. }
procedure TWebhookServer.CommandGet(AContext: TIdContext; ARequestInfo: TIdHTTPRequestInfo;
  AResponseInfo: TIdHTTPResponseInfo);
var
  Hit: TWebhookHit;
  Body: TStringStream;
begin
  Hit.At := Now;
  Hit.Method := ARequestInfo.Command;
  Hit.Path := ARequestInfo.URI + IfThen(ARequestInfo.QueryParams <> '', '?' + ARequestInfo.QueryParams, '');
  Hit.Remote := ARequestInfo.RemoteIP;
  Hit.Headers := ARequestInfo.RawHeaders.Text;
  Hit.Body := '';
  if ARequestInfo.PostStream <> nil then
  begin
    Body := TStringStream.Create('', TEncoding.UTF8);
    try
      ARequestInfo.PostStream.Position := 0;
      Body.CopyFrom(ARequestInfo.PostStream, ARequestInfo.PostStream.Size);
      Hit.Body := Body.DataString;
    finally
      Body.Free;
    end;
  end
  else if ARequestInfo.FormParams <> '' then
    Hit.Body := ARequestInfo.FormParams;
  AResponseInfo.ResponseNo := FResponseCode;
  AResponseInfo.ContentType := 'application/json';
  AResponseInfo.ContentText := '{"ok":true,"devbox":"recebido"}';
  if Assigned(FOnHit) then
    FOnHit(Hit);
end;

end.
