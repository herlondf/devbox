unit Devbox.UI.AISettings;

{ Configuração › IA: abas Interna (a IA das ações de texto), Voz (aparelhos,
  frase, motores, conversa ao vivo e o log do que o ouvido entende) e Custos
  (uso e custo das IAs pagas). }

interface

uses
  System.Classes,
  Vcl.Controls,
  Vcl.ExtCtrls,
  UI.ScrollArea,
  UI.Tabs,
  UI.Toggle,
  UI.Input,
  UI.Select,
  UI.Labels,
  UI.Code,
  UI.DataTable,
  Devbox.Speech,
  Devbox.UI.Kit;

type
  TAISettingsPage = class(TDevPage)
  private
    FTabs: TUITabs;
    FViews: array[0..2] of TUIScrollArea;
    // Interna
    FAIProvider: TUISelect;
    FAIBase, FAIModel, FAIKey: TUIInput;
    // Voz
    FVoiceToggle: TUIToggle;
    FVoiceSense: TUISelect;
    FVoicePhrase: TUIInput;
    FInDevice, FOutDevice: TUISelect;
    FVoiceStt: TUISelect;
    FVoiceKey: TUIInput;
    FLiveMode: TUISelect;
    FLiveModel, FLiveKey: TUIInput;
    FLog: TUICode;
    FLogVersion: Integer;
    FTestPlayer: TPcmPlayer;
    // Custos
    FCostSummary: TUILabel;
    FCostTable: TUIDataTable;
    FPriceModel: TUISelect;
    FPriceText, FMonthCap: TUIInput;
    FTimer: TTimer;
    FOnVoiceChanged: TNotifyEvent;
    FOnVoiceTalk: TNotifyEvent;
    function Body(AIndex: Integer): TWinControl;
    function NewTitle(AParent: TWinControl; const ACaption: string): TUILabel;
    procedure TabChange(Sender: TObject; AIndex: Integer);
    procedure UpdateContentHeight(AIndex: Integer);
    procedure BuildInternal;
    procedure BuildVoice;
    procedure BuildCosts;
    procedure TimerTick(Sender: TObject);
    procedure VoiceChanged;
    // Interna
    procedure LoadAIFields;
    procedure AIProviderChange(Sender: TObject);
    procedure AISaveClick(Sender: TObject);
    procedure AITestClick(Sender: TObject);
    // Voz
    procedure VoiceToggleChange(Sender: TObject);
    procedure VoiceSenseChange(Sender: TObject);
    procedure VoicePhraseSave(Sender: TObject);
    procedure VoiceTalkClick(Sender: TObject);
    procedure DeviceChange(Sender: TObject);
    procedure OutputTestClick(Sender: TObject);
    procedure VoiceSttChange(Sender: TObject);
    procedure VoiceKeySave(Sender: TObject);
    procedure LoadVoiceKeyField;
    procedure LiveModeChange(Sender: TObject);
    procedure LiveSave(Sender: TObject);
    procedure LoadLiveFields;
    procedure LogClear(Sender: TObject);
    // Custos
    procedure RefreshCosts;
    procedure PriceModelChange(Sender: TObject);
    procedure PriceSave(Sender: TObject);
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure PageShown; override;
    procedure PageHidden; override;
    procedure SetVoiceOn(AOn: Boolean);
    { Interruptor, frase, aparelhos, motor ou conversa mudaram (a janela principal aplica). }
    property OnVoiceChanged: TNotifyEvent read FOnVoiceChanged write FOnVoiceChanged;
    property OnVoiceTalk: TNotifyEvent read FOnVoiceTalk write FOnVoiceTalk;
  end;

{ Grava no banco o uso de IA que estava na fila (thread de UI). }
procedure FlushAIUsage;

implementation

uses
  System.SysUtils,
  System.StrUtils,
  System.Math,
  System.DateUtils,
  System.Threading,
  UI.Toast,
  UI.Button,
  UI.Audio.Capture,
  Devbox.AI,
  Devbox.Secrets,
  Devbox.Vosk,
  Devbox.Whisper,
  Devbox.Realtime,
  Devbox.Voice,
  Devbox.Usage,
  Devbox.Store;

const
  CTabNames: array[0..2] of string = ('Interna', 'Voz', 'Custos');
  CTabInternal = 0;
  CTabVoice = 1;
  CTabCosts = 2;
  CTickMs = 500;
  CDefaultDevice = 'Padrão do Windows';
  CLogHeight = 300;
  CDaysWeek = 7;

procedure FlushAIUsage;
var
  LUsage: TAiUsage;
begin
  for LUsage in UsageTake do
    Store.AddUsage(LUsage);
end;

{ TAISettingsPage }

constructor TAISettingsPage.Create(AOwner: TComponent);
var
  LIndex: Integer;
begin
  inherited Create(AOwner);
  Caption := 'IA';
  Hint := 'A IA das ações de texto, a voz do assistente e quanto as IAs pagas custaram';
  FTabs := TUITabs.Create(Self);
  for LIndex := 0 to High(CTabNames) do
    FTabs.AddTab(CTabNames[LIndex]);
  FTabs.Align := alTop;
  FTabs.Parent := Self;
  FTabs.OnChange := TabChange;
  for LIndex := 0 to High(FViews) do
  begin
    FViews[LIndex] := TUIScrollArea.Create(Self);
    FViews[LIndex].Top := 100000;
    FViews[LIndex].Align := alClient;
    FViews[LIndex].Visible := False;
    FViews[LIndex].Parent := Self;
  end;
  BuildInternal;
  BuildVoice;
  BuildCosts;
  FTimer := TTimer.Create(Self);
  FTimer.Interval := CTickMs;
  FTimer.OnTimer := TimerTick;
  // O uso de IA chega de qualquer thread; o timer grava sempre (a tela pode estar escondida).
  FTimer.Enabled := True;
  FTabs.ActiveIndex := CTabInternal;
  TabChange(nil, CTabInternal);
end;

destructor TAISettingsPage.Destroy;
begin
  FTestPlayer.Free;
  inherited;
end;

function TAISettingsPage.Body(AIndex: Integer): TWinControl;
begin
  Result := FViews[AIndex].InnerPanel;
end;

function TAISettingsPage.NewTitle(AParent: TWinControl; const ACaption: string): TUILabel;
begin
  Result := TUILabel.Create(Self);
  Result.Caption := ACaption;
  Result.Bold := True;
  Result.FontSize := 15;
  Result.AutoSize := False;
  Result.Height := ScaleValue(40);
  Result.Top := 100000;
  Result.Align := alTop;
  Result.Parent := AParent;
end;

procedure TAISettingsPage.TabChange(Sender: TObject; AIndex: Integer);
var
  LIndex: Integer;
begin
  for LIndex := 0 to High(FViews) do
    FViews[LIndex].Visible := LIndex = AIndex;
  UpdateContentHeight(AIndex);
  if AIndex = CTabCosts then
    RefreshCosts;
end;

{ Altura do conteúdo = fim do último controle (a área de rolagem não mede sozinha). }
procedure TAISettingsPage.UpdateContentHeight(AIndex: Integer);
var
  LIndex, LBottom: Integer;
  LControl: TControl;
  LBody: TWinControl;
begin
  LBody := Body(AIndex);
  LBottom := 0;
  for LIndex := 0 to LBody.ControlCount - 1 do
  begin
    LControl := LBody.Controls[LIndex];
    if LControl.Visible then
      LBottom := Max(LBottom, LControl.Top + LControl.Height + LControl.Margins.Bottom);
  end;
  FViews[AIndex].ContentHeight := LBottom + ScaleValue(24);
end;

procedure TAISettingsPage.PageShown;
begin
  inherited;
  UpdateContentHeight(FTabs.ActiveIndex);
end;

procedure TAISettingsPage.PageHidden;
begin
  inherited;
end;

procedure TAISettingsPage.TimerTick(Sender: TObject);
var
  LVersion: Integer;
  LText: string;
begin
  FlushAIUsage;
  if not Visible or (FTabs.ActiveIndex <> CTabVoice) then
    Exit;
  LText := VoiceLogText(LVersion);
  if LVersion <> FLogVersion then
  begin
    FLogVersion := LVersion;
    FLog.Text := LText;
  end;
end;

procedure TAISettingsPage.VoiceChanged;
begin
  if Assigned(FOnVoiceChanged) then
    FOnVoiceChanged(Self);
end;

{ Interna }

procedure TAISettingsPage.BuildInternal;
var
  LBody: TWinControl;
  LRow: TPanel;
begin
  LBody := Body(CTabInternal);
  NewTitle(LBody, 'IA das ações de texto');
  NewHint(LBody, 'Usada no botão IA… do Clipboard, em Explicar com IA nos logs, no Comando por IA e no pedido ' +
    'único por voz. O texto só vai para a IA quando você pede.');
  LRow := NewPanel(LBody, alTop, 54);
  LRow.Padding.SetBounds(0, ScaleValue(8), 0, ScaleValue(4));
  FAIProvider := TUISelect.Create(Self);
  FAIProvider.Items.Add(AIProviderNames[apAnthropic]);
  FAIProvider.Items.Add(AIProviderNames[apOpenAI]);
  FAIProvider.Width := ScaleValue(240);
  FAIProvider.AlignWithMargins := True;
  FAIProvider.Margins.SetBounds(0, 0, ScaleValue(8), 0);
  FAIProvider.Align := alLeft;
  FAIProvider.Parent := LRow;
  FAIModel := TUIInput.Create(Self);
  FAIModel.LabelMode := ilmBorder;
  FAIModel.LabelText := 'Modelo';
  FAIModel.ReserveHintSpace := False;
  FAIModel.Width := ScaleValue(240);
  FAIModel.AlignWithMargins := True;
  FAIModel.Margins.SetBounds(0, 0, ScaleValue(8), 0);
  FAIModel.Left := 1000;
  FAIModel.Align := alLeft;
  FAIModel.Parent := LRow;
  FAIBase := TUIInput.Create(Self);
  FAIBase.LabelMode := ilmBorder;
  FAIBase.LabelText := 'Endereço (compatível com OpenAI, ex.: http://localhost:11434/v1)';
  FAIBase.ReserveHintSpace := False;
  FAIBase.Align := alClient;
  FAIBase.Parent := LRow;
  LRow := NewPanel(LBody, alTop, 54);
  LRow.Padding.SetBounds(0, ScaleValue(4), 0, ScaleValue(4));
  NewButton(LRow, 'Testar', AITestClick, bvGhost, alRight);
  NewButton(LRow, 'Salvar', AISaveClick, bvPrimary, alRight);
  FAIKey := TUIInput.Create(Self);
  FAIKey.LabelMode := ilmBorder;
  FAIKey.LabelText := 'Chave (fica no Credential Manager do Windows, não no banco)';
  FAIKey.ReserveHintSpace := False;
  FAIKey.PasswordChar := '*';
  FAIKey.PasswordToggle := True;
  FAIKey.Align := alClient;
  FAIKey.Parent := LRow;
  LoadAIFields;
  FAIProvider.OnChange := AIProviderChange;
end;

procedure TAISettingsPage.LoadAIFields;
var
  C: TAIConfig;
begin
  C := LoadAIConfig;
  FAIProvider.ItemIndex := Ord(C.Provider);
  FAIModel.Value := C.Model;
  FAIBase.Value := C.BaseUrl;
  FAIBase.Visible := C.Provider = apOpenAI;
  // A chave não volta para a tela: só se sabe que existe.
  FAIKey.Value := '';
  if C.Key <> '' then
    FAIKey.LabelText := 'Chave salva no Credential Manager (deixe em branco para manter)'
  else
    FAIKey.LabelText := 'Chave (fica no Credential Manager do Windows, não no banco)';
end;

procedure TAISettingsPage.AIProviderChange(Sender: TObject);
begin
  Store.SetSetting('ai_provider', IntToStr(Max(FAIProvider.ItemIndex, 0)));
  Store.SetSetting('ai_model', '');
  LoadAIFields;
end;

procedure TAISettingsPage.AISaveClick(Sender: TObject);
begin
  Store.SetSetting('ai_provider', IntToStr(Max(FAIProvider.ItemIndex, 0)));
  Store.SetSetting('ai_model', Trim(FAIModel.Value));
  Store.SetSetting('ai_base_url', Trim(FAIBase.Value));
  if Trim(FAIKey.Value) <> '' then
    SaveAIKey(TAIProvider(Max(FAIProvider.ItemIndex, 0)), Trim(FAIKey.Value));
  LoadAIFields;
  TUIToastManager.Show('IA salva', ttSuccess, 2000);
end;

procedure TAISettingsPage.AITestClick(Sender: TObject);
var
  C: TAIConfig;
begin
  AISaveClick(nil);
  C := LoadAIConfig;
  TUIToastManager.Show('Testando a IA...', ttLoading, 3000);
  TTask.Run(
    procedure
    var
      Answer: string;
      Ok: Boolean;
    begin
      try
        Ok := AskAI(C, 'Responda só com: ok', 'teste', Answer);
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
          if Ok then
            TUIToastManager.Show('IA respondeu: ' + Copy(Answer, 1, 60), ttSuccess, 4000)
          else
            TUIToastManager.Show('IA não respondeu: ' + Answer, ttError, 7000);
        end);
    end);
end;

{ Voz }

function DeviceSelect(AOwner: TComponent; const ANames: TArray<string>; const ASaved: string): TUISelect;
var
  LName: string;
begin
  Result := TUISelect.Create(AOwner);
  Result.Items.Add(CDefaultDevice);
  for LName in ANames do
    Result.Items.Add(LName);
  Result.ItemIndex := Max(0, Result.Items.IndexOf(ASaved));
end;

procedure TAISettingsPage.BuildVoice;
var
  LBody: TWinControl;
  LRow: TPanel;
  LEngine: TSttEngine;
begin
  LBody := Body(CTabVoice);
  NewTitle(LBody, 'Assistente de voz');
  FVoiceToggle := NewToggleRow(LBody, 'Ouvir a frase de ativação',
    'O microfone fica ligado e a frase é conferida aqui mesmo (Vosk). A voz do Devbox é tirada do microfone ' +
    '(cancelamento de eco), então dá para usar sem fone.', nil);
  FVoiceToggle.Checked := Store.GetSetting('voice_on', '0') = '1';
  FVoiceToggle.OnChange := VoiceToggleChange;
  LRow := NewPanel(LBody, alTop, 54);
  LRow.Padding.SetBounds(0, ScaleValue(8), 0, ScaleValue(4));
  NewButton(LRow, 'Falar agora (sem a frase)', VoiceTalkClick, bvOutline, alRight);
  NewButton(LRow, 'Salvar frase', VoicePhraseSave, bvOutline, alRight);
  FVoicePhrase := TUIInput.Create(Self);
  FVoicePhrase.LabelMode := ilmBorder;
  FVoicePhrase.LabelText := 'Frase de ativação (ex.: Oi Java)';
  FVoicePhrase.ReserveHintSpace := False;
  FVoicePhrase.Value := Store.GetSetting('voice_phrase', VoiceDefaultPhrase);
  FVoicePhrase.Width := ScaleValue(240);
  FVoicePhrase.AlignWithMargins := True;
  FVoicePhrase.Margins.SetBounds(0, 0, ScaleValue(8), 0);
  FVoicePhrase.Align := alLeft;
  FVoicePhrase.Parent := LRow;
  FVoiceSense := TUISelect.Create(Self);
  FVoiceSense.Items.Add('Aceita parecido (mais falso alarme)');
  FVoiceSense.Items.Add('Equilibrado');
  FVoiceSense.Items.Add('Precisa ser bem igual');
  FVoiceSense.ItemIndex := EnsureRange(StrToIntDef(Store.GetSetting('voice_sense', '1'), 1), 0, 2);
  FVoiceSense.Width := ScaleValue(260);
  FVoiceSense.Left := 100000;
  FVoiceSense.Align := alLeft;
  FVoiceSense.Parent := LRow;
  FVoiceSense.OnChange := VoiceSenseChange;

  NewHint(LBody, 'Aparelhos: de onde vem o comando e por onde sai a voz (pedido único e conversa ao vivo).');
  LRow := NewPanel(LBody, alTop, 54);
  LRow.Padding.SetBounds(0, ScaleValue(8), 0, ScaleValue(4));
  NewButton(LRow, 'Testar saída', OutputTestClick, bvOutline, alRight);
  FInDevice := DeviceSelect(Self, TUIAudioCapture.DeviceNames, Store.GetSetting('voice_in_dev'));
  FInDevice.Width := ScaleValue(360);
  FInDevice.AlignWithMargins := True;
  FInDevice.Margins.SetBounds(0, 0, ScaleValue(8), 0);
  FInDevice.Align := alLeft;
  FInDevice.Parent := LRow;
  FInDevice.OnChange := DeviceChange;
  FOutDevice := DeviceSelect(Self, OutputDeviceNames, Store.GetSetting('voice_out_dev'));
  FOutDevice.Width := ScaleValue(360);
  FOutDevice.Left := 100000;
  FOutDevice.Align := alLeft;
  FOutDevice.Parent := LRow;
  FOutDevice.OnChange := DeviceChange;

  NewHint(LBody, 'Quem transforma o pedido falado em texto (no modo pedido único).');
  LRow := NewPanel(LBody, alTop, 54);
  LRow.Padding.SetBounds(0, ScaleValue(8), 0, ScaleValue(4));
  NewButton(LRow, 'Salvar chave', VoiceKeySave, bvOutline, alRight);
  FVoiceStt := TUISelect.Create(Self);
  for LEngine := Low(TSttEngine) to High(TSttEngine) do
    FVoiceStt.Items.Add(SttEngineNames[LEngine]);
  FVoiceStt.ItemIndex := EnsureRange(StrToIntDef(Store.GetSetting('voice_stt', '0'), 0), 0, Ord(High(TSttEngine)));
  FVoiceStt.Width := ScaleValue(380);
  FVoiceStt.AlignWithMargins := True;
  FVoiceStt.Margins.SetBounds(0, 0, ScaleValue(8), 0);
  FVoiceStt.Align := alLeft;
  FVoiceStt.Parent := LRow;
  FVoiceStt.OnChange := VoiceSttChange;
  FVoiceKey := TUIInput.Create(Self);
  FVoiceKey.LabelMode := ilmBorder;
  FVoiceKey.ReserveHintSpace := False;
  FVoiceKey.PasswordChar := '*';
  FVoiceKey.PasswordToggle := True;
  FVoiceKey.AlignWithMargins := True;
  FVoiceKey.Margins.SetBounds(0, 0, ScaleValue(8), 0);
  FVoiceKey.Align := alClient;
  FVoiceKey.Parent := LRow;
  LoadVoiceKeyField;

  NewHint(LBody, 'Depois da frase: um pedido e uma resposta, ou conversa ao vivo com a OpenAI ou o Gemini ' +
    '(fala e escuta ao mesmo tempo; dá para interromper).');
  LRow := NewPanel(LBody, alTop, 54);
  LRow.Padding.SetBounds(0, ScaleValue(8), 0, ScaleValue(4));
  NewButton(LRow, 'Salvar conversa', LiveSave, bvOutline, alRight);
  FLiveMode := TUISelect.Create(Self);
  FLiveMode.Items.Add('Pedido único (transcreve e responde)');
  FLiveMode.Items.Add('Conversa ao vivo: OpenAI Realtime');
  FLiveMode.Items.Add('Conversa ao vivo: Gemini Live');
  FLiveMode.ItemIndex := EnsureRange(StrToIntDef(Store.GetSetting('voice_live', '0'), 0), 0, 2);
  FLiveMode.Width := ScaleValue(300);
  FLiveMode.AlignWithMargins := True;
  FLiveMode.Margins.SetBounds(0, 0, ScaleValue(8), 0);
  FLiveMode.Align := alLeft;
  FLiveMode.Parent := LRow;
  FLiveMode.OnChange := LiveModeChange;
  FLiveModel := TUIInput.Create(Self);
  FLiveModel.LabelMode := ilmBorder;
  FLiveModel.ReserveHintSpace := False;
  FLiveModel.Width := ScaleValue(200);
  FLiveModel.AlignWithMargins := True;
  FLiveModel.Margins.SetBounds(0, 0, ScaleValue(8), 0);
  FLiveModel.Left := 100000;
  FLiveModel.Align := alLeft;
  FLiveModel.Parent := LRow;
  FLiveKey := TUIInput.Create(Self);
  FLiveKey.LabelMode := ilmBorder;
  FLiveKey.ReserveHintSpace := False;
  FLiveKey.PasswordChar := '*';
  FLiveKey.PasswordToggle := True;
  FLiveKey.AlignWithMargins := True;
  FLiveKey.Margins.SetBounds(0, 0, ScaleValue(8), 0);
  FLiveKey.Align := alClient;
  FLiveKey.Parent := LRow;
  LoadLiveFields;

  NewTitle(LBody, 'O que o ouvido está entendendo');
  LRow := NewPanel(LBody, alTop, 40);
  LRow.Padding.SetBounds(0, 0, 0, ScaleValue(4));
  NewHint(LRow, 'Ao vivo: cada fala, o que o Vosk ouviu e se bateu com a frase. Fica só na memória (últimas ' +
    '300 linhas), não vai para disco.', alClient);
  NewButton(LRow, 'Limpar', LogClear, bvGhost, alRight);
  FLog := TUICode.Create(Self);
  FLog.FontSize := 12;
  FLog.Height := ScaleValue(CLogHeight);
  FLog.Top := 100000;
  FLog.Align := alTop;
  FLog.Parent := LBody;
end;

procedure TAISettingsPage.LogClear(Sender: TObject);
begin
  FLog.Text := '';
end;

procedure TAISettingsPage.SetVoiceOn(AOn: Boolean);
begin
  FVoiceToggle.OnChange := nil;
  FVoiceToggle.Checked := AOn;
  FVoiceToggle.OnChange := VoiceToggleChange;
end;

procedure TAISettingsPage.VoiceToggleChange(Sender: TObject);
begin
  Store.SetSetting('voice_on', IfThen(FVoiceToggle.Checked, '1', '0'));
  VoiceChanged;
end;

procedure TAISettingsPage.VoiceSenseChange(Sender: TObject);
begin
  Store.SetSetting('voice_sense', IntToStr(Max(0, FVoiceSense.ItemIndex)));
  VoiceChanged;
end;

procedure TAISettingsPage.DeviceChange(Sender: TObject);
begin
  // Guarda o nome: o índice muda quando se pluga outro aparelho.
  if FInDevice.ItemIndex > 0 then
    Store.SetSetting('voice_in_dev', FInDevice.Items[FInDevice.ItemIndex])
  else
    Store.SetSetting('voice_in_dev', '');
  if FOutDevice.ItemIndex > 0 then
    Store.SetSetting('voice_out_dev', FOutDevice.Items[FOutDevice.ItemIndex])
  else
    Store.SetSetting('voice_out_dev', '');
  VoiceChanged;
end;

{ Fala uma frase no aparelho de saída escolhido (o mesmo da conversa). }
procedure TAISettingsPage.OutputTestClick(Sender: TObject);
begin
  DeviceChange(nil);
  TUIToastManager.Show('Falando no aparelho de saída...', ttLoading, 2500);
  TTask.Run(
    procedure
    var
      LPcm: TArray<SmallInt>;
      LError: string;
      LOk: Boolean;
    begin
      LOk := Synthesize('Teste de voz do Devbox. Se você está ouvindo, a saída está certa.', LPcm, LError);
      QueueUI(
        procedure
        begin
          if not LOk then
          begin
            TUIToastManager.Show('Voz do Windows falhou: ' + LError, ttError, 6000);
            Exit;
          end;
          if FTestPlayer = nil then
            FTestPlayer := TPcmPlayer.Create;
          FTestPlayer.Play(LPcm);
        end);
    end);
end;

procedure TAISettingsPage.VoicePhraseSave(Sender: TObject);
var
  LPhrase: string;
begin
  if Trim(FVoicePhrase.Value) = '' then
  begin
    TUIToastManager.Show('Escreva a frase de ativação', ttWarning, 2500);
    Exit;
  end;
  Store.SetSetting('voice_phrase', Trim(FVoicePhrase.Value));
  VoiceChanged;
  LPhrase := Trim(FVoicePhrase.Value);
  // O Vosk carrega em ~1 s na primeira vez: fora da tela.
  TTask.Run(
    procedure
    var
      LMissing: string;
    begin
      LMissing := VoskMissingWords(LPhrase);
      QueueUI(
        procedure
        begin
          if LMissing = '' then
            TUIToastManager.Show('Frase salva: ' + LPhrase, ttSuccess, 2500)
          else
            TUIToastManager.Show('Frase salva. O Vosk não conhece "' + LMissing +
              '": a frase vai ser conferida pelo whisper (mais lento).', ttWarning, 7000);
        end);
    end);
end;

procedure TAISettingsPage.VoiceTalkClick(Sender: TObject);
begin
  if Assigned(FOnVoiceTalk) then
    FOnVoiceTalk(Self);
end;

procedure TAISettingsPage.LoadVoiceKeyField;
var
  LEngine: TSttEngine;
begin
  LEngine := TSttEngine(Max(FVoiceStt.ItemIndex, 0));
  FVoiceKey.Value := '';
  FVoiceKey.Enabled := SttIsCloud(LEngine);
  if not SttIsCloud(LEngine) then
    FVoiceKey.LabelText := 'Local: sem chave, nada sai do PC'
  else if LoadSecret(SttSecretTarget(LEngine)) <> '' then
    FVoiceKey.LabelText := 'Chave salva no Credential Manager (deixe em branco para manter)'
  else
    FVoiceKey.LabelText := 'Chave da ' + IfThen(LEngine = stGroq, 'Groq', 'OpenAI') + ' (fica no Credential Manager)';
end;

procedure TAISettingsPage.VoiceSttChange(Sender: TObject);
begin
  Store.SetSetting('voice_stt', IntToStr(Max(0, FVoiceStt.ItemIndex)));
  LoadVoiceKeyField;
  VoiceChanged;
end;

procedure TAISettingsPage.VoiceKeySave(Sender: TObject);
var
  LEngine: TSttEngine;
begin
  LEngine := TSttEngine(Max(FVoiceStt.ItemIndex, 0));
  if not SttIsCloud(LEngine) or (Trim(FVoiceKey.Value) = '') then
    Exit;
  SaveSecret(SttSecretTarget(LEngine), 'devbox', Trim(FVoiceKey.Value));
  LoadVoiceKeyField;
  VoiceChanged;
  TUIToastManager.Show('Chave salva', ttSuccess, 2000);
end;

{ Chave e modelo de cada conversa ao vivo: 'Devbox:rt:1' (OpenAI), 'Devbox:rt:2' (Gemini); voice_live_model_<n>. }
procedure TAISettingsPage.LoadLiveFields;
var
  LMode: Integer;
begin
  LMode := Max(FLiveMode.ItemIndex, 0);
  FLiveModel.Enabled := LMode > 0;
  FLiveKey.Enabled := LMode > 0;
  FLiveModel.Value := '';
  FLiveKey.Value := '';
  FLiveModel.LabelText := 'Modelo';
  if LMode = 0 then
  begin
    FLiveKey.LabelText := 'Usa o motor do pedido e a IA da aba Interna';
    Exit;
  end;
  FLiveModel.Value := Store.GetSetting('voice_live_model_' + IntToStr(LMode),
    RealtimeDefaultModels[TRealtimeProvider(LMode - 1)]);
  if LoadSecret('Devbox:rt:' + IntToStr(LMode)) <> '' then
    FLiveKey.LabelText := 'Chave salva no Credential Manager (deixe em branco para manter)'
  else
    FLiveKey.LabelText := 'Chave da ' + IfThen(LMode = 1, 'OpenAI', 'Gemini (Google AI Studio)') +
      ' (fica no Credential Manager)';
end;

procedure TAISettingsPage.LiveModeChange(Sender: TObject);
begin
  Store.SetSetting('voice_live', IntToStr(Max(0, FLiveMode.ItemIndex)));
  LoadLiveFields;
  VoiceChanged;
end;

procedure TAISettingsPage.LiveSave(Sender: TObject);
var
  LMode: Integer;
begin
  LMode := Max(FLiveMode.ItemIndex, 0);
  Store.SetSetting('voice_live', IntToStr(LMode));
  if LMode > 0 then
  begin
    Store.SetSetting('voice_live_model_' + IntToStr(LMode), Trim(FLiveModel.Value));
    if Trim(FLiveKey.Value) <> '' then
      SaveSecret('Devbox:rt:' + IntToStr(LMode), 'devbox', Trim(FLiveKey.Value));
  end;
  LoadLiveFields;
  VoiceChanged;
  TUIToastManager.Show('Conversa salva', ttSuccess, 2000);
end;

{ Custos }

procedure TAISettingsPage.BuildCosts;
var
  LBody: TWinControl;
  LRow: TPanel;
  LModel: string;
begin
  LBody := Body(CTabCosts);
  NewTitle(LBody, 'Quanto as IAs pagas custaram');
  FCostSummary := TUILabel.Create(Self);
  FCostSummary.AutoSize := False;
  FCostSummary.Height := ScaleValue(28);
  FCostSummary.FontSize := 13;
  FCostSummary.Top := 100000;
  FCostSummary.Align := alTop;
  FCostSummary.Parent := LBody;
  NewHint(LBody, 'Estimativa pelo uso que cada API devolve (tokens de texto e de áudio, minutos transcritos) e o ' +
    'preço abaixo, em dólar. A fatura de cada empresa é a fonte final. Este mês, por modelo:');
  FCostTable := TUIDataTable.Create(Self);
  FCostTable.Density := tdCompact;
  FCostTable.AddColumn('model', 'Modelo', 'model', 200);
  FCostTable.AddColumn('calls', 'Chamadas', 'calls', 90);
  FCostTable.AddColumn('text', 'Tokens de texto', 'text', 150);
  FCostTable.AddColumn('audio', 'Tokens de áudio', 'audio', 140);
  FCostTable.AddColumn('minutes', 'Minutos', 'minutes', 90);
  FCostTable.AddColumn('cost', 'Custo (US$)', 'cost', 110);
  FCostTable.EmptyStateText := 'Nenhum uso de IA paga este mês';
  FCostTable.Height := ScaleValue(240);
  FCostTable.Top := 100000;
  FCostTable.Align := alTop;
  FCostTable.Parent := LBody;

  NewTitle(LBody, 'Preços e teto');
  NewHint(LBody, 'US$ por milhão de tokens: entrada; saída; áudio que entra; áudio que sai; e US$ por minuto ' +
    'transcrito. Padrões das páginas oficiais em 08/10/2026; mude se a empresa mudar.');
  LRow := NewPanel(LBody, alTop, 54);
  LRow.Padding.SetBounds(0, ScaleValue(8), 0, ScaleValue(4));
  NewButton(LRow, 'Salvar preço e teto', PriceSave, bvOutline, alRight);
  FPriceModel := TUISelect.Create(Self);
  for LModel in KnownPriceModels do
    FPriceModel.Items.Add(LModel);
  FPriceModel.ItemIndex := 0;
  FPriceModel.Width := ScaleValue(240);
  FPriceModel.AlignWithMargins := True;
  FPriceModel.Margins.SetBounds(0, 0, ScaleValue(8), 0);
  FPriceModel.Align := alLeft;
  FPriceModel.Parent := LRow;
  FPriceModel.OnChange := PriceModelChange;
  FPriceText := TUIInput.Create(Self);
  FPriceText.LabelMode := ilmBorder;
  FPriceText.LabelText := 'entrada;saída;áudio entra;áudio sai;por minuto';
  FPriceText.ReserveHintSpace := False;
  FPriceText.Width := ScaleValue(300);
  FPriceText.AlignWithMargins := True;
  FPriceText.Margins.SetBounds(0, 0, ScaleValue(8), 0);
  FPriceText.Left := 100000;
  FPriceText.Align := alLeft;
  FPriceText.Parent := LRow;
  FMonthCap := TUIInput.Create(Self);
  FMonthCap.LabelMode := ilmBorder;
  FMonthCap.LabelText := 'Teto do mês (US$, 0 = sem teto)';
  FMonthCap.ReserveHintSpace := False;
  FMonthCap.Value := Store.GetSetting('ai_month_cap', '0');
  FMonthCap.Align := alClient;
  FMonthCap.Parent := LRow;
  PriceModelChange(nil);
end;

procedure TAISettingsPage.PriceModelChange(Sender: TObject);
begin
  if FPriceModel.ItemIndex >= 0 then
    FPriceText.Value := PriceText(PriceFor(FPriceModel.Items[FPriceModel.ItemIndex]));
end;

procedure TAISettingsPage.PriceSave(Sender: TObject);
var
  LPrice: TAiPrice;
begin
  if (FPriceModel.ItemIndex < 0) or not ParsePrice(StringReplace(FPriceText.Value, ',', '.', [rfReplaceAll]),
    LPrice) then
  begin
    TUIToastManager.Show('Preço no formato entrada;saída;áudio entra;áudio sai;por minuto', ttWarning, 4000);
    Exit;
  end;
  SavePrice(FPriceModel.Items[FPriceModel.ItemIndex], LPrice);
  Store.SetSetting('ai_month_cap', StringReplace(Trim(FMonthCap.Value), ',', '.', [rfReplaceAll]));
  RefreshCosts;
  TUIToastManager.Show('Preço salvo (vale para o uso daqui em diante)', ttSuccess, 3000);
end;

function SumCost(const ATotals: TUsageTotals): Double;
var
  LTotal: TUsageTotal;
begin
  Result := 0;
  for LTotal in ATotals do
    Result := Result + LTotal.Cost;
end;

procedure TAISettingsPage.RefreshCosts;
var
  LMonth: TUsageTotals;
  LTotal: TUsageTotal;
  LCap, LMonthCost: Double;
  LText: string;
begin
  FlushAIUsage;
  LMonth := Store.UsageTotals(StartOfTheMonth(Now));
  LMonthCost := SumCost(LMonth);
  LText := Format('Hoje US$ %.2f  ·  7 dias US$ %.2f  ·  Este mês US$ %.2f',
    [SumCost(Store.UsageTotals(Date)), SumCost(Store.UsageTotals(Date - CDaysWeek + 1)), LMonthCost]);
  LCap := StrToFloatDef(Store.GetSetting('ai_month_cap'), 0, TFormatSettings.Invariant);
  if LCap > 0 then
    LText := LText + Format('  ·  %.0f%% do teto', [LMonthCost / LCap * 100]);
  FCostSummary.Caption := LText;
  FCostTable.BeginRowUpdate;
  try
    FCostTable.ClearMemRows;
    for LTotal in LMonth do
      FCostTable.AddMemRow([LTotal.Model, IntToStr(LTotal.Calls), IntToStr(LTotal.InputTokens + LTotal.OutputTokens),
        IntToStr(LTotal.AudioTokens), Format('%.1f', [LTotal.AudioSeconds / 60]), Format('%.4f', [LTotal.Cost])]);
  finally
    FCostTable.EndRowUpdate;
  end;
end;

end.
