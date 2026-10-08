unit Devbox.Issues.UI.Common;

{ Pedaços de UI usados por mais de uma tela: pintura de selo e avatar dentro da
  TUIVirtualList, barra de título escura e tom por tipo de item/evento. }

interface

uses
  System.Types,
  System.UITypes,
  Vcl.Forms,
  System.Skia,
  UI.Tokens,
  UI.VirtualList,
  Devbox.Issues.Model;

{ Barra de título escura/clara conforme o tema da suíte (Windows 10 20H1+). }
procedure ApplyTitleBarTheme(AForm: TCustomForm);

type
  TBadge = record
    Text: string;
    Tone: TUIBadgeTone;   // btGhost = só texto apagado, sem fundo
  end;
  TBadges = TArray<TBadge>;

function Badge(const AText: string; ATone: TUIBadgeTone): TBadge;

{ Selos lado a lado a partir de AX, centrados em ACy. Para antes de AMaxRight. }
procedure DrawBadgeRow(const ACanvas: ISkCanvas; AX, ACy: Single;
  const ABadges: TBadges; AMaxRight: Single);

{ Um selo alinhado à direita em ARight, centrado em ACy. }
procedure DrawPillRight(const ACanvas: ISkCanvas; ARight, ACy: Single; const ABadge: TBadge);

{ Índice do selo sob AX numa fileira desenhada por DrawBadgeRow a partir de
  AStartX; -1 se nenhum. }
function BadgeIndexAt(AX: Single; const ABadges: TBadges; AStartX: Single): Integer;

{ Corta o texto com reticências para caber em AMaxWidth. }
function FitText(const AText: string; const AFont: ISkFont; AMaxWidth: Single): string;

function Initials(const AName: string): string;

const
  // Texto de dica (cinza sob uma opção): menor que o texto normal e em itálico.
  HintFontSize = 12;

function EventTone(AKind: TEventKind): TUISemanticTone;

{ Modal entra esmaecendo (180 ms): a primeira pintura acontece invisível e
  some a sensação de travamento. Chamar no CreateWnd do form. }
procedure FadeInOnShow(AForm: TForm);

implementation

uses
  Devbox.I18n,
  System.Classes,
  UI.Animations,
  System.SysUtils,
  System.Math,
  Winapi.Windows,
  Winapi.Dwmapi,
  UI.Theme,
  UI.Fonts,
  UI.Painter;

procedure ApplyTitleBarTheme(AForm: TCustomForm);
const
  DWMWA_USE_IMMERSIVE_DARK_MODE = 20;
var
  Dark: BOOL;
begin
  if not AForm.HandleAllocated then
    Exit;
  Dark := UITheme.IsDark;
  DwmSetWindowAttribute(AForm.Handle, DWMWA_USE_IMMERSIVE_DARK_MODE, @Dark, SizeOf(Dark));
  // Sem isto a moldura só troca de cor quando a janela perde/ganha foco.
  SetWindowPos(AForm.Handle, 0, 0, 0, 0, 0, SWP_NOMOVE or SWP_NOSIZE or SWP_NOZORDER or
    SWP_NOACTIVATE or SWP_FRAMECHANGED);
  RedrawWindow(AForm.Handle, nil, 0, RDW_FRAME or RDW_INVALIDATE or RDW_UPDATENOW);
end;
function SubtleBg(const C: TUIColorTokens; ATone: TUIBadgeTone): TAlphaColor;
begin
  case ATone of
    btPrimary: Result := C.PrimarySubtle;
    btInfo: Result := C.InfoSubtle;
    btSuccess: Result := C.SuccessSubtle;
    btWarning: Result := C.WarningSubtle;
    btError: Result := C.ErrorSubtle;
  else
    Result := C.BGMuted;
  end;
end;

function Badge(const AText: string; ATone: TUIBadgeTone): TBadge;
begin
  Result.Text := AText;
  Result.Tone := ATone;
end;

const
  PillPadX = 7;
  PillGap = 6;
  PillH = 18;

function PillFont: ISkFont;
begin
  Result := TUIFontManager.GetFont(UITheme.Tokens.Typography.FamilyPrimary, 10.5,
    UITheme.Tokens.Typography.WeightMedium);
end;

procedure PaintPill(const ACanvas: ISkCanvas; const R: TRectF; const ABadge: TBadge);
var
  T: TUITokens;
begin
  T := UITheme.Tokens;
  if ABadge.Tone = btGhost then
    UIDrawText(ACanvas, ABadge.Text, R, PillFont, T.Color.FGMuted, taRight)
  else
  begin
    UIDrawRRectFill(ACanvas, R, PillH / 2, SubtleBg(T.Color, ABadge.Tone));
    UIDrawText(ACanvas, ABadge.Text, R, PillFont, UIOnColor(T.Color, ABadge.Tone), taCenter);
  end;
end;

function PillWidth(const ABadge: TBadge): Single;
begin
  Result := UITextWidth(ABadge.Text, PillFont) + IfThen(ABadge.Tone = btGhost, 0, 2 * PillPadX);
end;

procedure DrawBadgeRow(const ACanvas: ISkCanvas; AX, ACy: Single;
  const ABadges: TBadges; AMaxRight: Single);
var
  B: TBadge;
  W: Single;
begin
  for B in ABadges do
  begin
    W := PillWidth(B);
    if AX + W > AMaxRight then
      Break;
    PaintPill(ACanvas, TRectF.Create(AX, ACy - PillH / 2, AX + W, ACy + PillH / 2), B);
    AX := AX + W + PillGap;
  end;
end;

function BadgeIndexAt(AX: Single; const ABadges: TBadges; AStartX: Single): Integer;
var
  I: Integer;
  W: Single;
begin
  for I := 0 to High(ABadges) do
  begin
    W := PillWidth(ABadges[I]);
    if (AX >= AStartX) and (AX <= AStartX + W) then
      Exit(I);
    AStartX := AStartX + W + PillGap;
  end;
  Result := -1;
end;

procedure DrawPillRight(const ACanvas: ISkCanvas; ARight, ACy: Single; const ABadge: TBadge);
var
  W: Single;
begin
  W := PillWidth(ABadge);
  PaintPill(ACanvas, TRectF.Create(ARight - W, ACy - PillH / 2, ARight, ACy + PillH / 2), ABadge);
end;

function FitText(const AText: string; const AFont: ISkFont; AMaxWidth: Single): string;
var
  Lo, Hi, Mid: Integer;
begin
  if UITextWidth(AText, AFont) <= AMaxWidth then
    Exit(AText);
  // Busca binária pelo maior prefixo que cabe com '…'.
  Lo := 0;
  Hi := Length(AText);
  while Lo < Hi do
  begin
    Mid := (Lo + Hi + 1) div 2;
    if UITextWidth(Copy(AText, 1, Mid) + '…', AFont) <= AMaxWidth then
      Lo := Mid
    else
      Hi := Mid - 1;
  end;
  Result := Copy(AText, 1, Lo).TrimRight + '…';
end;

function Initials(const AName: string): string;
var
  Parts: TArray<string>;
begin
  Parts := AName.Trim.Split([' ', '-', '_', '.'], TStringSplitOptions.ExcludeEmpty);
  if Length(Parts) = 0 then
    Exit('?');
  if Length(Parts) = 1 then
    Result := Copy(Parts[0], 1, 2)
  else
    Result := Copy(Parts[0], 1, 1) + Copy(Parts[1], 1, 1);
  Result := Result.ToUpper;
end;

type
  TFormFader = class(TComponent)
  private
    FAnim: TUIAnimation;
  public
    destructor Destroy; override;
    procedure FormShow(Sender: TObject);
  end;

destructor TFormFader.Destroy;
begin
  FAnim.Free;
  inherited;
end;

procedure TFormFader.FormShow(Sender: TObject);
var
  F: TForm;
begin
  F := TForm(Owner);
  if FAnim = nil then
  begin
    FAnim := TUIAnimation.Create(0, 1, 180, aeEaseOutCubic);
    FAnim.OnUpdate :=
      procedure(const AValue: Single)
      begin
        F.AlphaBlendValue := Max(0, Min(255, Round(255 * AValue)));
      end;
  end;
  FAnim.Start;
end;

procedure FadeInOnShow(AForm: TForm);
var
  Fader: TFormFader;
begin
  if AForm.AlphaBlend then
    Exit;  // CreateWnd de novo (troca de DPI): já está ligado
  Fader := TFormFader.Create(AForm);
  AForm.AlphaBlendValue := 0;
  AForm.AlphaBlend := True;
  AForm.OnShow := Fader.FormShow;
end;

function EventTone(AKind: TEventKind): TUISemanticTone;
begin
  case AKind of
    ekAssigned, ekReviewRequested: Result := stPrimary;
    ekComment: Result := stInfo;
    ekMention, ekDueSoon: Result := stWarning;
    ekOverdue, ekFlagged, ekCiFailed: Result := stError;
    ekStatus, ekPrApproved: Result := stSuccess;
    ekChangesRequested: Result := stWarning;
  else
    Result := stNone;
  end;
end;

end.
