unit Devbox.UI.AISettings;

{ Configuração › IA: abas Provedor (a IA do assistente e das ações de texto; os
  cartões vêm da tela Issues, que guarda os eventos), Voz (aparelhos,
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
  UI.Card,
  UI.Button,
  Devbox.Speech,
  Devbox.UI.Kit;

type
  TAISettingsPage = class(TDevPage)
  private
    FTabs: TUITabs;
    FViews: array[0..2] of TUIScrollArea;
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
    FCostsTitle: TUILabel;
    FCostTable: TUIDataTable;
    FPriceModel: TUISelect;
    FPriceText, FMonthCap: TUIInput;
    FTimer: TTimer;
    FOnVoiceChanged: TNotifyEvent;
    FOnVoiceTalk: TNotifyEvent;
    FOnCostsShown: TNotifyEvent;
    function Body(AIndex: Integer): TWinControl;
    function NewTitle(AParent: TWinControl; const ACaption: string): TUILabel;
    procedure TabChange(Sender: TObject; AIndex: Integer);
    procedure UpdateContentHeight(AIndex: Integer);
    procedure BuildInternal;
    procedure BuildVoice;
    procedure BuildCosts;
    procedure TimerTick(Sender: TObject);
    procedure VoiceChanged;
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
    { Cartões da config de IA (vêm da tela Issues): provedor e IA automática na aba
      Provedor; o último (uso) no topo da aba Custos. }
    procedure HostAiCards(const ACards: TArray<TControl>);
    { Interruptor, frase, aparelhos, motor ou conversa mudaram (a janela principal aplica). }
    property OnVoiceChanged: TNotifyEvent read FOnVoiceChanged write FOnVoiceChanged;
    property OnVoiceTalk: TNotifyEvent read FOnVoiceTalk write FOnVoiceTalk;
    { Aba Custos aberta: quem tem cartão de uso atualiza os números. }
    property OnCostsShown: TNotifyEvent read FOnCostsShown write FOnCostsShown;
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
  CTabNames: array[0..2] of string = ('Provedor', 'Voz', 'Custos');
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
  begin
    RefreshCosts;
    if Assigned(FOnCostsShown) then
      FOnCostsShown(Self);
  end;
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
  NewTitle(LBody, 'Uma IA para tudo');
  LRow := NewPanel(LBody, alTop, 54);
  LRow.Padding.SetBounds(0, ScaleValue(4), 0, ScaleValue(8));
  NewButton(LRow, 'Testar', AITestClick, bvOutline, alRight);
  NewHint(LRow, 'Assistente (botão redondo), IA… do Clipboard, logs, Comando por IA, resumo do dia e voz.',
    alClient);
end;

procedure TAISettingsPage.HostAiCards(const ACards: TArray<TControl>);
var
  LCard: TControl;
  LTop, LIndex, LChild: Integer;
begin
  // Cada cartão logo abaixo do último controle (o alTop ordena pelo Top).
  for LIndex := 0 to High(ACards) - 1 do
  begin
    LCard := ACards[LIndex];
    LTop := 0;
    for LChild := 0 to Body(CTabInternal).ControlCount - 1 do
      LTop := Max(LTop, Body(CTabInternal).Controls[LChild].BoundsRect.Bottom);
    LCard.Parent := Body(CTabInternal);
    LCard.Top := LTop + 1;
  end;
  if ACards <> nil then
  begin
    LCard := ACards[High(ACards)];
    LCard.Parent := Body(CTabCosts);
    LCard.Top := 0;
  end;
  UpdateContentHeight(CTabInternal);
  UpdateContentHeight(CTabCosts);
end;

procedure TAISettingsPage.AITestClick(Sender: TObject);
var
  C: TAIConfig;
begin
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
const
  CRowH = 72;
  CFieldH = 44;
  CTitleH = 30;
var
  LBody: TWinControl;
  LCard: TUICard;
  LHost: TPanel;
  LEngine: TSttEngine;
  LTop: Integer;

  { Cartão de uma parte da voz, com ARows linhas. }
  function Section(const ATitle: string; ARows: Integer): TUICard;
  var
    LLabel: TUILabel;
  begin
    Result := TUICard.Create(Self);
    Result.Variant := cvOutlined;
    Result.CardPad := cpNone;
    Result.Padding.SetBounds(ScaleValue(16), ScaleValue(12), ScaleValue(16), ScaleValue(4));
    Result.Height := ScaleValue(CTitleH + ARows * CRowH + 20);
    Result.AlignWithMargins := True;
    Result.Margins.SetBounds(0, ScaleValue(12), 0, 0);
    Result.Parent := LBody;
    Inc(LTop, 1000);
    Result.Top := LTop;
    Result.Align := alTop;
    LLabel := TUILabel.Create(Self);
    LLabel.Caption := ATitle;
    LLabel.Bold := True;
    LLabel.FontSize := 14;
    LLabel.AutoSize := False;
    LLabel.Height := ScaleValue(CTitleH);
    LLabel.Align := alTop;
    LLabel.Parent := Result;
  end;

  { Linha: o que é e o que faz à esquerda; devolve o painel da direita para o controle. }
  function Row(ACard: TUICard; const ATitle, ADesc: string; AControlW: Integer): TPanel;
  var
    LRow, LText: TPanel;
    LLabel: TUILabel;
    LPad: Integer;
  begin
    LRow := NewPanel(ACard, alTop, CRowH);
    LRow.Top := 100000;
    LPad := (ScaleValue(CRowH) - ScaleValue(CFieldH)) div 2;
    Result := NewPanel(LRow, alRight);
    Result.Width := ScaleValue(AControlW);
    Result.Padding.SetBounds(0, LPad, 0, LPad);
    LText := NewPanel(LRow, alClient);
    LText.Padding.SetBounds(0, ScaleValue(12), ScaleValue(16), 0);
    LLabel := TUILabel.Create(Self);
    LLabel.Caption := ATitle;
    LLabel.AutoSize := False;
    LLabel.Height := ScaleValue(20);
    LLabel.Align := alTop;
    LLabel.Parent := LText;
    LLabel := NewHint(LText, ADesc, alClient);
    LLabel.WordWrap := True;
  end;

  function Input(AHost: TPanel; const ALabel: string; APassword: Boolean): TUIInput;
  begin
    Result := TUIInput.Create(Self);
    Result.LabelMode := ilmBorder;
    Result.LabelText := ALabel;
    Result.ReserveHintSpace := False;
    if APassword then
    begin
      Result.PasswordChar := '*';
      Result.PasswordToggle := True;
    end;
    Result.Align := alClient;
    Result.Parent := AHost;
  end;

  procedure SaveButton(AHost: TPanel; AOnClick: TNotifyEvent);
  var
    LButton: TUIButton;
  begin
    LButton := NewButton(AHost, 'Salvar', AOnClick, bvOutline, alRight);
    LButton.AlignWithMargins := True;
    LButton.Margins.SetBounds(ScaleValue(8), 0, 0, 0);
  end;

begin
  LBody := Body(CTabVoice);
  LTop := 0;

  LCard := Section('Ligar', 2);
  LHost := Row(LCard, 'Ouvir a frase de ativação', 'O microfone fica ligado e a frase é conferida aqui no PC. ' +
    'Nada vai para a internet antes da frase.', 60);
  FVoiceToggle := TUIToggle.Create(Self);
  FVoiceToggle.Checked := Store.GetSetting('voice_on', '0') = '1';
  FVoiceToggle.OnChange := VoiceToggleChange;
  FVoiceToggle.Align := alClient;
  FVoiceToggle.Parent := LHost;
  LHost := Row(LCard, 'Falar sem a frase', 'Começa a ouvir o pedido agora, como se você tivesse dito a frase.', 200);
  NewButton(LHost, 'Falar agora', VoiceTalkClick, bvOutline, alClient);

  LCard := Section('Frase de ativação', 2);
  LHost := Row(LCard, 'Frase', 'O que você diz para chamar o Devbox. Ex.: Oi Java.', 380);
  SaveButton(LHost, VoicePhraseSave);
  FVoicePhrase := Input(LHost, 'Frase', False);
  FVoicePhrase.Value := Store.GetSetting('voice_phrase', VoiceDefaultPhrase);
  LHost := Row(LCard, 'Precisão', 'Parecido chama mais fácil, mas às vezes à toa. Bem igual quase não erra, ' +
    'mas pode não ouvir.', 300);
  FVoiceSense := TUISelect.Create(Self);
  FVoiceSense.Items.Add('Aceita parecido');
  FVoiceSense.Items.Add('Equilibrado');
  FVoiceSense.Items.Add('Precisa ser bem igual');
  FVoiceSense.ItemIndex := EnsureRange(StrToIntDef(Store.GetSetting('voice_sense', '1'), 1), 0, 2);
  FVoiceSense.Align := alClient;
  FVoiceSense.Parent := LHost;
  FVoiceSense.OnChange := VoiceSenseChange;

  LCard := Section('Microfone e som', 3);
  LHost := Row(LCard, 'Microfone', 'De onde vem a sua voz.', 380);
  FInDevice := DeviceSelect(Self, TUIAudioCapture.DeviceNames, Store.GetSetting('voice_in_dev'));
  FInDevice.Align := alClient;
  FInDevice.Parent := LHost;
  FInDevice.OnChange := DeviceChange;
  LHost := Row(LCard, 'Saída de som', 'Por onde a voz do Devbox sai. O eco é tirado do microfone: dá para usar ' +
    'sem fone.', 380);
  FOutDevice := DeviceSelect(Self, OutputDeviceNames, Store.GetSetting('voice_out_dev'));
  FOutDevice.Align := alClient;
  FOutDevice.Parent := LHost;
  FOutDevice.OnChange := DeviceChange;
  LHost := Row(LCard, 'Testar a saída', 'Fala uma frase curta na saída escolhida.', 200);
  NewButton(LHost, 'Testar saída', OutputTestClick, bvOutline, alClient);

  LCard := Section('Entender o pedido', 2);
  LHost := Row(LCard, 'Motor de transcrição', 'Transforma sua fala em texto no modo pedido único. Local: nada sai ' +
    'do PC. Nuvem: entende melhor, precisa de chave.', 380);
  FVoiceStt := TUISelect.Create(Self);
  for LEngine := Low(TSttEngine) to High(TSttEngine) do
    FVoiceStt.Items.Add(SttEngineNames[LEngine]);
  FVoiceStt.ItemIndex := EnsureRange(StrToIntDef(Store.GetSetting('voice_stt', '0'), 0), 0, Ord(High(TSttEngine)));
  FVoiceStt.Align := alClient;
  FVoiceStt.Parent := LHost;
  FVoiceStt.OnChange := VoiceSttChange;
  LHost := Row(LCard, 'Chave do motor', 'Só para motor na nuvem. Fica no Credential Manager do Windows.', 380);
  SaveButton(LHost, VoiceKeySave);
  FVoiceKey := Input(LHost, '', True);
  LoadVoiceKeyField;

  LCard := Section('Como responder', 3);
  LHost := Row(LCard, 'Modo', 'Pedido único: você fala, ele responde uma vez. Conversa ao vivo: fala e escuta ' +
    'ao mesmo tempo e dá para interromper.', 380);
  FLiveMode := TUISelect.Create(Self);
  FLiveMode.Items.Add('Pedido único');
  FLiveMode.Items.Add('Conversa ao vivo: OpenAI Realtime');
  FLiveMode.Items.Add('Conversa ao vivo: Gemini Live');
  FLiveMode.ItemIndex := EnsureRange(StrToIntDef(Store.GetSetting('voice_live', '0'), 0), 0, 2);
  FLiveMode.Align := alClient;
  FLiveMode.Parent := LHost;
  FLiveMode.OnChange := LiveModeChange;
  LHost := Row(LCard, 'Modelo da conversa', 'Só na conversa ao vivo. Já vem com o padrão de cada empresa.', 380);
  FLiveModel := Input(LHost, 'Modelo', False);
  LHost := Row(LCard, 'Chave da conversa', 'OpenAI ou Google AI Studio. Fica no Credential Manager do Windows.', 380);
  SaveButton(LHost, LiveSave);
  FLiveKey := Input(LHost, '', True);
  LoadLiveFields;

  LCard := Section('O que o ouvido está entendendo', 0);
  LCard.Height := ScaleValue(CTitleH + 28 + CLogHeight + 28);
  LHost := NewPanel(LCard, alTop, 28);
  LHost.Top := 100000;
  NewHint(LHost, 'Ao vivo: cada fala, o que o Vosk ouviu e se bateu com a frase. Só na memória (300 linhas).',
    alClient);
  NewButton(LHost, 'Limpar', LogClear, bvGhost, alRight);
  FLog := TUICode.Create(Self);
  FLog.FontSize := 12;
  FLog.Height := ScaleValue(CLogHeight);
  FLog.Top := 100000;
  FLog.Align := alTop;
  FLog.Parent := LCard;
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
    FLiveKey.LabelText := 'Usa o motor do pedido e a IA da aba Provedor';
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
  FCostsTitle := NewTitle(LBody, 'Ações de texto, resumo do dia, voz e transcrição');
  FCostSummary := TUILabel.Create(Self);
  FCostSummary.AutoSize := False;
  FCostSummary.Height := ScaleValue(28);
  FCostSummary.FontSize := 13;
  FCostSummary.Top := 100000;
  FCostSummary.Align := alTop;
  FCostSummary.Parent := LBody;
  NewHint(LBody, 'Fora o assistente (cartão acima). Estimativa pelo uso de cada API e o preço abaixo, em US$. ' +
    'Este mês, por modelo:');
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
