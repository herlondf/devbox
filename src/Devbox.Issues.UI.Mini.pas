unit Devbox.Issues.UI.Mini;

{ Janela mini: pequena, sempre por cima, arrastável. Mostra os contadores e
  as issues que pedem ação agora; clique numa linha abre a issue no Vigia.
  A posição fica salva. }

interface

uses
  System.Classes,
  System.SysUtils,
  Winapi.Messages,
  Vcl.Controls,
  Vcl.Forms,
  Vcl.ExtCtrls,
  UI.Labels,
  Devbox.Issues.Model;

type
  TMiniOpenEvent = procedure(const AKey: string; AAccountId: Integer) of object;

  TMiniForm = class(TForm)
  private
    FHeader: TUILabel;
    FRows: TPanel;
    FItems: TItems;
    FOnOpen: TMiniOpenEvent;
    FOnClosed: TNotifyEvent;
    procedure RowClick(Sender: TObject);
    procedure HeaderMouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
    procedure CloseClick(Sender: TObject);
  protected
    procedure CreateParams(var Params: TCreateParams); override;
    procedure CreateWnd; override;
    procedure DoClose(var Action: TCloseAction); override;
  public
    constructor Create(AOwner: TComponent); override;
    { ANow = issues que pedem ação, já em ordem; os números vão no topo. }
    procedure ShowData(const ANow: TItems; AOverdue, AMine, ATotal: Integer);
    property OnOpen: TMiniOpenEvent read FOnOpen write FOnOpen;
    property OnClosed: TNotifyEvent read FOnClosed write FOnClosed;
  end;

implementation

uses
  Devbox.I18n,
  Winapi.Windows,
  System.Math,
  UI.Theme,
  UI.Button,
  UI.Painter.Vcl,
  Devbox.Issues.Store,
  Devbox.Issues.UI.Common;

const
  MiniW = 340;
  MaxRows = 6;
  RowH = 40;
  HeadH = 44;

constructor TMiniForm.Create(AOwner: TComponent);
var
  Head: TPanel;
  Btn: TUIButton;
  Pos: TArray<string>;
begin
  inherited CreateNew(AOwner);
  BorderStyle := bsNone;
  FormStyle := fsStayOnTop;
  Position := poDesigned;
  Color := UIThemeVclBackground;
  DoubleBuffered := True;
  ClientWidth := ScaleValue(MiniW);
  ClientHeight := ScaleValue(HeadH + RowH);

  Head := TPanel.Create(Self);
  Head.BevelOuter := bvNone;
  Head.ParentBackground := False;
  Head.Color := UIThemeVclBackground;
  Head.Height := ScaleValue(HeadH);
  Head.Padding.SetBounds(ScaleValue(12), ScaleValue(6), ScaleValue(6), ScaleValue(6));
  Head.Align := alTop;
  Head.Parent := Self;
  Head.OnMouseDown := HeaderMouseDown;
  Btn := TUIButton.Create(Self);
  Btn.Caption := '×';
  Btn.Variant := bvGhost;
  Btn.Size := UI.Button.bsSM;
  Btn.Width := ScaleValue(30);
  Btn.Hint := Tr('Fechar a janela mini');
  Btn.ShowHint := True;
  Btn.OnClick := CloseClick;
  Btn.Align := alRight;
  Btn.Parent := Head;
  FHeader := TUILabel.Create(Self);
  FHeader.Bold := True;
  FHeader.AutoSize := False;
  FHeader.Align := alClient;
  FHeader.Parent := Head;
  FHeader.OnMouseDown := HeaderMouseDown;
  FHeader.Hint := Tr('Arraste para mover');
  FHeader.ShowHint := True;

  FRows := TPanel.Create(Self);
  FRows.BevelOuter := bvNone;
  FRows.ParentBackground := False;
  FRows.Color := UIThemeVclBackground;
  FRows.Align := alClient;
  FRows.Parent := Self;

  // Posição salva; sem ela, canto superior direito da área útil.
  Pos := IssueStore.GetSetting('mini_pos').Split([',']);
  if Length(Pos) = 2 then
    SetBounds(StrToIntDef(Pos[0], 0), StrToIntDef(Pos[1], 0), Width, Height)
  else
    SetBounds(Screen.WorkAreaRect.Right - Width - ScaleValue(16), Screen.WorkAreaRect.Top + ScaleValue(16),
      Width, Height);
  // Monitor desligado desde a última vez: volta para a tela.
  if Screen.MonitorFromRect(BoundsRect, mdNull) = nil then
    SetBounds(Screen.WorkAreaRect.Right - Width - ScaleValue(16), Screen.WorkAreaRect.Top + ScaleValue(16),
      Width, Height);
end;

procedure TMiniForm.CreateParams(var Params: TCreateParams);
begin
  inherited;
  // Fora da barra de tarefas; borda fina para destacar do fundo.
  Params.ExStyle := Params.ExStyle or WS_EX_TOOLWINDOW;
  Params.Style := Params.Style or WS_BORDER;
  Params.WndParent := 0;
end;

procedure TMiniForm.CreateWnd;
begin
  inherited;
  ApplyTitleBarTheme(Self);
end;

procedure TMiniForm.DoClose(var Action: TCloseAction);
begin
  IssueStore.SetSetting('mini_pos', Format('%d,%d', [Left, Top]));
  Action := caHide;
  inherited;
  if Assigned(FOnClosed) then
    FOnClosed(Self);
end;

procedure TMiniForm.CloseClick(Sender: TObject);
begin
  Close;
end;

{ Arrastar pelo topo: a janela não tem barra de título. }
procedure TMiniForm.HeaderMouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
begin
  if Button <> mbLeft then
    Exit;
  ReleaseCapture;
  Perform(WM_SYSCOMMAND, SC_MOVE or HTCAPTION, 0);
  IssueStore.SetSetting('mini_pos', Format('%d,%d', [Left, Top]));
end;

procedure TMiniForm.RowClick(Sender: TObject);
var
  I: Integer;
begin
  I := TComponent(Sender).Tag;
  if (I >= 0) and (I <= High(FItems)) and Assigned(FOnOpen) then
    FOnOpen(FItems[I].Key, FItems[I].AccountId);
end;

procedure TMiniForm.ShowData(const ANow: TItems; AOverdue, AMine, ATotal: Integer);
var
  I, N: Integer;
  Row: TPanel;
  Key, Title: TUILabel;
begin
  FItems := Copy(ANow, 0, MaxRows);
  FHeader.Caption := Format(Tr('Agora %d  ·  Atrasadas %d  ·  Comigo %d'), [Length(ANow), AOverdue, AMine]);
  FHeader.Hint := Format(Tr('%d issues acompanhadas. Arraste para mover.'), [ATotal]);
  while FRows.ControlCount > 0 do
    FRows.Controls[0].Free;
  N := Length(FItems);
  for I := 0 to N - 1 do
  begin
    Row := TPanel.Create(FRows);
    Row.BevelOuter := bvNone;
    Row.ParentBackground := False;
    Row.Color := UIThemeVclBackground;
    Row.Height := ScaleValue(RowH);
    Row.Padding.SetBounds(ScaleValue(12), ScaleValue(2), ScaleValue(10), ScaleValue(2));
    Row.Cursor := crHandPoint;
    Row.Tag := I;
    Row.OnClick := RowClick;
    Row.Parent := FRows;
    Row.Top := (I + 1) * 1000;
    Row.Align := alTop;
    Key := TUILabel.Create(Row);
    Key.Caption := FItems[I].Key;
    Key.Variant := lvMuted;
    Key.FontSize := HintFontSize;
    Key.AutoSize := False;
    Key.Height := ScaleValue(16);
    Key.Cursor := crHandPoint;
    Key.Tag := I;
    Key.OnClick := RowClick;
    Key.Align := alTop;
    Key.Parent := Row;
    Title := TUILabel.Create(Row);
    Title.Caption := FItems[I].Title;
    Title.AutoSize := False;
    Title.Cursor := crHandPoint;
    Title.Tag := I;
    Title.OnClick := RowClick;
    Title.Top := 1000;
    Title.Align := alClient;
    Title.Parent := Row;
  end;
  if N = 0 then
  begin
    Title := TUILabel.Create(FRows);
    Title.Caption := Tr('Nada pedindo ação agora.');
    Title.Variant := lvMuted;
    Title.Italic := True;
    Title.AutoSize := False;
    Title.AlignWithMargins := True;
    Title.Margins.SetBounds(ScaleValue(12), ScaleValue(8), 0, 0);
    Title.Align := alClient;
    Title.Parent := FRows;
  end;
  ClientHeight := ScaleValue(HeadH) + ScaleValue(RowH) * Max(1, N) + ScaleValue(6);
end;

end.
