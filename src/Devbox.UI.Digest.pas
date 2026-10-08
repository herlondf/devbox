unit Devbox.UI.Digest;

{ Resumo do dia: agenda de hoje e e-mails importantes não lidos, resumidos pela
  IA numa hora marcada (ou no botão). O texto inteiro dos e-mails vai para a IA. }

interface

uses
  System.Classes,
  System.SysUtils,
  Vcl.ExtCtrls,
  UI.Labels,
  UI.Input,
  UI.Toggle,
  UI.Code,
  UI.Button,
  Devbox.Google,
  Devbox.MailSource,
  Devbox.UI.Kit;

type
  TDigestPage = class(TDevPage)
  private
    FOnToggle: TUIToggle;
    FTime: TUIInput;
    FWhen: TUILabel;
    FText: TUICode;
    FGenBtn: TUIButton;
    FTimer: TTimer;
    FRunning: Boolean;
    FOnTodayEvents: TFunc<TCalEvents>;
    procedure ToggleChange(Sender: TObject);
    procedure SaveTimeClick(Sender: TObject);
    procedure GenerateClick(Sender: TObject);
    procedure TimerTick(Sender: TObject);
    procedure ShowSaved;
    procedure Generate(AAuto: Boolean);
    function DueTime(out ATime: TDateTime): Boolean;
  public
    constructor Create(AOwner: TComponent); override;
    { Quem fornece os eventos de hoje (a tela Agenda). }
    property OnTodayEvents: TFunc<TCalEvents> read FOnTodayEvents write FOnTodayEvents;
  end;

implementation

uses
  System.StrUtils,
  System.Math,
  System.DateUtils,
  System.Threading,
  Vcl.Controls,
  UI.Toast,
  UI.ScrollArea,
  Devbox.Store,
  Devbox.AI,
  Devbox.Notify;

const
  CTickMs = 60 * 1000;
  CDefaultTime = '08:30';

constructor TDigestPage.Create(AOwner: TComponent);
var
  Row: TPanel;
  Scroll: TUIScrollArea;
begin
  inherited Create(AOwner);
  Caption := 'Resumo do dia';
  Hint := 'Agenda de hoje e e-mails importantes resumidos pela IA, uma vez por dia.';
  FOnToggle := NewToggleRow(Self, 'Gerar todo dia',
    'No horário abaixo (ou ao abrir o Devbox depois dele). Chega como aviso; o texto fica aqui.', ToggleChange);
  FOnToggle.OnChange := nil;
  FOnToggle.Checked := Store.GetSetting('digest_on', '0') = '1';
  FOnToggle.OnChange := ToggleChange;
  Row := NewPanel(Self, alTop, 54);
  Row.Padding.SetBounds(0, ScaleValue(6), 0, ScaleValue(6));
  FTime := TUIInput.Create(Self);
  FTime.LabelMode := ilmBorder;
  FTime.LabelText := 'Horário (hh:mm)';
  FTime.ReserveHintSpace := False;
  FTime.Value := Store.GetSetting('digest_time', CDefaultTime);
  FTime.Width := ScaleValue(140);
  FTime.AlignWithMargins := True;
  FTime.Margins.SetBounds(0, 0, ScaleValue(8), 0);
  FTime.Align := alLeft;
  FTime.Parent := Row;
  NewButton(Row, 'Salvar horário', SaveTimeClick);
  FGenBtn := NewButton(Row, 'Gerar agora', GenerateClick, bvPrimary);
  FWhen := NewHint(Self, '');
  Scroll := TUIScrollArea.Create(Self);
  Scroll.Top := 100000;
  Scroll.Align := alClient;
  Scroll.Parent := Self;
  FText := TUICode.Create(Self);
  FText.FontSize := 12;
  FText.Height := ScaleValue(560);
  FText.Align := alTop;
  FText.Parent := Scroll.InnerPanel;
  ShowSaved;
  FTimer := TTimer.Create(Self);
  FTimer.Interval := CTickMs;
  FTimer.OnTimer := TimerTick;
  FTimer.Enabled := True;
end;

procedure TDigestPage.ShowSaved;
var
  At: Double;
begin
  At := StrToFloatDef(Store.GetSetting('digest_at'), 0, TFormatSettings.Invariant);
  if At > 0 then
  begin
    FWhen.Caption := 'Resumo de ' + FormatDateTime('dd/mm/yyyy "às" hh:nn', At);
    FText.Text := Store.GetSetting('digest_text');
  end
  else
  begin
    FWhen.Caption := 'Nenhum resumo ainda';
    FText.Text := 'Clique em Gerar agora. Precisa de uma conta Google ligada e da IA configurada.';
  end;
end;

procedure TDigestPage.ToggleChange(Sender: TObject);
begin
  Store.SetSetting('digest_on', IfThen(FOnToggle.Checked, '1', '0'));
end;

function TDigestPage.DueTime(out ATime: TDateTime): Boolean;
var
  Parts: TArray<string>;
  H, M: Integer;
begin
  Parts := Trim(FTime.Value).Split([':']);
  Result := (Length(Parts) = 2) and TryStrToInt(Parts[0], H) and TryStrToInt(Parts[1], M) and InRange(H, 0, 23) and
    InRange(M, 0, 59);
  if Result then
    ATime := Date + EncodeTime(H, M, 0, 0);
end;

procedure TDigestPage.SaveTimeClick(Sender: TObject);
var
  T: TDateTime;
begin
  if not DueTime(T) then
  begin
    TUIToastManager.Show('Horário no formato hh:mm, ex.: 08:30', ttWarning, 3000);
    Exit;
  end;
  Store.SetSetting('digest_time', FormatDateTime('hh:nn', T));
  TUIToastManager.Show('Horário salvo', ttSuccess, 2000);
end;

procedure TDigestPage.TimerTick(Sender: TObject);
var
  T: TDateTime;
  At: Double;
begin
  if FRunning or (Store.GetSetting('digest_on', '0') <> '1') or not DueTime(T) or (Now < T) then
    Exit;
  At := StrToFloatDef(Store.GetSetting('digest_at'), 0, TFormatSettings.Invariant);
  if (Trunc(At) = Date) or (Store.GetSetting('digest_tried') = DateToStr(Date, TFormatSettings.Invariant)) then
    Exit;
  Generate(True);
end;

procedure TDigestPage.GenerateClick(Sender: TObject);
begin
  Generate(False);
end;

procedure TDigestPage.Generate(AAuto: Boolean);
var
  Config: TAIConfig;
  Accounts: TMailAccounts;
  Events: TCalEvents;
begin
  if FRunning then
    Exit;
  Config := LoadAIConfig;
  LoadGoogleClient;
  Accounts := LoadMailAccounts;
  Events := nil;
  if Assigned(FOnTodayEvents) then
    Events := FOnTodayEvents();
  // Só agenda por link (sem conta Google) também vale: o resumo sai sem e-mails.
  if ((Accounts = nil) and (Events = nil)) or not Config.Ready then
  begin
    if not AAuto then
      TUIToastManager.Show(IfThen(Config.Ready, 'Ligue uma conta ou um link iCal em Contas antes',
        'Configure a IA em Configurações antes'), ttWarning, 4000);
    Exit;
  end;
  FRunning := True;
  FGenBtn.Caption := 'Gerando...';
  TTask.Run(
    procedure
    var
      Err, Sys, Prompt, Answer: string;
      Msgs, One: TMailMsgs;
      Ok: Boolean;
      A: TMailAccount;
    begin
      Msgs := nil;
      try
        for A in Accounts do
          if SrcListDigest(A, One, Err) then
            Msgs := Msgs + One;
        Prompt := DigestPrompt(Events, Msgs, Sys);
        Ok := AskAI(Config, Sys, Prompt, Answer);
      except
        on E: Exception do
        begin
          Ok := False;
          Answer := E.Message;
        end;
      end;
      QueueUI(
        procedure
        begin
          FRunning := False;
          FGenBtn.Caption := 'Gerar agora';
          if not Ok then
          begin
            // Falhou no automático: não tenta de novo hoje (um aviso só); o botão continua valendo.
            if AAuto then
              Store.SetSetting('digest_tried', DateToStr(Date, TFormatSettings.Invariant));
            Notify('Resumo do dia', 'A IA não respondeu: ' + Answer, True);
            Exit;
          end;
          Store.SetSetting('digest_text', Answer);
          Store.SetSetting('digest_at', FloatToStr(Double(Now), TFormatSettings.Invariant));
          ShowSaved;
          Notify('Resumo do dia pronto', 'Abra o Devbox › Resumo do dia');
        end);
    end);
end;

end.
