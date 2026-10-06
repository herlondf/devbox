unit Devbox.UI.AICommand;

{ Pedido em português vira um comando (PowerShell, cmd ou WSL). O comando
  aparece antes; rodar pede confirmação no aviso. Nada roda sozinho. }

interface

uses
  System.Classes,
  System.SysUtils,
  Vcl.Controls,
  Vcl.ExtCtrls,
  UI.Labels,
  UI.Button,
  UI.TextArea,
  UI.Code,
  UI.Badge,
  UI.ProgressBar,
  Devbox.UI.Kit;

type
  TAICommandPage = class(TDevPage)
  private
    FAsk: TUITextArea;
    FProgress: TUIProgressBar;
    FShell: TUIBadge;
    FExplain: TUILabel;
    FCommand: TUICode;
    FOutput: TUICode;
    FRunBtn, FCopyBtn: TUIButton;
    FShellName, FCommandText: string;
    FBusy: Boolean;
    procedure AskClick(Sender: TObject);
    procedure CopyClick(Sender: TObject);
    procedure RunClick(Sender: TObject);
    procedure RunConfirmed(Sender: TObject);
    procedure ShowAnswer(const AShell, ACommand, AExplanation: string);
  public
    constructor Create(AOwner: TComponent); override;
  end;

implementation

uses
  System.StrUtils,
  System.Threading,
  Vcl.Clipbrd,
  UI.Tokens,
  UI.Toast,
  Devbox.Sys,
  Devbox.AI;

constructor TAICommandPage.Create(AOwner: TComponent);
var
  Bar, Row: TPanel;
begin
  inherited Create(AOwner);
  Caption := 'Comando por IA';
  Hint := 'Diga o que quer fazer; a IA escreve o comando, você confere e decide se roda';
  FAsk := TUITextArea.Create(Self);
  FAsk.LabelText := 'O que você quer fazer? (ex.: liberar a porta 5432, ver o que ocupa o disco D:)';
  FAsk.Rows := 3;
  FAsk.Height := ScaleValue(100);
  FAsk.Align := alTop;
  FAsk.Parent := Self;
  Bar := NewPanel(Self, alTop, 52);
  Bar.Padding.SetBounds(0, ScaleValue(8), 0, ScaleValue(4));
  NewButton(Bar, 'Gerar comando', AskClick, bvPrimary);
  FCopyBtn := NewButton(Bar, 'Copiar', CopyClick);
  FRunBtn := NewButton(Bar, 'Rodar…', RunClick);
  FCopyBtn.Enabled := False;
  FRunBtn.Enabled := False;
  FProgress := TUIProgressBar.Create(Self);
  FProgress.Indeterminate := True;
  FProgress.TrackHeight := 3;
  FProgress.Height := 3;
  FProgress.Visible := False;
  FProgress.Top := 100000;
  FProgress.Align := alTop;
  FProgress.Parent := Self;

  Row := NewPanel(Self, alTop, 36);
  Row.Padding.SetBounds(0, ScaleValue(8), 0, 0);
  FShell := TUIBadge.Create(Self);
  FShell.Visible := False;
  FShell.Width := ScaleValue(110);
  FShell.Align := alLeft;
  FShell.Parent := Row;
  FExplain := TUILabel.Create(Self);
  FExplain.AutoSize := False;
  FExplain.AlignWithMargins := True;
  FExplain.Margins.SetBounds(ScaleValue(10), 0, 0, 0);
  FExplain.Align := alClient;
  FExplain.Parent := Row;
  FCommand := TUICode.Create(Self);
  FCommand.FontSize := 13;
  FCommand.Height := ScaleValue(90);
  FCommand.Top := 100000;
  FCommand.Align := alTop;
  FCommand.Parent := Self;
  NewHint(Self, 'Saída do comando');
  FOutput := TUICode.Create(Self);
  FOutput.FontSize := 11;
  FOutput.Top := 100000;
  FOutput.Align := alClient;
  FOutput.Parent := Self;
end;

procedure TAICommandPage.AskClick(Sender: TObject);
var
  Config: TAIConfig;
  Prompt, System_: string;
begin
  if FBusy or (Trim(FAsk.Value) = '') then
    Exit;
  Config := LoadAIConfig;
  if not Config.Ready then
  begin
    TUIToastManager.Show('Configure a IA em Configurações › IA', ttWarning, 4000);
    Exit;
  end;
  Prompt := ActionPrompt(aaCommand, Trim(FAsk.Value), System_);
  FBusy := True;
  FProgress.Visible := True;
  TTask.Run(
    procedure
    var
      Answer: string;
      Ok: Boolean;
    begin
      try
        Ok := AskAI(Config, System_, Prompt, Answer);
      except
        on E: Exception do
        begin
          Ok := False;
          Answer := E.Message;
        end;
      end;
      System.Classes.TThread.Queue(nil,
        procedure
        var
          Shell, Cmd, Expl: string;
        begin
          FBusy := False;
          FProgress.Visible := False;
          if not Ok then
            TUIToastManager.Show('A IA não respondeu: ' + Answer, ttError, 6000)
          else if ParseCommandAnswer(Answer, Shell, Cmd, Expl) then
            ShowAnswer(Shell, Cmd, Expl)
          else
            TUIToastManager.Show('A IA não devolveu um comando. Tente explicar de outro jeito.', ttWarning, 5000);
        end);
    end);
end;

procedure TAICommandPage.ShowAnswer(const AShell, ACommand, AExplanation: string);
begin
  FShellName := AShell;
  FCommandText := ACommand;
  FShell.Caption := AShell;
  FShell.Visible := True;
  FExplain.Caption := AExplanation;
  FCommand.Text := ACommand;
  FOutput.Text := '';
  FCopyBtn.Enabled := True;
  FRunBtn.Enabled := True;
end;

procedure TAICommandPage.CopyClick(Sender: TObject);
begin
  Clipboard.AsText := FCommandText;
  TUIToastManager.Show('Comando copiado', ttSuccess, 1500);
end;

{ Rodar pede o "sim" no próprio aviso: o comando veio de uma IA. }
procedure TAICommandPage.RunClick(Sender: TObject);
begin
  if FCommandText = '' then
    Exit;
  TUIToastManager.Show('Rodar este comando no ' + FShellName + '? Confira antes.', ttWarning, 10000, 'Rodar',
    RunConfirmed);
end;

procedure TAICommandPage.RunConfirmed(Sender: TObject);
var
  Line: string;
begin
  if FShellName = 'cmd' then
    Line := 'cmd.exe /c ' + FCommandText
  else if FShellName = 'wsl' then
    Line := 'wsl.exe -e sh -c "' + StringReplace(FCommandText, '"', '\"', [rfReplaceAll]) + '"'
  else
    Line := 'powershell.exe -NoProfile -Command "' + StringReplace(FCommandText, '"', '\"', [rfReplaceAll]) + '"';
  FOutput.Text := 'rodando...';
  FProgress.Visible := True;
  TTask.Run(
    procedure
    var
      Output: string;
      Code: Integer;
    begin
      try
        Code := RunCapture(Line, Output, 120000);
      except
        on E: Exception do
        begin
          Code := -3;
          Output := E.Message;
        end;
      end;
      System.Classes.TThread.Queue(nil,
        procedure
        begin
          FProgress.Visible := False;
          FOutput.Text := StringReplace(TrimRight(Output), #13, '', [rfReplaceAll]) + #10#10 +
            Format('(saída %d)', [Code]);
        end);
    end);
end;

end.
