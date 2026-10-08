unit Devbox.Google;

{ Contas Google: login OAuth (app de desktop com PKCE e retorno em
  127.0.0.1), Gmail (ler, rótulos, arquivar) e Agenda (eventos da principal).
  O ID do cliente OAuth é do próprio usuário (projeto dele no Google Cloud).
  Segredo do cliente e refresh token ficam no Credential Manager.
  Tudo aqui bloqueia: chamar fora da thread de UI.
  DEVBOX_GOOGLE_BASE troca todos os endereços (servidor falso de teste). }

interface

uses
  System.SysUtils,
  System.JSON;

type
  TGoogleClient = record
    ClientId: string;
    ClientSecret: string;
    Port: Integer;
    function Ready: Boolean;
  end;

  TMailMsg = record
    Id: string;
    ThreadId: string;
    Account: string;
    FromName: string;
    FromEmail: string;
    Subject: string;
    Snippet: string;
    Body: string;           // só quando pediu o corpo
    Date: TDateTime;
    Labels: TArray<string>;
    function Unread: Boolean;
    function Important: Boolean;
    function InInbox: Boolean;
    function WebUrl: string;
  end;
  TMailMsgs = TArray<TMailMsg>;

  TCalEvent = record
    Id: string;
    Account: string;
    Title: string;
    Location: string;
    MeetUrl: string;
    WebUrl: string;
    Start: TDateTime;
    Finish: TDateTime;
    AllDay: Boolean;
  end;
  TCalEvents = TArray<TCalEvent>;

  TMailLabel = record
    Id: string;
    Name: string;
    IsSystem: Boolean;
  end;
  TMailLabels = TArray<TMailLabel>;

  TMailAction = (maKeep, maLabel, maArchive, maRead);

  TMailSuggestion = record
    Id: string;
    Action: TMailAction;
    LabelName: string;
    Reason: string;
  end;
  TMailSuggestions = TArray<TMailSuggestion>;

const
  MailActionNames: array[TMailAction] of string = ('Deixar', 'Rótulo', 'Arquivar', 'Marcar lido');
  GoogleDefaultPort = 4083;

{ Cor da faixa de cada conta na lista de e-mails e na agenda (pela ordem). }
function GoogleAccountColor(AIndex: Integer): Cardinal;

{ Lê o banco: só na thread de UI. Guarda uma cópia que as tarefas de fundo usam
  (o FireDAC não aceita a mesma conexão em duas threads). }
function LoadGoogleClient: TGoogleClient;
{ Build com cliente OAuth embutido (tools\google-client.ps1): entrar é só um clique. }
function GoogleEmbeddedClient: Boolean;
procedure SaveGoogleClient(const AClientId, AClientSecret: string);

{ Abre o navegador no login do Google e espera o retorno (até 3 min).
  AOpenUrl abre o endereço na thread de UI. }
function GoogleSignIn(const AClient: TGoogleClient; const AOpenUrl: TProc<string>;
  out AEmail, AError: string): Boolean;
procedure GoogleForget(const AEmail: string);
function GoogleSignedIn(const AEmail: string): Boolean;

// Gmail
function ListMail(const AEmail, AQuery: string; AMax: Integer; AWithBody: Boolean;
  out AMsgs: TMailMsgs; out AError: string): Boolean;
{ Um e-mail com o corpo. }
function GetMail(const AEmail, AId: string; out AMsg: TMailMsg; out AError: string): Boolean;
function ModifyMail(const AEmail, AId: string; const AAdd, ARemove: TArray<string>; out AError: string): Boolean;
function ListLabels(const AEmail: string; out ALabels: TMailLabels; out AError: string): Boolean;
function CreateLabel(const AEmail, AName: string; out AId, AError: string): Boolean;

// Agenda (só a principal)
function ListEvents(const AEmail: string; AFrom, ATo: TDateTime; out AEvents: TCalEvents;
  out AError: string): Boolean;

// IA
function OrganizePrompt(const AMsgs: TMailMsgs; const ALabels: TMailLabels; out ASystem: string): string;
function ParseSuggestions(const AAnswer: string): TMailSuggestions;
function DigestPrompt(const AEvents: TCalEvents; const AMsgs: TMailMsgs; out ASystem: string): string;

// Partes puras (self-check)
function Base64UrlDecode(const AText: string): TBytes;
function Base64UrlEncode(const ABytes: TBytes): string;
function HtmlToText(const AHtml: string): string;
procedure SplitFrom(const AFrom: string; out AName, AEmail: string);
function ParseMailJson(const AJson: string; out AMsg: TMailMsg): Boolean;
function ParseEventsJson(const AJson: string): TCalEvents;
function JwtEmail(const AIdToken: string): string;

implementation

uses
  Winapi.Windows,
  System.Classes,
  System.SyncObjs,
  System.StrUtils,
  System.DateUtils,
  System.Math,
  System.Hash,
  System.NetEncoding,
  System.RegularExpressions,
  System.Generics.Collections,
  System.Threading,
  System.Net.HttpClient,
  System.Net.URLClient,
  IdContext,
  IdCustomHTTPServer,
  IdHTTPServer,
  Devbox.Store,
  Devbox.Secrets;

{$I Devbox.GoogleClient.inc}

const
  CScopes = 'openid email https://www.googleapis.com/auth/gmail.modify ' +
    'https://www.googleapis.com/auth/calendar.readonly';
  CBodyMax = 2000;        // por e-mail no pedido à IA
  CTimeoutMs = 30000;

type
  TToken = record
    Access: string;
    Expires: TDateTime;
  end;

var
  GLock: TCriticalSection;
  GTokens: TDictionary<string, TToken>;
  GClient: TGoogleClient;

{ Endereços }

function TestBase: string;
begin
  Result := GetEnvironmentVariable('DEVBOX_GOOGLE_BASE').TrimRight(['/']);
end;

function AuthUrl: string;
begin
  Result := IfThen(TestBase <> '', TestBase + '/auth', 'https://accounts.google.com/o/oauth2/v2/auth');
end;

function TokenUrl: string;
begin
  Result := IfThen(TestBase <> '', TestBase + '/token', 'https://oauth2.googleapis.com/token');
end;

function GmailUrl(const APath: string): string;
begin
  Result := IfThen(TestBase <> '', TestBase, 'https://gmail.googleapis.com') + '/gmail/v1/users/me/' + APath;
end;

function CalendarUrl(const APath: string): string;
begin
  Result := IfThen(TestBase <> '', TestBase, 'https://www.googleapis.com') + '/calendar/v3/' + APath;
end;

function Enc(const S: string): string;
begin
  Result := TNetEncoding.URL.Encode(S);
end;

function SecretTarget(const AEmail: string): string;
begin
  Result := 'Devbox:google:' + LowerCase(AEmail);
end;

function GoogleAccountColor(AIndex: Integer): Cardinal;
const
  CColors: array[0..5] of Cardinal = ($FF2563EB, $FF059669, $FFD97706, $FF7C3AED, $FFDB2777, $FF0891B2);
begin
  Result := CColors[Abs(AIndex) mod Length(CColors)];
end;

{ Cliente OAuth }

function TGoogleClient.Ready: Boolean;
begin
  Result := (ClientId <> '') and (ClientSecret <> '');
end;

function LoadGoogleClient: TGoogleClient;
begin
  // Cliente próprio (Contas Google) vale mais que o embutido.
  Result.ClientId := Store.GetSetting('google_client_id');
  if Result.ClientId <> '' then
    Result.ClientSecret := LoadSecret('Devbox:google-client')
  else
  begin
    Result.ClientId := CEmbeddedGoogleClientId;
    Result.ClientSecret := CEmbeddedGoogleClientSecret;
  end;
  Result.Port := StrToIntDef(Store.GetSetting('google_port'), GoogleDefaultPort);
  GLock.Enter;
  try
    GClient := Result;
  finally
    GLock.Leave;
  end;
end;

function GoogleEmbeddedClient: Boolean;
begin
  Result := CEmbeddedGoogleClientId <> '';
end;

function CachedClient: TGoogleClient;
begin
  GLock.Enter;
  try
    Result := GClient;
  finally
    GLock.Leave;
  end;
end;

procedure SaveGoogleClient(const AClientId, AClientSecret: string);
begin
  Store.SetSetting('google_client_id', Trim(AClientId));
  if AClientSecret = '' then
    DeleteSecret('Devbox:google-client')
  else
    SaveSecret('Devbox:google-client', 'devbox', Trim(AClientSecret));
  LoadGoogleClient;
end;

{ Base64url }

function Base64UrlDecode(const AText: string): TBytes;
var
  S: string;
begin
  S := AText.Replace('-', '+').Replace('_', '/').Replace(#13, '').Replace(#10, '');
  while Length(S) mod 4 <> 0 do
    S := S + '=';
  Result := TNetEncoding.Base64.DecodeStringToBytes(S);
end;

function Base64UrlEncode(const ABytes: TBytes): string;
var
  E: TBase64Encoding;
begin
  E := TBase64Encoding.Create(0);   // 0 = sem quebra de linha
  try
    Result := E.EncodeBytesToString(ABytes).Replace('+', '-').Replace('/', '_').Replace('=', '');
  finally
    E.Free;
  end;
end;

function JwtEmail(const AIdToken: string): string;
var
  Parts: TArray<string>;
  V: TJSONValue;
begin
  Result := '';
  Parts := AIdToken.Split(['.']);
  if Length(Parts) < 2 then
    Exit;
  V := TJSONObject.ParseJSONValue(TEncoding.UTF8.GetString(Base64UrlDecode(Parts[1])));
  try
    if V <> nil then
      Result := V.GetValue<string>('email', '');
  finally
    V.Free;
  end;
end;

{ HTTP }

function ErrorOf(const AResp: string; ACode: Integer): string;
var
  V: TJSONValue;
  Msg: string;
begin
  Result := Format('HTTP %d', [ACode]);
  V := TJSONObject.ParseJSONValue(AResp);
  try
    if V = nil then
      Exit;
    // API: {"error":{"message":...}}; token: {"error":"invalid_grant","error_description":...}
    if V.TryGetValue<string>('error.message', Msg) or V.TryGetValue<string>('error_description', Msg) or
      V.TryGetValue<string>('error', Msg) then
      Result := Result + ': ' + Msg;
  finally
    V.Free;
  end;
end;

function Send(const AMethod, AUrl, ABody, AContentType, AToken: string; out AResp: string): Integer;
var
  Http: THTTPClient;
  Body: TStringStream;
  R: IHTTPResponse;
  H: TNetHeaders;
begin
  Http := THTTPClient.Create;
  Body := nil;
  try
    Http.ConnectionTimeout := 10000;
    Http.ResponseTimeout := CTimeoutMs;
    Http.UserAgent := 'Devbox';
    H := [];
    if AToken <> '' then
      H := H + [TNetHeader.Create('Authorization', 'Bearer ' + AToken)];
    if AContentType <> '' then
      H := H + [TNetHeader.Create('Content-Type', AContentType)];
    if AMethod = 'GET' then
      R := Http.Get(AUrl, nil, H)
    else
    begin
      Body := TStringStream.Create(ABody, TEncoding.UTF8);
      R := Http.Post(AUrl, Body, nil, H);
    end;
    AResp := R.ContentAsString(TEncoding.UTF8);
    Result := R.StatusCode;
  finally
    Body.Free;
    Http.Free;
  end;
end;

{ Troca o código ou o refresh token por um access token. }
function TokenRequest(const AForm: string; out AJson: TJSONValue; out AError: string): Boolean;
var
  Resp: string;
  Code: Integer;
begin
  AJson := nil;
  try
    Code := Send('POST', TokenUrl, AForm, 'application/x-www-form-urlencoded', '', Resp);
  except
    on E: Exception do
    begin
      AError := 'Sem resposta do Google: ' + E.Message;
      Exit(False);
    end;
  end;
  if Code <> 200 then
  begin
    AError := ErrorOf(Resp, Code);
    if ContainsText(Resp, 'invalid_grant') then
      AError := 'O acesso expirou ou foi revogado. Entre de novo na conta.';
    Exit(False);
  end;
  AJson := TJSONObject.ParseJSONValue(Resp);
  Result := AJson <> nil;
  if not Result then
    AError := 'Resposta do Google que não é JSON';
end;

procedure CacheToken(const AEmail, AAccess: string; AExpiresIn: Integer);
var
  T: TToken;
begin
  T.Access := AAccess;
  // Folga de 1 min para não usar um token no último segundo.
  T.Expires := IncSecond(Now, Max(AExpiresIn - 60, 30));
  GLock.Enter;
  try
    GTokens.AddOrSetValue(LowerCase(AEmail), T);
  finally
    GLock.Leave;
  end;
end;

function AccessToken(const AEmail: string; AForceRefresh: Boolean; out AError: string): string;
var
  T: TToken;
  Refresh: string;
  Client: TGoogleClient;
  J: TJSONValue;
begin
  Result := '';
  GLock.Enter;
  try
    if not AForceRefresh and GTokens.TryGetValue(LowerCase(AEmail), T) and (T.Expires > Now) then
      Exit(T.Access);
  finally
    GLock.Leave;
  end;
  Refresh := LoadSecret(SecretTarget(AEmail));
  if Refresh = '' then
  begin
    AError := 'Conta sem login. Entre de novo.';
    Exit;
  end;
  Client := CachedClient;
  if not Client.Ready then
  begin
    AError := 'Configure o ID e o segredo do cliente OAuth em Configurações › Google';
    Exit;
  end;
  if not TokenRequest('client_id=' + Enc(Client.ClientId) + '&client_secret=' + Enc(Client.ClientSecret) +
    '&refresh_token=' + Enc(Refresh) + '&grant_type=refresh_token', J, AError) then
    Exit;
  try
    Result := J.GetValue<string>('access_token', '');
    CacheToken(AEmail, Result, J.GetValue<Integer>('expires_in', 3600));
  finally
    J.Free;
  end;
end;

{ Chamada à API com o token da conta. 401 renova o token uma vez. }
function Api(const AEmail, AMethod, AUrl, ABody: string; out AResp, AError: string): Boolean;
var
  Token: string;
  Code, Try_: Integer;
begin
  Result := False;
  for Try_ := 0 to 1 do
  begin
    Token := AccessToken(AEmail, Try_ = 1, AError);
    if Token = '' then
      Exit;
    try
      Code := Send(AMethod, AUrl, ABody, IfThen(ABody <> '', 'application/json', ''), Token, AResp);
    except
      on E: Exception do
      begin
        AError := 'Sem resposta do Google: ' + E.Message;
        Exit;
      end;
    end;
    if (Code = 401) and (Try_ = 0) then
      Continue;
    Result := (Code >= 200) and (Code < 300);
    if not Result then
      AError := ErrorOf(AResp, Code);
    Exit;
  end;
end;

{ Login }

type
  { Recebe o retorno do Google em 127.0.0.1 e acorda quem espera. }
  TLoopback = class
  public
    Server: TIdHTTPServer;
    Done: TEvent;
    State: string;
    Code: string;
    Error: string;
    constructor Create(APort: Integer);
    destructor Destroy; override;
    procedure CommandGet(AContext: TIdContext; ARequestInfo: TIdHTTPRequestInfo;
      AResponseInfo: TIdHTTPResponseInfo);
  end;

constructor TLoopback.Create(APort: Integer);
begin
  inherited Create;
  Done := TEvent.Create(nil, True, False, '');
  Server := TIdHTTPServer.Create(nil);
  Server.OnCommandGet := CommandGet;
  with Server.Bindings.Add do
  begin
    IP := '127.0.0.1';
    Port := APort;
  end;
end;

destructor TLoopback.Destroy;
begin
  Server.Active := False;
  Server.Free;
  Done.Free;
  inherited;
end;

procedure TLoopback.CommandGet(AContext: TIdContext; ARequestInfo: TIdHTTPRequestInfo;
  AResponseInfo: TIdHTTPResponseInfo);
var
  Msg: string;
begin
  // O navegador também pede /favicon.ico: só a raiz conta.
  if ARequestInfo.Document <> '/' then
  begin
    AResponseInfo.ResponseNo := 404;
    Exit;
  end;
  if ARequestInfo.Params.Values['state'] <> State then
    Error := 'Retorno do login com estado diferente (pedido antigo?)'
  else if ARequestInfo.Params.Values['error'] <> '' then
    Error := 'O Google recusou: ' + ARequestInfo.Params.Values['error']
  else
    Code := ARequestInfo.Params.Values['code'];
  if Code <> '' then
    Msg := 'Pronto. Pode fechar esta aba e voltar ao Devbox.'
  else
    Msg := 'Não deu certo: ' + Error;
  AResponseInfo.ContentType := 'text/html';
  AResponseInfo.CharSet := 'utf-8';
  AResponseInfo.ContentText := '<html><body style="font-family:sans-serif;padding:40px"><h2>Devbox</h2><p>' +
    Msg + '</p></body></html>';
  Done.SetEvent;
end;

function NewVerifier: string;
begin
  // Dois GUIDs: 64 caracteres hex, dentro do que o PKCE aceita (43 a 128).
  Result := (TGUID.NewGuid.ToString + TGUID.NewGuid.ToString).Replace('{', '').Replace('}', '').Replace('-', '');
end;

function GoogleSignIn(const AClient: TGoogleClient; const AOpenUrl: TProc<string>;
  out AEmail, AError: string): Boolean;
var
  L: TLoopback;
  Port: Integer;
  Verifier, Redirect, Url: string;
  J: TJSONValue;
  Refresh: string;
begin
  Result := False;
  AEmail := '';
  J := nil;
  if not AClient.Ready then
  begin
    AError := 'Informe o ID e o segredo do cliente OAuth';
    Exit;
  end;
  Port := AClient.Port;
  if Port = 0 then
    Port := GoogleDefaultPort;
  Redirect := Format('http://127.0.0.1:%d/', [Port]);
  Verifier := NewVerifier;
  L := TLoopback.Create(Port);
  try
    L.State := TGUID.NewGuid.ToString.Replace('{', '').Replace('}', '');
    try
      L.Server.Active := True;
    except
      on E: Exception do
      begin
        AError := Format('A porta %d está em uso: %s', [Port, E.Message]);
        Exit;
      end;
    end;
    Url := AuthUrl + '?client_id=' + Enc(AClient.ClientId) + '&redirect_uri=' + Enc(Redirect) +
      '&response_type=code&scope=' + Enc(CScopes) + '&access_type=offline&prompt=consent' +
      '&code_challenge_method=S256&code_challenge=' +
      Base64UrlEncode(THashSHA2.GetHashBytes(Verifier)) + '&state=' + L.State;
    if TestBase <> '' then
      // Servidor falso de teste: segue o redirecionamento sem abrir o navegador.
      TTask.Run(
        procedure
        var
          Http: THTTPClient;
        begin
          Http := THTTPClient.Create;
          try
            try
              Http.Get(Url);
            except
              // L pode já ter sido liberado aqui: só registra.
              on E: Exception do
                OutputDebugString(PChar('Devbox teste login: ' + E.Message));
            end;
          finally
            Http.Free;
          end;
        end)
    else
      TThread.Synchronize(nil,
        procedure
        begin
          AOpenUrl(Url);
        end);
    if L.Done.WaitFor(180000) <> wrSignaled then
    begin
      AError := 'O login não voltou em 3 minutos';
      Exit;
    end;
    if L.Code = '' then
    begin
      AError := L.Error;
      Exit;
    end;
    if not TokenRequest('client_id=' + Enc(AClient.ClientId) + '&client_secret=' + Enc(AClient.ClientSecret) +
      '&code=' + Enc(L.Code) + '&code_verifier=' + Verifier + '&grant_type=authorization_code' +
      '&redirect_uri=' + Enc(Redirect), J, AError) then
      Exit;
  finally
    L.Free;
  end;
  try
    AEmail := JwtEmail(J.GetValue<string>('id_token', ''));
    Refresh := J.GetValue<string>('refresh_token', '');
    if AEmail = '' then
      AError := 'O Google não devolveu o e-mail da conta'
    else if Refresh = '' then
      AError := 'O Google não devolveu o refresh token. Tire o acesso do Devbox em ' +
        'myaccount.google.com/permissions e entre de novo.'
    else
    begin
      SaveSecret(SecretTarget(AEmail), AEmail, Refresh);
      CacheToken(AEmail, J.GetValue<string>('access_token', ''), J.GetValue<Integer>('expires_in', 3600));
      Result := True;
    end;
  finally
    J.Free;
  end;
end;

procedure GoogleForget(const AEmail: string);
begin
  DeleteSecret(SecretTarget(AEmail));
  GLock.Enter;
  try
    GTokens.Remove(LowerCase(AEmail));
  finally
    GLock.Leave;
  end;
end;

function GoogleSignedIn(const AEmail: string): Boolean;
begin
  Result := LoadSecret(SecretTarget(AEmail)) <> '';
end;

{ Texto }

function DecodeEntities(const S: string): string;
var
  Ms: TMatchCollection;
  I: Integer;
begin
  // TRegEx.Replace com avaliador só aceita método de objeto: troca de trás para frente.
  Result := S;
  Ms := TRegEx.Matches(S, '&#(\d+);');
  for I := Ms.Count - 1 downto 0 do
    Result := Copy(Result, 1, Ms[I].Index - 1) + Char(StrToIntDef(Ms[I].Groups[1].Value, 32)) +
      Copy(Result, Ms[I].Index + Ms[I].Length, MaxInt);
  Result := Result.Replace('&nbsp;', ' ').Replace('&lt;', '<').Replace('&gt;', '>')
    .Replace('&quot;', '"').Replace('&#39;', '''').Replace('&amp;', '&');
end;

function HtmlToText(const AHtml: string): string;
var
  S: string;
begin
  S := TRegEx.Replace(AHtml, '<(style|script|head)[^>]*>.*?</\1>', '', [roIgnoreCase, roSingleLine]);
  S := TRegEx.Replace(S, '<br\s*/?>|</(p|div|tr|li|h[1-6]|table)>', #10, [roIgnoreCase]);
  S := TRegEx.Replace(S, '<[^>]+>', '');
  S := DecodeEntities(S);
  S := TRegEx.Replace(S, '[ \t\r]+\n', #10);
  S := TRegEx.Replace(S, '[ \t]{2,}', ' ');
  S := TRegEx.Replace(S, '\n{3,}', #10#10);
  Result := Trim(S);
end;

procedure SplitFrom(const AFrom: string; out AName, AEmail: string);
var
  A, B: Integer;
begin
  A := Pos('<', AFrom);
  B := Pos('>', AFrom);
  if (A > 0) and (B > A) then
  begin
    AEmail := Trim(Copy(AFrom, A + 1, B - A - 1));
    AName := Trim(Copy(AFrom, 1, A - 1)).Trim(['"', ' ']);
  end
  else
  begin
    AEmail := Trim(AFrom);
    AName := '';
  end;
  if AName = '' then
    AName := Copy(AEmail, 1, Pos('@', AEmail + '@') - 1);
end;

{ Gmail }

function TMailMsg.Unread: Boolean;
begin
  Result := MatchStr('UNREAD', Labels);
end;

function TMailMsg.Important: Boolean;
begin
  Result := MatchStr('IMPORTANT', Labels);
end;

function TMailMsg.InInbox: Boolean;
begin
  Result := MatchStr('INBOX', Labels);
end;

function TMailMsg.WebUrl: string;
begin
  Result := 'https://mail.google.com/mail/?authuser=' + Enc(Account) + '#all/' + Id;
end;

function Header(APayload: TJSONValue; const AName: string): string;
var
  Hs: TJSONArray;
  H: TJSONValue;
begin
  Result := '';
  if (APayload <> nil) and APayload.TryGetValue<TJSONArray>('headers', Hs) then
    for H in Hs do
      if SameText(H.GetValue<string>('name', ''), AName) then
        Exit(H.GetValue<string>('value', ''));
end;

function PartText(APart: TJSONValue): string;
var
  Data, Charset: string;
  Enc_: TEncoding;
  Bytes: TBytes;
  M: TMatch;
begin
  Result := '';
  if not APart.TryGetValue<string>('body.data', Data) or (Data = '') then
    Exit;
  Bytes := Base64UrlDecode(Data);
  M := TRegEx.Match(Header(APart, 'Content-Type'), 'charset="?([\w\-]+)', [roIgnoreCase]);
  Charset := 'utf-8';
  if M.Success then
    Charset := M.Groups[1].Value;
  try
    Enc_ := TEncoding.GetEncoding(Charset);
  except
    Enc_ := TEncoding.GetEncoding(65001);
  end;
  try
    Result := Enc_.GetString(Bytes);
  finally
    Enc_.Free;
  end;
end;

{ Primeiro text/plain da árvore; sem ele, o primeiro text/html convertido. }
procedure FindBody(APart: TJSONValue; var APlain, AHtml: string);
var
  Mime: string;
  Parts: TJSONArray;
  P: TJSONValue;
begin
  Mime := LowerCase(APart.GetValue<string>('mimeType', ''));
  if (Mime = 'text/plain') and (APlain = '') then
    APlain := PartText(APart)
  else if (Mime = 'text/html') and (AHtml = '') then
    AHtml := PartText(APart);
  if APart.TryGetValue<TJSONArray>('parts', Parts) then
    for P in Parts do
      FindBody(P, APlain, AHtml);
end;

function ParseMailValue(V: TJSONValue; out AMsg: TMailMsg): Boolean;
var
  Payload: TJSONValue;
  Ls: TJSONArray;
  L: TJSONValue;
  Plain, Html: string;
  Ms: Int64;
begin
  AMsg := Default(TMailMsg);
  Result := (V <> nil) and V.TryGetValue<string>('id', AMsg.Id);
  if not Result then
    Exit;
  AMsg.ThreadId := V.GetValue<string>('threadId', '');
  AMsg.Snippet := DecodeEntities(V.GetValue<string>('snippet', ''));
  if V.TryGetValue<TJSONArray>('labelIds', Ls) then
    for L in Ls do
      AMsg.Labels := AMsg.Labels + [L.Value];
  if TryStrToInt64(V.GetValue<string>('internalDate', ''), Ms) then
    AMsg.Date := UnixToDateTime(Ms div 1000, False);
  Payload := V.FindValue('payload');
  SplitFrom(Header(Payload, 'From'), AMsg.FromName, AMsg.FromEmail);
  AMsg.Subject := Header(Payload, 'Subject');
  if AMsg.Subject = '' then
    AMsg.Subject := '(sem assunto)';
  if Payload <> nil then
  begin
    Plain := '';
    Html := '';
    FindBody(Payload, Plain, Html);
    if Trim(Plain) <> '' then
      AMsg.Body := Trim(Plain.Replace(#13, ''))
    else
      AMsg.Body := HtmlToText(Html);
  end;
end;

function ParseMailJson(const AJson: string; out AMsg: TMailMsg): Boolean;
var
  V: TJSONValue;
begin
  V := TJSONObject.ParseJSONValue(AJson);
  try
    Result := ParseMailValue(V, AMsg);
  finally
    V.Free;
  end;
end;

function ListMail(const AEmail, AQuery: string; AMax: Integer; AWithBody: Boolean;
  out AMsgs: TMailMsgs; out AError: string): Boolean;
var
  Resp, Url, One: string;
  V: TJSONValue;
  Arr: TJSONArray;
  Item: TJSONValue;
  Ids: TArray<string>;
  Id: string;
  M: TMailMsg;
begin
  AMsgs := nil;
  Result := Api(AEmail, 'GET', GmailUrl('messages?maxResults=' + IntToStr(AMax) + '&q=' + Enc(AQuery)), '',
    Resp, AError);
  if not Result then
    Exit;
  Ids := nil;
  V := TJSONObject.ParseJSONValue(Resp);
  try
    if (V <> nil) and V.TryGetValue<TJSONArray>('messages', Arr) then
      for Item in Arr do
        Ids := Ids + [Item.GetValue<string>('id', '')];
  finally
    V.Free;
  end;
  for Id in Ids do
  begin
    // Sem corpo: só os cabeçalhos que a lista mostra (bem mais leve).
    if AWithBody then
      Url := GmailUrl('messages/' + Id + '?format=full')
    else
      Url := GmailUrl('messages/' + Id + '?format=metadata&metadataHeaders=From&metadataHeaders=Subject');
    if not Api(AEmail, 'GET', Url, '', One, AError) then
      Exit(False);
    if ParseMailJson(One, M) then
    begin
      M.Account := AEmail;
      AMsgs := AMsgs + [M];
    end;
  end;
end;

function GetMail(const AEmail, AId: string; out AMsg: TMailMsg; out AError: string): Boolean;
var
  Resp: string;
begin
  AMsg := Default(TMailMsg);
  Result := Api(AEmail, 'GET', GmailUrl('messages/' + AId + '?format=full'), '', Resp, AError) and
    ParseMailJson(Resp, AMsg);
  if Result then
    AMsg.Account := AEmail
  else if AError = '' then
    AError := 'E-mail que não deu para ler';
end;

function JsonStrArray(const AItems: TArray<string>): TJSONArray;
var
  S: string;
begin
  Result := TJSONArray.Create;
  for S in AItems do
    Result.Add(S);
end;

function ModifyMail(const AEmail, AId: string; const AAdd, ARemove: TArray<string>; out AError: string): Boolean;
var
  Req: TJSONObject;
  Resp: string;
begin
  Req := TJSONObject.Create;
  try
    Req.AddPair('addLabelIds', JsonStrArray(AAdd));
    Req.AddPair('removeLabelIds', JsonStrArray(ARemove));
    Result := Api(AEmail, 'POST', GmailUrl('messages/' + AId + '/modify'), Req.ToJSON, Resp, AError);
  finally
    Req.Free;
  end;
end;

function ListLabels(const AEmail: string; out ALabels: TMailLabels; out AError: string): Boolean;
var
  Resp: string;
  V: TJSONValue;
  Arr: TJSONArray;
  Item: TJSONValue;
  L: TMailLabel;
begin
  ALabels := nil;
  Result := Api(AEmail, 'GET', GmailUrl('labels'), '', Resp, AError);
  if not Result then
    Exit;
  V := TJSONObject.ParseJSONValue(Resp);
  try
    if (V <> nil) and V.TryGetValue<TJSONArray>('labels', Arr) then
      for Item in Arr do
      begin
        L.Id := Item.GetValue<string>('id', '');
        L.Name := Item.GetValue<string>('name', '');
        L.IsSystem := Item.GetValue<string>('type', '') = 'system';
        ALabels := ALabels + [L];
      end;
  finally
    V.Free;
  end;
end;

function CreateLabel(const AEmail, AName: string; out AId, AError: string): Boolean;
var
  Req: TJSONObject;
  Resp: string;
  V: TJSONValue;
begin
  AId := '';
  Req := TJSONObject.Create;
  try
    Req.AddPair('name', AName);
    Req.AddPair('labelListVisibility', 'labelShow');
    Req.AddPair('messageListVisibility', 'show');
    Result := Api(AEmail, 'POST', GmailUrl('labels'), Req.ToJSON, Resp, AError);
  finally
    Req.Free;
  end;
  if not Result then
    Exit;
  V := TJSONObject.ParseJSONValue(Resp);
  try
    if V <> nil then
      AId := V.GetValue<string>('id', '');
  finally
    V.Free;
  end;
  Result := AId <> '';
end;

{ Agenda }

function ParseWhen(V: TJSONValue; out AAllDay: Boolean): TDateTime;
var
  S: string;
begin
  Result := 0;
  AAllDay := False;
  if V = nil then
    Exit;
  if V.TryGetValue<string>('dateTime', S) then
    Result := ISO8601ToDate(S, False)
  else if V.TryGetValue<string>('date', S) and (Length(S) >= 10) then
  begin
    AAllDay := True;
    Result := EncodeDate(StrToInt(Copy(S, 1, 4)), StrToInt(Copy(S, 6, 2)), StrToInt(Copy(S, 9, 2)));
  end;
end;

function ParseEventsJson(const AJson: string): TCalEvents;
var
  V: TJSONValue;
  Arr, Points: TJSONArray;
  Item, P: TJSONValue;
  E: TCalEvent;
  Dummy: Boolean;
begin
  Result := nil;
  V := TJSONObject.ParseJSONValue(AJson);
  try
    if (V = nil) or not V.TryGetValue<TJSONArray>('items', Arr) then
      Exit;
    for Item in Arr do
    begin
      if Item.GetValue<string>('status', '') = 'cancelled' then
        Continue;
      E := Default(TCalEvent);
      E.Id := Item.GetValue<string>('id', '');
      E.Title := Item.GetValue<string>('summary', '(sem título)');
      E.Location := Item.GetValue<string>('location', '');
      E.WebUrl := Item.GetValue<string>('htmlLink', '');
      E.Start := ParseWhen(Item.FindValue('start'), E.AllDay);
      E.Finish := ParseWhen(Item.FindValue('end'), Dummy);
      E.MeetUrl := Item.GetValue<string>('hangoutLink', '');
      if (E.MeetUrl = '') and Item.TryGetValue<TJSONArray>('conferenceData.entryPoints', Points) then
        for P in Points do
          if P.GetValue<string>('entryPointType', '') = 'video' then
          begin
            E.MeetUrl := P.GetValue<string>('uri', '');
            Break;
          end;
      Result := Result + [E];
    end;
  finally
    V.Free;
  end;
end;

function ListEvents(const AEmail: string; AFrom, ATo: TDateTime; out AEvents: TCalEvents;
  out AError: string): Boolean;
var
  Resp: string;
  I: Integer;
begin
  AEvents := nil;
  Result := Api(AEmail, 'GET', CalendarUrl('calendars/primary/events?singleEvents=true&orderBy=startTime' +
    '&maxResults=250&timeMin=' + Enc(DateToISO8601(AFrom, False)) + '&timeMax=' + Enc(DateToISO8601(ATo, False))),
    '', Resp, AError);
  if not Result then
    Exit;
  AEvents := ParseEventsJson(Resp);
  for I := 0 to High(AEvents) do
    AEvents[I].Account := AEmail;
end;

{ IA }

function MailBlock(const M: TMailMsg): string;
var
  Body: string;
begin
  Body := IfThen(M.Body <> '', M.Body, M.Snippet);
  if Length(Body) > CBodyMax then
    Body := Copy(Body, 1, CBodyMax) + ' [...]';
  Result := Format('--- id: %s'#10'De: %s <%s>'#10'Data: %s'#10'Assunto: %s'#10'%s'#10,
    [M.Id, M.FromName, M.FromEmail, FormatDateTime('dd/mm hh:nn', M.Date), M.Subject, Body]);
end;

function OrganizePrompt(const AMsgs: TMailMsgs; const ALabels: TMailLabels; out ASystem: string): string;
var
  M: TMailMsg;
  L: TMailLabel;
  Names: string;
begin
  ASystem := 'Você organiza a caixa de entrada de um desenvolvedor. Para cada e-mail, sugira UMA ação: ' +
    '"label" (pôr um rótulo; prefira um rótulo existente, senão proponha um nome curto), "archive" ' +
    '(newsletter, propaganda, notificação automática que não pede nada), "read" (só marcar como lido) ou ' +
    '"keep" (pede resposta ou ação da pessoa). Responda SÓ com JSON, sem texto fora dele: ' +
    '[{"id":"...","action":"label|archive|read|keep","label":"nome ou vazio","reason":"até 8 palavras em português"}]';
  Names := '';
  for L in ALabels do
    if not L.IsSystem then
      Names := Names + IfThen(Names <> '', ', ') + L.Name;
  Result := 'Rótulos existentes: ' + IfThen(Names <> '', Names, '(nenhum)') + #10#10;
  for M in AMsgs do
    Result := Result + MailBlock(M);
end;

function ParseSuggestions(const AAnswer: string): TMailSuggestions;
var
  A, B: Integer;
  V: TJSONValue;
  Item: TJSONValue;
  S: TMailSuggestion;
  Act: string;
begin
  Result := nil;
  // O modelo às vezes embrulha o JSON em ```: pega do primeiro [ ao último ].
  A := Pos('[', AAnswer);
  B := LastDelimiter(']', AAnswer);
  if (A = 0) or (B <= A) then
    Exit;
  V := TJSONObject.ParseJSONValue(Copy(AAnswer, A, B - A + 1));
  try
    if not (V is TJSONArray) then
      Exit;
    for Item in TJSONArray(V) do
    begin
      S.Id := Item.GetValue<string>('id', '');
      Act := LowerCase(Item.GetValue<string>('action', 'keep'));
      S.LabelName := Trim(Item.GetValue<string>('label', ''));
      S.Reason := Item.GetValue<string>('reason', '');
      case IndexStr(Act, ['label', 'archive', 'read']) of
        0: S.Action := maLabel;
        1: S.Action := maArchive;
        2: S.Action := maRead;
      else
        S.Action := maKeep;
      end;
      if (S.Action = maLabel) and (S.LabelName = '') then
        S.Action := maKeep;
      if S.Id <> '' then
        Result := Result + [S];
    end;
  finally
    V.Free;
  end;
end;

function DigestPrompt(const AEvents: TCalEvents; const AMsgs: TMailMsgs; out ASystem: string): string;
var
  E: TCalEvent;
  M: TMailMsg;
begin
  ASystem := 'Monte o resumo do dia de um desenvolvedor, em português do Brasil, texto simples (sem markdown ' +
    'além de "- " em listas). Três partes com estes títulos: "Agenda de hoje" (horário e título; avise ' +
    'conflito de horário), "E-mails que pedem ação" (quem, o quê e prazo se houver) e "Pode esperar" (uma ' +
    'linha). Sem introdução nem despedida. No máximo 25 linhas.';
  Result := 'Hoje: ' + FormatDateTime('dddd, dd/mm/yyyy', Date) + #10#10'Eventos:'#10;
  if AEvents = nil then
    Result := Result + '(nenhum)'#10;
  for E in AEvents do
    if E.AllDay then
      Result := Result + '- dia todo: ' + E.Title + #10
    else
      Result := Result + Format('- %s a %s: %s'#10, [FormatDateTime('hh:nn', E.Start),
        FormatDateTime('hh:nn', E.Finish), E.Title]);
  Result := Result + #10'E-mails importantes não lidos:'#10;
  if AMsgs = nil then
    Result := Result + '(nenhum)'#10;
  for M in AMsgs do
    Result := Result + MailBlock(M);
end;

initialization
  GLock := TCriticalSection.Create;
  GTokens := TDictionary<string, TToken>.Create;

finalization
  GTokens.Free;
  GLock.Free;

end.
