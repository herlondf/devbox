unit Devbox.UI.Watches;

{ Avisos de fim: "me avisa quando o build terminar", "quando a porta 5432
  fechar", "quando o container parar". Dispara uma vez e sai da lista. }

interface

uses
  System.Classes,
  System.SysUtils,
  Vcl.Controls,
  Vcl.ExtCtrls,
  UI.Input,
  UI.Select,
  UI.Button,
  UI.Dropdown,
  UI.DataTable,
  Devbox.Jobs,
  Devbox.UI.Kit;

type
  TWatchesPage = class(TDevPage)
  private
    FKind: TUISelect;
    FTarget: TUIInput;
    FPickBtn: TUIButton;
    FPick: TUIDropdown;
    FTable: TUIDataTable;
    FWatches: TWatches;
    FSel: Integer;
    FTimer: TTimer;
    FChecking: Boolean;
    FOnChanged: TNotifyEvent;
    procedure Reload;
    procedure TimerTick(Sender: TObject);
    procedure Fired(const AWatch: TWatch);
    procedure KindChange(Sender: TObject);
    procedure PickClick(Sender: TObject);
    procedure PickItem(Sender: TObject; const AID: string);
    procedure AddClick(Sender: TObject);
    procedure RemoveClick(Sender: TObject);
    procedure RowSelect(Sender: TObject; ARowIndex: Integer);
  public
    constructor Create(AOwner: TComponent); override;
    { Pedido vindo de outra tela (Serviços: container ou porta). }
    procedure AddWatch(AKind: TWatchKind; const ATarget, ACli, ACaption: string);
    { Quantos avisos ativos mudou (para o selo do menu). }
    property OnChanged: TNotifyEvent read FOnChanged write FOnChanged;
    function Count: Integer;
  end;

implementation

uses
  Winapi.Windows,
  Winapi.TlHelp32,
  System.StrUtils,
  System.Math,
  System.Threading,
  System.Generics.Collections,
  System.Generics.Defaults,
  UI.Toast,
  Devbox.Model,
  Devbox.Store,
  Devbox.Sys,
  Devbox.Notify;

const
  CCheckMs = 3000;

{ Nomes dos processos rodando agora, sem repetir, em ordem. Os do Windows
  ficam de fora: ninguém espera o svchost terminar. }
function ProcessNames: TArray<string>;
const
  SystemNames: array[0..11] of string = ('svchost.exe', 'System', '[System Process]', 'Registry',
    'smss.exe', 'csrss.exe', 'wininit.exe', 'services.exe', 'lsass.exe', 'winlogon.exe', 'dwm.exe', 'fontdrvhost.exe');
var
  Snap: THandle;
  E: TProcessEntry32;
  Seen: TDictionary<string, Boolean>;
  Name: string;
begin
  Result := nil;
  Seen := TDictionary<string, Boolean>.Create;
  Snap := CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  try
    if Snap = INVALID_HANDLE_VALUE then
      Exit;
    E.dwSize := SizeOf(E);
    if Process32First(Snap, E) then
      repeat
        Name := E.szExeFile;
        if not MatchText(Name, SystemNames) and not Seen.ContainsKey(LowerCase(Name)) then
        begin
          Seen.Add(LowerCase(Name), True);
          Result := Result + [Name];
        end;
      until not Process32Next(Snap, E);
  finally
    if Snap <> INVALID_HANDLE_VALUE then
      CloseHandle(Snap);
    Seen.Free;
  end;
  TArray.Sort<string>(Result, TIStringComparer.Ordinal);
end;

constructor TWatchesPage.Create(AOwner: TComponent);
var
  Bar: TPanel;
begin
  inherited Create(AOwner);
  Caption := 'Avisos de fim';
  Hint := 'Avisa na bandeja quando um processo termina, uma porta fecha ou um container para';
  FSel := -1;

  Bar := NewPanel(Self, alTop, 50);
  Bar.Padding.SetBounds(0, 0, 0, ScaleValue(8));
  NewButton(Bar, 'Avisar', AddClick, bvPrimary);
  FKind := TUISelect.Create(Self);
  FKind.Items.Add('Processo terminar');
  FKind.Items.Add('Porta fechar');
  FKind.ItemIndex := 0;
  FKind.OnChange := KindChange;
  FKind.Width := ScaleValue(190);
  FKind.AlignWithMargins := True;
  FKind.Margins.SetBounds(0, 0, ScaleValue(8), 0);
  FKind.Left := 100000;
  FKind.Align := alLeft;
  FKind.Parent := Bar;
  FPickBtn := NewButton(Bar, 'Escolher…', PickClick, bvGhost);
  FTarget := TUIInput.Create(Self);
  FTarget.LabelMode := ilmBorder;
  FTarget.ReserveHintSpace := False;
  FTarget.Align := alClient;
  FTarget.Parent := Bar;
  FPick := TUIDropdown.Create(Self);
  FPick.AnchorControl := FPickBtn;
  FPick.MaxHeight := 420;
  FPick.OnItemClick := PickItem;
  NewHint(Self, 'Container: use o botão "Avisar quando parar" na tela Serviços. ' +
    'Dica: pid:1234 vigia um processo só, quando há vários com o mesmo nome.');

  Bar := NewPanel(Self, alTop, 50);
  Bar.Padding.SetBounds(0, ScaleValue(6), 0, ScaleValue(6));
  NewButton(Bar, 'Remover', RemoveClick, bvGhost);

  FTable := TUIDataTable.Create(Self);
  FTable.SelectionMode := tsmSingle;
  FTable.Density := tdCompact;
  FTable.OnRowSelect := RowSelect;
  FTable.AddColumn('kind', 'Tipo', 'kind', 120);
  FTable.AddColumn('what', 'Esperando', 'what', 420);
  FTable.AddColumn('since', 'Desde', 'since', 120);
  FTable.EmptyStateText := 'Nenhum aviso ativo';
  FTable.Top := 100000;
  FTable.Align := alClient;
  FTable.Parent := Self;
  KindChange(nil);
  Reload;

  FTimer := TTimer.Create(Self);
  FTimer.Interval := CCheckMs;
  FTimer.OnTimer := TimerTick;
  FTimer.Enabled := True;
end;

function TWatchesPage.Count: Integer;
begin
  Result := Length(FWatches);
end;

procedure TWatchesPage.Reload;
var
  W: TWatch;
begin
  FWatches := Store.ListWatches;
  FTable.BeginRowUpdate;
  try
    FTable.ClearMemRows;
    for W in FWatches do
      FTable.AddMemRow([WatchKindNames[W.Kind], W.Caption, Ago(W.CreatedAt, Now)]);
  finally
    FTable.EndRowUpdate;
  end;
  FSel := -1;
  if Assigned(FOnChanged) then
    FOnChanged(Self);
end;

procedure TWatchesPage.KindChange(Sender: TObject);
begin
  if FKind.ItemIndex = 1 then
    FTarget.LabelText := 'Porta (ex.: 5432)'
  else
    FTarget.LabelText := 'Processo (ex.: node.exe, msbuild.exe ou pid:1234)';
  FTarget.Value := '';
end;

procedure TWatchesPage.PickClick(Sender: TObject);
var
  S: string;
  P: TListenPort;
begin
  FPick.ClearItems;
  if FKind.ItemIndex = 1 then
  begin
    for P in ListListenPorts do
      FPick.AddItem(IntToStr(P.Port), Format('%d  ·  %s', [P.Port, P.Process]));
  end
  else
    for S in ProcessNames do
      FPick.AddItem(S, S);
  FPick.Open;
end;

procedure TWatchesPage.PickItem(Sender: TObject; const AID: string);
begin
  FTarget.Value := AID;
end;

procedure TWatchesPage.AddWatch(AKind: TWatchKind; const ATarget, ACli, ACaption: string);
var
  W: TWatch;
begin
  W := Default(TWatch);
  W.Kind := AKind;
  W.Target := ATarget;
  W.Cli := ACli;
  W.Caption := ACaption;
  // Começar vigiando algo que já parou dispararia na hora: avisa antes.
  if not WatchAlive(W) then
  begin
    TUIToastManager.Show(ACaption + ' não está rodando agora', ttWarning, 4000);
    Exit;
  end;
  Store.AddWatch(W);
  Reload;
  TUIToastManager.Show('Combinado: aviso quando ' + LowerCase(Copy(ACaption, 1, 1)) + Copy(ACaption, 2, MaxInt) +
    ' parar', ttSuccess, 3000);
end;

procedure TWatchesPage.AddClick(Sender: TObject);
var
  T: string;
  Port: Integer;
begin
  T := Trim(FTarget.Value);
  if T = '' then
    Exit;
  if FKind.ItemIndex = 1 then
  begin
    if not TryStrToInt(T, Port) then
    begin
      FTarget.ErrorMessage := 'Número da porta';
      Exit;
    end;
    AddWatch(wkPort, T, '', 'Porta ' + T);
  end
  else
  begin
    if not StartsText('pid:', T) and not EndsText('.exe', T) then
      T := T + '.exe';
    AddWatch(wkProcess, T, '', 'Processo ' + T);
  end;
  FTarget.ErrorMessage := '';
  FTarget.Value := '';
end;

procedure TWatchesPage.RemoveClick(Sender: TObject);
begin
  if (FSel < 0) or (FSel > High(FWatches)) then
    Exit;
  Store.DeleteWatch(FWatches[FSel].Id);
  Reload;
end;

procedure TWatchesPage.RowSelect(Sender: TObject; ARowIndex: Integer);
begin
  FSel := ARowIndex;
end;

procedure TWatchesPage.Fired(const AWatch: TWatch);
begin
  Store.DeleteWatch(AWatch.Id);
  Notify('Terminou', AWatch.Caption + ' parou ' + Ago(AWatch.CreatedAt, Now).Replace('há ', 'depois de ', []) +
    '.');
  Reload;
end;

{ Checa em segundo plano (container chama o motor) e trata o resultado na tela. }
procedure TWatchesPage.TimerTick(Sender: TObject);
var
  List: TWatches;
begin
  if FChecking or (FWatches = nil) then
    Exit;
  FChecking := True;
  List := Copy(FWatches);
  TTask.Run(
    procedure
    var
      W: TWatch;
      Gone: TWatches;
    begin
      Gone := nil;
      // Sem isto, uma exceção deixaria FChecking preso e os avisos parariam.
      try
        for W in List do
          if not WatchAlive(W) then
            Gone := Gone + [W];
      except
        on E: Exception do
          Gone := nil;
      end;
      System.Classes.TThread.Queue(nil,
        procedure
        var
          G: TWatch;
        begin
          FChecking := False;
          for G in Gone do
            Fired(G);
        end);
    end);
end;

end.
