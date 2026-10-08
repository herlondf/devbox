unit Devbox.Imap;

{ E-mail por IMAP com senha de app (Gmail, Yahoo, iCloud, servidores IMAP de
  empresa). TLS pelo SChannel do Windows (Devbox.Tls); o e-mail inteiro é lido
  pelo leitor MIME do Indy. A senha fica no Credential Manager. Cada operação
  abre e fecha a própria conexão. Tudo aqui bloqueia: fora da thread de UI.
  Id dos e-mails: "<email>#<UID>" (UID da INBOX). }

interface

uses
  System.SysUtils,
  Devbox.Store,
  Devbox.Google;

const
  ImapIdSep = '#';

procedure SaveImapPassword(const AEmail, APassword: string);
procedure ForgetImapPassword(const AEmail: string);
function ImapHasPassword(const AEmail: string): Boolean;

{ Servidor conhecido pelo domínio do e-mail ('' se não souber). AWarning: aviso
  quando o provedor não aceita senha (Outlook/Hotmail exigem OAuth). }
procedure GuessImapServer(const AEmail: string; out AHost: string; out APort: Integer; out AWarning: string);

function ImapTest(const AAccount: TImapAccount; out AError: string): Boolean;
{ INBOX dos últimos ADays dias (os AMax mais novos). AUnseenOnly: só não lidos. }
function ImapListInbox(const AAccount: TImapAccount; ADays, AMax: Integer; AUnseenOnly: Boolean;
  out AMsgs: TMailMsgs; out AError: string): Boolean;
function ImapGetMail(const AAccount: TImapAccount; const AId: string; out AMsg: TMailMsg; out AError: string): Boolean;
function ImapSetSeen(const AAccount: TImapAccount; const AId: string; out AError: string): Boolean;
{ Move para a pasta (cria se não existir). }
function ImapMove(const AAccount: TImapAccount; const AId, AFolder: string; out AError: string): Boolean;
{ Move para a pasta de arquivo (a marcada \Archive, ou "Archive"). }
function ImapArchive(const AAccount: TImapAccount; const AId: string; out AError: string): Boolean;
function ImapFolders(const AAccount: TImapAccount; out ALabels: TMailLabels; out AError: string): Boolean;

// Partes puras (self-check)
function MUtf7Encode(const S: string): string;
function MUtf7Decode(const S: string): string;
function ImapQuote(const S: string): string;
function ParseImapDate(const S: string): TDateTime;
function ParseRawMail(const ARaw: TBytes; out AMsg: TMailMsg): Boolean;
procedure ParseHeaderFields(const AHeader: string; out AFrom, ASubject: string);

implementation

uses
  Winapi.Windows,
  System.Classes,
  System.StrUtils,
  System.DateUtils,
  System.Math,
  System.NetEncoding,
  System.RegularExpressions,
  IdGlobal,
  IdMessage,
  IdText,
  IdAttachment,
  IdAttachmentMemory,
  IdMessageParts,
  IdCoderHeader,
  Devbox.Tls,
  Devbox.Secrets;

const
  CMonths: array[1..12] of string = ('Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct',
    'Nov', 'Dec');

function SecretTarget(const AEmail: string): string;
begin
  Result := 'Devbox:imap:' + LowerCase(AEmail);
end;

procedure SaveImapPassword(const AEmail, APassword: string);
begin
  SaveSecret(SecretTarget(AEmail), AEmail, APassword);
end;

procedure ForgetImapPassword(const AEmail: string);
begin
  DeleteSecret(SecretTarget(AEmail));
end;

function ImapHasPassword(const AEmail: string): Boolean;
begin
  Result := LoadSecret(SecretTarget(AEmail)) <> '';
end;

procedure GuessImapServer(const AEmail: string; out AHost: string; out APort: Integer; out AWarning: string);
var
  Domain: string;
begin
  AHost := '';
  APort := 993;
  AWarning := '';
  Domain := LowerCase(Copy(AEmail, Pos('@', AEmail) + 1, MaxInt));
  if MatchStr(Domain, ['gmail.com', 'googlemail.com']) then
    AHost := 'imap.gmail.com'
  else if StartsStr('yahoo.', Domain) or MatchStr(Domain, ['ymail.com', 'rocketmail.com']) then
    AHost := 'imap.mail.yahoo.com'
  else if MatchStr(Domain, ['icloud.com', 'me.com', 'mac.com']) then
    AHost := 'imap.mail.me.com'
  else if MatchStr(Domain, ['uol.com.br']) then
    AHost := 'imap.uol.com.br'
  else if MatchStr(Domain, ['bol.com.br']) then
    AHost := 'imap.bol.com.br'
  else if MatchStr(Domain, ['terra.com.br']) then
    AHost := 'imap.terra.com.br'
  else if MatchStr(Domain, ['zoho.com']) then
    AHost := 'imap.zoho.com'
  else if MatchStr(Domain, ['gmx.com', 'gmx.net']) then
    AHost := 'imap.gmx.com'
  else if MatchStr(Domain, ['outlook.com', 'hotmail.com', 'live.com', 'msn.com']) then
  begin
    AHost := 'outlook.office365.com';
    AWarning := 'A Microsoft não aceita mais senha no IMAP do Outlook/Hotmail: precisa de login OAuth.';
  end;
end;

{ Partes puras }

function ImapQuote(const S: string): string;
begin
  Result := '"' + S.Replace('\', '\\').Replace('"', '\"') + '"';
end;

function MUtf7Encode(const S: string): string;
var
  I: Integer;
  Run: string;
  Bytes: TBytes;
  E: TBase64Encoding;

  procedure Flush;
  var
    J: Integer;
  begin
    if Run = '' then
      Exit;
    SetLength(Bytes, Length(Run) * 2);
    for J := 1 to Length(Run) do
    begin
      Bytes[(J - 1) * 2] := Ord(Run[J]) shr 8;
      Bytes[(J - 1) * 2 + 1] := Ord(Run[J]) and $FF;
    end;
    Result := Result + '&' + E.EncodeBytesToString(Bytes).Replace('/', ',').Replace('=', '') + '-';
    Run := '';
  end;

begin
  Result := '';
  Run := '';
  E := TBase64Encoding.Create(0);
  try
    for I := 1 to Length(S) do
      if (Ord(S[I]) >= $20) and (Ord(S[I]) <= $7E) then
      begin
        Flush;
        if S[I] = '&' then
          Result := Result + '&-'
        else
          Result := Result + S[I];
      end
      else
        Run := Run + S[I];
    Flush;
  finally
    E.Free;
  end;
end;

function MUtf7Decode(const S: string): string;
var
  I, J, K: Integer;
  Chunk: string;
  Bytes: TBytes;
begin
  Result := '';
  I := 1;
  while I <= Length(S) do
  begin
    if S[I] <> '&' then
    begin
      Result := Result + S[I];
      Inc(I);
      Continue;
    end;
    J := PosEx('-', S, I + 1);
    if J = 0 then
      J := Length(S) + 1;
    Chunk := Copy(S, I + 1, J - I - 1);
    if Chunk = '' then
      Result := Result + '&'
    else
    begin
      Chunk := Chunk.Replace(',', '/');
      while Length(Chunk) mod 4 <> 0 do
        Chunk := Chunk + '=';
      Bytes := TNetEncoding.Base64.DecodeStringToBytes(Chunk);
      K := 0;
      while K + 1 < Length(Bytes) do
      begin
        Result := Result + Char((Bytes[K] shl 8) or Bytes[K + 1]);
        Inc(K, 2);
      end;
    end;
    I := J + 1;
  end;
end;

{ "06-Oct-2026 10:00:00 -0300" (INTERNALDATE) para hora local. }
function ParseImapDate(const S: string): TDateTime;
var
  M: TMatch;
  Mon, Off: Integer;
  Utc: TDateTime;
begin
  Result := 0;
  M := TRegEx.Match(Trim(S), '^(\d{1,2})-(\w{3})-(\d{4}) (\d{2}):(\d{2}):(\d{2}) ([+-])(\d{2})(\d{2})');
  if not M.Success then
    Exit;
  Mon := AnsiIndexText(M.Groups[2].Value, CMonths) + 1;
  if Mon < 1 then
    Exit;
  Utc := EncodeDateTime(StrToInt(M.Groups[3].Value), Mon, StrToInt(M.Groups[1].Value), StrToInt(M.Groups[4].Value),
    StrToInt(M.Groups[5].Value), StrToInt(M.Groups[6].Value), 0);
  Off := StrToInt(M.Groups[8].Value) * 60 + StrToInt(M.Groups[9].Value);
  if M.Groups[7].Value = '+' then
    Utc := IncMinute(Utc, -Off)
  else
    Utc := IncMinute(Utc, Off);
  Result := TTimeZone.Local.ToLocalTime(Utc);
end;

procedure ParseHeaderFields(const AHeader: string; out AFrom, ASubject: string);
var
  Line: string;
  Text: string;
begin
  AFrom := '';
  ASubject := '';
  // Cabeçalho dobrado: continua na linha que começa com espaço ou tab.
  Text := AHeader.Replace(#13#10' ', ' ').Replace(#13#10#9, ' ').Replace(#10' ', ' ').Replace(#10#9, ' ');
  for Line in Text.Replace(#13, '').Split([#10]) do
    if StartsText('From:', Line) then
      AFrom := DecodeHeader(Trim(Copy(Line, 6, MaxInt)))
    else if StartsText('Subject:', Line) then
      ASubject := DecodeHeader(Trim(Copy(Line, 9, MaxInt)));
end;

type
  { Anexo em memória: o padrão do Indy grava arquivo temporário. }
  TAttachHelper = class
    procedure CreateAttachment(const AMsg: TIdMessage; const AHeaders: TStrings; var AAttachment: TIdAttachment);
  end;

procedure TAttachHelper.CreateAttachment(const AMsg: TIdMessage; const AHeaders: TStrings;
  var AAttachment: TIdAttachment);
begin
  AAttachment := TIdAttachmentMemory.Create(AMsg.MessageParts);
end;

function ParseRawMail(const ARaw: TBytes; out AMsg: TMailMsg): Boolean;
var
  Msg: TIdMessage;
  Helper: TAttachHelper;
  Stream: TBytesStream;
  I: Integer;
  Part: TIdMessagePart;
  Plain, Html, CT: string;
begin
  AMsg := Default(TMailMsg);
  Msg := TIdMessage.Create(nil);
  Helper := TAttachHelper.Create;
  Stream := TBytesStream.Create(ARaw);
  try
    Msg.OnCreateAttachment := Helper.CreateAttachment;
    Msg.NoDecode := False;
    try
      Msg.LoadFromStream(Stream);
    except
      Exit(False);
    end;
    AMsg.Subject := Msg.Subject;
    SplitFrom(Msg.From.Text, AMsg.FromName, AMsg.FromEmail);
    if Msg.From.Name <> '' then
      AMsg.FromName := Msg.From.Name;
    AMsg.Date := Msg.Date;
    Plain := '';
    Html := '';
    for I := 0 to Msg.MessageParts.Count - 1 do
    begin
      Part := Msg.MessageParts[I];
      if not (Part is TIdText) then
        Continue;
      CT := LowerCase(Part.ContentType);
      if StartsText('text/plain', CT) and (Plain = '') then
        Plain := TIdText(Part).Body.Text
      else if StartsText('text/html', CT) and (Html = '') then
        Html := TIdText(Part).Body.Text;
    end;
    // Mensagem de uma parte só: o texto fica em Body.
    if (Plain = '') and (Html = '') then
      if ContainsText(Msg.ContentType, 'html') then
        Html := Msg.Body.Text
      else
        Plain := Msg.Body.Text;
    if Trim(Plain) <> '' then
      AMsg.Body := Trim(Plain.Replace(#13, ''))
    else
      AMsg.Body := HtmlToText(Html);
    AMsg.Snippet := Copy(AMsg.Body.Replace(#10, ' '), 1, 200);
    if AMsg.Subject = '' then
      AMsg.Subject := '(sem assunto)';
    Result := True;
  finally
    Stream.Free;
    Helper.Free;
    Msg.Free;
  end;
end;

{ Sessão }

type
  TImapLine = record
    Text: string;
    Literals: TArray<TBytes>;
  end;

  TImapSession = class
  private
    FSock: TTlsSocket;
    FTag: Integer;
    FCaps: string;
  public
    constructor Create(const AAccount: TImapAccount);
    destructor Destroy; override;
    { Manda o comando e junta as respostas "* ..." até a linha do tag. }
    function Cmd(const ACommand: string; out ALines: TArray<TImapLine>; out AStatus: string): Boolean; overload;
    procedure Must(const ACommand: string; out ALines: TArray<TImapLine>); overload;
    procedure Must(const ACommand: string); overload;
    function HasCap(const ACap: string): Boolean;
  end;

  EImap = class(Exception);

constructor TImapSession.Create(const AAccount: TImapAccount);
var
  Greeting, Pass: string;
  L: TArray<TImapLine>;
begin
  inherited Create;
  FSock := TTlsSocket.Create;
  // Porta 143 só no servidor falso local (sem TLS); o resto sempre com TLS.
  FSock.Connect(AAccount.Host, AAccount.Port, not ((AAccount.Host = '127.0.0.1') and (AAccount.Port <> 993)));
  Greeting := FSock.ReadLine;
  if not StartsText('* OK', Greeting) then
    raise EImap.Create('O servidor não aceitou a conexão: ' + Greeting);
  Pass := LoadSecret(SecretTarget(AAccount.Email));
  if Pass = '' then
    raise EImap.Create('Sem senha salva para ' + AAccount.Email);
  Must('LOGIN ' + ImapQuote(IfThen(AAccount.User <> '', AAccount.User, AAccount.Email)) + ' ' + ImapQuote(Pass));
  Must('CAPABILITY', L);
  if L <> nil then
    FCaps := ' ' + UpperCase(L[0].Text) + ' ';
end;

destructor TImapSession.Destroy;
var
  L: TArray<TImapLine>;
  S: string;
begin
  try
    if FSock <> nil then
      Cmd('LOGOUT', L, S);
  except
    // Saída educada: se a conexão já caiu, não tem o que fazer.
    on E: Exception do
      OutputDebugString(PChar('IMAP logout: ' + E.Message));
  end;
  FSock.Free;
  inherited;
end;

function TImapSession.HasCap(const ACap: string): Boolean;
begin
  Result := ContainsText(FCaps, ' ' + ACap + ' ');
end;

function TImapSession.Cmd(const ACommand: string; out ALines: TArray<TImapLine>; out AStatus: string): Boolean;
var
  Tag, Line: string;
  Item: TImapLine;
  M: TMatch;
begin
  Inc(FTag);
  Tag := 'D' + IntToStr(FTag);
  FSock.SendText(Tag + ' ' + ACommand + #13#10);
  ALines := nil;
  while True do
  begin
    Line := FSock.ReadLine;
    Item.Text := Line;
    Item.Literals := nil;
    // Literal: a linha termina em {n} e os n bytes vêm a seguir, depois o resto da linha.
    M := TRegEx.Match(Line, '\{(\d+)\}$');
    while M.Success do
    begin
      Item.Literals := Item.Literals + [FSock.ReadBytes(StrToInt(M.Groups[1].Value))];
      Line := FSock.ReadLine;
      Item.Text := Item.Text + #1 + Line;
      M := TRegEx.Match(Line, '\{(\d+)\}$');
    end;
    if StartsStr(Tag + ' ', Item.Text) then
    begin
      AStatus := Copy(Item.Text, Length(Tag) + 2, MaxInt);
      Result := StartsText('OK', AStatus);
      Exit;
    end;
    if StartsStr('* ', Item.Text) then
      ALines := ALines + [Item];
  end;
end;

procedure TImapSession.Must(const ACommand: string; out ALines: TArray<TImapLine>);
var
  Status, Shown: string;
begin
  if not Cmd(ACommand, ALines, Status) then
  begin
    Shown := ACommand;
    if StartsText('LOGIN ', Shown) then
      Shown := 'LOGIN';
    raise EImap.Create(Shown + ': ' + Status);
  end;
end;

procedure TImapSession.Must(const ACommand: string);
var
  L: TArray<TImapLine>;
begin
  Must(ACommand, L);
end;

{ Operações }

function UidOf(const AId: string): string;
begin
  Result := Copy(AId, LastDelimiter(ImapIdSep, AId) + 1, MaxInt);
end;

function Run(const AAccount: TImapAccount; out AError: string; const AWork: TProc<TImapSession>): Boolean;
var
  S: TImapSession;
begin
  AError := '';
  try
    S := TImapSession.Create(AAccount);
    try
      AWork(S);
    finally
      S.Free;
    end;
    Result := True;
  except
    on E: Exception do
    begin
      AError := E.Message;
      if ContainsText(AError, 'AUTHENTICATIONFAILED') or ContainsText(AError, 'Invalid credentials') then
        AError := 'Login recusado. Confira o e-mail e a senha de app.';
      Result := False;
    end;
  end;
end;

function ImapTest(const AAccount: TImapAccount; out AError: string): Boolean;
begin
  Result := Run(AAccount, AError,
    procedure(S: TImapSession)
    begin
      S.Must('SELECT "INBOX"');
    end);
end;

function ImapListInbox(const AAccount: TImapAccount; ADays, AMax: Integer; AUnseenOnly: Boolean;
  out AMsgs: TMailMsgs; out AError: string): Boolean;
var
  Msgs: TMailMsgs;
begin
  Msgs := nil;
  Result := Run(AAccount, AError,
    procedure(S: TImapSession)
    var
      L: TArray<TImapLine>;
      Uids: TArray<string>;
      Since: TDateTime;
      Item: TImapLine;
      M: TMailMsg;
      Flags, FromH, Subj: string;
      Mt: TMatch;
    begin
      S.Must('SELECT "INBOX"');
      Since := Date - ADays;
      S.Must('UID SEARCH ' + IfThen(AUnseenOnly, 'UNSEEN ', '') + Format('SINCE %d-%s-%d',
        [DayOf(Since), CMonths[MonthOf(Since)], YearOf(Since)]), L);
      Uids := nil;
      for Item in L do
        if StartsText('* SEARCH', Item.Text) then
          Uids := Trim(Copy(Item.Text, 9, MaxInt)).Split([' '], TStringSplitOptions.ExcludeEmpty);
      if Uids = nil then
        Exit;
      // Os mais novos: UID cresce com a chegada.
      if Length(Uids) > AMax then
        Uids := Copy(Uids, Length(Uids) - AMax, AMax);
      S.Must('UID FETCH ' + string.Join(',', Uids) +
        ' (UID FLAGS INTERNALDATE BODY.PEEK[HEADER.FIELDS (FROM SUBJECT)])', L);
      for Item in L do
      begin
        Mt := TRegEx.Match(Item.Text, 'UID (\d+)');
        if not Mt.Success then
          Continue;
        M := Default(TMailMsg);
        M.Account := AAccount.Email;
        M.Id := AAccount.Email + ImapIdSep + Mt.Groups[1].Value;
        Mt := TRegEx.Match(Item.Text, 'FLAGS \(([^)]*)\)');
        Flags := IfThen(Mt.Success, UpperCase(Mt.Groups[1].Value), '');
        M.Labels := ['INBOX'];
        if not ContainsText(Flags, '\SEEN') then
          M.Labels := M.Labels + ['UNREAD'];
        if ContainsText(Flags, '\FLAGGED') then
          M.Labels := M.Labels + ['IMPORTANT'];
        Mt := TRegEx.Match(Item.Text, 'INTERNALDATE "([^"]+)"');
        if Mt.Success then
          M.Date := ParseImapDate(Mt.Groups[1].Value);
        if Item.Literals <> nil then
        begin
          ParseHeaderFields(TEncoding.UTF8.GetString(Item.Literals[0]), FromH, Subj);
          SplitFrom(FromH, M.FromName, M.FromEmail);
          M.Subject := IfThen(Subj <> '', Subj, '(sem assunto)');
        end;
        Msgs := Msgs + [M];
      end;
    end);
  AMsgs := Msgs;
end;

function ImapGetMail(const AAccount: TImapAccount; const AId: string; out AMsg: TMailMsg; out AError: string): Boolean;
var
  Msg: TMailMsg;
begin
  Msg := Default(TMailMsg);
  Result := Run(AAccount, AError,
    procedure(S: TImapSession)
    var
      L: TArray<TImapLine>;
      Item: TImapLine;
    begin
      S.Must('SELECT "INBOX"');
      S.Must('UID FETCH ' + UidOf(AId) + ' (FLAGS BODY.PEEK[])', L);
      for Item in L do
        if (Item.Literals <> nil) and ParseRawMail(Item.Literals[0], Msg) then
          Break;
    end) and (Msg.Subject <> '');
  if Result then
  begin
    Msg.Id := AId;
    Msg.Account := AAccount.Email;
  end
  else if AError = '' then
    AError := 'E-mail não encontrado';
  AMsg := Msg;
end;

function ImapSetSeen(const AAccount: TImapAccount; const AId: string; out AError: string): Boolean;
begin
  Result := Run(AAccount, AError,
    procedure(S: TImapSession)
    begin
      S.Must('SELECT "INBOX"');
      S.Must('UID STORE ' + UidOf(AId) + ' +FLAGS.SILENT (\Seen)');
    end);
end;

{ Pastas: nome decodificado e se é a de arquivo. }
function ListFolders(S: TImapSession): TMailLabels;
var
  L: TArray<TImapLine>;
  Item: TImapLine;
  Mt: TMatch;
  F: TMailLabel;
  Name: string;
begin
  Result := nil;
  S.Must('LIST "" "*"', L);
  for Item in L do
  begin
    Mt := TRegEx.Match(Item.Text, '^\* LIST \(([^)]*)\) (?:"[^"]*"|NIL) (.+)$');
    if not Mt.Success then
      Continue;
    Name := Trim(Mt.Groups[2].Value);
    if (Length(Name) >= 2) and (Name[1] = '"') then
      Name := Copy(Name, 2, Length(Name) - 2).Replace('\"', '"').Replace('\\', '\');
    F.Id := Name;
    F.Name := MUtf7Decode(Name);
    // \Archive, \All (Gmail) e afins contam como de sistema: a IA só vê as do usuário.
    F.IsSystem := SameText(Name, 'INBOX') or ContainsText(Mt.Groups[1].Value, '\Archive') or
      ContainsText(Mt.Groups[1].Value, '\All') or ContainsText(Mt.Groups[1].Value, '\Trash') or
      ContainsText(Mt.Groups[1].Value, '\Sent') or ContainsText(Mt.Groups[1].Value, '\Drafts') or
      ContainsText(Mt.Groups[1].Value, '\Junk') or ContainsText(Mt.Groups[1].Value, '\Noselect');
    if ContainsText(Mt.Groups[1].Value, '\Archive') then
      F.Name := #1 + F.Name;   // marca: pasta de arquivo
    Result := Result + [F];
  end;
end;

procedure MoveTo(S: TImapSession; const AUid, AFolderRaw: string);
begin
  if S.HasCap('MOVE') then
    S.Must('UID MOVE ' + AUid + ' ' + ImapQuote(AFolderRaw))
  else
  begin
    S.Must('UID COPY ' + AUid + ' ' + ImapQuote(AFolderRaw));
    S.Must('UID STORE ' + AUid + ' +FLAGS.SILENT (\Deleted)');
    if S.HasCap('UIDPLUS') then
      S.Must('UID EXPUNGE ' + AUid);
  end;
end;

function ImapMove(const AAccount: TImapAccount; const AId, AFolder: string; out AError: string): Boolean;
begin
  Result := Run(AAccount, AError,
    procedure(S: TImapSession)
    var
      F: TMailLabel;
      Raw: string;
    begin
      Raw := '';
      for F in ListFolders(S) do
        if SameText(F.Name.Replace(#1, ''), AFolder) then
          Raw := F.Id;
      if Raw = '' then
      begin
        Raw := MUtf7Encode(AFolder);
        S.Must('CREATE ' + ImapQuote(Raw));
      end;
      S.Must('SELECT "INBOX"');
      MoveTo(S, UidOf(AId), Raw);
    end);
end;

function ImapArchive(const AAccount: TImapAccount; const AId: string; out AError: string): Boolean;
begin
  Result := Run(AAccount, AError,
    procedure(S: TImapSession)
    var
      F: TMailLabel;
      Raw: string;
    begin
      Raw := '';
      for F in ListFolders(S) do
        if (F.Name <> '') and (F.Name[1] = #1) then
          Raw := F.Id;
      if Raw = '' then
        for F in ListFolders(S) do
          if MatchText(F.Name, ['Archive', 'Arquivo', 'Arquivados']) then
            Raw := F.Id;
      if Raw = '' then
      begin
        Raw := 'Archive';
        S.Must('CREATE "Archive"');
      end;
      S.Must('SELECT "INBOX"');
      MoveTo(S, UidOf(AId), Raw);
    end);
end;

function ImapFolders(const AAccount: TImapAccount; out ALabels: TMailLabels; out AError: string): Boolean;
var
  Labels: TMailLabels;
begin
  Labels := nil;
  Result := Run(AAccount, AError,
    procedure(S: TImapSession)
    var
      F: TMailLabel;
    begin
      for F in ListFolders(S) do
      begin
        Labels := Labels + [F];
        Labels[High(Labels)].Name := F.Name.Replace(#1, '');
      end;
    end);
  ALabels := Labels;
end;

end.
