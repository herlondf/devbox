unit Devbox.Issues.Diff;

{ Compara a busca nova com o snapshot anterior e gera eventos.
  Puro: sem rede, sem banco, sem relógio (AToday vem de fora). }

interface

uses
  Devbox.Issues.Model;

{ ANew volta com DueAlert atualizado, pronto para virar o próximo snapshot.
  ABaseline = primeira busca da conta: só avisa prazo, o resto vira linha de base. }
function DiffItems(const AOld: TItems; var ANew: TItems; const AAccount: TAccount;
  const AMe: TIdentity; AToday: TDateTime; ABaseline: Boolean): TIssueEvents;

{ Mantém só os tipos que a conta quer receber. }
function FilterEvents(const AEvents: TIssueEvents; AWanted: TEventKinds): TIssueEvents;

implementation

uses
  Devbox.I18n,
  System.SysUtils,
  System.StrUtils,
  System.DateUtils;

function FindOld(const AOld: TItems; const AKey: string; out AItem: TItem): Boolean;
var
  It: TItem;
begin
  for It in AOld do
    if SameText(It.Key, AKey) then
    begin
      AItem := It;
      Exit(True);
    end;
  Result := False;
end;

procedure Add(var AEvents: TIssueEvents; AKind: TEventKind; const AItem: TItem;
  const AAccount: TAccount; const ABody: string);
var
  E: TIssueEvent;
begin
  E.Kind := AKind;
  E.AccountId := AItem.AccountId;
  E.Key := AItem.Key;
  E.Url := AItem.Url;
  E.Title := Format('%s · %s · %s', [AAccount.Name, AItem.Key, Tr(EventNames[AKind])]);
  E.Body := ABody;
  AEvents := AEvents + [E];
end;

function Clip(const S: string; AMax: Integer = 140): string;
begin
  Result := S.Replace(#13, ' ').Replace(#10, ' ').Trim;
  if Length(Result) > AMax then
    Result := Copy(Result, 1, AMax - 1) + '…';
end;

function DiffItems(const AOld: TItems; var ANew: TItems; const AAccount: TAccount;
  const AMe: TIdentity; AToday: TDateTime; ABaseline: Boolean): TIssueEvents;
var
  I, DaysLeft: Integer;
  Old: TItem;
  HasOld, NewComment, ByOther: Boolean;
begin
  Result := nil;
  AToday := DateOf(AToday);
  for I := 0 to High(ANew) do
  begin
    HasOld := FindOld(AOld, ANew[I].Key, Old);

    // Prazo: o nível já avisado segue junto enquanto a data não mudar.
    if HasOld and SameDate(Old.DueDate, ANew[I].DueDate) then
      ANew[I].DueAlert := Old.DueAlert
    else
      ANew[I].DueAlert := 0;
    if ANew[I].DueDate > 0 then
    begin
      DaysLeft := Trunc(DateOf(ANew[I].DueDate) - AToday);
      if (DaysLeft < 0) and (ANew[I].DueAlert < 2) then
      begin
        Add(Result, ekOverdue, ANew[I], AAccount,
          Format(Tr('%s: venceu há %d dia(s)'), [Clip(ANew[I].Title), -DaysLeft]));
        ANew[I].DueAlert := 2;
      end
      else if (DaysLeft >= 0) and (DaysLeft <= AAccount.DueDays) and (ANew[I].DueAlert < 1) then
      begin
        Add(Result, ekDueSoon, ANew[I], AAccount, Format(Tr('%s: vence %s'), [Clip(ANew[I].Title),
          IfThen(DaysLeft = 0, 'hoje', Format(Tr('em %d dia(s)'), [DaysLeft]))]));
        ANew[I].DueAlert := 1;
      end;
    end;

    if ABaseline then
      Continue;

    if (isAssigned in ANew[I].Sources) and not (HasOld and (isAssigned in Old.Sources)) then
      Add(Result, ekAssigned, ANew[I], AAccount, Clip(ANew[I].Title));

    if (isReview in ANew[I].Sources) and not (HasOld and (isReview in Old.Sources)) then
      Add(Result, ekReviewRequested, ANew[I], AAccount, Clip(ANew[I].Title));

    if (isMention in ANew[I].Sources) and not (HasOld and (isMention in Old.Sources)) then
      Add(Result, ekMention, ANew[I], AAccount, Clip(ANew[I].Title));

    if not HasOld then
      Continue;

    // Meus PRs: decisão de review e CI mudaram desde a última busca.
    if not SameText(ANew[I].ReviewState, Old.ReviewState) then
    begin
      if SameText(ANew[I].ReviewState, 'APPROVED') then
        Add(Result, ekPrApproved, ANew[I], AAccount, Clip(ANew[I].Title) + IfThen(ANew[I].Reviewers <> '', sLineBreak + ANew[I].Reviewers, ''))
      else if SameText(ANew[I].ReviewState, 'CHANGES_REQUESTED') then
        Add(Result, ekChangesRequested, ANew[I], AAccount, Clip(ANew[I].Title) + IfThen(ANew[I].Reviewers <> '', sLineBreak + ANew[I].Reviewers, ''));
    end;
    if MatchText(ANew[I].CiState, ['FAILURE', 'ERROR']) and
      not MatchText(Old.CiState, ['FAILURE', 'ERROR']) then
      Add(Result, ekCiFailed, ANew[I], AAccount, Clip(ANew[I].Title) + IfThen(ANew[I].CiDetail <> '', sLineBreak + Tr('Job: ') + ANew[I].CiDetail, ''));

    // Snapshot sem StatusCategory é do banco antigo, que não guardava a flag:
    // não dá para saber se ela é nova.
    if ANew[I].Flagged and not Old.Flagged and (Old.StatusCategory <> '') then
      Add(Result, ekFlagged, ANew[I], AAccount, Clip(ANew[I].Title));

    if not SameText(Old.Status, ANew[I].Status) then
      Add(Result, ekStatus, ANew[I], AAccount,
        Format('%s → %s · %s', [Old.Status, ANew[I].Status, Clip(ANew[I].Title, 100)]));

    NewComment := ANew[I].CommentCount > Old.CommentCount;
    if AAccount.Kind in RepoKinds then
      // Notification (to-do no GitLab) nunca nasce de ação minha; nova reason não lida = outra pessoa mexeu.
      ByOther := (ANew[I].UnreadReason <> '') and (ANew[I].UnreadReason <> Old.UnreadReason)
    else
      ByOther := (ANew[I].LastCommentBy <> '') and not SameText(ANew[I].LastCommentBy, AMe.Id);

    if NewComment and ByOther then
    begin
      if ANew[I].MentionsMe then
        Add(Result, ekMention, ANew[I], AAccount, Clip(ANew[I].LastCommentBy + ': ' +
          IfThen(ANew[I].LastCommentText <> '', ANew[I].LastCommentText, ANew[I].Title)))
      else if AAccount.Kind in RepoKinds then
        Add(Result, ekComment, ANew[I], AAccount, Clip(ANew[I].Title))
      else
        Add(Result, ekComment, ANew[I], AAccount,
          Clip(ANew[I].LastCommentBy + ': ' + ANew[I].LastCommentText));
    end
    else if (AAccount.Kind in RepoKinds) and (ANew[I].UnreadReason = 'mention') and
      (Old.UnreadReason <> 'mention') then
      // Menção na descrição, sem comentário novo.
      Add(Result, ekMention, ANew[I], AAccount, Clip(ANew[I].Title));
  end;
end;

function FilterEvents(const AEvents: TIssueEvents; AWanted: TEventKinds): TIssueEvents;
var
  E: TIssueEvent;
begin
  Result := nil;
  for E in AEvents do
    if E.Kind in AWanted then
      Result := Result + [E];
end;

end.
