unit Devbox.UI.SidePeek;

{ Painel lateral fora da janela: uma janela sem borda que desliza ao lado da
  janela principal (à direita; sem espaço na tela, à esquerda). Quem usa põe o
  conteúdo em Body. Esc ou o X fecha. Acompanha a janela principal quando ela
  anda e some quando ela some (SidePeekFollow, chamado pela janela principal). }

interface

uses
  Winapi.Windows,
  Winapi.Messages,
  System.Classes,
  System.SysUtils,
  System.Generics.Collections,
  Vcl.Controls,
  Vcl.Forms,
  Vcl.ExtCtrls,
  UI.Labels,
  UI.Animations,
  UI.Button;

type
  TSidePeek = class(TForm)
  private
    FHost: TCustomForm;
    FTitle: TUILabel;
    FBody: TPanel;
    FPeekWidth: Integer;
    FOnLeft: Boolean;
    FOnClose: TNotifyEvent;
    FAnim: TUIAnimation;
    procedure CloseClick(Sender: TObject);
    procedure PeekKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure Place;
    procedure SetTitle(const AValue: string);
    function GetTitle: string;
  protected
    procedure CreateWnd; override;
  public
    { AHost: a janela de que o painel fica ao lado. AWidth em pixels de 96 dpi. }
    constructor CreatePeek(AHost: TCustomForm; AWidth: Integer);
    destructor Destroy; override;
    { Abre deslizando (ou só troca o conteúdo, se já está aberto). }
    procedure Open;
    procedure Close_;
    function IsOpen: Boolean;
    property Body: TPanel read FBody;
    property Title: string read GetTitle write SetTitle;
    property OnClose: TNotifyEvent read FOnClose write FOnClose;
  end;

{ A janela principal mudou de lugar, de tamanho ou de visibilidade. }
procedure SidePeekFollow(AHost: TCustomForm);
{ Fecha o painel aberto, se houver. True = havia um (Esc da janela principal). }
function SidePeekCloseAny: Boolean;

implementation

uses
  System.Math,
  Winapi.Dwmapi,
  UI.Theme,
  UI.Painter.Vcl,
  Vcl.Graphics,
  Devbox.UI.Kit;

const
  CSlideMs = 160;
  CSlidePx = 40;
  CGap = 6;
  CHeaderH = 52;
  CPad = 16;
  DWMWA_WINDOW_CORNER_PREFERENCE = 33;
  DWMWCP_ROUND = 2;
  DWMWA_BORDER_COLOR = 34;

var
  GPeeks: TList<TSidePeek>;

constructor TSidePeek.CreatePeek(AHost: TCustomForm; AWidth: Integer);
var
  LHeader: TPanel;
  LClose: TUIButton;
begin
  inherited CreateNew(AHost);
  FHost := AHost;
  FPeekWidth := AWidth;
  BorderStyle := bsNone;
  PopupMode := pmExplicit;
  PopupParent := AHost;
  KeyPreview := True;
  OnKeyDown := PeekKeyDown;
  DoubleBuffered := True;
  Color := UIThemeVclBackground;
  Padding.SetBounds(ScaleValue(CPad), 0, ScaleValue(CPad), ScaleValue(CPad));

  LHeader := TPanel.Create(Self);
  LHeader.BevelOuter := bvNone;
  LHeader.ParentBackground := False;
  LHeader.Height := ScaleValue(CHeaderH);
  LHeader.Align := alTop;
  LHeader.Parent := Self;
  LClose := TUIButton.Create(Self);
  LClose.Caption := '';
  LClose.IconSvg := LineIcon('M6 18 18 6M6 6l12 12');
  LClose.Variant := bvGhost;
  LClose.Hint := 'Fechar (Esc)';
  LClose.ShowHint := True;
  LClose.Width := ScaleValue(36);
  LClose.AlignWithMargins := True;
  LClose.Margins.SetBounds(ScaleValue(8), ScaleValue(10), 0, ScaleValue(6));
  LClose.Align := alRight;
  LClose.OnClick := CloseClick;
  LClose.Parent := LHeader;
  FTitle := TUILabel.Create(Self);
  FTitle.Bold := True;
  FTitle.FontSize := 15;
  FTitle.AutoSize := False;
  FTitle.AlignWithMargins := True;
  FTitle.Margins.SetBounds(0, ScaleValue(19), 0, 0);
  FTitle.Align := alClient;
  FTitle.Parent := LHeader;

  FBody := TPanel.Create(Self);
  FBody.BevelOuter := bvNone;
  FBody.ParentBackground := False;
  FBody.Align := alClient;
  FBody.Parent := Self;
  GPeeks.Add(Self);
end;

destructor TSidePeek.Destroy;
begin
  FAnim.Free;
  GPeeks.Remove(Self);
  inherited;
end;

procedure TSidePeek.CreateWnd;
var
  LPref: Integer;
  LBorder: COLORREF;
begin
  inherited;
  // Windows 11: cantos arredondados e borda de 1 px na cor de borda do tema (a padrão é clara e translúcida).
  LPref := DWMWCP_ROUND;
  DwmSetWindowAttribute(Handle, DWMWA_WINDOW_CORNER_PREFERENCE, @LPref, SizeOf(LPref));
  LBorder := ColorToRGB(UIAlphaToVclColor(UITheme.Tokens.Color.Border));
  DwmSetWindowAttribute(Handle, DWMWA_BORDER_COLOR, @LBorder, SizeOf(LBorder));
end;

procedure TSidePeek.SetTitle(const AValue: string);
begin
  FTitle.Caption := AValue;
end;

function TSidePeek.GetTitle: string;
begin
  Result := FTitle.Caption;
end;

procedure TSidePeek.Place;
var
  LHost, LWork: TRect;
  LWidth: Integer;
begin
  GetWindowRect(FHost.Handle, LHost);
  LWork := Screen.MonitorFromWindow(FHost.Handle).WorkareaRect;
  LWidth := ScaleValue(FPeekWidth);
  // Direita se couber; senão esquerda; sem espaço nenhum, por cima da borda direita.
  FOnLeft := (LHost.Right + CGap + LWidth > LWork.Right) and (LHost.Left - CGap - LWidth >= LWork.Left);
  if FOnLeft then
    SetBounds(LHost.Left - CGap - LWidth, LHost.Top, LWidth, LHost.Height)
  else
    SetBounds(Min(LHost.Right + CGap, LWork.Right - LWidth), LHost.Top, LWidth, LHost.Height);
end;

{ Desliza movendo a janela já pintada. O AnimateWindow tirava um retrato pelo
  WM_PRINT; o que o VCL não desenha nele (painéis) ficava transparente. }
procedure TSidePeek.Open;
var
  LFinal, LStart: Integer;
begin
  if IsOpen then
    Exit;
  Color := UIThemeVclBackground;
  PaintPanels(Self);
  Place;
  LFinal := Left;
  LStart := LFinal + IfThen(FOnLeft, ScaleValue(CSlidePx), -ScaleValue(CSlidePx));
  Left := LStart;
  Visible := True;
  FreeAndNil(FAnim);
  FAnim := TUIAnimation.Create(0, 1, CSlideMs, aeEaseOutCubic);
  FAnim.OnUpdate :=
    procedure(const AValue: Single)
    begin
      Left := LStart + Round((LFinal - LStart) * AValue);
    end;
  FAnim.Start;
end;

procedure TSidePeek.Close_;
begin
  if not IsOpen then
    Exit;
  if FAnim <> nil then
    FAnim.Stop;
  Visible := False;
  if Assigned(FOnClose) then
    FOnClose(Self);
end;

function TSidePeek.IsOpen: Boolean;
begin
  Result := Visible;
end;

procedure TSidePeek.CloseClick(Sender: TObject);
begin
  Close_;
end;

procedure TSidePeek.PeekKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if Key = VK_ESCAPE then
  begin
    Key := 0;
    Close_;
  end;
end;

procedure SidePeekFollow(AHost: TCustomForm);
var
  LPeek: TSidePeek;
begin
  for LPeek in GPeeks do
    if (LPeek.FHost = AHost) and LPeek.IsOpen then
      if not IsWindowVisible(AHost.Handle) or IsIconic(AHost.Handle) then
      begin
        LPeek.Visible := False;
        if Assigned(LPeek.FOnClose) then
          LPeek.FOnClose(LPeek);
      end
      else
        LPeek.Place;
end;

function SidePeekCloseAny: Boolean;
var
  LPeek: TSidePeek;
begin
  Result := False;
  for LPeek in GPeeks do
    if LPeek.IsOpen then
    begin
      LPeek.Close_;
      Result := True;
    end;
end;

initialization
  GPeeks := TList<TSidePeek>.Create;

finalization
  GPeeks.Free;

end.
