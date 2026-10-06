unit Devbox.UI.Expander;

// Expansor de texto: atalhos (";sql") que viram o texto de um snippet em
// qualquer programa. Lista os atalhos dos snippets e os prontos (;data...).

interface

uses
  System.Classes,
  System.SysUtils,
  UI.Toggle,
  UI.DataTable,
  Devbox.Model,
  Devbox.UI.Kit;

type
  TExpanderPage = class(TDevPage)
  private
    FToggle: TUIToggle;
    FTable: TUIDataTable;
    FRows: TClips;          // linhas de snippet, na ordem da tabela (prontos vêm depois)
    FSel: Integer;
    FOnChanged: TNotifyEvent;
    procedure Reload;
    procedure Changed;
    function OtherAbbrevs(AExceptId: Integer): TArray<string>;
    function SelectedSnippet(out AClip: TClip): Boolean;
    procedure ToggleChange(Sender: TObject);
    procedure RowSelect(Sender: TObject; ARowIndex: Integer);
    procedure RowDblClick(Sender: TObject; ARowIdx: Integer);
    procedure NewClick(Sender: TObject);
    procedure EditClick(Sender: TObject);
    procedure RemoveClick(Sender: TObject);
  public
    constructor Create(AOwner: TComponent); override;
    procedure PageShown; override;
    { Edita (ou cria, com AId = 0) um snippet pelo diálogo. True = salvou. }
    function EditSnippetById(AId: Integer): Boolean;
    { Atalho -> texto de todos os snippets com atalho. }
    function Abbrevs: TArray<string>;
    { Aviso para o form: atalhos mudaram (recarregar o gancho e o clipboard). }
    property OnChanged: TNotifyEvent read FOnChanged write FOnChanged;
  end;

implementation

uses
  System.StrUtils,
  Vcl.Controls,
  Vcl.ExtCtrls,
  UI.Button,
  UI.Toast,
  UI.Theme,
  Devbox.Store,
  Devbox.UI.Dialogs;

constructor TExpanderPage.Create(AOwner: TComponent);
var
  Bar: TPanel;
begin
  inherited Create(AOwner);
  Caption := 'Expansor de texto';
  Hint := 'Digite o atalho em qualquer programa: ele some e o texto do snippet entra no lugar';
  FToggle := NewToggleRow(Self, 'Expansor ligado',
    'Atalho começa com ";" (;sql, ;log-api). Campos {{nome}} são perguntados antes de colar.', ToggleChange);
  // Marcar dispara o OnChange, e a tabela ainda não existe.
  FToggle.OnChange := nil;
  FToggle.Checked := Store.GetSetting('expander_on', '1') = '1';
  FToggle.OnChange := ToggleChange;
  Bar := NewPanel(Self, alTop, 52);
  Bar.Padding.SetBounds(0, ScaleValue(8), 0, ScaleValue(8));
  NewButton(Bar, 'Novo snippet', NewClick, bvPrimary);
  NewButton(Bar, 'Editar', EditClick);
  NewButton(Bar, 'Tirar atalho', RemoveClick, bvGhost);
  FTable := TUIDataTable.Create(Self);
  FTable.SelectionMode := tsmSingle;
  FTable.Density := tdCompact;
  FTable.OnRowSelect := RowSelect;
  FTable.OnRowDblClick := RowDblClick;
  FTable.AddColumn('abbrev', 'Atalho', 'abbrev', 140);
  FTable.AddColumn('text', 'Vira', 'text', 420);
  FTable.AddColumn('fields', 'Campos', 'fields', 170);
  FTable.AddColumn('kind', 'Tipo', 'kind', 100);
  FTable.SetColType('kind', ctBadge);
  FTable.AddBadgeMap('kind', 'snippet', UITheme.Tokens.Color.PrimarySubtle, UITheme.Tokens.Color.Primary);
  FTable.AddBadgeMap('kind', 'pronto', UITheme.Tokens.Color.SuccessSubtle, UITheme.Tokens.Color.Success);
  FTable.EmptyStateText := 'Nenhum atalho ainda';
  FTable.Align := alClient;
  FTable.Top := 100000;
  FTable.Parent := Self;
  FSel := -1;
  Reload;
end;

procedure TExpanderPage.PageShown;
begin
  Reload;
end;

procedure TExpanderPage.Reload;
var
  C: TClip;
  I: Integer;
begin
  FRows := nil;
  for C in Store.ListClips do
    if C.Pinned and (C.Abbrev <> '') then
      FRows := FRows + [C];
  FTable.BeginRowUpdate;
  try
    FTable.ClearMemRows;
    for C in FRows do
      FTable.AddMemRow([C.Abbrev, C.Title, string.Join(', ', TemplateFields(C.Text)), 'snippet']);
    for I := 0 to High(BuiltinAbbrevs) do
      FTable.AddMemRow([BuiltinAbbrevs[I], BuiltinHelp[I], '', 'pronto']);
  finally
    FTable.EndRowUpdate;
  end;
  FSel := -1;
end;

function TExpanderPage.Abbrevs: TArray<string>;
var
  C: TClip;
  B: string;
begin
  Result := nil;
  for C in Store.ListClips do
    if C.Pinned and (C.Abbrev <> '') then
      Result := Result + [C.Abbrev];
  for B in BuiltinAbbrevs do
    Result := Result + [B];
end;

function TExpanderPage.OtherAbbrevs(AExceptId: Integer): TArray<string>;
var
  C: TClip;
begin
  Result := nil;
  for C in Store.ListClips do
    if C.Pinned and (C.Abbrev <> '') and (C.Id <> AExceptId) then
      Result := Result + [C.Abbrev];
end;

procedure TExpanderPage.Changed;
begin
  Reload;
  if Assigned(FOnChanged) then
    FOnChanged(Self);
end;

function TExpanderPage.SelectedSnippet(out AClip: TClip): Boolean;
begin
  // As linhas de snippet vêm primeiro; as de baixo são os prontos.
  Result := (FSel >= 0) and (FSel <= High(FRows));
  if Result then
    AClip := FRows[FSel];
end;

function TExpanderPage.EditSnippetById(AId: Integer): Boolean;
var
  C: TClip;
  Text, Abbrev: string;
begin
  Text := '';
  Abbrev := '';
  for C in Store.ListClips do
    if C.Id = AId then
    begin
      Text := C.Text;
      Abbrev := C.Abbrev;
    end;
  Result := EditSnippet(Text, Abbrev, OtherAbbrevs(AId));
  if not Result then
    Exit;
  Store.SaveSnippet(AId, Text, Abbrev);
  Changed;
  TUIToastManager.Show(IfThen(Abbrev = '', 'Snippet salvo', 'Snippet salvo. Digite ' + Abbrev + ' em qualquer lugar.'),
    ttSuccess, 3500);
end;

procedure TExpanderPage.ToggleChange(Sender: TObject);
begin
  Store.SetSetting('expander_on', IfThen(FToggle.Checked, '1', '0'));
  Changed;
end;

procedure TExpanderPage.RowSelect(Sender: TObject; ARowIndex: Integer);
begin
  FSel := ARowIndex;
end;

procedure TExpanderPage.RowDblClick(Sender: TObject; ARowIdx: Integer);
begin
  EditClick(nil);
end;

procedure TExpanderPage.NewClick(Sender: TObject);
begin
  EditSnippetById(0);
end;

procedure TExpanderPage.EditClick(Sender: TObject);
var
  C: TClip;
begin
  if SelectedSnippet(C) then
    EditSnippetById(C.Id)
  else
    TUIToastManager.Show('Escolha um snippet da lista. Os prontos não mudam.', ttInfo, 3000);
end;

procedure TExpanderPage.RemoveClick(Sender: TObject);
var
  C: TClip;
begin
  if not SelectedSnippet(C) then
    Exit;
  Store.SetAbbrev(C.Id, '');
  Changed;
  TUIToastManager.Show('Atalho tirado. O snippet continua no Clipboard.', ttSuccess, 3000);
end;

end.
