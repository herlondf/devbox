unit Devbox.UI.Focus;

{ Modo foco/reunião: pausa o clipboard, segura os avisos do Devbox (saem
  juntos no fim) e pode silenciar os do Windows. Liga por tempo (25/50 min),
  até desligar, ou sozinho quando a câmera ou o microfone estão em uso. }

interface

uses
  System.Classes,
  System.SysUtils,
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
    procedure Focus25(Sender: TObject);
    procedure Focus50(Sender: TObject);
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
  UI.Tokens,
  UI.Toast,
  Devbox.Store,
  Devbox.Focus,
  Devbox.Envs,
  Devbox.Notify;

const
  CMeetingCheckMs = 10000;

constructor TFocusPage.Create(AOwner: TComponent);
var
  Top_, Left_, Opts, Bar: TPanel;

  function Option(const ACaption, ASetting: string; ADefault: Boolean): TUICheckbox;
  begin
    Result := TUICheckbox.Create(Self);
    Result.Caption := ACaption;
    Result.Checked := Store.GetSetting(ASetting, IfThen(ADefault, '1', '0')) = '1';
    Result.HelpKeyword := ASetting;
    Result.OnChange := OptionChange;
    Result.Height := ScaleValue(34);
    Result.Top := 100000;
    Result.Align := alTop;
    Result.Parent := Opts;
  end;

begin
  inherited Create(AOwner);
  Caption := 'Foco e reunião';
  Hint := 'Menos interrupção: clipboard em pausa e avisos guardados para depois';

  Top_ := NewPanel(Self, alTop, 300);
  Left_ := NewPanel(Top_, alLeft);
  Left_.Width := ScaleValue(260);
  FRing := TUIRadialProgress.Create(Self);
  FRing.RingSize := 180;
  FRing.StrokeWidth := 10;
  FRing.ShowPercent := False;
  FRing.Max := 100;
  FRing.Value := 0;
  FRing.Align := alClient;
  FRing.Parent := Left_;
  // Embaixo do anel: aparecer e sumir não mexe na ordem das opções.
  FCountdown := TUICountdown.Create(Self);
  FCountdown.ShowLabels := False;
  FCountdown.Height := ScaleValue(60);
  FCountdown.Visible := False;
  FCountdown.Align := alBottom;
  FCountdown.Parent := Left_;

  Opts := NewPanel(Top_, alClient);
  Opts.Padding.SetBounds(ScaleValue(20), 0, 0, 0);
  FState := TUILabel.Create(Self);
  FState.Bold := True;
  FState.FontSize := 18;
  FState.AutoSize := False;
  FState.Height := ScaleValue(32);
  FState.Align := alTop;
  FState.Parent := Opts;
  Bar := NewPanel(Opts, alTop, 50);
  Bar.Padding.SetBounds(0, ScaleValue(8), 0, ScaleValue(4));
  NewButton(Bar, 'Foco 25 min', Focus25, bvPrimary);
  NewButton(Bar, 'Foco 50 min', Focus50);
  NewButton(Bar, 'Até eu desligar', FocusOpen);
  NewButton(Bar, 'Encerrar', StopClick, bvGhost);
  FPauseClip := Option('Pausar o histórico do clipboard', 'focus_clip', True);
  FMuteNotify := Option('Guardar os avisos do Devbox para o fim', 'focus_notify', True);
  FMuteWindows := Option('Silenciar também os avisos do Windows (experimental)', 'focus_windows', False);
  FAutoMeeting := Option('Ligar sozinho quando a câmera ou o microfone estiverem em uso', 'focus_meeting', True);

  FMeetingLabel := NewHint(Self, '');
  Bar := NewPanel(Self, alTop, 150);
  Bar.Padding.SetBounds(0, ScaleValue(8), 0, ScaleValue(8));
  FTodayStat := TUIStat.Create(Self);
  FTodayStat.CardLabel := 'Foco hoje';
  FTodayStat.Width := ScaleValue(220);
  FTodayStat.Align := alLeft;
  FTodayStat.Parent := Bar;
  FWeekChart := TUIChart.Create(Self);
  FWeekChart.Backend := cbSkia;
  FWeekChart.ChartType := ctBar;
  FWeekChart.Title := 'Minutos de foco, últimos 7 dias';
  FWeekChart.ShowLegend := False;
  FWeekChart.AlignWithMargins := True;
  FWeekChart.Margins.SetBounds(ScaleValue(12), 0, 0, 0);
  FWeekChart.Align := alClient;
  FWeekChart.Parent := Bar;
  FillStats;
  with TUILabel.Create(Self) do
  begin
    Caption := 'Histórico';
    Bold := True;
    AutoSize := False;
    Height := ScaleValue(30);
    Top := 100000;
    Align := alTop;
    Parent := Self;
  end;
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
      System.Classes.TThread.Queue(nil,
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

procedure TFocusPage.Focus25(Sender: TObject);
begin
  StartFocus(25, False, '25 minutos');
end;

procedure TFocusPage.Focus50(Sender: TObject);
begin
  StartFocus(50, False, '50 minutos');
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
