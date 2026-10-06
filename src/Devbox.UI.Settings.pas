unit Devbox.UI.Settings;

{ Preferências gerais: guardar clipboard, atalho global, autostart, limpar. }

interface

uses
  System.Classes,
  UI.Toggle,
  UI.Input,
  UI.Select,
  Devbox.UI.Kit;

type
  TSettingsPage = class(TDevPage)
  private
    FClipToggle, FHotkeyToggle, FAutostartToggle: TUIToggle;
    FOnHotkeyChanged: TNotifyEvent;
    FOnHistoryCleared: TNotifyEvent;
    FAIProvider: TUISelect;
    FAIBase, FAIModel, FAIKey: TUIInput;
    procedure SettingToggle(Sender: TObject);
    procedure ClearHistoryClick(Sender: TObject);
    procedure AIProviderChange(Sender: TObject);
    procedure AISaveClick(Sender: TObject);
    procedure AITestClick(Sender: TObject);
    procedure LoadAIFields;
  public
    constructor Create(AOwner: TComponent); override;
    property OnHotkeyChanged: TNotifyEvent read FOnHotkeyChanged write FOnHotkeyChanged;
    property OnHistoryCleared: TNotifyEvent read FOnHistoryCleared write FOnHistoryCleared;
  end;

implementation

uses
  System.SysUtils,
  System.StrUtils,
  Vcl.Controls,
  Vcl.ExtCtrls,
  UI.Toast,
  UI.Labels,
  UI.Button,
  System.Math,
  System.Threading,
  Devbox.AI,
  Devbox.Model,
  Devbox.Store,
  Devbox.Sys;

constructor TSettingsPage.Create(AOwner: TComponent);
var
  Row: TPanel;
  Title: TUILabel;
begin
  inherited Create(AOwner);
  Caption := 'Configurações';
  Hint := 'Preferências do Devbox neste usuário do Windows';
  FClipToggle := NewToggleRow(Self, 'Guardar o que eu copio',
    Format('Últimos %d itens ficam no histórico. Snippets ficam para sempre.', [HistoryLimit]), SettingToggle);
  FClipToggle.OnChange := nil;
  FClipToggle.Checked := Store.GetSetting('clip_on', '1') = '1';
  FClipToggle.OnChange := SettingToggle;
  FHotkeyToggle := NewToggleRow(Self, 'Atalho Win+Alt+B',
    'Abre a busca do clipboard de qualquer programa. Enter cola onde você estava.', SettingToggle);
  FHotkeyToggle.OnChange := nil;
  FHotkeyToggle.Checked := Store.GetSetting('hotkey_on', '1') = '1';
  FHotkeyToggle.OnChange := SettingToggle;
  FAutostartToggle := NewToggleRow(Self, 'Iniciar com o Windows',
    'O Devbox abre escondido na bandeja quando você entra no Windows.', SettingToggle);
  FAutostartToggle.OnChange := nil;
  FAutostartToggle.Checked := AutostartEnabled;
  FAutostartToggle.OnChange := SettingToggle;
  Row := NewPanel(Self, alTop, 48);
  Row.Padding.SetBounds(0, ScaleValue(8), 0, 0);
  NewButton(Row, 'Limpar histórico', ClearHistoryClick);

  // IA
  Title := TUILabel.Create(Self);
  Title.Caption := 'IA';
  Title.Bold := True;
  Title.FontSize := 15;
  Title.AutoSize := False;
  Title.Height := ScaleValue(40);
  Title.Top := 100000;
  Title.Align := alTop;
  Title.Parent := Self;
  NewHint(Self, 'Usada no botão IA… do Clipboard, em Explicar com IA nos logs e no Comando por IA. ' +
    'O texto só vai para a IA quando você clica.');
  Row := NewPanel(Self, alTop, 54);
  Row.Padding.SetBounds(0, ScaleValue(8), 0, ScaleValue(4));
  FAIProvider := TUISelect.Create(Self);
  FAIProvider.Items.Add(AIProviderNames[apAnthropic]);
  FAIProvider.Items.Add(AIProviderNames[apOpenAI]);
  FAIProvider.Width := ScaleValue(240);
  FAIProvider.AlignWithMargins := True;
  FAIProvider.Margins.SetBounds(0, 0, ScaleValue(8), 0);
  FAIProvider.Align := alLeft;
  FAIProvider.Parent := Row;
  FAIModel := TUIInput.Create(Self);
  FAIModel.LabelMode := ilmBorder;
  FAIModel.LabelText := 'Modelo';
  FAIModel.ReserveHintSpace := False;
  FAIModel.Width := ScaleValue(240);
  FAIModel.AlignWithMargins := True;
  FAIModel.Margins.SetBounds(0, 0, ScaleValue(8), 0);
  FAIModel.Left := 1000;
  FAIModel.Align := alLeft;
  FAIModel.Parent := Row;
  FAIBase := TUIInput.Create(Self);
  FAIBase.LabelMode := ilmBorder;
  FAIBase.LabelText := 'Endereço (compatível com OpenAI, ex.: http://localhost:11434/v1)';
  FAIBase.ReserveHintSpace := False;
  FAIBase.Align := alClient;
  FAIBase.Parent := Row;
  Row := NewPanel(Self, alTop, 54);
  Row.Padding.SetBounds(0, ScaleValue(4), 0, ScaleValue(4));
  NewButton(Row, 'Testar', AITestClick, bvGhost, alRight);
  NewButton(Row, 'Salvar', AISaveClick, bvPrimary, alRight);
  FAIKey := TUIInput.Create(Self);
  FAIKey.LabelMode := ilmBorder;
  FAIKey.LabelText := 'Chave (fica no Credential Manager do Windows, não no banco)';
  FAIKey.ReserveHintSpace := False;
  FAIKey.PasswordChar := '*';
  FAIKey.PasswordToggle := True;
  FAIKey.Align := alClient;
  FAIKey.Parent := Row;
  LoadAIFields;
  FAIProvider.OnChange := AIProviderChange;
end;

procedure TSettingsPage.LoadAIFields;
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

procedure TSettingsPage.AIProviderChange(Sender: TObject);
begin
  Store.SetSetting('ai_provider', IntToStr(Max(FAIProvider.ItemIndex, 0)));
  Store.SetSetting('ai_model', '');
  LoadAIFields;
end;

procedure TSettingsPage.AISaveClick(Sender: TObject);
begin
  Store.SetSetting('ai_provider', IntToStr(Max(FAIProvider.ItemIndex, 0)));
  Store.SetSetting('ai_model', Trim(FAIModel.Value));
  Store.SetSetting('ai_base_url', Trim(FAIBase.Value));
  if Trim(FAIKey.Value) <> '' then
    SaveAIKey(TAIProvider(Max(FAIProvider.ItemIndex, 0)), Trim(FAIKey.Value));
  LoadAIFields;
  TUIToastManager.Show('IA salva', ttSuccess, 2000);
end;

procedure TSettingsPage.AITestClick(Sender: TObject);
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
      System.Classes.TThread.Queue(nil,
        procedure
        begin
          if Ok then
            TUIToastManager.Show('IA respondeu: ' + Copy(Answer, 1, 60), ttSuccess, 4000)
          else
            TUIToastManager.Show('IA não respondeu: ' + Answer, ttError, 7000);
        end);
    end);
end;

procedure TSettingsPage.SettingToggle(Sender: TObject);
begin
  if Sender = FClipToggle then
    Store.SetSetting('clip_on', IfThen(FClipToggle.Checked, '1', '0'))
  else if Sender = FHotkeyToggle then
  begin
    Store.SetSetting('hotkey_on', IfThen(FHotkeyToggle.Checked, '1', '0'));
    if Assigned(FOnHotkeyChanged) then
      FOnHotkeyChanged(Self);
  end
  else if Sender = FAutostartToggle then
    SetAutostart(FAutostartToggle.Checked);
end;

procedure TSettingsPage.ClearHistoryClick(Sender: TObject);
begin
  Store.ClearHistory;
  if Assigned(FOnHistoryCleared) then
    FOnHistoryCleared(Self);
  TUIToastManager.Show('Histórico limpo. Os snippets ficaram.', ttSuccess, 2500);
end;

end.
