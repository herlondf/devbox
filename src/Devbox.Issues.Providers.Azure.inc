{ ── Azure DevOps (Boards, API 7.1) ────────────────────────────────────────
  Incluído em Devbox.Issues.Providers. BaseUrl = https://dev.azure.com/<organização>.
  Chave: 'Projeto#123' (o id do work item é único na organização).
  ponytail: formato das respostas pela documentação; sem organização de teste
  aqui, o caminho real ainda não foi exercitado. }

const
  AzureApi = 'api-version=7.1';
  AzureCommentsApi = 'api-version=7.1-preview.4';
  AzureFields = 'System.Id,System.Title,System.State,System.TeamProject,System.AssignedTo,' +
    'System.ChangedDate,System.CommentCount,System.WorkItemType,System.Tags,' +
    'Microsoft.VSTS.Scheduling.DueDate,Microsoft.VSTS.Scheduling.TargetDate';
  AzureDoneStates: array[0..5] of string = ('Done', 'Closed', 'Removed', 'Resolved', 'Completed', 'Concluído');
  AzureNewStates: array[0..4] of string = ('New', 'To Do', 'Proposed', 'Approved', 'Novo');

{ Campo do Azure pelo nome exato: 'System.Title' tem ponto, e o GetValue<T>
  do Delphi leria o ponto como caminho. }
function AzVal(AFields: TJSONValue; const AName: string): TJSONValue;
begin
  Result := nil;
  if AFields is TJSONObject then
    Result := TJSONObject(AFields).GetValue(AName);
end;

function AzStr(AFields: TJSONValue; const AName: string): string;
var
  V: TJSONValue;
begin
  V := AzVal(AFields, AName);
  if (V = nil) or (V is TJSONNull) then
    Result := ''
  else
    Result := V.Value;
end;

function AzureSplit(const AKey: string; out AProject: string; out AId: Integer): Boolean;
var
  M: TMatch;
begin
  M := TRegEx.Match(AKey.Trim, '^([^/#]+)#(\d+)$');
  Result := M.Success;
  if Result then
  begin
    AProject := M.Groups[1].Value.Trim;
    AId := StrToInt(M.Groups[2].Value);
  end;
end;

function AzureId(const AKey: string): Integer;
var
  Proj: string;
begin
  if not AzureSplit(AKey, Proj, Result) then
    raise Exception.Create('Chave Azure inválida: ' + AKey + ' (use Projeto#123)');
end;

function AzureMe(const AAccount: TAccount; const AToken: string): TIdentity;
var
  J: TJSONValue;
begin
  J := GetJson(AAccount, AToken, '/_apis/connectionData?api-version=7.1-preview');
  try
    Result.DisplayName := J.GetValue<string>('authenticatedUser.providerDisplayName', '');
    // uniqueName (e-mail) é o que o System.AssignedTo aceita.
    Result.Id := J.GetValue<string>('authenticatedUser.properties.Account.$value', '');
    if Result.Id = '' then
      Result.Id := J.GetValue<string>('authenticatedUser.id', '');
  finally
    J.Free;
  end;
end;

function ParseAzureItem(AJson: TJSONObject; const AAccount: TAccount; const AMe: TIdentity): TItem;
var
  F: TJSONValue;
  Proj, Due, Tags: string;
begin
  Result := Default(TItem);
  Result.AccountId := AAccount.Id;
  F := AJson.FindValue('fields');
  if F = nil then
    Exit;
  Proj := AzStr(F, 'System.TeamProject');
  Result.Key := Proj + '#' + AJson.GetValue<string>('id', '');
  Result.Title := AzStr(F, 'System.Title');
  Result.Url := TrimSlash(AAccount.BaseUrl) + '/' + Enc(Proj) + '/_workitems/edit/' +
    AJson.GetValue<string>('id', '');
  Result.Status := AzStr(F, 'System.State');
  if MatchText(Result.Status, AzureDoneStates) then
    Result.StatusCategory := 'done'
  else if MatchText(Result.Status, AzureNewStates) then
    Result.StatusCategory := 'new'
  else
    Result.StatusCategory := 'indeterminate';
  if AzVal(F, 'System.AssignedTo') is TJSONObject then
  begin
    Result.Assignee := AzVal(F, 'System.AssignedTo').GetValue<string>('displayName', '');
    if SameText(AzVal(F, 'System.AssignedTo').GetValue<string>('uniqueName', ''), AMe.Id) then
      Include(Result.Sources, isAssigned);
  end;
  // Prazo: campo da conta (nome de referência, ex.: Custom.Prazo); senão DueDate ou TargetDate.
  Due := '';
  if AAccount.DueField.Trim <> '' then
    Due := AzStr(F, AAccount.DueField.Trim)
  else
  begin
    Due := AzStr(F, 'Microsoft.VSTS.Scheduling.DueDate');
    if Due = '' then
      Due := AzStr(F, 'Microsoft.VSTS.Scheduling.TargetDate');
  end;
  if Due <> '' then
    Result.DueDate := DateOf(ParseIsoDate(Due));
  Result.UpdatedAt := ParseIsoDate(AzStr(F, 'System.ChangedDate'));
  Result.CommentCount := StrToIntDef(AzStr(F, 'System.CommentCount'), 0);
  Tags := AzStr(F, 'System.Tags');
  // Tag "Blocked" (ou "Impedimento") faz o papel do Flagged do Jira.
  Result.Flagged := MatchText('Blocked', Tags.Replace(' ', '').Split([';'])) or
    ContainsText(Tags, 'Impedimento');
end;

{ WIQL -> ids -> workitemsbatch (até 200 por chamada). }
procedure AzureQuery(const AAccount: TAccount; const AToken: string; const AMe: TIdentity;
  const AWhere: string; ASource: TItemSource; var AItems: TItems);
const
  CBatch = 200;
  CMax = 600;
var
  Body: TJSONObject;
  R: TJSONValue;
  Arr: TJSONArray;
  Ids: TArray<Integer>;
  I, J: Integer;
  Part: string;
  It: TItem;
begin
  Body := TJSONObject.Create;
  try
    Body.AddPair('query', 'SELECT [System.Id] FROM WorkItems WHERE ' + AWhere +
      ' ORDER BY [System.ChangedDate] DESC');
    R := TJSONObject.ParseJSONValue(SendJsonRead(AAccount, AToken, 'POST', '/_apis/wit/wiql?' + AzureApi,
      Body.ToJSON));
  finally
    Body.Free;
  end;
  try
    Ids := nil;
    if R.TryGetValue<TJSONArray>('workItems', Arr) then
      for I := 0 to Min(Arr.Count, CMax) - 1 do
        Ids := Ids + [Arr.Items[I].GetValue<Integer>('id', 0)];
  finally
    R.Free;
  end;
  I := 0;
  while I <= High(Ids) do
  begin
    Part := '';
    for J := I to Min(I + CBatch, Length(Ids)) - 1 do
      Part := Part + IfThen(Part <> '', ',') + IntToStr(Ids[J]);
    R := TJSONObject.ParseJSONValue(SendJsonRead(AAccount, AToken, 'POST',
      '/_apis/wit/workitemsbatch?' + AzureApi,
      Format('{"ids":[%s],"fields":["%s"]}', [Part, string.Join('","', AzureFields.Split([',']))])));
    try
      if R.TryGetValue<TJSONArray>('value', Arr) then
        for J := 0 to Arr.Count - 1 do
        begin
          It := ParseAzureItem(Arr.Items[J] as TJSONObject, AAccount, AMe);
          if It.Key = '' then
            Continue;
          Include(It.Sources, ASource);
          Merge(AItems, It);
        end;
    finally
      R.Free;
    end;
    Inc(I, CBatch);
  end;
end;

{ Último comentário (autor e texto) só das que mudaram nas últimas 24 h:
  é o que o aviso de comentário precisa, sem uma chamada por item. }
procedure AzureLastComments(const AAccount: TAccount; const AToken: string; const AMe: TIdentity;
  var AItems: TItems);
var
  I: Integer;
  Proj: string;
  Id: Integer;
  J: TJSONValue;
  Arr: TJSONArray;
  Html: string;
begin
  for I := 0 to High(AItems) do
  begin
    if (AItems[I].CommentCount = 0) or (AItems[I].UpdatedAt < TTimeZone.Local.ToUniversalTime(Now) - 1) or
      not AzureSplit(AItems[I].Key, Proj, Id) then
      Continue;
    try
      J := GetJson(AAccount, AToken, Format('/%s/_apis/wit/workItems/%d/comments?$top=1&order=desc&%s',
        [Enc(Proj), Id, AzureCommentsApi]));
      try
        if J.TryGetValue<TJSONArray>('comments', Arr) and (Arr.Count > 0) then
        begin
          AItems[I].LastCommentBy := Arr.Items[0].GetValue<string>('createdBy.uniqueName', '');
          Html := Arr.Items[0].GetValue<string>('text', '');
          AItems[I].LastCommentText := CleanCommentText(Html);
          // Menção do Azure vem como <a href="#" data-vss-mention="version:2.0,<id>">@Nome</a>.
          AItems[I].MentionsMe := ContainsText(Html, 'data-vss-mention') and
            ContainsText(AItems[I].LastCommentText, '@' + AMe.DisplayName);
        end;
      finally
        J.Free;
      end;
    except
      on E: Exception do
        OutputDebugString(PChar('Devbox issues: comentário Azure ' + AItems[I].Key + ' (' + E.Message + ')'));
    end;
  end;
end;

function FetchAzure(const AAccount: TAccount; const AToken: string;
  const AManualKeys: TArray<string>; out AMe: TIdentity): TItems;
const
  Open = '[System.State] NOT IN (''Done'', ''Closed'', ''Removed'', ''Resolved'', ''Completed'')';
var
  K, Ids, Proj: string;
  Id: Integer;
begin
  Result := nil;
  AMe := AzureMe(AAccount, AToken);
  AzureQuery(AAccount, AToken, AMe, '[System.AssignedTo] = @Me AND ' + Open, isAssigned, Result);
  AzureQuery(AAccount, AToken, AMe, '[System.Id] IN (@Follows) AND ' + Open, isWatching, Result);
  if AAccount.Mentions then
    AzureQuery(AAccount, AToken, AMe, '[System.Id] IN (@RecentMentions) AND ' + Open, isMention, Result);
  // Busca extra: um pedaço de WIQL, ex.: [System.AreaPath] UNDER 'App\Pagamentos'.
  if AAccount.ExtraQuery.Trim <> '' then
    AzureQuery(AAccount, AToken, AMe, '(' + AAccount.ExtraQuery.Trim + ') AND ' + Open, isQuery, Result);
  Ids := '';
  for K in AManualKeys do
    if AzureSplit(K, Proj, Id) then
      Ids := Ids + IfThen(Ids <> '', ',') + IntToStr(Id);
  if Ids <> '' then
    AzureQuery(AAccount, AToken, AMe, '[System.Id] IN (' + Ids + ')', isWatching, Result);
  AzureLastComments(AAccount, AToken, AMe, Result);
end;

function AzureComments(const AAccount: TAccount; const AToken, AKey: string; AMax: Integer): TComments;
var
  Proj: string;
  Id, I: Integer;
  J: TJSONValue;
  Arr: TJSONArray;
  C: TComment;
begin
  Result := nil;
  if not AzureSplit(AKey, Proj, Id) then
    raise Exception.Create('Chave Azure inválida: ' + AKey);
  J := GetJson(AAccount, AToken, Format('/%s/_apis/wit/workItems/%d/comments?$top=%d&order=desc&%s',
    [Enc(Proj), Id, AMax, AzureCommentsApi]));
  try
    if not J.TryGetValue<TJSONArray>('comments', Arr) then
      Exit;
    for I := Arr.Count - 1 downto 0 do
    begin
      C.Author := Arr.Items[I].GetValue<string>('createdBy.displayName', '');
      C.AuthorId := Arr.Items[I].GetValue<string>('createdBy.uniqueName', '');
      C.At := ParseIsoDate(Arr.Items[I].GetValue<string>('createdDate', ''));
      C.Text := CleanCommentText(Arr.Items[I].GetValue<string>('text', ''));
      Result := Result + [C];
    end;
  finally
    J.Free;
  end;
end;

procedure AzurePostComment(const AAccount: TAccount; const AToken, AKey, AText: string);
var
  Proj: string;
  Id: Integer;
begin
  if not AzureSplit(AKey, Proj, Id) then
    raise Exception.Create('Chave Azure inválida: ' + AKey);
  SendJson(AAccount, AToken, 'POST', Format('/%s/_apis/wit/workItems/%d/comments?%s',
    [Enc(Proj), Id, AzureCommentsApi]), Format('{"text":%s}', [TJSONString.Create(AText).ToJSON]));
end;

{ Muda campos por JSON Patch (o SendJsonRead manda o content-type certo no Azure). }
procedure AzurePatch(const AAccount: TAccount; const AToken: string; AId: Integer;
  const AField, AValue: string);
begin
  SendJson(AAccount, AToken, 'PATCH', Format('/_apis/wit/workitems/%d?%s', [AId, AzureApi]),
    Format('[{"op":"add","path":"/fields/%s","value":%s}]', [AField, TJSONString.Create(AValue).ToJSON]));
end;

function AzureFieldsOf(const AAccount: TAccount; const AToken: string; AId: Integer): TJSONValue;
begin
  Result := GetJson(AAccount, AToken, Format('/_apis/wit/workitems/%d?%s', [AId, AzureApi]));
end;

{ Estados do tipo do work item, menos o atual. }
function AzureTransitions(const AAccount: TAccount; const AToken, AKey: string): TTransitions;
var
  J, S: TJSONValue;
  Arr: TJSONArray;
  Proj, WType, Cur: string;
  Id, I: Integer;
  T: TTransition;
begin
  Result := nil;
  if not AzureSplit(AKey, Proj, Id) then
    raise Exception.Create('Chave Azure inválida: ' + AKey);
  J := AzureFieldsOf(AAccount, AToken, Id);
  try
    WType := AzStr(J.FindValue('fields'), 'System.WorkItemType');
    Cur := AzStr(J.FindValue('fields'), 'System.State');
  finally
    J.Free;
  end;
  S := GetJson(AAccount, AToken, Format('/%s/_apis/wit/workitemtypes/%s/states?%s',
    [Enc(Proj), Enc(WType), AzureApi]));
  try
    if S.TryGetValue<TJSONArray>('value', Arr) then
      for I := 0 to Arr.Count - 1 do
      begin
        T := Default(TTransition);
        T.Name := Arr.Items[I].GetValue<string>('name', '');
        T.Id := T.Name;
        T.ToStatus := T.Name;
        if (T.Name <> '') and not SameText(T.Name, Cur) then
          Result := Result + [T];
      end;
  finally
    S.Free;
  end;
end;

procedure AzureAddTag(const AAccount: TAccount; const AToken, AKey, ATag: string);
var
  Id: Integer;
  J: TJSONValue;
  Tags: string;
begin
  Id := AzureId(AKey);
  J := AzureFieldsOf(AAccount, AToken, Id);
  try
    Tags := AzStr(J.FindValue('fields'), 'System.Tags');
  finally
    J.Free;
  end;
  AzurePatch(AAccount, AToken, Id, 'System.Tags', IfThen(Tags <> '', Tags + '; ', '') + ATag.Trim);
end;

function AzureCreate(const AAccount: TAccount; const AToken, AProject, ATitle, ABody: string): string;
var
  R: TJSONValue;
begin
  R := TJSONObject.ParseJSONValue(SendJsonRead(AAccount, AToken, 'POST',
    Format('/%s/_apis/wit/workitems/$Task?%s', [Enc(AProject.Trim), AzureApi]),
    Format('[{"op":"add","path":"/fields/System.Title","value":%s},' +
      '{"op":"add","path":"/fields/System.Description","value":%s}]',
      [TJSONString.Create(ATitle).ToJSON, TJSONString.Create(ABody).ToJSON])));
  try
    Result := AProject.Trim + '#' + R.GetValue<string>('id', '');
  finally
    R.Free;
  end;
end;

function AzureTitleAndDescription(const AAccount: TAccount; const AToken, AKey: string;
  out ADescription: string): string;
var
  J: TJSONValue;
begin
  J := AzureFieldsOf(AAccount, AToken, AzureId(AKey));
  try
    Result := AzStr(J.FindValue('fields'), 'System.Title');
    ADescription := CleanCommentText(AzStr(J.FindValue('fields'), 'System.Description'));
  finally
    J.Free;
  end;
end;
