{ ── GitLab (API v4) ───────────────────────────────────────────────────────
  Incluído em Devbox.Issues.Providers (usa GetJson/SendJson/Merge de lá).
  Chaves: issue 'grupo/projeto#12', merge request 'grupo/projeto!5'.
  BaseUrl é a raiz do servidor (https://gitlab.com ou o self-managed). }

function GitLabSplit(const AKey: string; out AProject, ANumber: string; out AIsMR: Boolean): Boolean;
var
  M: TMatch;
begin
  M := TRegEx.Match(AKey.Trim, '^(.+?)([#!])(\d+)$');
  Result := M.Success and (Pos('/', M.Groups[1].Value) > 0);
  if Result then
  begin
    AProject := M.Groups[1].Value;
    AIsMR := M.Groups[2].Value = '!';
    ANumber := M.Groups[3].Value;
  end;
end;

{ '/api/v4/projects/<grupo%2Fprojeto>/issues/12' (ou merge_requests). }
function GitLabItemPath(const AKey: string): string;
var
  Proj, Num: string;
  IsMR: Boolean;
begin
  if not GitLabSplit(AKey, Proj, Num, IsMR) then
    raise Exception.Create('Chave GitLab inválida: ' + AKey + ' (use grupo/projeto#12 ou !5)');
  Result := '/api/v4/projects/' + Enc(Proj) + IfThen(IsMR, '/merge_requests/', '/issues/') + Num;
end;

function GitLabMe(const AAccount: TAccount; const AToken: string; out ANumericId: string): TIdentity;
var
  J: TJSONValue;
begin
  J := GetJson(AAccount, AToken, '/api/v4/user');
  try
    Result.Id := J.GetValue<string>('username', '');
    Result.DisplayName := J.GetValue<string>('name', Result.Id);
    ANumericId := J.GetValue<string>('id', '');
  finally
    J.Free;
  end;
end;

function ParseGitLabItem(AJson: TJSONObject; AAccountId: Integer; AIsMR: Boolean): TItem;
var
  Arr: TJSONArray;
  State: string;
begin
  Result := Default(TItem);
  Result.AccountId := AAccountId;
  Result.Key := AJson.GetValue<string>('references.full', '');
  Result.Title := AJson.GetValue<string>('title', '');
  Result.Url := AJson.GetValue<string>('web_url', '');
  State := AJson.GetValue<string>('state', '');
  if State = 'opened' then
  begin
    Result.Status := IfThen(AIsMR and AJson.GetValue<Boolean>('draft', False), 'rascunho', 'open');
    Result.StatusCategory := IfThen(AIsMR, 'indeterminate', 'new');
  end
  else
  begin
    Result.Status := State;
    Result.StatusCategory := 'done';
  end;
  if AJson.TryGetValue<TJSONArray>('assignees', Arr) and (Arr.Count > 0) then
    Result.Assignee := Arr.Items[0].GetValue<string>('name', Arr.Items[0].GetValue<string>('username', ''));
  if AJson.FindValue('due_date') is TJSONString then
    Result.DueDate := ParseIsoDate(AJson.GetValue<string>('due_date'))
  else if AJson.FindValue('milestone.due_date') is TJSONString then
    Result.DueDate := ParseIsoDate(AJson.GetValue<string>('milestone.due_date'));
  Result.UpdatedAt := ParseIsoDate(AJson.GetValue<string>('updated_at', ''));
  Result.CommentCount := AJson.GetValue<Integer>('user_notes_count', 0);
  if AIsMR and (AJson.FindValue('detailed_merge_status') is TJSONString) then
  begin
    // 'approved' / 'not_approved' / 'requested_changes'... vira o ReviewState do GitHub.
    State := AJson.GetValue<string>('detailed_merge_status');
    if State = 'requested_changes' then
      Result.ReviewState := 'CHANGES_REQUESTED'
    else if State = 'mergeable' then
      Result.ReviewState := 'APPROVED'
    else
      Result.ReviewState := 'REVIEW_REQUIRED';
  end;
end;

{ Lista paginada (per_page=100, até MaxPages) de issues ou MRs. }
procedure GitLabList(const AAccount: TAccount; const AToken, APath: string; AIsMR: Boolean;
  ASource: TItemSource; var AItems: TItems);
var
  J: TJSONValue;
  Arr: TJSONArray;
  I, Page: Integer;
  It: TItem;
begin
  for Page := 1 to MaxPages do
  begin
    J := GetJson(AAccount, AToken, Format('%s%sper_page=%d&page=%d',
      [APath, IfThen(Pos('?', APath) > 0, '&', '?'), PageSize, Page]));
    try
      if not (J is TJSONArray) then
        Exit;
      Arr := TJSONArray(J);
      for I := 0 to Arr.Count - 1 do
      begin
        It := ParseGitLabItem(Arr.Items[I] as TJSONObject, AAccount.Id, AIsMR);
        if It.Key = '' then
          Continue;
        Include(It.Sources, ASource);
        Merge(AItems, It);
      end;
      if Arr.Count < PageSize then
        Exit;
    finally
      J.Free;
    end;
  end;
end;

{ CI do MR: a lista não traz o pipeline; o detalhe traz head_pipeline. }
procedure GitLabMrPipeline(const AAccount: TAccount; const AToken: string; var AItem: TItem);
var
  J: TJSONValue;
  St: string;
begin
  J := GetJson(AAccount, AToken, GitLabItemPath(AItem.Key));
  try
    if not (J.FindValue('head_pipeline') is TJSONObject) then
      Exit;
    St := J.GetValue<string>('head_pipeline.status', '');
    if St = 'failed' then
      AItem.CiState := 'FAILURE'
    else if St = 'success' then
      AItem.CiState := 'SUCCESS'
    else if St <> '' then
      AItem.CiState := 'PENDING';
    if AItem.CiState = 'FAILURE' then
      AItem.CiUrl := J.GetValue<string>('head_pipeline.web_url', '');
  finally
    J.Free;
  end;
end;

{ To-dos pendentes: menção, review pedido, associação. Fazem o papel das
  notifications do GitHub (UnreadReason). }
procedure GitLabTodos(const AAccount: TAccount; const AToken: string; var AItems: TItems);
var
  J: TJSONValue;
  Arr: TJSONArray;
  I, K: Integer;
  Action, Key: string;
  It: TItem;
  Found: Boolean;
begin
  J := GetJson(AAccount, AToken, '/api/v4/todos?state=pending&per_page=100');
  try
    if not (J is TJSONArray) then
      Exit;
    Arr := TJSONArray(J);
    for I := 0 to Arr.Count - 1 do
    begin
      if not (Arr.Items[I].FindValue('target') is TJSONObject) then
        Continue;
      Action := Arr.Items[I].GetValue<string>('action_name', '');
      Key := Arr.Items[I].GetValue<string>('target.references.full', '');
      if Key = '' then
        Continue;
      Found := False;
      for K := 0 to High(AItems) do
        if SameText(AItems[K].Key, Key) then
        begin
          Found := True;
          if MatchText(Action, ['mentioned', 'directly_addressed']) then
          begin
            AItems[K].UnreadReason := 'mention';
            AItems[K].MentionsMe := True;
          end
          else if AItems[K].UnreadReason = '' then
            AItems[K].UnreadReason := Action;
        end;
      // Menção numa issue que não é minha nem observada: entra pela menção.
      if not Found and AAccount.Mentions and MatchText(Action, ['mentioned', 'directly_addressed']) and
        (Arr.Items[I].GetValue<string>('target.state', '') = 'opened') then
      begin
        It := ParseGitLabItem(Arr.Items[I].FindValue('target') as TJSONObject, AAccount.Id,
          Arr.Items[I].GetValue<string>('target_type', '') = 'MergeRequest');
        Include(It.Sources, isMention);
        It.UnreadReason := 'mention';
        It.MentionsMe := True;
        Merge(AItems, It);
      end;
    end;
  finally
    J.Free;
  end;
end;

function FetchGitLab(const AAccount: TAccount; const AToken: string;
  const AManualKeys: TArray<string>; out AMe: TIdentity): TItems;
var
  NumId, K: string;
  I: Integer;
  J: TJSONValue;
  It: TItem;
  Proj, Num: string;
  IsMR: Boolean;
begin
  Result := nil;
  AMe := GitLabMe(AAccount, AToken, NumId);
  GitLabList(AAccount, AToken, '/api/v4/issues?scope=assigned_to_me&state=opened', False, isAssigned, Result);
  GitLabList(AAccount, AToken, '/api/v4/merge_requests?scope=all&state=opened&reviewer_username=' +
    Enc(AMe.Id), True, isReview, Result);
  if AAccount.MyPrs then
  begin
    GitLabList(AAccount, AToken, '/api/v4/merge_requests?scope=created_by_me&state=opened', True, isMine, Result);
    for I := 0 to High(Result) do
      if isMine in Result[I].Sources then
        try
          GitLabMrPipeline(AAccount, AToken, Result[I]);
        except
          on E: Exception do
            OutputDebugString(PChar('Devbox issues: pipeline do MR (' + E.Message + ')'));
        end;
  end;
  // Busca extra: parâmetros da API de issues, ex.: labels=bug&milestone=Sprint 5.
  if AAccount.ExtraQuery.Trim <> '' then
    GitLabList(AAccount, AToken, '/api/v4/issues?scope=all&state=opened&' + AAccount.ExtraQuery.Trim,
      False, isQuery, Result);
  for K in AManualKeys do
    if GitLabSplit(K, Proj, Num, IsMR) then
      try
        J := GetJson(AAccount, AToken, GitLabItemPath(K));
        try
          It := ParseGitLabItem(J as TJSONObject, AAccount.Id, IsMR);
          Include(It.Sources, isWatching);
          Merge(Result, It);
        finally
          J.Free;
        end;
      except
        on E: Exception do
          OutputDebugString(PChar('Devbox issues: manual ' + K + ' (' + E.Message + ')'));
      end;
  try
    GitLabTodos(AAccount, AToken, Result);
  except
    on E: Exception do
      OutputDebugString(PChar('Devbox issues: todos do GitLab (' + E.Message + ')'));
  end;
end;

function GitLabComments(const AAccount: TAccount; const AToken, AKey: string; AMax: Integer): TComments;
var
  J: TJSONValue;
  Arr: TJSONArray;
  I: Integer;
  C: TComment;
begin
  Result := nil;
  J := GetJson(AAccount, AToken, GitLabItemPath(AKey) +
    Format('/notes?sort=desc&order_by=created_at&per_page=%d', [AMax * 2]));
  try
    Arr := J as TJSONArray;
    // Veio do mais novo para o mais antigo; notas de sistema ("mudou o label") ficam fora.
    for I := Arr.Count - 1 downto 0 do
    begin
      if Arr.Items[I].GetValue<Boolean>('system', False) then
        Continue;
      C.Author := Arr.Items[I].GetValue<string>('author.name', '');
      C.AuthorId := Arr.Items[I].GetValue<string>('author.username', '');
      C.At := ParseIsoDate(Arr.Items[I].GetValue<string>('created_at', ''));
      C.Text := MarkdownToText(Arr.Items[I].GetValue<string>('body', ''));
      Result := Result + [C];
    end;
  finally
    J.Free;
  end;
  if Length(Result) > AMax then
    Result := Copy(Result, Length(Result) - AMax, AMax);
end;

function GitLabTitle(const AAccount: TAccount; const AToken, AKey: string): string;
var
  J: TJSONValue;
begin
  J := GetJson(AAccount, AToken, GitLabItemPath(AKey));
  try
    Result := J.GetValue<string>('title', '');
  finally
    J.Free;
  end;
end;

function GitLabDescription(const AAccount: TAccount; const AToken, AKey: string): string;
var
  J: TJSONValue;
begin
  J := GetJson(AAccount, AToken, GitLabItemPath(AKey));
  try
    Result := MarkdownToText(J.GetValue<string>('description', ''));
  finally
    J.Free;
  end;
end;

function GitLabCreate(const AAccount: TAccount; const AToken, AProject, ATitle, ABody: string): string;
var
  Body: TJSONObject;
  R: TJSONValue;
begin
  Body := TJSONObject.Create;
  try
    Body.AddPair('title', ATitle);
    Body.AddPair('description', ABody);
    R := TJSONObject.ParseJSONValue(SendJsonRead(AAccount, AToken, 'POST',
      '/api/v4/projects/' + Enc(AProject.Trim) + '/issues', Body.ToJSON));
    try
      Result := R.GetValue<string>('references.full', '');
    finally
      R.Free;
    end;
  finally
    Body.Free;
  end;
end;

{ Tempo gasto: o GitLab aceita '1h30m'. }
procedure GitLabAddSpent(const AAccount: TAccount; const AToken, AKey: string; AHours: Double);
var
  Mins: Integer;
begin
  Mins := Round(AHours * 60);
  SendJson(AAccount, AToken, 'POST', GitLabItemPath(AKey) + '/add_spent_time',
    Format('{"duration":"%dh%dm"}', [Mins div 60, Mins mod 60]));
end;

procedure GitLabAssignToMe(const AAccount: TAccount; const AToken, AKey: string);
var
  NumId: string;
begin
  GitLabMe(AAccount, AToken, NumId);
  SendJson(AAccount, AToken, 'PUT', GitLabItemPath(AKey), Format('{"assignee_ids":[%s]}', [NumId]));
end;
