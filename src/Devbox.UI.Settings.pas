unit Devbox.UI.Settings;

{ Configuração › Geral: clipboard, sistema (inicialização, idioma, atualizações) e a
  manutenção automática. Cada seção é um cartão com linhas "o que é / controle"
  (design system, docs/DESIGN.md). A IA e a voz ficam em Configuração › IA. }

interface

uses
  System.Classes,
  UI.Toggle,
  UI.Select,
  UI.ScrollArea,
  Devbox.UI.Kit;

type
  TSettingsPage = class(TDevPage)
  private
    FScroll: TUIScrollArea;
    FClipToggle, FHotkeyToggle, FAutostartToggle, FHealthToggle: TUIToggle;
    FLang, FUpdateMode, FHealthSchedule: TUISelect;
    FOnHotkeyChanged: TNotifyEvent;
    FOnHistoryCleared: TNotifyEvent;
    FOnCheckUpdates: TNotifyEvent;
    FOnHealthNow: TNotifyEvent;
    procedure SettingToggle(Sender: TObject);
    procedure LangChange(Sender: TObject);
    procedure UpdateModeChange(Sender: TObject);
    procedure HealthScheduleChange(Sender: TObject);
    procedure CheckUpdatesClick(Sender: TObject);
    procedure ClearHistoryClick(Sender: TObject);
    procedure HealthNowClick(Sender: TObject);
    procedure ScrollResize(Sender: TObject);
  public
    constructor Create(AOwner: TComponent); override;
    procedure PageShown; override;
    property OnHotkeyChanged: TNotifyEvent read FOnHotkeyChanged write FOnHotkeyChanged;
    property OnHistoryCleared: TNotifyEvent read FOnHistoryCleared write FOnHistoryCleared;
    { "Procurar agora" (a tela Issues tem o atualizador). }
    property OnCheckUpdates: TNotifyEvent read FOnCheckUpdates write FOnCheckUpdates;
    { "Rodar agora" da manutenção (a janela principal roda e avisa). }
    property OnHealthNow: TNotifyEvent read FOnHealthNow write FOnHealthNow;
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
  UI.Card,
  Devbox.Issues.Store,
  Devbox.Health,
  Devbox.Model,
  Devbox.Store,
  Devbox.Sys;

const
  CToggleW = 60;
  CSelectW = 300;
  CButtonW = 200;

constructor TSettingsPage.Create(AOwner: TComponent);
var
  LBody: TWinControl;
  LCard: TUICard;
  LHost: TPanel;

  function Toggle(AHost: TPanel; AChecked: Boolean): TUIToggle;
  begin
    Result := TUIToggle.Create(Self);
    Result.Checked := AChecked;
    Result.OnChange := SettingToggle;
    Result.Align := alClient;
    Result.Parent := AHost;
  end;

  function Select(AHost: TPanel; const AItems: array of string; AIndex: Integer; AOnChange: TNotifyEvent): TUISelect;
  var
    LItem: string;
  begin
    Result := TUISelect.Create(Self);
    for LItem in AItems do
      Result.Items.Add(LItem);
    Result.ItemIndex := AIndex;
    Result.Align := alClient;
    Result.Parent := AHost;
    Result.OnChange := AOnChange;
  end;

begin
  inherited Create(AOwner);
  Caption := 'Geral';
  Hint := 'Preferências do Devbox neste usuário do Windows';
  FScroll := TUIScrollArea.Create(Self);
  FScroll.Align := alClient;
  FScroll.Parent := Self;
  FScroll.OnResize := ScrollResize;
  LBody := FScroll.InnerPanel;

  LCard := NewSection(LBody, 'Clipboard', 3);
  LHost := NewSettingRow(LCard, 'Guardar o que eu copio',
    Format('Os últimos %d itens ficam no histórico. Snippets ficam para sempre.', [HistoryLimit]), CToggleW);
  FClipToggle := Toggle(LHost, Store.GetSetting('clip_on', '1') = '1');
  LHost := NewSettingRow(LCard, 'Atalho Win+Alt+B',
    'Abre a busca do clipboard de qualquer programa. Enter cola onde você estava.', CToggleW);
  FHotkeyToggle := Toggle(LHost, Store.GetSetting('hotkey_on', '1') = '1');
  LHost := NewSettingRow(LCard, 'Histórico', 'Apaga o que foi copiado. Os snippets ficam.', CButtonW);
  NewButton(LHost, 'Limpar histórico', ClearHistoryClick, bvOutline, alClient);

  LCard := NewSection(LBody, 'Sistema', 3);
  LHost := NewSettingRow(LCard, 'Iniciar com o Windows',
    'O Devbox abre escondido na bandeja quando você entra no Windows.', CToggleW);
  FAutostartToggle := Toggle(LHost, AutostartEnabled);
  LHost := NewSettingRow(LCard, 'Idioma das Issues',
    'Telas das Issues em português ou inglês (o resto é em português). Vale ao reabrir.', CSelectW);
  FLang := Select(LHost, ['Automático (Windows)', 'Português', 'English'],
    Max(0, IndexText(IssueStore.GetSetting('lang'), ['', 'pt', 'en'])), LangChange);
  LHost := NewSettingRow(LCard, 'Atualizações (versão ' + AppVersion + ')',
    'Procura versão nova uma vez por dia, só na cópia instalada pelo instalador.', CSelectW + CButtonW);
  NewButton(LHost, 'Procurar agora', CheckUpdatesClick, bvOutline, alRight).Width := ScaleValue(CButtonW - 60);
  FUpdateMode := Select(LHost, ['Só avisar', 'Instalar sozinho', 'Não procurar'],
    Max(0, IndexText(IssueStore.GetSetting('update_mode'), ['notify', 'auto', 'off'])), UpdateModeChange);
  FUpdateMode.AlignWithMargins := True;
  FUpdateMode.Margins.SetBounds(0, 0, ScaleValue(8), 0);

  LCard := NewSection(LBody, 'Manutenção do Windows', 3);
  LHost := NewSettingRow(LCard, 'Aviso de manutenção',
    'Procura temporários, lixo de build, pouco espaço em disco, PATH quebrado e excesso de programas na ' +
    'inicialização. Só avisa; apagar e desligar ficam na Limpeza.', CToggleW);
  FHealthToggle := Toggle(LHost, Store.GetSetting('health_on', '1') = '1');
  LHost := NewSettingRow(LCard, 'Quando', 'Horário passado com o Devbox fechado: roda ao abrir.', CSelectW);
  FHealthSchedule := Select(LHost, [HealthScheduleNames[hs2PerDay], HealthScheduleNames[hs3PerDay]],
    EnsureRange(StrToIntDef(Store.GetSetting('health_schedule', '0'), 0), 0, Ord(High(THealthSchedule))),
    HealthScheduleChange);
  LHost := NewSettingRow(LCard, 'Rodar agora', 'Faz a varredura agora e mostra o aviso.', CButtonW);
  NewButton(LHost, 'Rodar agora', HealthNowClick, bvOutline, alClient);
end;

procedure TSettingsPage.ScrollResize(Sender: TObject);
var
  LIndex, LBottom: Integer;
  LControl: TControl;
begin
  LBottom := 0;
  for LIndex := 0 to FScroll.InnerPanel.ControlCount - 1 do
  begin
    LControl := FScroll.InnerPanel.Controls[LIndex];
    LBottom := Max(LBottom, LControl.BoundsRect.Bottom);
  end;
  FScroll.ContentHeight := LBottom + ScaleValue(DSGap * 2);
end;

procedure TSettingsPage.PageShown;
begin
  inherited;
  ScrollResize(nil);
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

procedure TSettingsPage.HealthScheduleChange(Sender: TObject);
begin
  Store.SetSetting('health_schedule', IntToStr(Max(0, FHealthSchedule.ItemIndex)));
end;

procedure TSettingsPage.CheckUpdatesClick(Sender: TObject);
begin
  if Assigned(FOnCheckUpdates) then
    FOnCheckUpdates(Self);
end;

procedure TSettingsPage.HealthNowClick(Sender: TObject);
begin
  if Assigned(FOnHealthNow) then
    FOnHealthNow(Self);
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
    SetAutostart(FAutostartToggle.Checked)
  else if Sender = FHealthToggle then
    Store.SetSetting('health_on', IfThen(FHealthToggle.Checked, '1', '0'));
end;

procedure TSettingsPage.ClearHistoryClick(Sender: TObject);
begin
  Store.ClearHistory;
  if Assigned(FOnHistoryCleared) then
    FOnHistoryCleared(Self);
  TUIToastManager.Show('Histórico limpo. Os snippets ficaram.', ttSuccess, 2500);
end;

end.
