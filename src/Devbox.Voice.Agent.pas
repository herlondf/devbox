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
  Devbox.Realtime;

type
  TVoiceAction = (vaConversa, vaEmails, vaAgenda, vaReuniao, vaFocoLigar, vaFocoDesligar, vaAbrir, vaEncerrar);

  TVoiceContext = record
    Config: TAIConfig;
    Accounts: TMailAccounts;
    Today: TCalEvents;          // eventos de hoje, em ordem
    Upcoming: TCalEvents;       // próximos (para "próxima reunião")
    Now: TDateTime;
  end;

  TVoiceReply = record
    Action: TVoiceAction;
    Page: string;      // vaAbrir: 'mail', 'agenda', 'digest', 'clipboard'...
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
function AgendaSpeech(const AEvents: TCalEvents): string;
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
    'foco_desligar', 'abrir', 'encerrar');
  CRealtimeInstructions = 'Você é o assistente de voz do Devbox, no computador de um desenvolvedor. Fale português ' +
    'do Brasil, curto e natural, como numa conversa: no máximo 2 ou 3 frases por vez, sem listas nem símbolos. ' +
    'Use as ferramentas para e-mails, agenda, reuniões, modo foco e para abrir telas do Devbox; não invente dados. ' +
    'Ao ler e-mails, diga quem mandou e o que pede, do mais urgente para o menos. Quando o usuário se despedir ou ' +
    'pedir para parar, diga tchau em poucas palavras e chame encerrar_conversa.';
  CNoParams = '{"type":"object","properties":{}}';
  CMaxToolMails = 15;
  CIntentSystem = 'Você é o assistente de voz do Devbox, de um desenvolvedor no Windows. O pedido veio de fala ' +
    'transcrita (pode ter erros). Escolha UMA ação: "emails" (resumir ou ler e-mails), ' +
    '"agenda" (compromissos de hoje), "reuniao" (próxima reunião), "foco_ligar", "foco_desligar", "abrir" (abrir ' +
    'uma tela: email, agenda, digest, clipboard, services, cleanup, network, system, jobs, settings) ou ' +
    '"conversa" (qualquer outra coisa: responda você mesmo em "fala", em português, no máximo 2 frases curtas, ' +
    'sem markdown). Responda SÓ com JSON: {"acao":"...","tela":"...","fala":"..."}';
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

function AgendaSpeech(const AEvents: TCalEvents): string;
var
  LEvent: TCalEvent;
  LParts: TArray<string>;
begin
  if AEvents = nil then
    Exit('Você não tem compromissos hoje.');
  LParts := nil;
  for LEvent in AEvents do
    if LEvent.AllDay then
      LParts := LParts + ['o dia todo, ' + LEvent.Title]
    else
      LParts := LParts + ['às ' + SpokenTime(LEvent.Start) + ', ' + LEvent.Title];
  if Length(AEvents) = 1 then
    Result := 'Hoje você tem um compromisso: ' + LParts[0] + '.'
  else
    Result := Format('Hoje você tem %d compromissos: %s.', [Length(AEvents), string.Join('; ', LParts)]);
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
  Result := CRealtimeInstructions;
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
    Tool('proxima_reuniao', 'A próxima reunião que ainda não acabou.', CNoParams),
    Tool('modo_foco', 'Liga ou desliga o modo foco do Devbox (silencia avisos).',
      '{"type":"object","properties":{"ligar":{"type":"boolean"}},"required":["ligar"]}'),
    Tool('abrir_tela', 'Abre uma tela do Devbox na frente do usuário.',
      '{"type":"object","properties":{"tela":{"type":"string","enum":["mail","agenda","digest","clipboard",' +
      '"services","cleanup","network","system","jobs","settings"]}},"required":["tela"]}'),
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

function RunRealtimeTool(const AName, AArgs: string; const ACtx: TVoiceContext; out AReply: TVoiceReply): string;
var
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
      AReply.Speech := AgendaSpeech(ACtx.Today);
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
