unit Devbox.UI.Agenda;

{ Agenda: eventos da agenda principal das contas Google ligadas, só para
  consulta. Aviso antes de cada reunião e atalho para entrar no Meet. }

interface

uses
  System.Classes,
  System.SysUtils,
  System.Generics.Collections,
  Vcl.ExtCtrls,
  UI.Labels,
  UI.Select,
  UI.Scheduler,
  UI.Scheduler.Model,
  Devbox.Store,
  Devbox.Google,
  Devbox.ICal,
  Devbox.UI.Kit;

type
  TAgendaPage = class(TDevPage)
  private
    FRemindSel: TUISelect;
    FNext: TUILabel;
    FStatus: TUILabel;
    FSched: TUIScheduler;
    FAccounts: TGoogleAccounts;
    FFeeds: TICalFeeds;
    FEvents: TDictionary<string, TCalEvents>;
    FShown: TCalEvents;
    FReminded: TDictionary<string, Boolean>;
    FLoading: Integer;
    FRefreshTimer: TTimer;
    FTickTimer: TTimer;
    procedure FetchAccount(const AEmail: string);
    procedure FetchFeed(const AFeed: TICalFeed);
    function HasSources: Boolean;
    procedure Loaded_(const AEmail: string; const AEvents: TCalEvents; const AError: string);
    procedure FillScheduler;
    procedure UpdateNext;
    function NextMeeting(out AEvent: TCalEvent): Boolean;
    function RemindMinutes: Integer;
    procedure RefreshClick(Sender: TObject);
    procedure JoinClick(Sender: TObject);
    procedure RemindChange(Sender: TObject);
    procedure EventOpen(Sender: TObject; AEvent: TUISchedulerEvent);
    procedure RefreshTick(Sender: TObject);
    procedure Tick(Sender: TObject);
  public
    constructor Create(AOwner: TComponent); override;
    procedure PageRefresh; override;
    destructor Destroy; override;
    procedure Reload;
    { Eventos de hoje de todas as contas (o resumo do dia usa). }
    function TodayEvents: TCalEvents;
    { Todos os eventos carregados (passados e futuros), de todas as contas e links. }
    function AllEvents: TCalEvents;
  end;

implementation

uses
  System.StrUtils,
  System.Math,
  System.DateUtils,
  System.Threading,
  System.Generics.Defaults,
  Vcl.Controls,
  UI.Toast,
  UI.Button,
  Devbox.Model,
  Devbox.Notify,
  Devbox.Sys;

const
  CPastDays = 7;
  CFutureDays = 31;
  CRefreshMs = 5 * 60 * 1000;
  CTickMs = 30 * 1000;
  CRemindOptions: array[0..4] of Integer = (0, 5, 10, 15, 30);

constructor TAgendaPage.Create(AOwner: TComponent);
var
  Bar: TPanel;
  M: Integer;
begin
  inherited Create(AOwner);
  FRefreshable := True;
  Caption := 'Agenda';
  Hint := 'Contas Google e agendas por link iCal, só para consulta. Duplo clique abre o Meet ou o evento.';
  FEvents := TDictionary<string, TCalEvents>.Create;
  FReminded := TDictionary<string, Boolean>.Create;

  Bar := NewPanel(Self, alTop, 50);
  Bar.Padding.SetBounds(0, ScaleValue(6), 0, ScaleValue(6));
  NewButton(Bar, 'Entrar na próxima reunião', JoinClick, bvPrimary);
  FRemindSel := TUISelect.Create(Self);
  for M in CRemindOptions do
    if M = 0 then
      FRemindSel.Items.Add('Sem aviso')
    else
      FRemindSel.Items.Add(Format('Avisar %d min antes', [M]));
  FRemindSel.Width := ScaleValue(190);
  FRemindSel.Align := alRight;
  FRemindSel.Parent := Bar;
  FNext := TUILabel.Create(Self);
  FNext.Bold := True;
  FNext.FontSize := 14;
  FNext.AutoSize := False;
  FNext.Height := ScaleValue(28);
  FNext.Top := 100000;
  FNext.Align := alTop;
  FNext.Parent := Self;
  FStatus := NewHint(Self, '');

  FSched := TUIScheduler.Create(Self);
  FSched.ReadOnly := True;
  FSched.View := svWeek;
  FSched.StartHour := 7;
  FSched.OnEventOpen := EventOpen;
  FSched.Top := 100000;
  FSched.Align := alClient;
  FSched.Parent := Self;

  FRemindSel.ItemIndex := 0;
  for M := 0 to High(CRemindOptions) do
    if CRemindOptions[M] = RemindMinutes then
      FRemindSel.ItemIndex := M;
  FRemindSel.OnChange := RemindChange;
  FRefreshTimer := TTimer.Create(Self);
  FRefreshTimer.Interval := CRefreshMs;
  FRefreshTimer.OnTimer := RefreshTick;
  FTickTimer := TTimer.Create(Self);
  FTickTimer.Interval := CTickMs;
  FTickTimer.OnTimer := Tick;
  Reload;
end;

destructor TAgendaPage.Destroy;
begin
  FReminded.Free;
  FEvents.Free;
  inherited;
end;

function TAgendaPage.RemindMinutes: Integer;
begin
  Result := StrToIntDef(Store.GetSetting('cal_remind_min', '10'), 10);
end;

procedure TAgendaPage.Reload;
var
  A: TGoogleAccount;
begin
  // Cópia do cliente OAuth para as tarefas de fundo (elas não podem ler o banco).
  LoadGoogleClient;
  FAccounts := nil;
  for A in Store.ListGoogleAccounts do
    if A.Enabled and GoogleSignedIn(A.Email) then
      FAccounts := FAccounts + [A];
  FFeeds := LoadICalFeeds;
  FEvents.Clear;
  FRefreshTimer.Enabled := HasSources;
  FTickTimer.Enabled := HasSources;
  FillScheduler;
  if not HasSources then
    FStatus.Caption := 'Nenhuma agenda. Ligue uma conta ou cole um link iCal em Configuração › E-mail e agenda.'
  else
    RefreshClick(nil);
end;

function TAgendaPage.HasSources: Boolean;
begin
  Result := (FAccounts <> nil) or (FFeeds <> nil);
end;

procedure TAgendaPage.RefreshTick(Sender: TObject);
begin
  RefreshClick(nil);
end;

procedure TAgendaPage.RefreshClick(Sender: TObject);
var
  A: TGoogleAccount;
  F: TICalFeed;
begin
  if FLoading > 0 then
    Exit;
  for A in FAccounts do
    FetchAccount(A.Email);
  for F in FFeeds do
    FetchFeed(F);
  if FLoading > 0 then
    FStatus.Caption := 'Buscando...';
end;

procedure TAgendaPage.FetchAccount(const AEmail: string);
var
  Email: string;
begin
  Email := AEmail;
  Inc(FLoading);
  TTask.Run(
    procedure
    var
      Events: TCalEvents;
      Err: string;
    begin
      try
        ListEvents(Email, Date - CPastDays, Date + CFutureDays, Events, Err);
      except
        on E: Exception do
          Err := E.Message;
      end;
      QueueUI(
        procedure
        begin
          Loaded_(Email, Events, Err);
        end);
    end);
end;

procedure TAgendaPage.FetchFeed(const AFeed: TICalFeed);
var
  Feed: TICalFeed;
begin
  Feed := AFeed;
  Inc(FLoading);
  TTask.Run(
    procedure
    var
      Events: TCalEvents;
      Err: string;
      I: Integer;
    begin
      try
        if FetchICal(Feed.Url, Date - CPastDays, Date + CFutureDays, Events, Err) then
          for I := 0 to High(Events) do
            Events[I].Account := Feed.Name;
      except
        on E: Exception do
          Err := E.Message;
      end;
      QueueUI(
        procedure
        begin
          Loaded_('ical:' + Feed.Name, Events, Err);
        end);
    end);
end;

procedure TAgendaPage.Loaded_(const AEmail: string; const AEvents: TCalEvents; const AError: string);
begin
  Dec(FLoading);
  if AError <> '' then
    TUIToastManager.Show(AEmail + ': ' + AError, ttError, 6000)
  else
    FEvents.AddOrSetValue(AEmail, AEvents);
  if FLoading = 0 then
  begin
    FillScheduler;
    FStatus.Caption := 'Atualizado ' + FormatDateTime('hh:nn', Now);
    Tick(nil);
  end;
end;

procedure TAgendaPage.FillScheduler;
var
  Keys: TArray<string>;
  A: TGoogleAccount;
  F: TICalFeed;
  I: Integer;
  E: TCalEvent;
  Ev: TUISchedulerEvent;
  Events: TCalEvents;
begin
  FShown := nil;
  // Ordem fixa (contas pela ordem de cadastro, depois os links): a cor de cada uma não muda.
  Keys := nil;
  for A in Store.ListGoogleAccounts do
    Keys := Keys + [A.Email];
  for F in FFeeds do
    Keys := Keys + ['ical:' + F.Name];
  FSched.ClearEvents;
  for I := 0 to High(Keys) do
    if FEvents.TryGetValue(Keys[I], Events) then
      for E in Events do
      begin
        // Dia todo: do começo do dia ao começo do seguinte.
        if E.AllDay then
          Ev := FSched.AddEvent(E.Start, Max(E.Finish, E.Start + 1), E.Title)
        else
          Ev := FSched.AddEvent(E.Start, E.Finish, E.Title);
        if Length(FAccounts) + Length(FFeeds) > 1 then
          Ev.Color := GoogleAccountColor(I);
        Ev.Tag := Length(FShown);
        FShown := FShown + [E];
      end;
  FSched.EventsChanged;
  UpdateNext;
end;

function TAgendaPage.NextMeeting(out AEvent: TCalEvent): Boolean;
var
  E: TCalEvent;
begin
  Result := False;
  // Em andamento conta como a próxima: dá para entrar atrasado.
  for E in FShown do
    if not E.AllDay and (E.Finish > Now) and (not Result or (E.Start < AEvent.Start)) then
    begin
      AEvent := E;
      Result := True;
    end;
end;

procedure TAgendaPage.UpdateNext;
var
  E: TCalEvent;
  Mins: Int64;
begin
  if not NextMeeting(E) then
  begin
    FNext.Caption := IfThen(HasSources, 'Nenhuma reunião pela frente', '');
    Exit;
  end;
  if E.Start <= Now then
    FNext.Caption := Format('Agora: %s (até %s)', [E.Title, FormatDateTime('hh:nn', E.Finish)])
  else
  begin
    Mins := MinutesBetween(Now, E.Start) + 1;
    if Trunc(E.Start) = Date then
      FNext.Caption := Format('Próxima: %s às %s (em %d min)', [E.Title, FormatDateTime('hh:nn', E.Start), Mins])
    else
      FNext.Caption := Format('Próxima: %s em %s', [E.Title, FormatDateTime('dd/mm hh:nn', E.Start)]);
  end;
  if E.MeetUrl <> '' then
    FNext.Caption := FNext.Caption + '  ·  tem Meet';
end;

procedure TAgendaPage.Tick(Sender: TObject);
var
  E: TCalEvent;
  Key: string;
  Before: Integer;
begin
  UpdateNext;
  Before := RemindMinutes;
  if Before <= 0 then
    Exit;
  for E in FShown do
  begin
    if E.AllDay or (E.Start <= Now) or (E.Start > IncMinute(Now, Before)) then
      Continue;
    Key := E.Account + '|' + E.Id + '|' + FloatToStr(E.Start);
    if FReminded.ContainsKey(Key) then
      Continue;
    FReminded.Add(Key, True);
    Notify(Format('Em %d min: %s', [MinutesBetween(Now, E.Start) + 1, E.Title]),
      IfThen(E.MeetUrl <> '', 'Entre pela Agenda do Devbox (tem Meet)', IfThen(E.Location <> '', E.Location,
      FormatDateTime('hh:nn', E.Start))));
  end;
end;

procedure TAgendaPage.RemindChange(Sender: TObject);
begin
  Store.SetSetting('cal_remind_min', IntToStr(CRemindOptions[Max(0, FRemindSel.ItemIndex)]));
end;

procedure TAgendaPage.JoinClick(Sender: TObject);
var
  E: TCalEvent;
begin
  if not NextMeeting(E) then
    TUIToastManager.Show('Nenhuma reunião pela frente', ttInfo, 2500)
  else if E.MeetUrl <> '' then
    OpenUrl(E.MeetUrl)
  else
  begin
    TUIToastManager.Show(E.Title + ' não tem link de vídeo. Abrindo o evento.', ttInfo, 3000);
    OpenUrl(E.WebUrl);
  end;
end;

procedure TAgendaPage.EventOpen(Sender: TObject; AEvent: TUISchedulerEvent);
var
  E: TCalEvent;
begin
  if (AEvent.Tag < 0) or (AEvent.Tag > High(FShown)) then
    Exit;
  E := FShown[AEvent.Tag];
  if E.MeetUrl <> '' then
    OpenUrl(E.MeetUrl)
  else if E.WebUrl <> '' then
    OpenUrl(E.WebUrl);
end;

function TAgendaPage.AllEvents: TCalEvents;
begin
  Result := FShown;
end;

function TAgendaPage.TodayEvents: TCalEvents;
var
  E: TCalEvent;
begin
  Result := nil;
  for E in FShown do
    if (Trunc(E.Start) = Date) or (E.AllDay and (E.Start <= Date) and (E.Finish > Date)) then
      Result := Result + [E];
  TArray.Sort<TCalEvent>(Result, TComparer<TCalEvent>.Construct(
    function(const A, B: TCalEvent): Integer
    begin
      Result := CompareValue(A.Start, B.Start);
    end));
end;

procedure TAgendaPage.PageRefresh;
begin
  RefreshClick(nil);
end;

end.
