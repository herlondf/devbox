unit Devbox.UI.DialogBase;

{ Base dos diálogos (janela com corpo e rodapé OK/Cancelar) e o diálogo de
  campos do expansor. Separado dos outros diálogos para o DevboxHelper.exe
  não carregar rede, agendador e ambientes. }

interface

uses
  System.SysUtils,
  System.Classes,
  Vcl.Forms,
  Vcl.ExtCtrls,
  UI.Input;

type
  TDialogForm = class(TForm)
  private
    FBody: TPanel;
    FOnValidate: TFunc<Boolean>;
    procedure OkClick(Sender: TObject);
    procedure CancelClick(Sender: TObject);
  protected
    procedure CreateWnd; override;
  public
    constructor CreateDialog(const ACaption: string; AWidth, AHeight: Integer);
    property Body: TPanel read FBody;
    property OnValidate: TFunc<Boolean> read FOnValidate write FOnValidate;
  end;

function NewInput(AForm: TDialogForm; const ALabel: string): TUIInput;

{ Mostra um texto longo (resposta da IA) com rolagem e botão de copiar. }
procedure ShowTextDialog(const ATitle, AText: string);

{ Um campo por nome; AValues sai na mesma ordem. Fica por cima de tudo. }
function AskFields(const ATitle: string; const AFields: TArray<string>; out AValues: TArray<string>): Boolean;

implementation

uses
  Winapi.Windows,
  System.UITypes,
  System.Math,
  Vcl.Controls,
  Winapi.Dwmapi,
  UI.Theme,
  UI.Button,
  UI.Painter.Vcl,
  Vcl.Clipbrd,
  UI.Code,
  UI.ScrollArea,
  UI.Toast,
  Devbox.Sys,
  Devbox.UI.Kit;

constructor TDialogForm.CreateDialog(const ACaption: string; AWidth, AHeight: Integer);
var
  Footer: TPanel;

  procedure Btn(const ACaption: string; AVariant: TUIButtonVariant; AClick: TNotifyEvent; ADefault: Boolean);
  var
    B: TUIButton;
  begin
    B := TUIButton.Create(Self);
    B.Caption := ACaption;
    B.Variant := AVariant;
    B.AutoWidth := True;
    B.OnClick := AClick;
    B.Default := ADefault;
    B.Cancel := not ADefault;
    B.AlignWithMargins := True;
    B.Margins.SetBounds(ScaleValue(8), 0, 0, 0);
    B.Align := alRight;
    B.Parent := Footer;
  end;

begin
  inherited CreateNew(nil);
  Caption := ACaption;
  BorderStyle := bsDialog;
  Position := poScreenCenter;
  ClientWidth := ScaleValue(AWidth);
  ClientHeight := ScaleValue(AHeight);
  KeyPreview := True;
  Color := UIThemeVclBackground;
  Footer := TPanel.Create(Self);
  Footer.BevelOuter := bvNone;
  Footer.ParentBackground := False;
  Footer.Height := ScaleValue(60);
  Footer.Padding.SetBounds(ScaleValue(16), ScaleValue(12), ScaleValue(16), ScaleValue(12));
  Footer.Align := alBottom;
  Footer.Parent := Self;
  // alRight: o criado primeiro fica mais à direita.
  Btn('OK', bvPrimary, OkClick, True);
  Btn('Cancelar', bvOutline, CancelClick, False);
  FBody := TPanel.Create(Self);
  FBody.BevelOuter := bvNone;
  FBody.ParentBackground := False;
  FBody.Padding.SetBounds(ScaleValue(16), ScaleValue(16), ScaleValue(16), 0);
  FBody.Align := alClient;
  FBody.Parent := Self;
end;

procedure TDialogForm.CreateWnd;
const
  DWMWA_USE_IMMERSIVE_DARK_MODE = 20;
var
  Dark: BOOL;
begin
  inherited;
  Dark := UITheme.IsDark;
  DwmSetWindowAttribute(Handle, DWMWA_USE_IMMERSIVE_DARK_MODE, @Dark, SizeOf(Dark));
end;

procedure TDialogForm.OkClick(Sender: TObject);
begin
  if Assigned(FOnValidate) and not FOnValidate() then
    Exit;
  ModalResult := mrOk;
end;

procedure TDialogForm.CancelClick(Sender: TObject);
begin
  ModalResult := mrCancel;
end;

function NewInput(AForm: TDialogForm; const ALabel: string): TUIInput;
begin
  Result := TUIInput.Create(AForm);
  Result.LabelMode := ilmBorder;
  Result.LabelText := ALabel;
  Result.ReserveHintSpace := False;
  Result.AlignWithMargins := True;
  Result.Margins.SetBounds(0, 0, 0, AForm.ScaleValue(12));
  Result.Top := 100000;
  Result.Align := alTop;
  Result.Parent := AForm.Body;
end;

function AskFields(const ATitle: string; const AFields: TArray<string>; out AValues: TArray<string>): Boolean;
const
  CRowHeight = 50;
  CChrome = 110;
var
  F: TDialogForm;
  Inputs: TArray<TUIInput>;
  I: Integer;
begin
  F := TDialogForm.CreateDialog('Preencher: ' + ATitle, 460, CChrome + Length(AFields) * CRowHeight);
  try
    F.FormStyle := fsStayOnTop;
    SetLength(Inputs, Length(AFields));
    for I := 0 to High(AFields) do
      Inputs[I] := NewInput(F, AFields[I]);
    F.ActiveControl := Inputs[0];
    PaintPanels(F);
    // O foco está em outro programa: sem isto a janela só pisca na barra de tarefas.
    F.HandleNeeded;
    ForceForeground(F.Handle);
    Result := F.ShowModal = mrOk;
    SetLength(AValues, Length(AFields));
    for I := 0 to High(AFields) do
      AValues[I] := Inputs[I].Value;
  finally
    F.Free;
  end;
end;

procedure ShowTextDialog(const ATitle, AText: string);
const
  CLineHeight = 17;
var
  F: TDialogForm;
  Scroll: TUIScrollArea;
  Code: TUICode;
  Lines: Integer;
  Text: string;
begin
  F := TDialogForm.CreateDialog(ATitle, 720, 520);
  try
    Text := StringReplace(AText, #13, '', [rfReplaceAll]);
    Scroll := TUIScrollArea.Create(F);
    Scroll.Align := alClient;
    Scroll.Parent := F.Body;
    Code := TUICode.Create(F);
    Code.Text := Text;
    Lines := Length(Text) - Length(StringReplace(Text, #10, '', [rfReplaceAll])) + 1;
    Code.Height := F.ScaleValue(Max(Lines * CLineHeight + 40, 200));
    Code.Align := alTop;
    Code.Parent := Scroll.InnerPanel;
    // OK copia: quem abre uma resposta quase sempre quer levar para algum lugar.
    F.OnValidate :=
      function: Boolean
      begin
        Clipboard.AsText := AText;
        TUIToastManager.Show('Resposta copiada', ttSuccess, 1500);
        Result := True;
      end;
    PaintPanels(F);
    F.ShowModal;
  finally
    F.Free;
  end;
end;

end.
