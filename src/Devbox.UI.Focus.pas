unit Devbox.UI.Focus;

{ Modo foco/reunião: pausa o clipboard, segura os avisos do Devbox (saem
  juntos no fim) e pode silenciar os do Windows. Liga por tempo (25/50 min),
  até desligar, ou sozinho quando a câmera ou o microfone estão em uso. }

interface

uses
  System.Classes,
  System.SysUtils,
  UI.Tokens,
  Vcl.Controls,
  Vcl.ExtCtrls,
  UI.Labels,
  UI.Button,
  UI.Checkbox,
  UI.Countdown,
  UI.RadialProgress,
  UI.Timeline,
  UI.ScrollArea,
  UI.Stat,
  UI.Chart,
  UI.Card,
  Devbox.UI.Kit;

type
  TFocusPage = class(TDevPage)
  private
    FRing: TUIRadialProgress;
    FState: TUILabel;
    FCountdown: TUICountdown;
    FPauseClip, FMuteNotify, FMuteWindows, FAutoMeeting: TUICheckbox;
    FMeetingLabel: TUILabel;
    FHistory: TUITimeline;
    FTodayStat: TUIStat;
    FWeekChart: TUIChart;
    FTick: TTimer;
    FMeetingTimer: TTimer;
    FEndsAt: TDateTime;           // 0 = até desligar
    FStartedAt: TDateTime;
    FTotalSec: Integer;
    FByMeeting: Boolean;          // ligou sozinho pela reunião
    FWindowsBefore: Boolean;      // avisos do Windows antes de ligar
    FOnChanged: TNotifyEvent;
    procedure FillStats;
    procedure StartFocus(AMinutes: Integer; AByMeeting: Boolean; const AWhy: string);
    procedure StopFocus(const AWhy: string);
    procedure UpdateView;
    procedure FocusOpen(Sender: TObject);
    procedure StopClick(Sender: TObject);
    procedure OptionChange(Sender: TObject);
    procedure TickTimer(Sender: TObject);
    procedure MeetingTimerTick(Sender: TObject);
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    { Atalho da bandeja: liga até desligar ou desliga. }
    procedure Toggle;
    { Pomodoro: foco durante o trabalho (AMinutes) e desligado na pausa. }
    procedure StartTimed(AMinutes: Integer; const AWhy: string);
    procedure StopBy(const AWhy: string);
    { Mudou o estado (a bandeja e o menu mostram). }
    property OnChanged: TNotifyEvent read FOnChanged write FOnChanged;
  end;

implementation

uses
  System.StrUtils,
  System.Math,
  System.DateUtils,
  System.Threading,
  UI.Theme,
  UI.Toast,
  Devbox.Store,
  Devbox.Focus,
  Devbox.Envs,
  Devbox.Notify;

const
  CMeetingCheckMs = 10000;
  CRingBox = 240;       // igual ao Pomodoro: anel em caixa quadrada, sempre redondo
  CRingSize = 208;
  CRingStroke = 12;
  CRingInset = 16;
  CRowH = 34;
  CTitleH = 30;
  CStatsH = 150;

constructor TFocusPage.Create(AOwner: TComponent);
var
  LTop, LRingHost, LInfo, LBar, LStats: TPanel;
  LCard: TUICard;

  function Option(const ACaption, ASetting: string; ADefault: Boolean): TUICheckbox;
  begin
    Result := TUICheckbox.Create(Self);
    Result.Caption := ACaption;
    Result.Checked := Store.GetSetting(ASetting, IfThen(ADefault, '1', '0')) = '1';
    Result.HelpKeyword := ASetting;
    Result.OnChange := OptionChange;
    Result.Height := ScaleValue(CRowH);
    Result.Top := 100000;
    Result.Align := alTop;
    Result.Parent := LCard;
  end;

  function Title(AParent: TWinControl; const ACaption: string): TUILabel;
  begin
    Result := TUILabel.Create(Self);
    Result.Caption := ACaption;
    Result.Bold := True;
    Result.AutoSize := False;
    Result.Height := ScaleValue(CTitleH);
    Result.Top := 100000;
    Result.Align := alTop;
    Result.Parent := AParent;
  end;

begin
  inherited Create(AOwner);
  Caption := 'Foco e reunião';
  Hint := 'Menos interrupção: clipboard em pausa e avisos guardados para depois';

  // Topo: anel (quadrado, sempre redondo) e, ao lado, estado e botões.
  LTop := NewPanel(Self, alTop, CRingBox);
  LRingHost := NewPanel(LTop, alLeft);
  LRingHost.Width := ScaleValue(CRingBox);
  FRing := TUIRadialProgress.Create(Self);
  FRing.RingSize := CRingSize;
  FRing.StrokeWidth := CRingStroke;
  FRing.TabStop := False;  // sem isto o anel de foco do teclado aparece em volta
  FRing.ShowPercent := False;
  FRing.Max := 100;
  FRing.Value := 0;
  FRing.SetBounds(ScaleValue(CRingInset), ScaleValue(CRingInset), ScaleValue(CRingBox - 2 * CRingInset),
    ScaleValue(CRingBox - 2 * CRingInset));
  // Ordem de cima para baixo: o NewPanel põe tudo no fim; aqui cada bloco tem a sua vez.
  LTop.Top := 0;
  FRing.Parent := LRingHost;
  LInfo := NewPanel(LTop, alClient);
  LInfo.Padding.SetBounds(ScaleValue(24), ScaleValue(30), 0, 0);
  FState := TUILabel.Create(Self);
  FState.Bold := True;
  FState.FontSize := 18;
  FState.AutoSize := False;
  FState.Height := ScaleValue(30);
  FState.Align := alTop;
  FState.Parent := LInfo;
  FCountdown := TUICountdown.Create(Self);
  FCountdown.ShowLabels := False;
  FCountdown.Height := ScaleValue(48);
  FCountdown.Visible := False;
  FCountdown.Top := 100000;
  FCountdown.Align := alTop;
  FCountdown.Parent := LInfo;
  LBar := NewPanel(LInfo, alTop, 52);
  LBar.Top := 100000;
  LBar.Padding.SetBounds(0, ScaleValue(8), 0, ScaleValue(4));
  NewButton(LBar, 'Ligar o foco', FocusOpen, bvPrimary);
  NewButton(LBar, 'Encerrar', StopClick, bvGhost).Left := 100000;
  FMeetingLabel := NewHint(LInfo, '');
  FMeetingLabel.Top := 100000;

  // O que o foco faz: um cartão só, em vez de caixas soltas.
  LCard := TUICard.Create(Self);
  LCard.Variant := cvOutlined;
  LCard.CardPad := cpNone;
  LCard.Padding.SetBounds(ScaleValue(16), ScaleValue(12), ScaleValue(16), ScaleValue(8));
  LCard.Height := ScaleValue(CTitleH + 4 * CRowH + 28);
  LCard.AlignWithMargins := True;
  LCard.Margins.SetBounds(0, ScaleValue(16), 0, 0);
  LCard.Top := LTop.Top + LTop.Height + 1;
  LCard.Align := alTop;
  LCard.Parent := Self;
  Title(LCard, 'Enquanto o foco está ligado');
  FPauseClip := Option('Pausar o histórico do clipboard', 'focus_clip', True);
  FMuteNotify := Option('Guardar os avisos do Devbox e das Issues para o fim', 'focus_notify', True);
  FMuteWindows := Option('Silenciar também os avisos do Windows (experimental)', 'focus_windows', False);
  FAutoMeeting := Option('Ligar sozinho em reunião (câmera ou microfone em uso por outro programa)',
    'focus_meeting', True);

  // Números: hoje e a semana, lado a lado.
  LStats := NewPanel(Self, alTop, CStatsH);
  LStats.Top := LCard.Top + LCard.Height + 1;
  LStats.Padding.SetBounds(0, ScaleValue(16), 0, 0);
  FTodayStat := TUIStat.Create(Self);
  FTodayStat.CardLabel := 'Foco hoje';
  FTodayStat.Tone := stPrimary;
  FTodayStat.Width := ScaleValue(240);
  FTodayStat.Align := alLeft;
  FTodayStat.Parent := LStats;
  FWeekChart := TUIChart.Create(Self);
  FWeekChart.Backend := cbSkia;
  FWeekChart.ChartType := ctBar;
  FWeekChart.Title := 'Minutos de foco, últimos 7 dias';
  FWeekChart.ShowLegend := False;
  FWeekChart.AlignWithMargins := True;
  FWeekChart.Margins.SetBounds(ScaleValue(16), 0, 0, 0);
  FWeekChart.Align := alClient;
  FWeekChart.Parent := LStats;
  FillStats;

  Title(Self, 'Histórico').Margins.SetBounds(0, ScaleValue(12), 0, 0);
  with TUIScrollArea.Create(Self) do
  begin
    Top := 100000;
    Align := alClient;
    Parent := Self;
    FHistory := TUITimeline.Create(Self);
    FHistory.Align := alTop;
    FHistory.Parent := InnerPanel;
  end;

  OptionChange(nil);
  FTick := TTimer.Create(Self);
  FTick.Interval := 1000;
  FTick.OnTimer := TickTimer;
  FTick.Enabled := False;
  FMeetingTimer := TTimer.Create(Self);
  FMeetingTimer.Interval := CMeetingCheckMs;
  FMeetingTimer.OnTimer := MeetingTimerTick;
  FMeetingTimer.Enabled := True;
  UpdateView;
end;

destructor TFocusPage.Destroy;
begin
  // Saindo do app com foco ligado: devolve os avisos do Windows como estavam.
  if FocusActive and FMuteWindows.Checked then
    SetWindowsToasts(FWindowsBefore);
  inherited;
end;

procedure TFocusPage.OptionChange(Sender: TObject);
begin
  if Sender is TUICheckbox then
    Store.SetSetting(TUICheckbox(Sender).HelpKeyword, IfThen(TUICheckbox(Sender).Checked, '1', '0'));
  FocusPauseClipboard := FPauseClip.Checked;
  FocusMuteNotify := FMuteNotify.Checked;
end;

procedure TFocusPage.StartFocus(AMinutes: Integer; AByMeeting: Boolean; const AWhy: string);
begin
  if FocusActive then
    StopFocus('');
  FocusActive := True;
  FocusQueue := nil;
  FByMeeting := AByMeeting;
  FStartedAt := Now;
  FTotalSec := AMinutes * 60;
  if AMinutes > 0 then
  begin
    FEndsAt := IncMinute(Now, AMinutes);
    FCountdown.StartFrom(FTotalSec);
    FCountdown.Start;  // StartFrom só define o tempo
  end
  else
    FEndsAt := 0;
  if FMuteWindows.Checked then
    FWindowsBefore := SetWindowsToasts(False);
  FHistory.AddEvent(FormatDateTime('dd/mm hh:nn', Now), 'Foco ligado', AWhy, '', stPrimary);
  FTick.Enabled := True;
  UpdateView;
  if Assigned(FOnChanged) then
    FOnChanged(Self);
end;

procedure TFocusPage.StopFocus(const AWhy: string);
var
  Pending: TArray<string>;
  Mins: Integer;
begin
  if not FocusActive then
    Exit;
  FocusActive := False;
  FTick.Enabled := False;
  FCountdown.Stop;
  if FMuteWindows.Checked then
    SetWindowsToasts(FWindowsBefore);
  Mins := MinutesBetween(Now, FStartedAt);
  // Reunião não conta como foco do Pomodoro.
  if not FByMeeting then
    Store.AddFocusSession(FStartedAt, Mins);
  FillStats;
  if AWhy <> '' then
    FHistory.AddEvent(FormatDateTime('dd/mm hh:nn', Now), Format('Foco encerrado (%d min)', [Mins]), AWhy, '',
      stSuccess);
  Pending := FocusQueue;
  FocusQueue := nil;
  UpdateView;
  if Pending <> nil then
    Notify(Format('%d avisos durante o foco', [Length(Pending)]), string.Join(#13#10, Copy(Pending, 0, 5)) +
      IfThen(Length(Pending) > 5, #13#10'…', ''));
  if Assigned(FOnChanged) then
    FOnChanged(Self);
end;

procedure TFocusPage.FillStats;
const
  CDays = 7;
var
  Mins: TArray<Integer>;
  Labels: TArray<string>;
  Values: TArray<Double>;
  I, Week: Integer;
begin
  Mins := Store.FocusMinutesPerDay(CDays);
  Labels := nil;
  Values := nil;
  Week := 0;
  for I := 0 to CDays - 1 do
  begin
    Labels := Labels + [FormatDateTime('ddd dd', Date - CDays + 1 + I)];
    Values := Values + [Mins[I]];
    Inc(Week, Mins[I]);
  end;
  FTodayStat.Value := Format('%d min', [Mins[CDays - 1]]);
  FTodayStat.SubText := Format('%d min na semana', [Week]);
  FWeekChart.SetSeries(Labels, [TUIChartSeries.Create('min', Values)]);
end;

procedure TFocusPage.StartTimed(AMinutes: Integer; const AWhy: string);
begin
  StartFocus(AMinutes, False, AWhy);
end;

procedure TFocusPage.StopBy(const AWhy: string);
begin
  StopFocus(AWhy);
end;

procedure TFocusPage.Toggle;
begin
  if FocusActive then
    StopFocus('desligado pela bandeja')
  else
    StartFocus(0, False, 'ligado pela bandeja');
end;

procedure TFocusPage.UpdateView;
begin
  FCountdown.Visible := FocusActive and (FEndsAt > 0);
  if not FocusActive then
  begin
    FState.Caption := 'Foco desligado';
    FRing.Value := 0;
  end
  else if FByMeeting then
    FState.Caption := 'Em reunião'
  else if FEndsAt > 0 then
    FState.Caption := 'Foco até ' + FormatDateTime('hh:nn', FEndsAt)
  else
    FState.Caption := 'Foco ligado';
  if FocusActive and (FEndsAt > 0) and (FTotalSec > 0) then
    FRing.Value := 100 * Max(0, SecondsBetween(FEndsAt, Now)) / FTotalSec
  else if FocusActive then
    FRing.Value := 100;
end;

procedure TFocusPage.TickTimer(Sender: TObject);
begin
  if FocusActive and (FEndsAt > 0) and (Now >= FEndsAt) then
  begin
    StopFocus('tempo acabou');
    Notify('Foco encerrado', 'Hora de uma pausa');
    Exit;
  end;
  UpdateView;
end;

procedure TFocusPage.MeetingTimerTick(Sender: TObject);
begin
  if not FAutoMeeting.Checked then
  begin
    FMeetingLabel.Caption := '';
    Exit;
  end;
  TTask.Run(
    procedure
    var
      Apps: TArray<string>;
    begin
      try
        Apps := AppsInMeeting;
      except
        Apps := nil;
      end;
      QueueUI(
        procedure
        begin
          if Apps <> nil then
          begin
            FMeetingLabel.Caption := 'Em uso agora: ' + string.Join(', ', Apps);
            if not FocusActive then
              StartFocus(0, True, 'câmera/microfone: ' + string.Join(', ', Apps));
          end
          else
          begin
            FMeetingLabel.Caption := 'Câmera e microfone livres';
            if FocusActive and FByMeeting then
              StopFocus('reunião acabou');
          end;
        end);
    end);
end;

procedure TFocusPage.FocusOpen(Sender: TObject);
begin
  StartFocus(0, False, 'até desligar');
end;

procedure TFocusPage.StopClick(Sender: TObject);
begin
  StopFocus('encerrado à mão');
end;

end.
