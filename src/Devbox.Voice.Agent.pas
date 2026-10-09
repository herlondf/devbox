unit Devbox.Voice.Agent;

{ O que fazer com um pedido falado (já em texto). A IA classifica o pedido
  numa ação; o Devbox busca os dados e monta a fala. Agenda e próxima reunião
  saem daqui mesmo (rápido); e-mails a IA resume para ser falado.
  RunVoiceCommand bloqueia: fora da thread de UI (sem banco: o contexto vem
  pronto da thread de UI). }

interface

uses
  System.SysUtils,
  Devbox.AI,
  Devbox.Google,
  Devbox.MailSource,
  Devbox.Issues.Model,
  Devbox.Realtime;

type
  TVoiceAction = (vaConversa, vaEmails, vaAgenda, vaReuniao, vaFocoLigar, vaFocoDesligar, vaAbrir, vaEncerrar,
    vaIssues);

  TVoiceContext = record
    Config: TAIConfig;
    Accounts: TMailAccounts;
    Today: TCalEvents;          // eventos de hoje, em ordem
    Upcoming: TCalEvents;       // de 7 dias atrás a 31 à frente (amanhã, próxima reunião)
    Issues: TItems;             // issues abertas das contas ligadas (o retrato do último poll)
    Now: TDateTime;
  end;

  TVoiceReply = record
    Action: TVoiceAction;
    Page: string;      // vaAbrir: 'home', 'issues', 'mail', 'agenda', 'clipboard'...
    Day: TDateTime;    // vaAgenda: o dia pedido (0 = hoje)
    Speech: string;    // o que falar
  end;

function RunVoiceCommand(const AText: string; const ACtx: TVoiceContext; out AReply: TVoiceReply;
  out AError: string): Boolean;

{ Conversa ao vivo (OpenAI Realtime, Gemini Live): instruções e ferramentas do Devbox. }
function RealtimeInstructions: string;
function RealtimeTools: TArray<TRealtimeTool>;
{ Roda a ferramenta que a IA pediu. Bloqueia (e-mails vão à rede): fora da thread de UI.
  Devolve o JSON do resultado; AReply.Action diz o que a tela faz (foco, abrir, encerrar). }
function RunRealtimeTool(const AName, AArgs: string; const ACtx: TVoiceContext; out AReply: TVoiceReply): string;

// Partes puras (self-check)
function ParseVoiceIntent(const AAnswer: string; out AReply: TVoiceReply): Boolean;
function AgendaSpeech(const AEvents: TCalEvents; const ADayLabel: string = 'Hoje'): string;
{ Eventos que caem no dia (os de dia todo que cobrem o dia também). }
function EventsOn(const AEvents: TCalEvents; ADay: TDateTime): TCalEvents;
{ "hoje", "amanha" ou AAAA-MM-DD; 0 se não entendeu. }
function ParseVoiceDay(const AText: string; AToday: TDateTime): TDateTime;
function NextMeetingSpeech(const AEvents: TCalEvents; ANow: TDateTime): string;
function SpokenTime(ATime: TDateTime): string;

implementation

uses
  System.JSON,
  System.Classes,
  System.StrUtils,
  System.DateUtils,
  System.Math;

const
  CIntentTokens = 400;
  CSummaryTokens = 500;
  CActionNames: array[TVoiceAction] of string = ('conversa', 'emails', 'agenda', 'reuniao', 'foco_ligar',
    'foco_desligar', 'abrir', 'encerrar', 'issues');
  CWeekDays: array[1..7] of string = ('domingo', 'segunda-feira', 'terça-feira', 'quarta-feira', 'quinta-feira',
    'sexta-feira', 'sábado');
  CMaxToolIssues = 25;
  CPages = '"home","issues","mail","agenda","focus","pomodoro","clipboard","tools","services","cleanup",' +
    '"network","system","jobs","settings","ai"';
  CRealtimeInstructions = 'Você é o assistente de voz do Devbox, no computador de um desenvolvedor. Fale português ' +
    'do Brasil, curto e natural, como numa conversa: no máximo 2 ou 3 frases por vez, sem listas nem símbolos. ' +
    'Use as ferramentas para e-mails, agenda (de qualquer dia), reuniões, issues e tarefas (GitHub, Jira), modo foco ' +
    'e para abrir telas do Devbox; não invente dados. ' +
    'Ao ler e-mails, diga quem mandou e o que pede, do mais urgente para o menos. Quando o usuário se despedir ou ' +
    'pedir para parar, diga tchau em poucas palavras e chame encerrar_conversa.';
  CNoParams = '{"type":"object","properties":{}}';
  CMaxToolMails = 15;
  CIntentSystem = 'Você é o assistente de voz do Devbox, de um desenvolvedor no Windows. O pedido veio de fala ' +
    'transcrita (pode ter erros). Escolha UMA ação: "emails" (resumir ou ler e-mails), ' +
    '"agenda" (compromissos de um dia; em "dia": "hoje", "amanha" ou AAAA-MM-DD), "reuniao" (próxima reunião), ' +
    '"issues" (perguntas sobre issues, tarefas, PRs, prazos do GitHub ou Jira), "foco_ligar", "foco_desligar", ' +
    '"abrir" (abrir uma tela: home, issues, email, agenda, focus, pomodoro, clipboard, tools, services, cleanup, ' +
    'network, system, jobs, settings, ai) ou "conversa" (qualquer outra coisa: responda você mesmo em "fala", em ' +
    'português, no máximo 2 frases curtas, sem markdown). Responda SÓ com JSON: ' +
    '{"acao":"...","tela":"...","dia":"...","fala":"..."}';
  CIssuesSystem = 'Responda o pedido para ser FALADO em voz alta, em português do Brasil, usando só a lista de ' +
    'issues abaixo: no máximo 4 frases curtas, sem listas, sem símbolos, sem markdown, sem links. Diga a chave só ' +
    'quando ajudar. Se a lista não responde, diga isso em uma frase.';
  CSummarySystem = 'Resuma para ser FALADO em voz alta, em português do Brasil: no máximo 4 frases curtas, sem ' +
    'listas, sem símbolos, sem markdown, sem endereços de e-mail. Diga quem mandou e o que pede, começando pelo ' +
    'mais urgente. Se não houver nada importante, diga isso em uma frase.';

function SpokenTime(ATime: TDateTime): string;
var
  LHour, LMin, LSec, LMs: Word;
begin
  DecodeTime(ATime, LHour, LMin, LSec, LMs);
  if LMin = 0 then
    Result := Format('%d horas', [LHour])
  else
    Result := Format('%d e %d', [LHour, LMin]);
end;

function EventsOn(const AEvents: TCalEvents; ADay: TDateTime): TCalEvents;
var
  LEvent: TCalEvent;
begin
  Result := nil;
  ADay := Trunc(ADay);
  for LEvent in AEvents do
    if (Trunc(LEvent.Start) = ADay) or (LEvent.AllDay and (LEvent.Start <= ADay) and (LEvent.Finish > ADay)) then
      Result := Result + [LEvent];
end;

function ParseVoiceDay(const AText: string; AToday: TDateTime): TDateTime;
var
  LText: string;
  LYear, LMonth, LDay: Integer;
begin
  Result := 0;
  LText := LowerCase(Trim(AText));
  if (LText = '') or (LText = 'hoje') then
    Exit(Trunc(AToday));
  if (LText = 'amanha') or (LText = 'amanhã') then
    Exit(Trunc(AToday) + 1);
  if (Length(LText) = 10) and TryStrToInt(Copy(LText, 1, 4), LYear) and TryStrToInt(Copy(LText, 6, 2), LMonth) and
    TryStrToInt(Copy(LText, 9, 2), LDay) and IsValidDate(LYear, LMonth, LDay) then
    Result := EncodeDate(LYear, LMonth, LDay);
end;

function AgendaSpeech(const AEvents: TCalEvents; const ADayLabel: string): string;
var
  LEvent: TCalEvent;
  LParts: TArray<string>;
begin
  if AEvents = nil then
    Exit(Format('%s você não tem compromissos.', [ADayLabel]));
  LParts := nil;
  for LEvent in AEvents do
    if LEvent.AllDay then
      LParts := LParts + ['o dia todo, ' + LEvent.Title]
    else
      LParts := LParts + ['às ' + SpokenTime(LEvent.Start) + ', ' + LEvent.Title];
  if Length(AEvents) = 1 then
    Result := ADayLabel + ' você tem um compromisso: ' + LParts[0] + '.'
  else
    Result := Format('%s você tem %d compromissos: %s.', [ADayLabel, Length(AEvents), string.Join('; ', LParts)]);
end;

function NextMeetingSpeech(const AEvents: TCalEvents; ANow: TDateTime): string;
var
  LEvent, LBest: TCalEvent;
  LFound: Boolean;
  LMins: Int64;
begin
  LFound := False;
  for LEvent in AEvents do
    if not LEvent.AllDay and (LEvent.Finish > ANow) and (not LFound or (LEvent.Start < LBest.Start)) then
    begin
      LBest := LEvent;
      LFound := True;
    end;
  if not LFound then
    Exit('Você não tem reuniões pela frente.');
  if LBest.Start <= ANow then
    Exit(Format('Você está em %s agora, até %s.', [LBest.Title, SpokenTime(LBest.Finish)]));
  LMins := MinutesBetween(ANow, LBest.Start) + 1;
  if Trunc(LBest.Start) = Trunc(ANow) then
    Result := Format('Sua próxima reunião é %s, às %s, daqui a %d minutos.', [LBest.Title, SpokenTime(LBest.Start),
      LMins])
  else
    Result := Format('Sua próxima reunião é %s, %s às %s.', [LBest.Title, FormatDateTime('dd/mm', LBest.Start),
      SpokenTime(LBest.Start)]);
  if LBest.MeetUrl <> '' then
    Result := Result + ' Tem link do Meet na agenda.';
end;

function RealtimeInstructions: string;
begin
  // A data entra aqui: "amanhã" e "sexta" viram AAAA-MM-DD do lado da IA.
  Result := CRealtimeInstructions + Format(' Hoje é %s, %s.', [CWeekDays[DayOfWeek(Date)],
    FormatDateTime('yyyy-mm-dd', Date)]);
end;

function Tool(const AName, ADescription, AParams: string): TRealtimeTool;
begin
  Result.Name := AName;
  Result.Description := ADescription;
  Result.Params := AParams;
end;

function RealtimeTools: TArray<TRealtimeTool>;
begin
  Result := [
    Tool('emails_importantes', 'E-mails importantes não lidos de todas as contas ligadas no Devbox (remetente, ' +
      'assunto, trecho).', CNoParams),
    Tool('agenda_hoje', 'Compromissos de hoje, em ordem (hora, título, se tem link do Meet).', CNoParams),
    Tool('agenda_do_dia', 'Compromissos de um dia (até 31 dias à frente ou 7 para trás), em ordem.',
      '{"type":"object","properties":{"data":{"type":"string","description":"AAAA-MM-DD"}},"required":["data"]}'),
    Tool('minhas_issues', 'Issues e PRs abertos do usuário no GitHub e no Jira (chave, título, status, prazo, ' +
      'impedimento). Filtro: todas, vencendo (prazo nos próximos 7 dias), atrasadas, impedidas ou mencionado.',
      '{"type":"object","properties":{"filtro":{"type":"string","enum":["todas","vencendo","atrasadas",' +
      '"impedidas","mencionado"]}}}'),
    Tool('issue', 'Detalhe de uma issue pela chave (ex.: PROJ-12 ou dono/repo#3): status, prazo, último comentário.',
      '{"type":"object","properties":{"chave":{"type":"string"}},"required":["chave"]}'),
    Tool('proxima_reuniao', 'A próxima reunião que ainda não acabou.', CNoParams),
    Tool('modo_foco', 'Liga ou desliga o modo foco do Devbox (silencia avisos).',
      '{"type":"object","properties":{"ligar":{"type":"boolean"}},"required":["ligar"]}'),
    Tool('abrir_tela', 'Abre uma tela do Devbox na frente do usuário.',
      '{"type":"object","properties":{"tela":{"type":"string","enum":[' + CPages + ']}},"required":["tela"]}'),
    Tool('encerrar_conversa', 'Termina a conversa por voz (depois da despedida).', CNoParams)];
end;

function EventJson(const AEvent: TCalEvent): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('titulo', AEvent.Title);
  if AEvent.AllDay then
    Result.AddPair('hora', 'dia todo')
  else
  begin
    Result.AddPair('inicio', FormatDateTime('dd/mm hh:nn', AEvent.Start));
    Result.AddPair('fim', FormatDateTime('hh:nn', AEvent.Finish));
  end;
  Result.AddPair('tem_meet', TJSONBool.Create(AEvent.MeetUrl <> ''));
end;

function IssueJson(const AItem: TItem; ADetail: Boolean): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('chave', AItem.Key);
  Result.AddPair('titulo', AItem.Title);
  Result.AddPair('status', AItem.Status);
  if AItem.DueDate > 0 then
    Result.AddPair('prazo', FormatDateTime('yyyy-mm-dd', AItem.DueDate));
  if AItem.Flagged then
    Result.AddPair('impedida', TJSONBool.Create(True));
  if AItem.Assignee <> '' then
    Result.AddPair('responsavel', AItem.Assignee);
  if ADetail then
  begin
    Result.AddPair('comentarios', TJSONNumber.Create(AItem.CommentCount));
    if AItem.LastCommentText <> '' then
      Result.AddPair('ultimo_comentario', AItem.LastCommentBy + ': ' + Copy(AItem.LastCommentText, 1, 600));
    if AItem.CiState <> '' then
      Result.AddPair('ci', AItem.CiState);
    if AItem.ReviewState <> '' then
      Result.AddPair('review', AItem.ReviewState);
  end;
end;

function IssuesFiltered(const AItems: TItems; const AFilter: string; ANow: TDateTime): TItems;
var
  LItem: TItem;
  LTake: Boolean;
begin
  Result := nil;
  for LItem in AItems do
  begin
    if AFilter = 'vencendo' then
      LTake := (LItem.DueDate > 0) and (Trunc(LItem.DueDate) >= Trunc(ANow)) and (LItem.DueDate < Trunc(ANow) + 8)
    else if AFilter = 'atrasadas' then
      LTake := (LItem.DueDate > 0) and (Trunc(LItem.DueDate) < Trunc(ANow))
    else if AFilter = 'impedidas' then
      LTake := LItem.Flagged
    else if AFilter = 'mencionado' then
      LTake := LItem.MentionsMe
    else
      LTake := True;
    if LTake then
      Result := Result + [LItem];
  end;
end;

function IssuesJson(const AItems: TItems): TJSONArray;
var
  LItem: TItem;
begin
  Result := TJSONArray.Create;
  for LItem in Copy(AItems, 0, CMaxToolIssues) do
    Result.AddElement(IssueJson(LItem, False));
end;

function RunRealtimeTool(const AName, AArgs: string; const ACtx: TVoiceContext; out AReply: TVoiceReply): string;
var
  LDay: TDateTime;
  LItem: TItem;
  LItems: TItems;
  LResult: TJSONObject;
  LList: TJSONArray;
  LArgs: TJSONValue;
  LEvent, LBest: TCalEvent;
  LFound: Boolean;
  LAccount: TMailAccount;
  LMsgs, LOne: TMailMsgs;
  LMsg: TMailMsg;
  LErr: string;
begin
  AReply := Default(TVoiceReply);
  AReply.Action := vaConversa;
  LResult := TJSONObject.Create;
  LArgs := TJSONObject.ParseJSONValue(AArgs);
  try
    if AName = 'agenda_hoje' then
    begin
      LList := TJSONArray.Create;
      for LEvent in ACtx.Today do
        LList.AddElement(EventJson(LEvent));
      LResult.AddPair('compromissos', LList);
    end
    else if AName = 'agenda_do_dia' then
    begin
      LDay := 0;
      if LArgs <> nil then
        LDay := ParseVoiceDay(LArgs.GetValue<string>('data', ''), ACtx.Now);
      if LDay = 0 then
        LResult.AddPair('erro', 'data no formato AAAA-MM-DD')
      else
      begin
        LList := TJSONArray.Create;
        for LEvent in EventsOn(ACtx.Upcoming, LDay) do
          LList.AddElement(EventJson(LEvent));
        LResult.AddPair('dia', FormatDateTime('yyyy-mm-dd', LDay) + ' (' + CWeekDays[DayOfWeek(LDay)] + ')');
        LResult.AddPair('compromissos', LList);
      end;
    end
    else if AName = 'minhas_issues' then
    begin
      LItems := IssuesFiltered(ACtx.Issues, IfThen(LArgs <> nil, LArgs.GetValue<string>('filtro', 'todas'), 'todas'),
        ACtx.Now);
      LResult.AddPair('hoje', FormatDateTime('yyyy-mm-dd', ACtx.Now));
      LResult.AddPair('total', TJSONNumber.Create(Length(LItems)));
      LResult.AddPair('issues', IssuesJson(LItems));
    end
    else if AName = 'issue' then
    begin
      LFound := False;
      if LArgs <> nil then
        for LItem in ACtx.Issues do
          if SameText(LItem.Key, Trim(LArgs.GetValue<string>('chave', ''))) then
          begin
            LResult.AddPair('issue', IssueJson(LItem, True));
            LFound := True;
            Break;
          end;
      if not LFound then
        LResult.AddPair('erro', 'issue não está entre as abertas do usuário');
    end
    else if AName = 'proxima_reuniao' then
    begin
      LFound := False;
      for LEvent in ACtx.Upcoming do
        if not LEvent.AllDay and (LEvent.Finish > ACtx.Now) and (not LFound or (LEvent.Start < LBest.Start)) then
        begin
          LBest := LEvent;
          LFound := True;
        end;
      LResult.AddPair('agora', FormatDateTime('dd/mm hh:nn', ACtx.Now));
      if LFound then
        LResult.AddPair('reuniao', EventJson(LBest))
      else
        LResult.AddPair('reuniao', TJSONNull.Create);
    end
    else if AName = 'emails_importantes' then
    begin
      LMsgs := nil;
      for LAccount in ACtx.Accounts do
        if SrcListDigest(LAccount, LOne, LErr) then
          LMsgs := LMsgs + LOne;
      LList := TJSONArray.Create;
      for LMsg in Copy(LMsgs, 0, CMaxToolMails) do
        LList.AddElement(TJSONObject.Create.AddPair('de', IfThen(LMsg.FromName <> '', LMsg.FromName,
          LMsg.FromEmail)).AddPair('assunto', LMsg.Subject).AddPair('trecho', LMsg.Snippet).AddPair('quando',
          FormatDateTime('dd/mm hh:nn', LMsg.Date)));
      LResult.AddPair('contas', TJSONNumber.Create(Length(ACtx.Accounts)));
      LResult.AddPair('emails', LList);
    end
    else if AName = 'modo_foco' then
    begin
      if (LArgs <> nil) and LArgs.GetValue<Boolean>('ligar', False) then
        AReply.Action := vaFocoLigar
      else
        AReply.Action := vaFocoDesligar;
      LResult.AddPair('ok', TJSONBool.Create(True));
    end
    else if AName = 'abrir_tela' then
    begin
      AReply.Action := vaAbrir;
      if LArgs <> nil then
        AReply.Page := LArgs.GetValue<string>('tela', '');
      LResult.AddPair('ok', TJSONBool.Create(True));
    end
    else if AName = 'encerrar_conversa' then
    begin
      AReply.Action := vaEncerrar;
      LResult.AddPair('ok', TJSONBool.Create(True));
    end
    else
      LResult.AddPair('erro', 'ferramenta desconhecida: ' + AName);
    Result := LResult.ToJSON;
  finally
    LArgs.Free;
    LResult.Free;
  end;
end;

function ParseVoiceIntent(const AAnswer: string; out AReply: TVoiceReply): Boolean;
var
  LStart, LEnd, LIndex: Integer;
  LJson: TJSONValue;
  LAction: string;
begin
  AReply := Default(TVoiceReply);
  LStart := Pos('{', AAnswer);
  LEnd := LastDelimiter('}', AAnswer);
  if (LStart = 0) or (LEnd <= LStart) then
    Exit(False);
  LJson := TJSONObject.ParseJSONValue(Copy(AAnswer, LStart, LEnd - LStart + 1));
  try
    if LJson = nil then
      Exit(False);
    LAction := LowerCase(LJson.GetValue<string>('acao', 'conversa'));
    LIndex := IndexStr(LAction, CActionNames);
    if LIndex < 0 then
      LIndex := Ord(vaConversa);
    AReply.Action := TVoiceAction(LIndex);
    AReply.Page := LowerCase(LJson.GetValue<string>('tela', ''));
    AReply.Day := ParseVoiceDay(LJson.GetValue<string>('dia', ''), Date);
    AReply.Speech := Trim(LJson.GetValue<string>('fala', ''));
    if AReply.Page = 'email' then
      AReply.Page := 'mail';
    Result := True;
  finally
    LJson.Free;
  end;
end;

function RunVoiceCommand(const AText: string; const ACtx: TVoiceContext; out AReply: TVoiceReply;
  out AError: string): Boolean;
var
  LAnswer, LSys, LPrompt, LErr: string;
  LMsgs, LOne: TMailMsgs;
  LAccount: TMailAccount;
  LIssues: TJSONArray;
begin
  AError := '';
  AReply := Default(TVoiceReply);
  if not AskAI(ACtx.Config, CIntentSystem, AText, LAnswer, CIntentTokens) then
  begin
    AError := LAnswer;
    Exit(False);
  end;
  if not ParseVoiceIntent(LAnswer, AReply) then
  begin
    AReply.Action := vaConversa;
    AReply.Speech := LAnswer;
  end;
  case AReply.Action of
    vaAgenda:
      if (AReply.Day = 0) or (Trunc(AReply.Day) = Trunc(ACtx.Now)) then
        AReply.Speech := AgendaSpeech(ACtx.Today)
      else if Trunc(AReply.Day) = Trunc(ACtx.Now) + 1 then
        AReply.Speech := AgendaSpeech(EventsOn(ACtx.Upcoming, AReply.Day), 'Amanhã')
      else
        AReply.Speech := AgendaSpeech(EventsOn(ACtx.Upcoming, AReply.Day), CWeekDays[DayOfWeek(AReply.Day)] + ', ' +
          FormatDateTime('dd/mm', AReply.Day) + ',');
    vaIssues:
      if ACtx.Issues = nil then
        AReply.Speech := 'Não achei issues abertas nas contas ligadas do Devbox.'
      else
      begin
        LIssues := IssuesJson(ACtx.Issues);
        try
          LPrompt := Format('Hoje: %s.'#10'Pedido: %s'#10#10'Issues abertas (até %d):'#10'%s',
            [FormatDateTime('yyyy-mm-dd', ACtx.Now), AText, CMaxToolIssues, LIssues.ToJSON]);
        finally
          LIssues.Free;
        end;
        if not AskAI(ACtx.Config, CIssuesSystem, LPrompt, LAnswer, CSummaryTokens) then
        begin
          AError := LAnswer;
          Exit(False);
        end;
        AReply.Speech := LAnswer;
      end;
    vaReuniao:
      AReply.Speech := NextMeetingSpeech(ACtx.Upcoming, ACtx.Now);
    vaFocoLigar:
      AReply.Speech := 'Modo foco ligado.';
    vaFocoDesligar:
      AReply.Speech := 'Modo foco desligado.';
    vaAbrir:
      if AReply.Speech = '' then
        AReply.Speech := 'Abrindo.';
    vaEmails:
      begin
        if ACtx.Accounts = nil then
          AReply.Speech := 'Você não tem contas de e-mail ligadas no Devbox.'
        else
        begin
          LMsgs := nil;
          for LAccount in ACtx.Accounts do
            if SrcListDigest(LAccount, LOne, LErr) then
              LMsgs := LMsgs + LOne;
          if LMsgs = nil then
            AReply.Speech := 'Você não tem e-mails importantes não lidos.'
          else
          begin
            LPrompt := 'Pedido: ' + AText + #10#10 + DigestPrompt(nil, LMsgs, LSys);
            if not AskAI(ACtx.Config, CSummarySystem, LPrompt, LAnswer, CSummaryTokens) then
            begin
              AError := LAnswer;
              Exit(False);
            end;
            AReply.Speech := LAnswer;
          end;
        end;
      end;
  end;
  if AReply.Speech = '' then
    AReply.Speech := 'Não entendi o pedido.';
  Result := True;
end;

end.
