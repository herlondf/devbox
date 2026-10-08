unit Devbox.UI.Settings;

{ Configuração › Geral: guardar clipboard, atalho global, autostart, limpar.
  A IA e a voz ficam em Configuração › IA (Devbox.UI.AISettings). }

interface

uses
  System.Classes,
  UI.Toggle,
  UI.Select,
  Devbox.UI.Kit;

type
  TSettingsPage = class(TDevPage)
  private
    FClipToggle, FHotkeyToggle, FAutostartToggle: TUIToggle;
    FOnHotkeyChanged: TNotifyEvent;
    FOnHistoryCleared: TNotifyEvent;
    FLang, FUpdateMode: TUISelect;
    FOnCheckUpdates: TNotifyEvent;
    procedure SettingToggle(Sender: TObject);
    procedure LangChange(Sender: TObject);
    procedure UpdateModeChange(Sender: TObject);
    procedure CheckUpdatesClick(Sender: TObject);
    procedure ClearHistoryClick(Sender: TObject);
  public
    constructor Create(AOwner: TComponent); override;
    property OnHotkeyChanged: TNotifyEvent read FOnHotkeyChanged write FOnHotkeyChanged;
    property OnHistoryCleared: TNotifyEvent read FOnHistoryCleared write FOnHistoryCleared;
    { "Procurar agora" (a tela Issues tem o atualizador). }
    property OnCheckUpdates: TNotifyEvent read FOnCheckUpdates write FOnCheckUpdates;
  end;

implementation

uses
  System.SysUtils,
  System.Math,
  System.StrUtils,
  Vcl.Controls,
  Vcl.ExtCtrls,
  UI.Toast,
  UI.Button,
  Devbox.Issues.Store,
  Devbox.Model,
  Devbox.Store,
  Devbox.Sys;

constructor TSettingsPage.Create(AOwner: TComponent);
var
  Row: TPanel;
begin
  inherited Create(AOwner);
  Caption := 'Geral';
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

  // Idioma e atualizações vieram do Vigia (preferências em issue_setting, as mesmas de lá).
  NewHint(Self, 'Idioma das telas de Issues (português ou inglês; o resto do Devbox é em português). ' +
    'Vale ao reabrir o Devbox.');
  Row := NewPanel(Self, alTop, 54);
  Row.Padding.SetBounds(0, ScaleValue(8), 0, ScaleValue(4));
  FLang := TUISelect.Create(Self);
  FLang.Items.Add('Automático (Windows)');
  FLang.Items.Add('Português');
  FLang.Items.Add('English');
  FLang.ItemIndex := Max(0, IndexText(IssueStore.GetSetting('lang'), ['', 'pt', 'en']));
  FLang.Width := ScaleValue(260);
  FLang.Align := alLeft;
  FLang.Parent := Row;
  FLang.OnChange := LangChange;
  NewHint(Self, 'Atualizações: versão ' + AppVersion + '. Procura release nova do Devbox uma vez por dia ' +
    '(só na cópia instalada pelo instalador).');
  Row := NewPanel(Self, alTop, 54);
  Row.Padding.SetBounds(0, ScaleValue(8), 0, ScaleValue(4));
  FUpdateMode := TUISelect.Create(Self);
  FUpdateMode.Items.Add('Só avisar');
  FUpdateMode.Items.Add('Instalar sozinho');
  FUpdateMode.Items.Add('Não procurar');
  FUpdateMode.ItemIndex := Max(0, IndexText(IssueStore.GetSetting('update_mode'), ['notify', 'auto', 'off']));
  FUpdateMode.Width := ScaleValue(260);
  FUpdateMode.AlignWithMargins := True;
  FUpdateMode.Margins.SetBounds(0, 0, ScaleValue(8), 0);
  FUpdateMode.Align := alLeft;
  FUpdateMode.Parent := Row;
  FUpdateMode.OnChange := UpdateModeChange;
  NewButton(Row, 'Procurar agora', CheckUpdatesClick, bvOutline, alLeft).Left := 100000;
end;

procedure TSettingsPage.LangChange(Sender: TObject);
const
  CCodes: array[0..2] of string = ('', 'pt', 'en');
begin
  IssueStore.SetSetting('lang', CCodes[EnsureRange(FLang.ItemIndex, 0, 2)]);
  TUIToastManager.Show('Idioma das Issues muda ao reabrir o Devbox', ttInfo, 3000);
end;

procedure TSettingsPage.UpdateModeChange(Sender: TObject);
const
  CModes: array[0..2] of string = ('notify', 'auto', 'off');
begin
  IssueStore.SetSetting('update_mode', CModes[EnsureRange(FUpdateMode.ItemIndex, 0, 2)]);
end;

procedure TSettingsPage.CheckUpdatesClick(Sender: TObject);
begin
  if Assigned(FOnCheckUpdates) then
    FOnCheckUpdates(Self);
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
