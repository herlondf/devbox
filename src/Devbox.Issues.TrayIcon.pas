unit Devbox.Issues.TrayIcon;

interface

uses
  Winapi.Windows;

{ Ícone da tray desenhado na hora: bolinha com o número de avisos não vistos
  ("V" quando zero). Vermelha se há prazo vencido. Quem chama libera o HICON. }
function MakeTrayIcon(ACount: Integer; AAlert: Boolean): HICON;

implementation

uses
  System.SysUtils,
  System.Types,
  System.Math,
  System.UITypes,
  Vcl.Graphics;

function MakeTrayIcon(ACount: Integer; AAlert: Boolean): HICON;
var
  Size: Integer;
  Color, Mask: TBitmap;
  Info: TIconInfo;
  Text: string;
begin
  Size := GetSystemMetrics(SM_CXSMICON);
  Color := TBitmap.Create;
  Mask := TBitmap.Create;
  try
    Color.SetSize(Size, Size);
    Color.PixelFormat := pf24bit;
    Mask.Monochrome := True;
    Mask.SetSize(Size, Size);

    // Máscara: branco = transparente, preto = opaco.
    Mask.Canvas.Brush.Color := clWhite;
    Mask.Canvas.FillRect(Rect(0, 0, Size, Size));
    Mask.Canvas.Brush.Color := clBlack;
    Mask.Canvas.Pen.Color := clBlack;
    Mask.Canvas.Ellipse(0, 0, Size, Size);

    Color.Canvas.Brush.Color := clBlack;
    Color.Canvas.FillRect(Rect(0, 0, Size, Size));
    if AAlert then
      Color.Canvas.Brush.Color := RGB(220, 38, 38)
    else
      Color.Canvas.Brush.Color := RGB(37, 99, 235);
    Color.Canvas.Pen.Color := Color.Canvas.Brush.Color;
    Color.Canvas.Ellipse(0, 0, Size, Size);

    if ACount <= 0 then
      Text := 'V'
    else if ACount > 9 then
      Text := '9+'
    else
      Text := IntToStr(ACount);
    Color.Canvas.Font.Name := 'Segoe UI';
    Color.Canvas.Font.Style := [fsBold];
    Color.Canvas.Font.Quality := fqAntialiased;  // sem franja colorida do ClearType
    Color.Canvas.Font.Color := clWhite;
    Color.Canvas.Font.Height := -Round(Size * IfThen(Length(Text) > 1, 0.55, 0.7));
    Color.Canvas.Brush.Style := bsClear;
    Color.Canvas.TextOut((Size - Color.Canvas.TextWidth(Text)) div 2,
      (Size - Color.Canvas.TextHeight(Text)) div 2, Text);

    Info.fIcon := True;
    Info.xHotspot := 0;
    Info.yHotspot := 0;
    Info.hbmMask := Mask.Handle;
    Info.hbmColor := Color.Handle;
    Result := CreateIconIndirect(Info);
  finally
    Color.Free;
    Mask.Free;
  end;
end;

end.
