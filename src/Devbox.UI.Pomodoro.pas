unit Devbox.UI.Pomodoro;

{ Pomodoro: trabalho e pausa em ciclos (25/5, pausa longa a cada 4). Pode ligar
  o modo foco durante o trabalho (a janela principal liga e desliga pela tela
  Foco). Avisa no fim de cada etapa e conta os pomodoros do dia. }

interface

uses
  System.Classes,
  System.SysUtils,
  Vcl.Controls,
  Vcl.ExtCtrls,
  UI.Labels,
  UI.Button,
  UI.Checkbox,
  UI.NumberInput,
  UI.RadialProgress,
  UI.Stat,
  UI.Card,
  Devbox.UI.Kit;

type
  TPomoPhase = (ppWork, ppShortBreak, ppLongBreak);
  TPomoWorkProc = reference to procedure(AMinutes: Integer);

  TPomodoroPage = class(TDevPage)
  private
    FRing: TUIRadialProgress;
    FPhaseLabel, FTimeLabel, FCycleLabel: TUILabel;
    FStartBtn: TUIButton;
    FWork, FShort, FLong, FEvery: TUINumberInput;
    FFocusOpt, FAutoOpt: TUICheckbox;
    FTodayStat, FMinutesStat: TUIStat;
    FTimer: TTimer;
    FPhase: TPomoPhase;
    FRunning: Boolean;
    FRemaining: Integer;      // segundos
    FTotal: Integer;
    FEndsAt: TDateTime;       // fim da etapa enquanto corre
    FDone: Integer;           // pomodoros terminados no ciclo atual
    FOnWorkStart: TPomoWorkProc;
    FOnWorkStop: TProc;
    FOnStatus: TProc<string>;
    procedure StartClick(Sender: TObject);
    procedure SkipClick(Sender: TObject);
    procedure ResetClick(Sender: TObject);
    procedure OptionChange(Sender: TObject);
    procedure TimerTick(Sender: TObject);
    procedure SetPhase(APhase: TPomoPhase);
    procedure Run;
    procedure Pause;
    procedure Finish;
    procedure UpdateView;
    procedure FillStats;
    function PhaseMinutes(APhase: TPomoPhase): Integer;
  public
    constructor Create(AOwner: TComponent); override;
    { F5 não se aplica; espaço começa ou pausa (tela na frente). }
    function PageKey(var AKey: Word; AShift: TShiftState): Boolean; override;
    function PageShortcuts: TArray<TDevShortcut>; override;
    { Trabalho começou (minutos que faltam) ou parou: liga e desliga o modo foco. }
    property OnWorkStart: TPomoWorkProc read FOnWorkStart write FOnWorkStart;
    property OnWorkStop: TProc read FOnWorkStop write FOnWorkStop;
    { Texto curto do estado ("Trabalho 12:40") enquanto corre; vazio parado. Vai para a bandeja. }
    property OnStatus: TProc<string> read FOnStatus write FOnStatus;
    { Começa ou pausa (bandeja, paleta). }
    procedure Toggle;
  end;

implementation

uses
  Winapi.Windows,
  System.StrUtils,
  System.Math,
  System.DateUtils,
  UI.Tokens,
  Devbox.Store,
  Devbox.Notify;

const
  CTickMs = 500;
  CRingBox = 240;
  CRingSize = 208;
  CRingStroke = 12;
  CRingInset = 16;
  CRowH = 70;            // rótulo (20) + campo numérico (44) + folga
  CSecPerMin = 60;
  CPhaseNames: array[TPomoPhase] of string = ('Trabalho', 'Pausa curta', 'Pausa longa');
  CDefaults: array[TPomoPhase] of Integer = (25, 5, 15);
  CSettings: array[TPomoPhase] of string = ('pomo_work', 'pomo_short', 'pomo_long');
  CDefaultEvery = 4;

constructor TPomodoroPage.Create(AOwner: TComponent);
var
  LTop, LRingHost, LInfo, LBar, LStats, LRow: TPanel;
  LCard: TUICard;

  function Number(const ALabel, ASetting: string; ADefault, AMax: Integer; const ASuffix: string): TUINumberInput;
  var
    LCaption: TUILabel;
    LHost: TPanel;
  begin
    LHost := NewPanel(LRow, alLeft);
    LHost.Width := ScaleValue(200);
    LHost.Padding.SetBounds(0, 0, ScaleValue(16), 0);
    LHost.Left := 100000;
    LCaption := TUILabel.Create(Self);
    LCaption.Caption := ALabel;
    LCaption.AutoSize := False;
    LCaption.Height := ScaleValue(20);
    LCaption.Align := alTop;
    LCaption.Parent := LHost;
    Result := TUINumberInput.Create(Self);
    Result.Min := 1;
    Result.Max := AMax;
    Result.SuffixText := ASuffix;
    Result.Value := StrToIntDef(Store.GetSetting(ASetting), ADefault);
    Result.HelpKeyword := ASetting;
    Result.OnChange := OptionChange;
    Result.Top := 100000;
    Result.Align := alTop;
    Result.Parent := LHost;
  end;

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
    Result.Parent := LCard;
  end;

begin
  inherited Create(AOwner);
  Caption := 'Pomodoro';
  Hint := 'Trabalho e pausa em ciclos. Espaço começa ou pausa.';

  LTop := NewPanel(Self, alTop, CRingBox);
  LTop.Top := 0;
  LRingHost := NewPanel(LTop, alLeft);
  LRingHost.Width := ScaleValue(CRingBox);
  FRing := TUIRadialProgress.Create(Self);
  FRing.RingSize := CRingSize;
  FRing.StrokeWidth := CRingStroke;
  FRing.TabStop := False;  // sem isto o anel de foco do teclado aparece em volta
  FRing.ShowPercent := False;
  FRing.AnimateValue := False;
  FRing.Max := 100;
  FRing.SetBounds(ScaleValue(CRingInset), ScaleValue(CRingInset), ScaleValue(CRingBox - 2 * CRingInset),
    ScaleValue(CRingBox - 2 * CRingInset));
  FRing.Parent := LRingHost;
  LInfo := NewPanel(LTop, alClient);
  LInfo.Padding.SetBounds(ScaleValue(24), ScaleValue(30), 0, 0);
  FPhaseLabel := TUILabel.Create(Self);
  FPhaseLabel.Bold := True;
  FPhaseLabel.FontSize := 18;
  FPhaseLabel.AutoSize := False;
  FPhaseLabel.Height := ScaleValue(30);
  FPhaseLabel.Align := alTop;
  FPhaseLabel.Parent := LInfo;
  FTimeLabel := TUILabel.Create(Self);
  FTimeLabel.Bold := True;
  FTimeLabel.FontSize := 44;
  FTimeLabel.AutoSize := False;
  FTimeLabel.Height := ScaleValue(64);
  FTimeLabel.Top := 100000;
  FTimeLabel.Align := alTop;
  FTimeLabel.Parent := LInfo;
  FCycleLabel := NewHint(LInfo, '');
  FCycleLabel.Top := 100000;
  LBar := NewPanel(LInfo, alTop, 52);
  LBar.Top := 100000;
  LBar.Padding.SetBounds(0, ScaleValue(8), 0, ScaleValue(4));
  FStartBtn := NewButton(LBar, 'Começar', StartClick, bvPrimary);
  NewButton(LBar, 'Pular etapa', SkipClick).Left := 100000;
  NewButton(LBar, 'Reiniciar', ResetClick, bvGhost).Left := 200000;

  LCard := TUICard.Create(Self);
  LCard.Variant := cvOutlined;
  LCard.CardPad := cpNone;
  LCard.Padding.SetBounds(ScaleValue(16), ScaleValue(12), ScaleValue(16), ScaleValue(8));
  LCard.Height := ScaleValue(30 + CRowH + 2 * 34 + 28);
  LCard.AlignWithMargins := True;
  LCard.Margins.SetBounds(0, ScaleValue(16), 0, 0);
  LCard.Top := LTop.Height + 1;
  LCard.Align := alTop;
  LCard.Parent := Self;
  with TUILabel.Create(Self) do
  begin
    Caption := 'Tempos e regras';
    Bold := True;
    AutoSize := False;
    Height := ScaleValue(30);
    Align := alTop;
    Parent := LCard;
  end;
  LRow := NewPanel(LCard, alTop, CRowH);
  LRow.Top := 100000;
  FWork := Number('Trabalho', CSettings[ppWork], CDefaults[ppWork], 120, 'min');
  FShort := Number('Pausa curta', CSettings[ppShortBreak], CDefaults[ppShortBreak], 60, 'min');
  FLong := Number('Pausa longa', CSettings[ppLongBreak], CDefaults[ppLongBreak], 60, 'min');
  FEvery := Number('Pausa longa a cada', 'pomo_every', CDefaultEvery, 12, 'pomodoros');
  FFocusOpt := Option('Ligar o modo foco durante o trabalho (pausa o clipboard e guarda os avisos)', 'pomo_focus', True);
  FAutoOpt := Option('Começar a próxima etapa sozinho', 'pomo_auto', False);

  LStats := NewPanel(Self, alTop, 150);  // mesma altura dos números do Foco
  LStats.Top := LCard.Top + LCard.Height + 1;
  LStats.Padding.SetBounds(0, ScaleValue(16), 0, 0);
  FTodayStat := TUIStat.Create(Self);
  FTodayStat.CardLabel := 'Pomodoros hoje';
  FTodayStat.Tone := stPrimary;
  FTodayStat.Width := ScaleValue(240);
  FTodayStat.Align := alLeft;
  FTodayStat.Parent := LStats;
  FMinutesStat := TUIStat.Create(Self);
  FMinutesStat.CardLabel := 'Minutos de trabalho hoje';
  FMinutesStat.Tone := stSuccess;
  FMinutesStat.Width := ScaleValue(240);
  FMinutesStat.AlignWithMargins := True;
  FMinutesStat.Margins.SetBounds(ScaleValue(12), 0, 0, 0);
  FMinutesStat.Left := 100000;
  FMinutesStat.Align := alLeft;
  FMinutesStat.Parent := LStats;

  FTimer := TTimer.Create(Self);
  FTimer.Interval := CTickMs;
  FTimer.OnTimer := TimerTick;
  FTimer.Enabled := False;
  SetPhase(ppWork);
  FillStats;
end;

function TPomodoroPage.PhaseMinutes(APhase: TPomoPhase): Integer;
begin
  case APhase of
    ppWork: Result := Round(FWork.Value);
    ppShortBreak: Result := Round(FShort.Value);
  else
    Result := Round(FLong.Value);
  end;
end;

procedure TPomodoroPage.SetPhase(APhase: TPomoPhase);
begin
  FPhase := APhase;
  FTotal := PhaseMinutes(APhase) * CSecPerMin;
  FRemaining := FTotal;
  UpdateView;
end;

procedure TPomodoroPage.Run;
begin
  FRunning := True;
  FEndsAt := IncSecond(Now, FRemaining);
  FTimer.Enabled := True;
  if (FPhase = ppWork) and FFocusOpt.Checked and Assigned(FOnWorkStart) then
    FOnWorkStart(Ceil(FRemaining / CSecPerMin));
  UpdateView;
end;

procedure TPomodoroPage.Pause;
begin
  FRunning := False;
  FTimer.Enabled := False;
  FRemaining := Max(0, SecondsBetween(FEndsAt, Now));
  if (FPhase = ppWork) and FFocusOpt.Checked and Assigned(FOnWorkStop) then
    FOnWorkStop();
  UpdateView;
end;

procedure TPomodoroPage.Finish;
var
  LNext: TPomoPhase;
  LToday: string;
begin
  FRunning := False;
  FTimer.Enabled := False;
  // O foco sai antes do aviso (aviso durante o foco ficaria guardado para depois).
  if (FPhase = ppWork) and FFocusOpt.Checked and Assigned(FOnWorkStop) then
    FOnWorkStop();
  if FPhase = ppWork then
  begin
    Inc(FDone);
    LToday := FormatDateTime('yyyy-mm-dd', Date);
    if Store.GetSetting('pomo_day') <> LToday then
    begin
      Store.SetSetting('pomo_day', LToday);
      Store.SetSetting('pomo_today', '0');
      Store.SetSetting('pomo_minutes', '0');
    end;
    Store.SetSetting('pomo_today', IntToStr(StrToIntDef(Store.GetSetting('pomo_today'), 0) + 1));
    Store.SetSetting('pomo_minutes', IntToStr(StrToIntDef(Store.GetSetting('pomo_minutes'), 0) +
      FTotal div CSecPerMin));
    FillStats;
    if FDone mod Max(1, Round(FEvery.Value)) = 0 then
      LNext := ppLongBreak
    else
      LNext := ppShortBreak;
    Notify('Pomodoro feito', Format('Hora da %s: %d min', [AnsiLowerCase(CPhaseNames[LNext]),
      PhaseMinutes(LNext)]));
  end
  else
  begin
    LNext := ppWork;
    Notify('Pausa acabou', Format('De volta ao trabalho: %d min', [PhaseMinutes(ppWork)]));
  end;
  MessageBeep(MB_ICONASTERISK);
  SetPhase(LNext);
  if FAutoOpt.Checked then
    Run;
end;

procedure TPomodoroPage.TimerTick(Sender: TObject);
begin
  FRemaining := Max(0, SecondsBetween(FEndsAt, Now));
  if Now >= FEndsAt then
    Finish
  else
    UpdateView;
end;

procedure TPomodoroPage.UpdateView;
var
  LEvery: Integer;
begin
  FPhaseLabel.Caption := CPhaseNames[FPhase] + IfThen(not FRunning and (FRemaining < FTotal), ' (pausado)', '');
  FTimeLabel.Caption := Format('%.2d:%.2d', [FRemaining div CSecPerMin, FRemaining mod CSecPerMin]);
  LEvery := Max(1, Round(FEvery.Value));
  FCycleLabel.Caption := Format('Pomodoro %d de %d até a pausa longa', [FDone mod LEvery + Ord(FPhase = ppWork),
    LEvery]);
  if FTotal > 0 then
    FRing.Value := 100 * FRemaining / FTotal
  else
    FRing.Value := 0;
  if Assigned(FOnStatus) then
    if FRunning then
      FOnStatus(CPhaseNames[FPhase] + ' ' + FTimeLabel.Caption)
    else
      FOnStatus('');
  if FRunning then
    FStartBtn.Caption := 'Pausar'
  else if FRemaining < FTotal then
    FStartBtn.Caption := 'Continuar'
  else
    FStartBtn.Caption := 'Começar';
end;

procedure TPomodoroPage.FillStats;
var
  LToday: Boolean;
begin
  LToday := Store.GetSetting('pomo_day') = FormatDateTime('yyyy-mm-dd', Date);
  FTodayStat.Value := IfThen(LToday, Store.GetSetting('pomo_today', '0'), '0');
  FTodayStat.SubText := 'terminados';
  FMinutesStat.Value := IfThen(LToday, Store.GetSetting('pomo_minutes', '0'), '0') + ' min';
  FMinutesStat.SubText := 'só os pomodoros completos';
end;

procedure TPomodoroPage.StartClick(Sender: TObject);
begin
  if FRunning then
    Pause
  else
    Run;
end;

procedure TPomodoroPage.SkipClick(Sender: TObject);
begin
  if FRunning and (FPhase = ppWork) and FFocusOpt.Checked and Assigned(FOnWorkStop) then
    FOnWorkStop();
  FRunning := False;
  FTimer.Enabled := False;
  if FPhase = ppWork then
    SetPhase(ppShortBreak)
  else
    SetPhase(ppWork);
end;

procedure TPomodoroPage.ResetClick(Sender: TObject);
begin
  if FRunning and (FPhase = ppWork) and FFocusOpt.Checked and Assigned(FOnWorkStop) then
    FOnWorkStop();
  FRunning := False;
  FTimer.Enabled := False;
  FDone := 0;
  SetPhase(ppWork);
end;

procedure TPomodoroPage.OptionChange(Sender: TObject);
begin
  if Sender is TUICheckbox then
    Store.SetSetting(TUICheckbox(Sender).HelpKeyword, IfThen(TUICheckbox(Sender).Checked, '1', '0'))
  else if Sender is TUINumberInput then
  begin
    Store.SetSetting(TUINumberInput(Sender).HelpKeyword, IntToStr(Round(TUINumberInput(Sender).Value)));
    // Tempo novo vale já se a etapa ainda não começou.
    if not FRunning and (FRemaining = FTotal) then
      SetPhase(FPhase)
    else
      UpdateView;
  end;
end;

procedure TPomodoroPage.Toggle;
begin
  StartClick(nil);
end;

function TPomodoroPage.PageShortcuts: TArray<TDevShortcut>;
begin
  Result := [DevShortcut('Espaço', 'Começar ou pausar', procedure begin StartClick(nil); end)];
end;

function TPomodoroPage.PageKey(var AKey: Word; AShift: TShiftState): Boolean;
begin
  Result := (AKey = VK_SPACE) and (AShift = []);
  if Result then
    StartClick(nil);
end;

end.
