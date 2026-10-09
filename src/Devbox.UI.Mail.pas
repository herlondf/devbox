unit Devbox.UI.Mail;

{ E-mail: caixa de entrada das contas Google e IMAP ligadas, aviso de e-mail
  novo e organização por IA. A lista ocupa a tela; o e-mail abre num painel ao
  lado da janela (TSidePeek). A IA só sugere; nada muda na caixa sem o clique
  em Aplicar. As contas falam pela Devbox.MailSource. }

interface

uses
  System.Classes,
  System.SysUtils,
  System.Generics.Collections,
  Vcl.ExtCtrls,
  UI.Labels,
  UI.Select,
  UI.Code,
  UI.Button,
  UI.VirtualList,
  UI.MailList,
  Devbox.Store,
  Devbox.Google,
  Devbox.MailSource,
  Devbox.UI.SidePeek,
  Devbox.UI.Kit;

type
  TMailPage = class(TDevPage)
  private
    FAccountSel: TUISelect;
    FStatus: TUILabel;
    FList: TUIMailList;
    FSubject: TUILabel;
    FMeta: TUILabel;
    FBody: TUICode;
    FDetail: TPanel;
    FPeek: TSidePeek;
    FOrganizeBtn: TUIButton;
    FAccounts: TMailAccounts;
    FMsgs: TDictionary<string, TMailMsg>;
    FSuggest: TDictionary<string, TMailSuggestion>;
    FLabels: TDictionary<string, TMailLabels>;
    FPrimed: TDictionary<string, Boolean>;
    FCurrent: string;
    FLoading: Integer;
    FOrganizing: Boolean;
    FRefreshedAt: TDateTime;
    FRefreshTimer: TTimer;
    FNotifyTimer: TTimer;
    procedure FillAccounts;
    procedure FillList;
    procedure ShowDetail(const AMsg: TMailMsg);
    procedure OpenPeek;
    procedure UpdateStatus;
    function AccountIndex(const AEmail: string): Integer;
    function TagsOf(const AMsg: TMailMsg): TArray<string>;
    function ShownMsgs: TArray<TMailMsg>;
    procedure RefreshClick(Sender: TObject);
    procedure OrganizeClick(Sender: TObject);
    procedure ApplyClick(Sender: TObject);
    procedure OpenClick(Sender: TObject);
    procedure MarkReadClick(Sender: TObject);
    procedure AccountChange(Sender: TObject);
    procedure ItemClick(Sender: TObject; AIndex: Integer; const AItem: TUIVListItem);
    procedure ItemDblClick(Sender: TObject; AIndex: Integer; const AItem: TUIVListItem);
    procedure RefreshTick(Sender: TObject);
    procedure NotifyTick(Sender: TObject);
    procedure Loaded_(const AEmail: string; const AMsgs: TMailMsgs; const ALabels: TMailLabels;
      const AError: string);
    procedure ApplyDone(const AId: string; AAction: TMailAction; const ALabel, AError: string);
    procedure QueueApplyDone(const AId: string; AAction: TMailAction; const ALabel, AError: string);
    procedure FetchAccount(const AAccount: TMailAccount);
    procedure CheckAccount(const AAccount: TMailAccount);
    function AccountOf(const AEmail: string; out AAccount: TMailAccount): Boolean;
  public
    constructor Create(AOwner: TComponent); override;
    procedure PageRefresh; override;
    procedure PageHidden; override;
    function PageKey(var AKey: Word; AShift: TShiftState): Boolean; override;
    function PageShortcuts: TArray<TDevShortcut>; override;
    function PageContext: string; override;
    { Não lidos de todas as contas (o Hoje mostra). }
    function UnreadMails: TMailMsgs;
    { Abre o e-mail no painel lateral (clique no Hoje). }
    procedure OpenMessage(const AId: string);
    destructor Destroy; override;
    { Contas mudaram: relê a lista delas e busca de novo. }
    procedure Reload;
  end;

implementation

uses
  Winapi.Windows,
  System.StrUtils,
  System.Math,
  System.UITypes,
  System.DateUtils,
  System.Threading,
  System.Generics.Defaults,
  Vcl.Controls,
  Vcl.Forms,
  UI.Toast,
  UI.Tokens,
  UI.ScrollArea,
  Devbox.Model,
  Devbox.AI,
  Devbox.Notify,
  Devbox.Sys;

const
  COrganizeMax = 25;
  CAIMaxTokens = 4096;
  CRefreshMs = 5 * 60 * 1000;
  CNotifyMs = 2 * 60 * 1000;
  CAllAccounts = 'Todas as contas';
  CDetailW = 520;
  CBodyLineH = 17;
  CBodyCharsPerLine = 74;

function NoteOf(const S: TMailSuggestion; out ATone: TUISemanticTone): string;
begin
  case S.Action of
    maLabel:
      begin
        ATone := stInfo;
        Result := 'Rótulo: ' + S.LabelName;
      end;
    maArchive:
      begin
        ATone := stSuccess;
        Result := 'Arquivar';
      end;
    maRead:
      begin
        ATone := stNone;
        Result := 'Marcar lido';
      end;
  else
    ATone := stWarning;
    Result := 'Pede ação';
  end;
end;

{ TMailPage }

constructor TMailPage.Create(AOwner: TComponent);
var
  Bar, Right, Row: TPanel;
  Scroll: TUIScrollArea;
begin
  inherited Create(AOwner);
  FRefreshable := True;
  Caption := 'E-mail';
  Hint := 'Caixa de entrada das suas contas (Google e IMAP). A IA sugere; você escolhe o que aplicar.';
  FMsgs := TDictionary<string, TMailMsg>.Create;
  FSuggest := TDictionary<string, TMailSuggestion>.Create;
  FLabels := TDictionary<string, TMailLabels>.Create;
  FPrimed := TDictionary<string, Boolean>.Create;

  Bar := NewPanel(Self, alTop, 50);
  Bar.Padding.SetBounds(0, ScaleValue(6), 0, ScaleValue(6));
  FAccountSel := TUISelect.Create(Self);
  FAccountSel.Width := ScaleValue(260);
  FAccountSel.AlignWithMargins := True;
  FAccountSel.Margins.SetBounds(0, 0, ScaleValue(8), 0);
  FAccountSel.Align := alLeft;
  FAccountSel.Parent := Bar;
  FOrganizeBtn := NewButton(Bar, 'Organizar com IA', OrganizeClick, bvPrimary);
  NewButton(Bar, 'Aplicar sugestões', ApplyClick);
  FStatus := NewHint(Self, '');

  // O detalhe vai para o painel lateral no primeiro clique (OpenPeek).
  Right := NewPanel(Self, alClient);
  Right.Parent := nil;
  FDetail := Right;
  FSubject := TUILabel.Create(Self);
  FSubject.Bold := True;
  FSubject.FontSize := 15;
  FSubject.AutoSize := False;
  FSubject.Height := ScaleValue(30);
  FSubject.Caption := 'Escolha um e-mail';
  FSubject.Align := alTop;
  FSubject.Parent := Right;
  FMeta := NewHint(Right, '');
  Row := NewPanel(Right, alTop, 44);
  Row.Padding.SetBounds(0, ScaleValue(4), 0, ScaleValue(4));
  NewButton(Row, 'Abrir no Gmail', OpenClick);
  NewButton(Row, 'Marcar lido', MarkReadClick, bvGhost);
  Scroll := TUIScrollArea.Create(Self);
  Scroll.Top := 100000;
  Scroll.Align := alClient;
  Scroll.Parent := Right;
  FBody := TUICode.Create(Self);
  FBody.FontSize := 11;
  FBody.Height := ScaleValue(300);
  FBody.Align := alTop;
  FBody.Parent := Scroll.InnerPanel;

  FList := TUIMailList.Create(Self);
  FList.OnItemClick := ItemClick;
  FList.OnItemDblClick := ItemDblClick;
  FList.Top := 100000;
  FList.Align := alClient;
  FList.Parent := Self;

  FRefreshTimer := TTimer.Create(Self);
  FRefreshTimer.Interval := CRefreshMs;
  FRefreshTimer.OnTimer := RefreshTick;
  FNotifyTimer := TTimer.Create(Self);
  FNotifyTimer.Interval := CNotifyMs;
  FNotifyTimer.OnTimer := NotifyTick;
  FAccountSel.OnChange := AccountChange;
  Reload;
end;

destructor TMailPage.Destroy;
begin
  FPrimed.Free;
  FLabels.Free;
  FSuggest.Free;
  FMsgs.Free;
  inherited;
end;

procedure TMailPage.Reload;
begin
  // Cópia do cliente OAuth e das contas para as tarefas de fundo (elas não podem ler o banco).
  LoadGoogleClient;
  FAccounts := LoadMailAccounts;
  FillAccounts;
  FRefreshTimer.Enabled := FAccounts <> nil;
  FNotifyTimer.Enabled := FAccounts <> nil;
  if FAccounts = nil then
  begin
    FMsgs.Clear;
    FillList;
    FStatus.Caption := 'Nenhuma conta ligada. Adicione uma em Configuração › E-mail e agenda.';
    Exit;
  end;
  RefreshClick(nil);
  System.Classes.TThread.ForceQueue(nil,
    procedure
    begin
      NotifyTick(nil);
    end);
end;

procedure TMailPage.FillAccounts;
var
  A: TMailAccount;
  Old: string;
begin
  Old := '';
  if FAccountSel.ItemIndex > 0 then
    Old := FAccountSel.Items[FAccountSel.ItemIndex];
  FAccountSel.OnChange := nil;
  FAccountSel.Items.Clear;
  FAccountSel.Items.Add(CAllAccounts);
  for A in FAccounts do
    FAccountSel.Items.Add(A.Email);
  FAccountSel.ItemIndex := Max(FAccountSel.Items.IndexOf(Old), 0);
  FAccountSel.OnChange := AccountChange;
end;

function TMailPage.AccountIndex(const AEmail: string): Integer;
begin
  for Result := 0 to High(FAccounts) do
    if SameText(FAccounts[Result].Email, AEmail) then
      Exit;
  Result := 0;
end;

function TMailPage.AccountOf(const AEmail: string; out AAccount: TMailAccount): Boolean;
var
  A: TMailAccount;
begin
  for A in FAccounts do
    if SameText(A.Email, AEmail) then
    begin
      AAccount := A;
      Exit(True);
    end;
  Result := False;
end;

function TMailPage.TagsOf(const AMsg: TMailMsg): TArray<string>;
var
  Ls: TMailLabels;
  L: TMailLabel;
begin
  Result := nil;
  if not FLabels.TryGetValue(AMsg.Account, Ls) then
    Exit;
  for L in Ls do
    if not L.IsSystem and MatchStr(L.Id, AMsg.Labels) then
      Result := Result + [L.Name];
end;

function TMailPage.ShownMsgs: TArray<TMailMsg>;
var
  M: TMailMsg;
  Account: string;
begin
  Result := nil;
  Account := '';
  if FAccountSel.ItemIndex > 0 then
    Account := FAccountSel.Items[FAccountSel.ItemIndex];
  for M in FMsgs.Values do
    if (Account = '') or SameText(M.Account, Account) then
      Result := Result + [M];
  TArray.Sort<TMailMsg>(Result, TComparer<TMailMsg>.Construct(
    function(const A, B: TMailMsg): Integer
    begin
      Result := CompareValue(B.Date, A.Date);
    end));
end;

procedure TMailPage.FillList;
var
  M: TMailMsg;
  Info: TUIMailInfo;
  S: TMailSuggestion;
  Keep: TArray<string>;
  Idx: Integer;
begin
  // A atualização automática refaz a lista: a seleção do usuário volta pelo ID.
  Keep := nil;
  for Info in FList.SelectedMails do
    Keep := Keep + [Info.ID];
  FList.ClearMails;
  for M in ShownMsgs do
  begin
    Info := Default(TUIMailInfo);
    Info.ID := M.Id;
    Info.Sender := M.FromName;
    Info.Subject := M.Subject;
    Info.Snippet := M.Snippet;
    Info.Date := M.Date;
    Info.Unread := M.Unread;
    Info.Important := M.Important;
    Info.Tags := TagsOf(M);
    if Length(FAccounts) > 1 then
      Info.AccentColor := GoogleAccountColor(AccountIndex(M.Account))
    else
      Info.AccentColor := TAlphaColors.Null;
    if FSuggest.TryGetValue(M.Id, S) then
      Info.Note := NoteOf(S, Info.NoteTone);
    FList.AddMail(Info);
  end;
  for Idx := 0 to FList.ItemCount - 1 do
    if MatchStr(FList.GetItem(Idx).ID, Keep) then
      FList.SelectIndex(Idx);
  UpdateStatus;
end;

procedure TMailPage.UpdateStatus;
var
  Unread: Integer;
  M: TMailMsg;
begin
  if FAccounts = nil then
    Exit;
  Unread := 0;
  for M in ShownMsgs do
    if M.Unread then
      Inc(Unread);
  if FLoading > 0 then
    FStatus.Caption := 'Buscando...'
  else
    FStatus.Caption := Format('%d %s dos últimos 14 dias, %d %s · atualizado %s',
      [FList.MailCount, IfThen(FList.MailCount = 1, 'e-mail', 'e-mails'), Unread,
      IfThen(Unread = 1, 'não lido', 'não lidos'), Ago(FRefreshedAt, Now)]);
end;

procedure TMailPage.AccountChange(Sender: TObject);
begin
  FillList;
end;

procedure TMailPage.RefreshTick(Sender: TObject);
begin
  RefreshClick(nil);
end;

procedure TMailPage.RefreshClick(Sender: TObject);
var
  A: TMailAccount;
begin
  if FLoading > 0 then
    Exit;
  for A in FAccounts do
    FetchAccount(A);
  UpdateStatus;
end;

{ Um método por conta: o parâmetro é de cada chamada, não o do laço. }
procedure TMailPage.FetchAccount(const AAccount: TMailAccount);
var
  Acc: TMailAccount;
begin
  Acc := AAccount;
  Inc(FLoading);
  TTask.Run(
    procedure
    var
      Err: string;
      Msgs: TMailMsgs;
      Labels: TMailLabels;
    begin
      Msgs := nil;
      Labels := nil;
      try
        SrcListInbox(Acc, Msgs, Labels, Err);
      except
        on E: Exception do
          Err := E.Message;
      end;
      QueueUI(
        procedure
        begin
          Loaded_(Acc.Email, Msgs, Labels, Err);
        end);
    end);
end;

procedure TMailPage.Loaded_(const AEmail: string; const AMsgs: TMailMsgs; const ALabels: TMailLabels;
  const AError: string);
var
  M: TMailMsg;
  Old: TArray<string>;
  Id: string;
begin
  Dec(FLoading);
  if AError <> '' then
    TUIToastManager.Show(AEmail + ': ' + AError, ttError, 6000)
  else
  begin
    FLabels.AddOrSetValue(AEmail, ALabels);
    Old := nil;
    for M in FMsgs.Values do
      if SameText(M.Account, AEmail) then
        Old := Old + [M.Id];
    for Id in Old do
      FMsgs.Remove(Id);
    for M in AMsgs do
      FMsgs.AddOrSetValue(M.Id, M);
  end;
  if FLoading = 0 then
  begin
    FRefreshedAt := Now;
    FillList;
  end;
end;

{ Aviso de importante não lido. Na primeira checagem de uma conta, só marca o
  que já existe como visto: sem enxurrada de avisos ao ligar. }
procedure TMailPage.NotifyTick(Sender: TObject);
var
  A: TMailAccount;
begin
  for A in FAccounts do
    CheckAccount(A);
end;

procedure TMailPage.CheckAccount(const AAccount: TMailAccount);
var
  Acc: TMailAccount;
  Email: string;
begin
  Acc := AAccount;
  Email := AAccount.Email;
  TTask.Run(
    procedure
    var
      Err: string;
      Msgs: TMailMsgs;
      Ok: Boolean;
    begin
      try
        Ok := SrcListNotify(Acc, Msgs, Err);
      except
        Ok := False;
      end;
      if not Ok then
        Exit;
      QueueUI(
        procedure
        var
          M: TMailMsg;
          First: Boolean;
        begin
          First := not FPrimed.ContainsKey(Email) and not Store.MailSeenAny(Email);
          FPrimed.AddOrSetValue(Email, True);
          for M in Msgs do
            if not Store.MailSeen(Email, M.Id) then
            begin
              Store.MarkMailSeen(Email, M.Id);
              if not First then
                Notify('E-mail de ' + M.FromName, M.Subject);
            end;
        end);
    end);
end;

procedure TMailPage.ItemClick(Sender: TObject; AIndex: Integer; const AItem: TUIVListItem);
var
  M: TMailMsg;
  Acc: TMailAccount;
begin
  if not FMsgs.TryGetValue(AItem.ID, M) or not AccountOf(M.Account, Acc) then
    Exit;
  FCurrent := M.Id;
  ShowDetail(M);
  OpenPeek;
  if M.Body <> '' then
    Exit;
  TTask.Run(
    procedure
    var
      Full: TMailMsg;
      Err: string;
      Ok: Boolean;
    begin
      try
        Ok := SrcGetMail(Acc, M.Id, Full, Err);
      except
        on E: Exception do
        begin
          Ok := False;
          Err := E.Message;
        end;
      end;
      QueueUI(
        procedure
        begin
          if not Ok then
          begin
            if FCurrent = M.Id then
              FBody.Text := 'Não deu para ler o e-mail: ' + Err;
            Exit;
          end;
          if FMsgs.ContainsKey(Full.Id) then
            FMsgs[Full.Id] := Full;
          if FCurrent = Full.Id then
            ShowDetail(Full);
        end);
    end);
end;

procedure TMailPage.ShowDetail(const AMsg: TMailMsg);
var
  Lines: Integer;
  L: string;
  S: TMailSuggestion;
begin
  FSubject.Caption := AMsg.Subject;
  FMeta.Caption := Format('%s <%s> · %s · %s', [AMsg.FromName, AMsg.FromEmail,
    FormatDateTime('dd/mm/yyyy hh:nn', AMsg.Date), AMsg.Account]);
  if FSuggest.TryGetValue(AMsg.Id, S) and (S.Reason <> '') then
    FMeta.Caption := FMeta.Caption + ' · IA: ' + S.Reason;
  if AMsg.Body <> '' then
    FBody.Text := AMsg.Body
  else
    FBody.Text := AMsg.Snippet + #10#10'Carregando o e-mail...';
  // Altura pelo texto (quebra aproximada): a rolagem é da área de fora.
  Lines := 0;
  for L in FBody.Text.Split([#10]) do
    Inc(Lines, 1 + Length(L) div CBodyCharsPerLine);
  FBody.Height := ScaleValue(Max(300, Lines * CBodyLineH + 40));
end;

procedure TMailPage.OpenPeek;
begin
  if FPeek = nil then
  begin
    FPeek := TSidePeek.CreatePeek(GetParentForm(Self), CDetailW);
    FPeek.Title := 'E-mail';
    FDetail.Parent := FPeek.Body;
  end;
  FPeek.Open;
end;

function TMailPage.PageKey(var AKey: Word; AShift: TShiftState): Boolean;
begin
  Result := (AKey = VK_DELETE) and (FCurrent <> '') and FSuggest.ContainsKey(FCurrent);
  if Result then
  begin
    FSuggest.Remove(FCurrent);
    FillList;
  end;
end;

function TMailPage.UnreadMails: TMailMsgs;
var
  LMsg: TMailMsg;
begin
  Result := nil;
  for LMsg in FMsgs.Values do
    if LMsg.Unread then
      Result := Result + [LMsg];
end;

procedure TMailPage.OpenMessage(const AId: string);
var
  LItem: TUIVListItem;
  LIndex: Integer;
begin
  for LIndex := 0 to FList.ItemCount - 1 do
    if FList.GetItem(LIndex).ID = AId then
    begin
      FList.SelectIndex(LIndex);
      FList.ScrollToIndex(LIndex);
      Break;
    end;
  LItem := Default(TUIVListItem);
  LItem.ID := AId;
  ItemClick(nil, -1, LItem);
end;

function TMailPage.PageContext: string;
const
  CMaxChars = 6000;
var
  LMsg: TMailMsg;
begin
  Result := '';
  if (FPeek <> nil) and FPeek.IsOpen and FMsgs.TryGetValue(FCurrent, LMsg) then
    Result := Format('E-mail aberto: "%s", de %s <%s>, %s.', [LMsg.Subject, LMsg.FromName, LMsg.FromEmail,
      FormatDateTime('dd/mm/yyyy hh:nn', LMsg.Date)]) + sLineBreak +
      Copy(IfThen(LMsg.Body <> '', LMsg.Body, LMsg.Snippet), 1, CMaxChars);
end;

function TMailPage.PageShortcuts: TArray<TDevShortcut>;
begin
  Result := [DevShortcut('Delete', 'Descartar sugestão da IA', procedure
    var
      LKey: Word;
    begin
      LKey := VK_DELETE;
      PageKey(LKey, []);
    end)];
end;

procedure TMailPage.PageHidden;
begin
  if FPeek <> nil then
    FPeek.Close_;
  inherited;
end;

procedure TMailPage.ItemDblClick(Sender: TObject; AIndex: Integer; const AItem: TUIVListItem);
begin
  FCurrent := AItem.ID;
  OpenClick(nil);
end;

procedure TMailPage.OpenClick(Sender: TObject);
var
  M: TMailMsg;
  Acc: TMailAccount;
begin
  if not FMsgs.TryGetValue(FCurrent, M) or not AccountOf(M.Account, Acc) then
    TUIToastManager.Show('Escolha um e-mail', ttInfo, 2000)
  else if Acc.IsImap then
    TUIToastManager.Show('Conta IMAP: abra no seu programa de e-mail ou no site do provedor', ttInfo, 3500)
  else
    OpenUrl(M.WebUrl);
end;

procedure TMailPage.MarkReadClick(Sender: TObject);
var
  M: TMailMsg;
  Acc: TMailAccount;
begin
  if not FMsgs.TryGetValue(FCurrent, M) or not AccountOf(M.Account, Acc) then
  begin
    TUIToastManager.Show('Escolha um e-mail', ttInfo, 2000);
    Exit;
  end;
  TTask.Run(
    procedure
    var
      Err: string;
    begin
      try
        SrcMarkRead(Acc, M.Id, Err);
      except
        on E: Exception do
          Err := E.Message;
      end;
      QueueUI(
        procedure
        begin
          ApplyDone(M.Id, maRead, '', Err);
        end);
    end);
end;

procedure TMailPage.OrganizeClick(Sender: TObject);
var
  Msgs: TArray<TMailMsg>;
  Config: TAIConfig;
  Labels: TMailLabels;
  Ls: TMailLabels;
  Accounts: TMailAccounts;
begin
  if FOrganizing then
    Exit;
  Config := LoadAIConfig;
  if not Config.Ready then
  begin
    TUIToastManager.Show('Configure a IA em Configurações antes', ttWarning, 4000);
    Exit;
  end;
  Msgs := Copy(ShownMsgs, 0, COrganizeMax);
  if Msgs = nil then
  begin
    TUIToastManager.Show('Nada para organizar', ttInfo, 2000);
    Exit;
  end;
  Labels := nil;
  for Ls in FLabels.Values do
    Labels := Labels + Ls;
  Accounts := FAccounts;
  FOrganizing := True;
  FOrganizeBtn.Caption := 'Organizando...';
  TUIToastManager.Show(Format('Lendo %d e-mails e pedindo sugestões à IA...', [Length(Msgs)]), ttLoading, 5000);
  TTask.Run(
    procedure
    var
      I: Integer;
      Full: TMailMsg;
      Err, Sys, Prompt, Answer: string;
      Ok: Boolean;
      Sugs: TMailSuggestions;
      A: TMailAccount;
    begin
      Sugs := nil;
      try
        // O corpo inteiro vai para a IA (escolha do usuário); a lista só tem o trecho.
        for I := 0 to High(Msgs) do
          if Msgs[I].Body = '' then
            for A in Accounts do
              if SameText(A.Email, Msgs[I].Account) and SrcGetMail(A, Msgs[I].Id, Full, Err) then
                Msgs[I] := Full;
        Prompt := OrganizePrompt(Msgs, Labels, Sys);
        Ok := AskAI(Config, Sys, Prompt, Answer, CAIMaxTokens);
        if Ok then
          Sugs := ParseSuggestions(Answer);
      except
        on E: Exception do
        begin
          Ok := False;
          Answer := E.Message;
        end;
      end;
      QueueUI(
        procedure
        var
          S: TMailSuggestion;
          M: TMailMsg;
          Acts, Idx: Integer;
        begin
          FOrganizing := False;
          FOrganizeBtn.Caption := 'Organizar com IA';
          for M in Msgs do
            if FMsgs.ContainsKey(M.Id) then
              FMsgs[M.Id] := M;
          if not Ok then
          begin
            TUIToastManager.Show('A IA não respondeu: ' + Answer, ttError, 8000);
            Exit;
          end;
          if Sugs = nil then
          begin
            TUIToastManager.Show('A IA respondeu fora do formato esperado', ttError, 6000);
            Exit;
          end;
          for S in Sugs do
            if FMsgs.ContainsKey(S.Id) then
              FSuggest.AddOrSetValue(S.Id, S);
          FillList;
          Acts := 0;
          for Idx := 0 to FList.ItemCount - 1 do
            if FSuggest.TryGetValue(FList.GetItem(Idx).ID, S) and (S.Action <> maKeep) then
              Inc(Acts);
          TUIToastManager.Show(Format('%d sugestões. Delete descarta a do e-mail aberto; Aplicar faz o resto.',
            [Acts]), ttSuccess, 6000);
        end);
    end);
end;

procedure TMailPage.ApplyClick(Sender: TObject);
type
  TJob = record
    Msg: TMailMsg;
    Sug: TMailSuggestion;
    Acc: TMailAccount;
  end;
var
  Jobs: TArray<TJob>;
  Job: TJob;
  M: TMailMsg;
  Labels: TDictionary<string, TMailLabels>;
begin
  Jobs := nil;
  // Todas as sugestões com ação da lista (as que o usuário não quis, ele descartou com Delete).
  for M in ShownMsgs do
    if FSuggest.TryGetValue(M.Id, Job.Sug) and (Job.Sug.Action <> maKeep) and AccountOf(M.Account, Job.Acc) then
    begin
      Job.Msg := M;
      Jobs := Jobs + [Job];
    end;
  if Jobs = nil then
  begin
    TUIToastManager.Show('Nenhuma sugestão para aplicar (Organizar com IA antes)', ttInfo, 3500);
    Exit;
  end;
  // Cópia para a thread: rótulos criados lá entram nela, não no cache da tela.
  Labels := TDictionary<string, TMailLabels>.Create(FLabels);
  TUIToastManager.Show(Format('Aplicando %d sugestões...', [Length(Jobs)]), ttLoading, 3000);
  TTask.Run(
    procedure
    var
      J: TJob;
      Ls: TMailLabels;
      Err: string;
      Done: TMailAction;
    begin
      try
        for J in Jobs do
        begin
          Err := '';
          Done := J.Sug.Action;
          try
            case J.Sug.Action of
              maArchive:
                SrcArchive(J.Acc, J.Msg.Id, Err);
              maRead:
                SrcMarkRead(J.Acc, J.Msg.Id, Err);
              maLabel:
                begin
                  if not Labels.TryGetValue(J.Acc.Email, Ls) then
                    Ls := nil;
                  if SrcLabel(J.Acc, J.Msg.Id, J.Sug.LabelName, Ls, Err) then
                    Labels.AddOrSetValue(J.Acc.Email, Ls);
                  // No IMAP o rótulo é pasta: o e-mail sai da caixa de entrada.
                  if LabelLeavesInbox(J.Acc) then
                    Done := maArchive;
                end;
            end;
          except
            on E: Exception do
              Err := E.Message;
          end;
          QueueApplyDone(J.Msg.Id, Done, J.Sug.LabelName, Err);
        end;
      finally
        QueueUI(
          procedure
          begin
            Labels.Free;
            RefreshClick(nil);
          end);
      end;
    end);
end;

procedure TMailPage.QueueApplyDone(const AId: string; AAction: TMailAction; const ALabel, AError: string);
var
  Id, LabelName, Err: string;
  Action: TMailAction;
begin
  Id := AId;
  Action := AAction;
  LabelName := ALabel;
  Err := AError;
  QueueUI(
    procedure
    begin
      ApplyDone(Id, Action, LabelName, Err);
    end);
end;

procedure TMailPage.ApplyDone(const AId: string; AAction: TMailAction; const ALabel, AError: string);
var
  M: TMailMsg;
  Kept: TArray<string>;
  L: string;
begin
  if AError <> '' then
  begin
    TUIToastManager.Show('Não aplicou: ' + AError, ttError, 6000);
    Exit;
  end;
  FSuggest.Remove(AId);
  FList.SetNote(AId, '', stNone);
  if not FMsgs.TryGetValue(AId, M) then
    Exit;
  case AAction of
    maArchive:
      begin
        FMsgs.Remove(AId);
        FList.RemoveMail(AId);
        if FCurrent = AId then
        begin
          FCurrent := '';
          FSubject.Caption := 'Escolha um e-mail';
          FMeta.Caption := '';
          FBody.Text := '';
        end;
      end;
    maRead:
      begin
        Kept := nil;
        for L in M.Labels do
          if L <> 'UNREAD' then
            Kept := Kept + [L];
        M.Labels := Kept;
        FMsgs[AId] := M;
        FList.SetUnread(AId, False);
      end;
  end;
  UpdateStatus;
end;

procedure TMailPage.PageRefresh;
begin
  RefreshClick(nil);
end;

end.
