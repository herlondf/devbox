unit Devbox.ICal;

{ Agenda por link iCal (o "endereço secreto em formato iCal" do Google Agenda,
  ou o .ics de qualquer agenda). Só leitura, sem login. O link dá acesso à
  agenda: fica no Credential Manager. FetchICal bloqueia: fora da thread de UI. }

interface

uses
  System.SysUtils,
  Devbox.Google;

type
  TICalFeed = record
    Name: string;
    Url: string;
  end;
  TICalFeeds = TArray<TICalFeed>;

function LoadICalFeeds: TICalFeeds;
procedure SaveICalFeeds(const AFeeds: TICalFeeds);

function FetchICal(const AUrl: string; AFrom, ATo: TDateTime; out AEvents: TCalEvents; out AError: string): Boolean;

{ Eventos entre AFrom e ATo, com as repetições (RRULE) expandidas. Puro. }
function ParseICal(const AText: string; AFrom, ATo: TDateTime): TCalEvents;

implementation

uses
  System.Classes,
  System.StrUtils,
  System.DateUtils,
  System.Math,
  System.RegularExpressions,
  System.Generics.Collections,
  System.Net.HttpClient,
  Devbox.Secrets;

const
  CSecretTarget = 'Devbox:ical';
  CMaxSteps = 5000;
  CMeetPattern = 'https://(meet\.google\.com|[\w.-]*zoom\.us|teams\.microsoft\.com|teams\.live\.com)/[^\s"<>\\]+';

function LoadICalFeeds: TICalFeeds;
var
  Line: string;
  Parts: TArray<string>;
  F: TICalFeed;
begin
  Result := nil;
  for Line in LoadSecret(CSecretTarget).Split([#10], TStringSplitOptions.ExcludeEmpty) do
  begin
    Parts := Line.Split([#9]);
    if Length(Parts) = 2 then
    begin
      F.Name := Parts[0];
      F.Url := Parts[1];
      Result := Result + [F];
    end;
  end;
end;

procedure SaveICalFeeds(const AFeeds: TICalFeeds);
var
  F: TICalFeed;
  Text: string;
begin
  Text := '';
  for F in AFeeds do
    Text := Text + F.Name.Replace(#9, ' ') + #9 + Trim(F.Url) + #10;
  if Text = '' then
    DeleteSecret(CSecretTarget)
  else
    SaveSecret(CSecretTarget, 'devbox', Text);
end;

{ Leitura }

type
  TProp = record
    Name: string;
    Params: string;
    Value: string;
  end;

  TVEvent = record
    Uid, Summary, Location, Description, Url, Status: string;
    Start, Finish: TDateTime;
    AllDay: Boolean;
    Duration: Double;
    RRule: string;
    RecurrenceId: TDateTime;
    ExDates: TArray<TDateTime>;
  end;

function Unescape(const S: string): string;
begin
  Result := S.Replace('\n', #10).Replace('\N', #10).Replace('\,', ',').Replace('\;', ';').Replace('\\', '\');
end;

function SplitProp(const ALine: string): TProp;
var
  Colon, Semi: Integer;
  Head: string;
begin
  Result := Default(TProp);
  // O valor começa no primeiro ':' fora de aspas dos parâmetros; parâmetro com ':' entre aspas é raro.
  Colon := Pos(':', ALine);
  if Colon = 0 then
    Exit;
  Head := Copy(ALine, 1, Colon - 1);
  Result.Value := Copy(ALine, Colon + 1, MaxInt);
  Semi := Pos(';', Head);
  if Semi > 0 then
  begin
    Result.Name := UpperCase(Copy(Head, 1, Semi - 1));
    Result.Params := UpperCase(Copy(Head, Semi + 1, MaxInt));
  end
  else
    Result.Name := UpperCase(Head);
end;

{ 20261006 (dia todo), 20261006T090000 (hora local ou com TZID: tratada como
  local) e 20261006T090000Z (UTC). }
function ParseStamp(const AValue: string; out AAllDay: Boolean): TDateTime;
var
  V: string;
  Y, M, D, H, N, S: Integer;
begin
  Result := 0;
  V := Trim(AValue);
  AAllDay := Pos('T', V) = 0;
  if (Length(V) < 8) or not TryStrToInt(Copy(V, 1, 4), Y) or not TryStrToInt(Copy(V, 5, 2), M) or
    not TryStrToInt(Copy(V, 7, 2), D) then
    Exit;
  if not TryEncodeDate(Y, M, D, Result) then
    Exit(0);
  if AAllDay or (Length(V) < 15) then
    Exit;
  H := StrToIntDef(Copy(V, 10, 2), 0);
  N := StrToIntDef(Copy(V, 12, 2), 0);
  S := StrToIntDef(Copy(V, 14, 2), 0);
  Result := Result + EncodeTime(Min(H, 23), Min(N, 59), Min(S, 59), 0);
  if V.EndsWith('Z', True) then
    Result := TTimeZone.Local.ToLocalTime(Result);
end;

{ P1D, PT1H30M, P1W. }
function ParseDuration(const AValue: string): Double;
var
  M: TMatch;
begin
  Result := 0;
  for M in TRegEx.Matches(UpperCase(AValue), '(\d+)([WDHMS])') do
    case M.Groups[2].Value[1] of
      'W': Result := Result + 7 * StrToInt(M.Groups[1].Value);
      'D': Result := Result + StrToInt(M.Groups[1].Value);
      'H': Result := Result + StrToInt(M.Groups[1].Value) / HoursPerDay;
      'M': Result := Result + StrToInt(M.Groups[1].Value) / MinsPerDay;
      'S': Result := Result + StrToInt(M.Groups[1].Value) / SecsPerDay;
    end;
end;

function RulePart(const ARule, AKey: string): string;
var
  P: string;
begin
  Result := '';
  for P in ARule.Split([';']) do
    if StartsText(AKey + '=', P) then
      Exit(Copy(P, Length(AKey) + 2, MaxInt));
end;

function SameMinute(A, B: TDateTime): Boolean;
begin
  Result := Abs(A - B) < 1 / MinsPerDay / 2;
end;

function MeetLink(const E: TVEvent): string;
var
  M: TMatch;
begin
  M := TRegEx.Match(E.Location + ' ' + E.Url + ' ' + E.Description, CMeetPattern, [roIgnoreCase]);
  if M.Success then
    Result := M.Value
  else
    Result := '';
end;

{ Começos das ocorrências que cruzam [AFrom, ATo]. Sem RRULE: só o próprio. }
function Occurrences(const E: TVEvent; AFrom, ATo: TDateTime): TArray<TDateTime>;
const
  CDayCodes: array[1..7] of string = ('MO', 'TU', 'WE', 'TH', 'FR', 'SA', 'SU');
var
  Freq, ByDay: string;
  Interval, Count, Made, Step, I: Integer;
  Until_, Cur, Day, Len, WeekStart: TDateTime;
  Dummy, Excluded: Boolean;
  Days: TArray<Integer>;
  Code: string;

  procedure Take(AStart: TDateTime);
  var
    Ex: TDateTime;
  begin
    if AStart < E.Start then
      Exit;
    Inc(Made);
    Excluded := False;
    for Ex in E.ExDates do
      if SameMinute(Ex, AStart) or (E.AllDay and (Trunc(Ex) = Trunc(AStart))) then
        Excluded := True;
    if not Excluded and (AStart + Len > AFrom) and (AStart < ATo) then
      Result := Result + [AStart];
  end;

begin
  Result := nil;
  Len := Max(E.Finish - E.Start, 0);
  if E.RRule = '' then
  begin
    if (E.Start + Len > AFrom) and (E.Start < ATo) then
      Result := [E.Start];
    Exit;
  end;
  Freq := UpperCase(RulePart(E.RRule, 'FREQ'));
  Interval := Max(StrToIntDef(RulePart(E.RRule, 'INTERVAL'), 1), 1);
  Count := StrToIntDef(RulePart(E.RRule, 'COUNT'), 0);
  Until_ := 0;
  if RulePart(E.RRule, 'UNTIL') <> '' then
  begin
    Until_ := ParseStamp(RulePart(E.RRule, 'UNTIL'), Dummy);
    if Dummy then
      Until_ := Until_ + 1 - 1 / SecsPerDay;
  end;
  ByDay := UpperCase(RulePart(E.RRule, 'BYDAY'));
  Days := nil;
  for Code in ByDay.Split([',']) do
    for I := 1 to 7 do
      // "1MO" (mensal) também cai aqui pelo fim do código; vale para semanal.
      if Code.EndsWith(CDayCodes[I]) then
        Days := Days + [I];
  Made := 0;
  Step := 0;
  Cur := E.Start;
  while Step < CMaxSteps do
  begin
    Inc(Step);
    if (Count > 0) and (Made >= Count) then
      Break;
    if ((Until_ > 0) and (Cur > Until_)) or (Cur > ATo) then
      Break;
    if (Freq = 'WEEKLY') and (Days <> nil) then
    begin
      // Semana de Cur (segunda a domingo); cada dia pedido nela.
      WeekStart := Trunc(Cur) - (DayOfTheWeek(Cur) - 1);
      for I in Days do
      begin
        Day := WeekStart + (I - 1) + Frac(E.Start);
        if (Count > 0) and (Made >= Count) then
          Break;
        if (Until_ > 0) and (Day > Until_) then
          Break;
        Take(Day);
      end;
      Cur := WeekStart + 7 * Interval + Frac(E.Start);
      Continue;
    end;
    Take(Cur);
    if Freq = 'DAILY' then
      Cur := Cur + Interval
    else if Freq = 'WEEKLY' then
      Cur := Cur + 7 * Interval
    else if Freq = 'MONTHLY' then
      Cur := IncMonth(E.Start, Step * Interval)
    else if Freq = 'YEARLY' then
      Cur := IncYear(E.Start, Step * Interval)
    else
      Break;
  end;
  TArray.Sort<TDateTime>(Result);
end;

function ParseICal(const AText: string; AFrom, ATo: TDateTime): TCalEvents;
var
  Text, Line: string;
  Lines: TArray<string>;
  InEvent: Boolean;
  E: TVEvent;
  Events: TList<TVEvent>;
  Overrides: TDictionary<string, Boolean>;
  P: TProp;
  AllDay: Boolean;
  Ex: string;
  V: TVEvent;
  Starts: TArray<TDateTime>;
  S: TDateTime;
  Ev: TCalEvent;
  Key: string;
begin
  Result := nil;
  // Linha dobrada: continua na seguinte que começa com espaço ou tab.
  Text := AText.Replace(#13#10, #10).Replace(#13, #10).Replace(#10' ', '').Replace(#10#9, '');
  Lines := Text.Split([#10]);
  Events := TList<TVEvent>.Create;
  Overrides := TDictionary<string, Boolean>.Create;
  try
    InEvent := False;
    for Line in Lines do
    begin
      if SameText(Line, 'BEGIN:VEVENT') then
      begin
        InEvent := True;
        E := Default(TVEvent);
        Continue;
      end;
      if SameText(Line, 'END:VEVENT') then
      begin
        InEvent := False;
        if E.Finish = 0 then
          if E.Duration > 0 then
            E.Finish := E.Start + E.Duration
          else if E.AllDay then
            E.Finish := E.Start + 1
          else
            E.Finish := E.Start;
        if (E.Start > 0) and not SameText(E.Status, 'CANCELLED') then
          Events.Add(E);
        // Exceção de uma ocorrência: some a gerada no mesmo horário.
        if (E.Uid <> '') and (E.RecurrenceId > 0) then
          Overrides.AddOrSetValue(E.Uid + '|' + FormatDateTime('yyyymmddhhnn', E.RecurrenceId), True);
        Continue;
      end;
      if not InEvent then
        Continue;
      P := SplitProp(Line);
      if P.Name = 'UID' then
        E.Uid := P.Value
      else if P.Name = 'SUMMARY' then
        E.Summary := Unescape(P.Value)
      else if P.Name = 'LOCATION' then
        E.Location := Unescape(P.Value)
      else if P.Name = 'DESCRIPTION' then
        E.Description := Unescape(P.Value)
      else if P.Name = 'URL' then
        E.Url := P.Value
      else if P.Name = 'STATUS' then
        E.Status := P.Value
      else if P.Name = 'DTSTART' then
        E.Start := ParseStamp(P.Value, E.AllDay)
      else if P.Name = 'DTEND' then
        E.Finish := ParseStamp(P.Value, AllDay)
      else if P.Name = 'DURATION' then
        E.Duration := ParseDuration(P.Value)
      else if P.Name = 'RRULE' then
        E.RRule := P.Value
      else if P.Name = 'RECURRENCE-ID' then
        E.RecurrenceId := ParseStamp(P.Value, AllDay)
      else if P.Name = 'EXDATE' then
        for Ex in P.Value.Split([',']) do
          E.ExDates := E.ExDates + [ParseStamp(Ex, AllDay)];
    end;

    for V in Events do
    begin
      Starts := Occurrences(V, AFrom, ATo);
      for S in Starts do
      begin
        Key := V.Uid + '|' + FormatDateTime('yyyymmddhhnn', S);
        if (V.RecurrenceId = 0) and (V.RRule <> '') and Overrides.ContainsKey(Key) then
          Continue;
        Ev := Default(TCalEvent);
        Ev.Id := V.Uid;
        Ev.Title := IfThen(V.Summary <> '', V.Summary, '(sem título)');
        Ev.Location := V.Location;
        Ev.Start := S;
        Ev.Finish := S + (V.Finish - V.Start);
        Ev.AllDay := V.AllDay;
        Ev.MeetUrl := MeetLink(V);
        Ev.WebUrl := IfThen(StartsText('http', V.Url), V.Url, '');
        Result := Result + [Ev];
      end;
    end;
  finally
    Overrides.Free;
    Events.Free;
  end;
end;

function FetchICal(const AUrl: string; AFrom, ATo: TDateTime; out AEvents: TCalEvents; out AError: string): Boolean;
var
  Http: THTTPClient;
  R: IHTTPResponse;
  Url: string;
begin
  AEvents := nil;
  AError := '';
  Url := Trim(AUrl);
  if StartsText('webcal://', Url) then
    Url := 'https://' + Copy(Url, 10, MaxInt);
  Http := THTTPClient.Create;
  try
    Http.ConnectionTimeout := 10000;
    Http.ResponseTimeout := 30000;
    Http.UserAgent := 'Devbox';
    try
      R := Http.Get(Url);
    except
      on E: Exception do
      begin
        AError := 'Sem resposta: ' + E.Message;
        Exit(False);
      end;
    end;
    if R.StatusCode <> 200 then
    begin
      AError := Format('HTTP %d', [R.StatusCode]);
      Exit(False);
    end;
    AEvents := ParseICal(R.ContentAsString(TEncoding.UTF8), AFrom, ATo);
    Result := True;
  finally
    Http.Free;
  end;
end;

end.
