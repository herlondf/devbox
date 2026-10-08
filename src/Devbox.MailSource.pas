unit Devbox.MailSource;

{ As mesmas operações de e-mail para conta Google (API do Gmail) e conta IMAP.
  Sem banco: pode rodar nas tarefas de fundo. Bloqueia. }

interface

uses
  System.SysUtils,
  Devbox.Store,
  Devbox.Google;

type
  TMailAccount = record
    Email: string;
    IsImap: Boolean;
    Imap: TImapAccount;
  end;
  TMailAccounts = TArray<TMailAccount>;

{ Contas ligadas e com acesso salvo, Google primeiro. Lê o banco: thread de UI. }
function LoadMailAccounts: TMailAccounts;

function SrcListInbox(const A: TMailAccount; out AMsgs: TMailMsgs; out ALabels: TMailLabels;
  out AError: string): Boolean;
{ O que gera aviso: importante não lido (Google) ou não lido do último dia (IMAP). }
function SrcListNotify(const A: TMailAccount; out AMsgs: TMailMsgs; out AError: string): Boolean;
{ Não lidos que entram no resumo do dia, com o corpo. }
function SrcListDigest(const A: TMailAccount; out AMsgs: TMailMsgs; out AError: string): Boolean;
function SrcGetMail(const A: TMailAccount; const AId: string; out AMsg: TMailMsg; out AError: string): Boolean;
function SrcMarkRead(const A: TMailAccount; const AId: string; out AError: string): Boolean;
function SrcArchive(const A: TMailAccount; const AId: string; out AError: string): Boolean;
{ Google: põe o rótulo (cria se não existir; ALabels guarda o criado). IMAP: move para a pasta. }
function SrcLabel(const A: TMailAccount; const AId, ALabel: string; var ALabels: TMailLabels;
  out AError: string): Boolean;
{ No IMAP o rótulo tira da caixa de entrada (é pasta). }
function LabelLeavesInbox(const A: TMailAccount): Boolean;

implementation

uses
  Devbox.Imap;

const
  CInboxQuery = 'in:inbox newer_than:14d';
  CInboxMax = 40;
  CInboxDays = 14;
  CNotifyQuery = 'is:important is:unread in:inbox newer_than:1d';
  CNotifyMax = 20;
  CDigestQuery = 'is:important is:unread in:inbox newer_than:2d';
  CDigestMax = 15;
  CDigestImapMax = 10;

function LoadMailAccounts: TMailAccounts;
var
  G: TGoogleAccount;
  I: TImapAccount;
  A: TMailAccount;
begin
  Result := nil;
  for G in Store.ListGoogleAccounts do
    if G.Enabled and GoogleSignedIn(G.Email) then
    begin
      A := Default(TMailAccount);
      A.Email := G.Email;
      Result := Result + [A];
    end;
  for I in Store.ListImapAccounts do
    if I.Enabled and ImapHasPassword(I.Email) then
    begin
      A := Default(TMailAccount);
      A.Email := I.Email;
      A.IsImap := True;
      A.Imap := I;
      Result := Result + [A];
    end;
end;

function SrcListInbox(const A: TMailAccount; out AMsgs: TMailMsgs; out ALabels: TMailLabels;
  out AError: string): Boolean;
begin
  AMsgs := nil;
  ALabels := nil;
  if A.IsImap then
    Result := ImapFolders(A.Imap, ALabels, AError) and ImapListInbox(A.Imap, CInboxDays, CInboxMax, False, AMsgs,
      AError)
  else
    Result := ListLabels(A.Email, ALabels, AError) and ListMail(A.Email, CInboxQuery, CInboxMax, False, AMsgs,
      AError);
end;

function SrcListNotify(const A: TMailAccount; out AMsgs: TMailMsgs; out AError: string): Boolean;
begin
  if A.IsImap then
    Result := ImapListInbox(A.Imap, 1, CNotifyMax, True, AMsgs, AError)
  else
    Result := ListMail(A.Email, CNotifyQuery, CNotifyMax, False, AMsgs, AError);
end;

function SrcListDigest(const A: TMailAccount; out AMsgs: TMailMsgs; out AError: string): Boolean;
var
  Heads: TMailMsgs;
  M, Full: TMailMsg;
begin
  if not A.IsImap then
    Exit(ListMail(A.Email, CDigestQuery, CDigestMax, True, AMsgs, AError));
  AMsgs := nil;
  Result := ImapListInbox(A.Imap, 2, CDigestImapMax, True, Heads, AError);
  if Result then
    for M in Heads do
      if ImapGetMail(A.Imap, M.Id, Full, AError) then
        AMsgs := AMsgs + [Full];
end;

function SrcGetMail(const A: TMailAccount; const AId: string; out AMsg: TMailMsg; out AError: string): Boolean;
begin
  if A.IsImap then
    Result := ImapGetMail(A.Imap, AId, AMsg, AError)
  else
    Result := GetMail(A.Email, AId, AMsg, AError);
end;

function SrcMarkRead(const A: TMailAccount; const AId: string; out AError: string): Boolean;
begin
  if A.IsImap then
    Result := ImapSetSeen(A.Imap, AId, AError)
  else
    Result := ModifyMail(A.Email, AId, nil, ['UNREAD'], AError);
end;

function SrcArchive(const A: TMailAccount; const AId: string; out AError: string): Boolean;
begin
  if A.IsImap then
    Result := ImapArchive(A.Imap, AId, AError)
  else
    Result := ModifyMail(A.Email, AId, nil, ['INBOX'], AError);
end;

function SrcLabel(const A: TMailAccount; const AId, ALabel: string; var ALabels: TMailLabels;
  out AError: string): Boolean;
var
  L: TMailLabel;
  LabelId: string;
begin
  if A.IsImap then
    Exit(ImapMove(A.Imap, AId, ALabel, AError));
  LabelId := '';
  for L in ALabels do
    if SameText(L.Name, ALabel) then
      LabelId := L.Id;
  if LabelId = '' then
  begin
    if not CreateLabel(A.Email, ALabel, LabelId, AError) then
      Exit(False);
    L.Id := LabelId;
    L.Name := ALabel;
    L.IsSystem := False;
    ALabels := ALabels + [L];
  end;
  Result := ModifyMail(A.Email, AId, [LabelId], nil, AError);
end;

function LabelLeavesInbox(const A: TMailAccount): Boolean;
begin
  Result := A.IsImap;
end;

end.
