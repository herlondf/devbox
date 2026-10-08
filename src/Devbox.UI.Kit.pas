unit Devbox.UI.Kit;

{ Base das telas (TDevPage) e peças usadas por mais de uma: painel, botão,
  rótulo de dica, linha de switch, ícones do menu. }

interface

uses
  System.Classes,
  System.SysUtils,
  Vcl.Controls,
  Vcl.ExtCtrls,
  UI.Button,
  UI.Labels,
  UI.Toggle;

type
  { Uma tela do menu lateral. Caption = título no topo; Hint = linha de baixo. }
  TDevPage = class(TPanel)
  protected
    function NewPanel(AParent: TWinControl; AAlign: TAlign; AHeight: Integer = 0): TPanel;
    function NewButton(AParent: TWinControl; const ACaption: string; AOnClick: TNotifyEvent;
      AVariant: TUIButtonVariant = bvOutline; AAlign: TAlign = alLeft): TUIButton;
    { Texto cinza, menor e em itálico. }
    function NewHint(AParent: TWinControl; const AText: string; AAlign: TAlign = alTop): TUILabel;
    function NewToggleRow(AParent: TWinControl; const ACaption, AHint: string;
      AOnChange: TNotifyEvent): TUIToggle;
  public
    constructor Create(AOwner: TComponent); override;
    { A tela entrou ou saiu da frente: liga e desliga timers. }
    procedure PageShown; virtual;
    procedure PageHidden; virtual;
    { Tecla do form com a tela na frente. True = tratou. }
    function PageKey(var AKey: Word; AShift: TShiftState): Boolean; virtual;
  end;

var
  { Ligada no começo da destruição da janela. Resposta de tarefa de fundo que
    chega depois (o Delphi roda a fila enquanto espera as tarefas na saída) é
    descartada: a tela já não existe. }
  AppClosing: Boolean;

{ TThread.Queue que não roda depois de AppClosing. Para toda resposta de tarefa
  de fundo que mexe em tela. }
procedure QueueUI(const AProc: TProc);
{ TTask.Run sem overload. O código das telas de Issues (vindo do Vigia) não compila
  com TTask.Run(procedure ...) direto: o compilador recusa o literal na escolha do overload. }
procedure RunTask(const AProc: TProc);
{ TThread.ForceQueue (próxima volta da fila) que não roda depois de AppClosing. }
procedure ForceQueueUI(const AProc: TProc);

{ TPanel do VCL não ouve o tema: pinta o fundo de todos dentro de AControl. }
procedure PaintPanels(AControl: TWinControl);

{ Ícone de traço no formato dos Heroicons (24x24, currentColor). }
function LineIcon(const APath: string): string;

const
  IconClipboard = 'M9 3.75h6v3H9z M7.5 5.25H5.25v15h13.5v-15H16.5 M8.25 11.25h7.5 M8.25 15h5.25';
  IconKeyboard = 'M3.75 6.75h16.5v10.5H3.75z M7.5 10.5h.01 M10.5 10.5h.01 M13.5 10.5h.01 M16.5 10.5h.01 M7.5 13.5h9';
  IconBroom = 'M14.25 3.75l-4.5 9 M6 13.5h9l1.5 6.75H4.5z M8.25 16.5v3.75 M12 16.5v3.75';
  IconBell = 'M14.25 18.75a2.25 2.25 0 1 1-4.5 0 M5.25 15.75h13.5l-1.5-2.25V9.75a5.25 5.25 0 0 0-10.5 0v3.75z';
  IconClock = 'M12 6.75V12l3.75 2.25 M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18z';
  IconGlobe = 'M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18z M3.6 9h16.8 M3.6 15h16.8 M12 3c2.5 2.7 2.5 15.3 0 18 M12 3c-2.5 2.7-2.5 15.3 0 18';
  IconPlay = 'M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18z M10.25 8.75l4.75 3.25-4.75 3.25z';
  IconTarget = 'M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18z M12 7.5a4.5 4.5 0 1 0 0 9 4.5 4.5 0 0 0 0-9z M12 11.25v1.5';
  IconWrench = 'M11.4 15.2l-5.1 5.1a2.1 2.1 0 1 1-3-3l5.1-5.1 M15.75 3a5.25 5.25 0 0 0-4.6 7.8l2.1 2.1a5.25 5.25 0 0 0 7.75-4.6l-3.2 3.2-2.9-.6-.6-2.9 3.2-3.2A5.2 5.2 0 0 0 15.75 3z';
  IconSparkles = 'M9.8 15.9 9 18.75l-.8-2.85a4.5 4.5 0 0 0-3.1-3.1L2.25 12l2.85-.8a4.5 4.5 0 0 0 3.1-3.1L9 5.25l.8 2.85a4.5 4.5 0 0 0 3.1 3.1l2.85.8-2.85.8a4.5 4.5 0 0 0-3.1 3.1z' +
    ' M18.25 8.6 18 9.75l-.26-1.15a3.4 3.4 0 0 0-2.34-2.34L14.25 6l1.15-.26a3.4 3.4 0 0 0 2.34-2.34L18 2.25l.26 1.15a3.4 3.4 0 0 0 2.34 2.34l1.15.26-1.15.26a3.4 3.4 0 0 0-2.34 2.34z';
  IconCpu = 'M8.25 3v1.5 M15.75 3v1.5 M8.25 19.5V21 M15.75 19.5V21 M3 8.25h1.5 M3 15.75h1.5 M19.5 8.25H21 M19.5 15.75H21 M6.75 4.5h10.5v15H6.75z M9.75 9.75h4.5v4.5h-4.5z';
  IconServer = 'M3.75 4.5h16.5v6H3.75z M3.75 13.5h16.5v6H3.75z M7.5 7.5h.01 M7.5 16.5h.01';
  IconMail = 'M3 6.75h18v10.5H3z M3 7.5l9 6 9-6';
  IconCalendar = 'M4.5 6h15v14.25h-15z M4.5 10.5h15 M8.25 3.75v3.75 M15.75 3.75v3.75';
  IconUser = 'M12 3.75a3.75 3.75 0 1 0 0 7.5 3.75 3.75 0 0 0 0-7.5z M4.5 20.25a7.5 7.5 0 0 1 15 0';
  IconNews = 'M5.25 4.5h13.5v15H5.25z M8.25 8.25h7.5 M8.25 12h7.5 M8.25 15.75h4.5';
  IconIssues = 'M2.25 12s3.75-6.75 9.75-6.75S21.75 12 21.75 12s-3.75 6.75-9.75 6.75S2.25 12 2.25 12z ' +
    'M12 9a3 3 0 1 0 0 6 3 3 0 0 0 0-6z';
  IconSettings = 'M12 9a3 3 0 1 0 0 6 3 3 0 0 0 0-6Z M12 2.25v3 M12 18.75v3 M2.25 12h3 M18.75 12h3 ' +
    'M5.1 5.1l2.1 2.1 M16.8 16.8l2.1 2.1 M5.1 18.9l2.1-2.1 M16.8 7.2l2.1-2.1';

implementation

uses
  System.Threading,
  UI.Theme,
  UI.Painter.Vcl;

procedure QueueUI(const AProc: TProc);
var
  Proc: TProc;
begin
  Proc := AProc;
  TThread.Queue(nil,
    procedure
    begin
      if not AppClosing then
        Proc();
    end);
end;

procedure RunTask(const AProc: TProc);
begin
  TTask.Run(AProc);
end;

procedure ForceQueueUI(const AProc: TProc);
var
  Proc: TProc;
begin
  Proc := AProc;
  TThread.ForceQueue(nil,
    procedure
    begin
      if not AppClosing then
        Proc();
    end);
end;

function LineIcon(const APath: string): string;
var
  P, Paths: string;
begin
  // Um <path> por pedaço separado por " M": traços soltos não se ligam.
  Paths := '';
  for P in APath.Replace(' M', #1'M').Split([#1]) do
    Paths := Paths + '<path stroke-linecap="round" stroke-linejoin="round" d="' + P + '"/>';
  Result := '<svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" ' +
    'stroke-width="1.5" stroke="currentColor">' + Paths + '</svg>';
end;

procedure PaintPanels(AControl: TWinControl);
var
  I: Integer;
begin
  if (AControl is TPanel) and not TPanel(AControl).ParentBackground then
    TPanel(AControl).Color := UIThemeVclBackground;
  for I := 0 to AControl.ControlCount - 1 do
    if AControl.Controls[I] is TWinControl then
      PaintPanels(TWinControl(AControl.Controls[I]));
end;

{ TDevPage }

constructor TDevPage.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  BevelOuter := bvNone;
  // Caption é o título da tela no topo da janela; o TPanel não deve desenhá-lo no meio.
  ShowCaption := False;
  ParentBackground := False;
  DoubleBuffered := True;
  Visible := False;
  Align := alClient;
end;

procedure TDevPage.PageShown;
begin
end;

procedure TDevPage.PageHidden;
begin
end;

function TDevPage.PageKey(var AKey: Word; AShift: TShiftState): Boolean;
begin
  Result := False;
end;

function TDevPage.NewPanel(AParent: TWinControl; AAlign: TAlign; AHeight: Integer): TPanel;
begin
  Result := TPanel.Create(Self);
  Result.BevelOuter := bvNone;
  Result.ParentBackground := False;
  Result.DoubleBuffered := True;
  if AHeight > 0 then
    Result.Height := ScaleValue(AHeight);
  Result.Align := AAlign;
  Result.Top := 100000;
  Result.Left := 100000;
  Result.Parent := AParent;
end;

function TDevPage.NewButton(AParent: TWinControl; const ACaption: string;
  AOnClick: TNotifyEvent; AVariant: TUIButtonVariant; AAlign: TAlign): TUIButton;
begin
  Result := TUIButton.Create(Self);
  Result.Caption := ACaption;
  Result.Variant := AVariant;
  Result.AutoWidth := True;
  Result.OnClick := AOnClick;
  Result.AlignWithMargins := True;
  if AAlign = alRight then
    Result.Margins.SetBounds(ScaleValue(8), 0, 0, 0)
  else
    Result.Margins.SetBounds(0, 0, ScaleValue(8), 0);
  Result.Left := 100000;
  Result.Align := AAlign;
  Result.Parent := AParent;
end;

function TDevPage.NewHint(AParent: TWinControl; const AText: string; AAlign: TAlign): TUILabel;
begin
  Result := TUILabel.Create(Self);
  Result.Caption := AText;
  Result.Variant := lvMuted;
  Result.FontSize := 12;
  Result.Italic := True;
  Result.AutoSize := False;
  Result.Height := ScaleValue(22);
  Result.Top := 100000;
  Result.Align := AAlign;
  Result.Parent := AParent;
end;

{ Switch à esquerda; título e dica num painel ao lado (alTop antes de alLeft
  tomaria a largura toda e esconderia o switch). }
function TDevPage.NewToggleRow(AParent: TWinControl; const ACaption, AHint: string;
  AOnChange: TNotifyEvent): TUIToggle;
var
  Row, Text: TPanel;
  L: TUILabel;
begin
  Row := NewPanel(AParent, alTop, 56);
  Result := TUIToggle.Create(Self);
  Result.Width := ScaleValue(44);
  Result.AlignWithMargins := True;
  Result.Margins.SetBounds(0, ScaleValue(2), 0, ScaleValue(30));
  Result.Align := alLeft;
  Result.OnChange := AOnChange;
  Result.Parent := Row;
  Text := NewPanel(Row, alClient);
  Text.Padding.SetBounds(ScaleValue(10), 0, 0, 0);
  L := TUILabel.Create(Self);
  L.Caption := ACaption;
  L.AutoSize := False;
  L.Height := ScaleValue(24);
  L.Align := alTop;
  L.Parent := Text;
  NewHint(Text, AHint);
end;

end.
