unit Devbox.UI.Capture;

{ Captura de tela para relato de bug: tira a tela toda, a pessoa arrasta a
  região, e um editor simples marca o que importa (seta, retângulo, texto,
  número de passo) e borra o que é sensível. Copiar põe a imagem no clipboard
  (e no histórico do Devbox); Salvar grava PNG. }

interface

uses
  System.SysUtils;

{ Começa a captura. Esc cancela. }
procedure StartCapture;

implementation

uses
  Winapi.Windows,
  Winapi.Messages,
  System.Classes,
  System.Types,
  System.UITypes,
  System.Math,
  System.Generics.Collections,
  Vcl.Controls,
  Vcl.Forms,
  Vcl.Graphics,
  Vcl.ExtCtrls,
  Vcl.Dialogs,
  Vcl.Clipbrd,
  Vcl.Imaging.pngimage,
  UI.Theme,
  UI.Button,
  UI.Toast,
  UI.Painter.Vcl,
  Devbox.UI.Kit,
  Devbox.UI.DialogBase;

type
  TTool = (tlArrow, tlRect, tlText, tlNumber, tlBlur);

  TShape = record
    Tool: TTool;
    A, B: TPoint;          // em pixels da imagem
    Text: string;
  end;

  { Tela cheia por cima de tudo com a captura escurecida; o retângulo arrastado
    aparece claro. }
  TSelectForm = class(TForm)
  private
    FShot: TBitmap;
    FDim: TBitmap;
    FStart, FEnd: TPoint;
    FDragging: Boolean;
    FOrigin: TPoint;       // canto da tela virtual (pode ser negativo com 2 monitores)
  protected
    procedure Paint; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
    procedure WMEraseBkgnd(var Message: TWMEraseBkgnd); message WM_ERASEBKGND;
  public
    constructor CreateShot;
    destructor Destroy; override;
  end;

  TAnnotateForm = class(TForm)
  private
    FImage: TBitmap;
    FShapes: TList<TShape>;
    FTool: TTool;
    FToolButtons: array[TTool] of TUIButton;
    FBox: TPaintBox;
    FScale: Single;
    FDragging: Boolean;
    FCurrent: TShape;
    FNextNumber: Integer;
    procedure ToolClick(Sender: TObject);
    procedure UndoClick(Sender: TObject);
    procedure CopyClick(Sender: TObject);
    procedure SaveClick(Sender: TObject);
    procedure SelectTool(ATool: TTool);
    procedure BoxPaint(Sender: TObject);
    procedure BoxDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
    procedure BoxMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
    procedure BoxUp(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
    function ToImage(X, Y: Integer): TPoint;
    function Render: TBitmap;
    procedure DrawShape(ACanvas: TCanvas; const AShape: TShape; ABase: TBitmap);
    procedure FormClose(Sender: TObject; var Action: TCloseAction);
  protected
    procedure Resize; override;
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
  public
    constructor CreateFor(AImage: TBitmap);
    destructor Destroy; override;
  end;

const
  CAPTUREBLT = $40000000;           // inclui janelas em camadas (menus, tooltips)
  CMarkColor = TColor($2626DC);     // vermelho (BGR)
  CPenWidth = 4;
  CBlurBlock = 12;
  CNumberRadius = 16;

{ Tela }

function CaptureScreen(out AOrigin: TPoint): TBitmap;
var
  DC: HDC;
  W, H: Integer;
begin
  AOrigin := Point(GetSystemMetrics(SM_XVIRTUALSCREEN), GetSystemMetrics(SM_YVIRTUALSCREEN));
  W := GetSystemMetrics(SM_CXVIRTUALSCREEN);
  H := GetSystemMetrics(SM_CYVIRTUALSCREEN);
  Result := TBitmap.Create;
  Result.PixelFormat := pf24bit;
  Result.SetSize(W, H);
  DC := GetDC(0);
  try
    BitBlt(Result.Canvas.Handle, 0, 0, W, H, DC, AOrigin.X, AOrigin.Y, SRCCOPY or CAPTUREBLT);
  finally
    ReleaseDC(0, DC);
  end;
end;

procedure StartCapture;
begin
  TSelectForm.CreateShot.Show;
end;

{ TSelectForm }

constructor TSelectForm.CreateShot;
const
  CDimAlpha = 110;
var
  Blend: TBlendFunction;
  Black: TBitmap;
begin
  inherited CreateNew(nil);
  FShot := CaptureScreen(FOrigin);
  // Cópia escurecida para o fundo; a região escolhida mostra a original.
  FDim := TBitmap.Create;
  FDim.Assign(FShot);
  Black := TBitmap.Create;
  try
    Black.SetSize(1, 1);
    Black.Canvas.Pixels[0, 0] := clBlack;
    Blend.BlendOp := AC_SRC_OVER;
    Blend.BlendFlags := 0;
    Blend.SourceConstantAlpha := CDimAlpha;
    Blend.AlphaFormat := 0;
    Winapi.Windows.AlphaBlend(FDim.Canvas.Handle, 0, 0, FDim.Width, FDim.Height, Black.Canvas.Handle, 0, 0, 1, 1, Blend);
  finally
    Black.Free;
  end;
  BorderStyle := bsNone;
  FormStyle := fsStayOnTop;
  Cursor := crCross;
  KeyPreview := True;
  DoubleBuffered := True;
  Scaled := False;
  HandleNeeded;
  SetWindowPos(Handle, HWND_TOPMOST, FOrigin.X, FOrigin.Y, FShot.Width, FShot.Height, SWP_NOACTIVATE);
end;

destructor TSelectForm.Destroy;
begin
  FShot.Free;
  FDim.Free;
  inherited;
end;

procedure TSelectForm.WMEraseBkgnd(var Message: TWMEraseBkgnd);
begin
  Message.Result := 1;
end;

procedure TSelectForm.Paint;
var
  R: TRect;
begin
  Canvas.Draw(0, 0, FDim);
  if FDragging then
  begin
    R := Rect(Min(FStart.X, FEnd.X), Min(FStart.Y, FEnd.Y), Max(FStart.X, FEnd.X), Max(FStart.Y, FEnd.Y));
    Canvas.CopyRect(R, FShot.Canvas, R);
    Canvas.Brush.Style := bsClear;
    Canvas.Pen.Color := RGB(99, 102, 241);
    Canvas.Pen.Width := 2;
    Canvas.Rectangle(R);
    Canvas.Font.Color := clWhite;
    Canvas.Font.Size := 10;
    Canvas.TextOut(R.Left, Max(R.Top - 20, 0), Format('%d × %d', [R.Width, R.Height]));
  end
  else
  begin
    Canvas.Font.Color := clWhite;
    Canvas.Font.Size := 14;
    Canvas.Brush.Style := bsClear;
    Canvas.TextOut(40, 40, 'Arraste para escolher a região  ·  Esc cancela');
  end;
end;

procedure TSelectForm.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  if Button <> mbLeft then
    Exit;
  FDragging := True;
  FStart := Point(X, Y);
  FEnd := FStart;
  Invalidate;
end;

procedure TSelectForm.MouseMove(Shift: TShiftState; X, Y: Integer);
begin
  if FDragging then
  begin
    FEnd := Point(X, Y);
    Invalidate;
  end;
end;

procedure TSelectForm.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
const
  CMinSide = 8;
var
  R: TRect;
  Part: TBitmap;
begin
  if not FDragging then
    Exit;
  FDragging := False;
  R := Rect(Min(FStart.X, X), Min(FStart.Y, Y), Max(FStart.X, X), Max(FStart.Y, Y));
  if (R.Width < CMinSide) or (R.Height < CMinSide) then
  begin
    Invalidate;
    Exit;
  end;
  Part := TBitmap.Create;
  Part.PixelFormat := pf24bit;
  Part.SetSize(R.Width, R.Height);
  Part.Canvas.CopyRect(Rect(0, 0, R.Width, R.Height), FShot.Canvas, R);
  Hide;
  TAnnotateForm.CreateFor(Part).Show;
  Release;
end;

procedure TSelectForm.KeyDown(var Key: Word; Shift: TShiftState);
begin
  if Key = VK_ESCAPE then
    Release;
end;

{ TAnnotateForm }

constructor TAnnotateForm.CreateFor(AImage: TBitmap);
const
  ToolNames: array[TTool] of string = ('Seta', 'Retângulo', 'Texto', 'Número', 'Borrar');
var
  Bar: TPanel;
  T: TTool;

  function Btn(const ACaption: string; AClick: TNotifyEvent; AVariant: TUIButtonVariant;
    AAlign: TAlign = alLeft): TUIButton;
  begin
    Result := TUIButton.Create(Self);
    Result.Caption := ACaption;
    Result.Variant := AVariant;
    Result.AutoWidth := True;
    Result.OnClick := AClick;
    Result.AlignWithMargins := True;
    Result.Margins.SetBounds(0, 0, ScaleValue(6), 0);
    Result.Left := 100000;
    Result.Align := AAlign;
    Result.Parent := Bar;
  end;

begin
  inherited CreateNew(nil);
  FImage := AImage;
  FShapes := TList<TShape>.Create;
  FNextNumber := 1;
  Caption := 'Devbox  ·  marcar captura';
  Position := poScreenCenter;
  KeyPreview := True;
  Color := UIThemeVclBackground;
  ClientWidth := Min(Max(FImage.Width + 40, ScaleValue(940)), Screen.WorkAreaWidth - 80);
  ClientHeight := Min(FImage.Height + ScaleValue(110), Screen.WorkAreaHeight - 80);
  FormStyle := fsStayOnTop;
  OnClose := FormClose;

  Bar := TPanel.Create(Self);
  Bar.BevelOuter := bvNone;
  Bar.ParentBackground := False;
  Bar.Color := UIThemeVclBackground;
  Bar.Height := ScaleValue(56);
  Bar.Padding.SetBounds(ScaleValue(12), ScaleValue(10), ScaleValue(12), ScaleValue(10));
  Bar.Align := alTop;
  Bar.Parent := Self;
  for T := Low(TTool) to High(TTool) do
  begin
    FToolButtons[T] := Btn(ToolNames[T], ToolClick, bvGhost);
    FToolButtons[T].Tag := Ord(T);
  end;
  Btn('Desfazer', UndoClick, bvGhost);
  Btn('Copiar', CopyClick, bvPrimary, alRight);
  Btn('Salvar PNG…', SaveClick, bvOutline, alRight);

  FBox := TPaintBox.Create(Self);
  FBox.Align := alClient;
  FBox.OnPaint := BoxPaint;
  FBox.OnMouseDown := BoxDown;
  FBox.OnMouseMove := BoxMove;
  FBox.OnMouseUp := BoxUp;
  FBox.Cursor := crCross;
  FBox.Parent := Self;
  SelectTool(tlArrow);
end;

destructor TAnnotateForm.Destroy;
begin
  FShapes.Free;
  FImage.Free;
  inherited;
end;

procedure TAnnotateForm.Resize;
begin
  inherited;
  if (FImage <> nil) and (FBox <> nil) and (FBox.Width > 0) then
    FScale := Min(1, Min(FBox.Width / FImage.Width, FBox.Height / FImage.Height));
end;

procedure TAnnotateForm.SelectTool(ATool: TTool);
var
  T: TTool;
begin
  FTool := ATool;
  for T := Low(TTool) to High(TTool) do
    if T = ATool then
      FToolButtons[T].Variant := bvPrimary
    else
      FToolButtons[T].Variant := bvGhost;
end;

procedure TAnnotateForm.ToolClick(Sender: TObject);
begin
  SelectTool(TTool(TComponent(Sender).Tag));
end;

procedure TAnnotateForm.UndoClick(Sender: TObject);
begin
  if FShapes.Count = 0 then
    Exit;
  if FShapes.Last.Tool = tlNumber then
    Dec(FNextNumber);
  FShapes.Delete(FShapes.Count - 1);
  FBox.Invalidate;
end;

function TAnnotateForm.ToImage(X, Y: Integer): TPoint;
begin
  if FScale <= 0 then
    FScale := 1;
  Result := Point(Round(X / FScale), Round(Y / FScale));
end;

procedure Pixelate(ABmp: TBitmap; const ARect: TRect);
var
  R: TRect;
  X, Y: Integer;
  C: TColor;
begin
  R := ARect;
  IntersectRect(R, R, Rect(0, 0, ABmp.Width, ABmp.Height));
  Y := R.Top;
  while Y < R.Bottom do
  begin
    X := R.Left;
    while X < R.Right do
    begin
      C := ABmp.Canvas.Pixels[X, Y];
      ABmp.Canvas.Brush.Color := C;
      ABmp.Canvas.FillRect(Rect(X, Y, Min(X + CBlurBlock, R.Right), Min(Y + CBlurBlock, R.Bottom)));
      Inc(X, CBlurBlock);
    end;
    Inc(Y, CBlurBlock);
  end;
end;

procedure TAnnotateForm.DrawShape(ACanvas: TCanvas; const AShape: TShape; ABase: TBitmap);
var
  R: TRect;
  Angle: Double;
  Head: Integer;
  P1, P2: TPoint;
  S: string;
  W: Integer;
begin
  ACanvas.Pen.Color := CMarkColor;
  ACanvas.Pen.Width := CPenWidth;
  ACanvas.Brush.Style := bsClear;
  R := Rect(Min(AShape.A.X, AShape.B.X), Min(AShape.A.Y, AShape.B.Y), Max(AShape.A.X, AShape.B.X),
    Max(AShape.A.Y, AShape.B.Y));
  case AShape.Tool of
    tlRect:
      ACanvas.Rectangle(R);
    tlArrow:
      begin
        ACanvas.MoveTo(AShape.A.X, AShape.A.Y);
        ACanvas.LineTo(AShape.B.X, AShape.B.Y);
        Angle := ArcTan2(AShape.B.Y - AShape.A.Y, AShape.B.X - AShape.A.X);
        Head := 18;
        P1 := Point(AShape.B.X - Round(Head * Cos(Angle - Pi / 7)), AShape.B.Y - Round(Head * Sin(Angle - Pi / 7)));
        P2 := Point(AShape.B.X - Round(Head * Cos(Angle + Pi / 7)), AShape.B.Y - Round(Head * Sin(Angle + Pi / 7)));
        ACanvas.Brush.Style := bsSolid;
        ACanvas.Brush.Color := CMarkColor;
        ACanvas.Polygon([AShape.B, P1, P2]);
      end;
    tlText:
      begin
        ACanvas.Font.Name := 'Segoe UI';
        ACanvas.Font.Size := 16;
        ACanvas.Font.Style := [fsBold];
        ACanvas.Font.Color := CMarkColor;
        // Fundo branco atrás do texto: lê em cima de qualquer tela.
        W := ACanvas.TextWidth(AShape.Text);
        ACanvas.Brush.Style := bsSolid;
        ACanvas.Brush.Color := clWhite;
        ACanvas.FillRect(Rect(AShape.A.X - 4, AShape.A.Y - 2, AShape.A.X + W + 4, AShape.A.Y + ACanvas.TextHeight('Ag') + 2));
        ACanvas.TextOut(AShape.A.X, AShape.A.Y, AShape.Text);
      end;
    tlNumber:
      begin
        ACanvas.Brush.Style := bsSolid;
        ACanvas.Brush.Color := CMarkColor;
        ACanvas.Pen.Color := clWhite;
        ACanvas.Pen.Width := 2;
        ACanvas.Ellipse(AShape.A.X - CNumberRadius, AShape.A.Y - CNumberRadius, AShape.A.X + CNumberRadius,
          AShape.A.Y + CNumberRadius);
        ACanvas.Font.Name := 'Segoe UI';
        ACanvas.Font.Size := 13;
        ACanvas.Font.Style := [fsBold];
        ACanvas.Font.Color := clWhite;
        ACanvas.Brush.Style := bsClear;
        S := AShape.Text;
        ACanvas.TextOut(AShape.A.X - ACanvas.TextWidth(S) div 2, AShape.A.Y - ACanvas.TextHeight(S) div 2, S);
      end;
    tlBlur:
      if ABase <> nil then
        Pixelate(ABase, R);
  end;
end;

{ Imagem final em tamanho real: borrões primeiro (mexem nos pixels), marcas depois. }
function TAnnotateForm.Render: TBitmap;
var
  S: TShape;
begin
  Result := TBitmap.Create;
  Result.Assign(FImage);
  for S in FShapes do
    if S.Tool = tlBlur then
      DrawShape(Result.Canvas, S, Result);
  for S in FShapes do
    if S.Tool <> tlBlur then
      DrawShape(Result.Canvas, S, nil);
end;

procedure TAnnotateForm.BoxPaint(Sender: TObject);
var
  Final: TBitmap;
  Shapes: TList<TShape>;
begin
  // Mostra o resultado (com o que está sendo arrastado) na escala da janela.
  if FDragging and (FCurrent.Tool in [tlArrow, tlRect, tlBlur]) then
  begin
    Shapes := FShapes;
    Shapes.Add(FCurrent);
    try
      Final := Render;
    finally
      Shapes.Delete(Shapes.Count - 1);
    end;
  end
  else
    Final := Render;
  try
    if FScale <= 0 then
      Resize;
    SetStretchBltMode(FBox.Canvas.Handle, HALFTONE);
    FBox.Canvas.StretchDraw(Rect(0, 0, Round(Final.Width * FScale), Round(Final.Height * FScale)), Final);
  finally
    Final.Free;
  end;
end;

procedure TAnnotateForm.BoxDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  S: TShape;
  Values: TArray<string>;
begin
  if Button <> mbLeft then
    Exit;
  S := Default(TShape);
  S.Tool := FTool;
  S.A := ToImage(X, Y);
  S.B := S.A;
  case FTool of
    tlText:
      begin
        if not AskFields('texto na captura', ['Texto'], Values) or (Trim(Values[0]) = '') then
          Exit;
        S.Text := Values[0];
        FShapes.Add(S);
        FBox.Invalidate;
      end;
    tlNumber:
      begin
        S.Text := IntToStr(FNextNumber);
        Inc(FNextNumber);
        FShapes.Add(S);
        FBox.Invalidate;
      end;
  else
    FCurrent := S;
    FDragging := True;
  end;
end;

procedure TAnnotateForm.BoxMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
begin
  if not FDragging then
    Exit;
  FCurrent.B := ToImage(X, Y);
  FBox.Invalidate;
end;

procedure TAnnotateForm.BoxUp(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  if not FDragging then
    Exit;
  FDragging := False;
  FCurrent.B := ToImage(X, Y);
  if (Abs(FCurrent.B.X - FCurrent.A.X) > 3) or (Abs(FCurrent.B.Y - FCurrent.A.Y) > 3) then
    FShapes.Add(FCurrent);
  FBox.Invalidate;
end;

procedure TAnnotateForm.CopyClick(Sender: TObject);
var
  Final: TBitmap;
begin
  Final := Render;
  try
    Clipboard.Assign(Final);
  finally
    Final.Free;
  end;
  TUIToastManager.Show('Captura copiada: cole no chat ou na issue', ttSuccess, 3000);
  Close;
end;

procedure TAnnotateForm.SaveClick(Sender: TObject);
var
  Final: TBitmap;
  Png: TPngImage;
  Dlg: TFileSaveDialog;
begin
  Dlg := TFileSaveDialog.Create(nil);
  try
    Dlg.Title := 'Salvar captura';
    Dlg.DefaultExtension := 'png';
    Dlg.FileName := FormatDateTime('"captura-"yyyymmdd"-"hhnnss".png"', Now);
    with Dlg.FileTypes.Add do
    begin
      DisplayName := 'Imagem PNG';
      FileMask := '*.png';
    end;
    if not Dlg.Execute then
      Exit;
    Final := Render;
    Png := TPngImage.Create;
    try
      Png.Assign(Final);
      Png.SaveToFile(Dlg.FileName);
    finally
      Png.Free;
      Final.Free;
    end;
    TUIToastManager.Show('Captura salva', ttSuccess, 2500);
  finally
    Dlg.Free;
  end;
end;

procedure TAnnotateForm.FormClose(Sender: TObject; var Action: TCloseAction);
begin
  Action := caFree;
end;

procedure TAnnotateForm.KeyDown(var Key: Word; Shift: TShiftState);
begin
  if Key = VK_ESCAPE then
    Close
  else if (Key = Ord('Z')) and (ssCtrl in Shift) then
    UndoClick(nil)
  else if (Key = Ord('C')) and (ssCtrl in Shift) then
    CopyClick(nil);
end;

end.
