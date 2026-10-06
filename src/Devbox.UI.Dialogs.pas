unit Devbox.UI.Dialogs;

// Diálogos do Devbox.exe: snippet (texto + atalho), tarefa do agendador, URL
// do monitor e ambiente de projeto. A base e o de campos estão em DialogBase.

interface

uses
  System.SysUtils,
  Devbox.Model,
  Devbox.Jobs,
  Devbox.Envs;

{ False = cancelou. AOthers: atalhos já usados (sem o deste snippet). }
function EditSnippet(var AText, AAbbrev: string; const AOthers: TArray<string>): Boolean;

{ Cria ou altera uma tarefa do agendador. False = cancelou. }
function EditJob(var AJob: TJob): Boolean;

{ Cria ou altera uma URL do monitor. }
function EditUrlCheck(var ACheck: TUrlCheck): Boolean;

{ Cria ou altera um ambiente de projeto (nome + roteiro de passos). }
function EditEnv(var AEnv: TEnv): Boolean;

implementation

uses
  Winapi.Windows,
  System.Classes,
  System.UITypes,
  System.Math,
  System.StrUtils,
  Vcl.Controls,
  Vcl.Forms,
  Vcl.ExtCtrls,
  Winapi.Dwmapi,
  UI.Theme,
  UI.Button,
  UI.Input,
  UI.TextArea,
  UI.Labels,
  UI.Select,
  UI.Checkbox,
  UI.NumberInput,
  UI.Painter.Vcl,
  UI.Toast,
  Devbox.Sys,
  Devbox.UI.Kit,
  Devbox.UI.DialogBase;

function EditSnippet(var AText, AAbbrev: string; const AOthers: TArray<string>): Boolean;
var
  F: TDialogForm;
  Text: TUITextArea;
  Abbrev: TUIInput;
  Hint: TUILabel;
begin
  F := TDialogForm.CreateDialog('Snippet', 620, 470);
  try
    Abbrev := NewInput(F, 'Atalho do expansor (opcional), ex.: ;sql');
    Abbrev.Value := AAbbrev;
    Hint := TUILabel.Create(F);
    Hint.Caption := 'Use {{nome}} no texto para um campo que o Devbox pergunta antes de colar.';
    Hint.Variant := lvMuted;
    Hint.FontSize := 12;
    Hint.Italic := True;
    Hint.AutoSize := False;
    Hint.Height := F.ScaleValue(26);
    Hint.Top := 100000;
    Hint.Align := alTop;
    Hint.Parent := F.Body;
    Text := TUITextArea.Create(F);
    Text.LabelText := 'Texto';
    Text.Value := AText;
    Text.Rows := 10;
    Text.Top := 100000;
    Text.Align := alClient;
    Text.Parent := F.Body;
    F.OnValidate :=
      function: Boolean
      var
        A, Conflict, B: string;
        Others: TArray<string>;
      begin
        Others := AOthers;
        for B in BuiltinAbbrevs do
          Others := Others + [B];
        A := Trim(Abbrev.Value).ToLower;
        Abbrev.ErrorMessage := '';
        if Trim(Text.Value) = '' then
          Exit(False);
        if A <> '' then
        begin
          if not ValidAbbrev(A) then
            Abbrev.ErrorMessage := 'Comece com ";" e use de 2 a 20 letras minúsculas, dígitos ou "-"'
          else
          begin
            Conflict := AbbrevConflict(A, Others);
            if Conflict <> '' then
              Abbrev.ErrorMessage := Format('Conflita com %s: um não pode começar com o outro', [Conflict]);
          end;
        end;
        Result := Abbrev.ErrorMessage = '';
      end;
    // O handle nasce no ClientWidth do construtor, antes dos painéis: pinta aqui.
    PaintPanels(F);
    Result := F.ShowModal = mrOk;
    if Result then
    begin
      AText := Text.Value;
      AAbbrev := Trim(Abbrev.Value).ToLower;
    end;
  finally
    F.Free;
  end;
end;

function EditJob(var AJob: TJob): Boolean;
var
  F: TDialogForm;
  Name, Dir, Clock: TUIInput;
  Cmd: TUITextArea;
  Kind: TUISelect;
  Every: TUINumberInput;
  Days: array[0..6] of TUICheckbox;
  NotifyOk: TUICheckbox;
  Row: TPanel;
  I: Integer;
  Hint: TUILabel;
begin
  F := TDialogForm.CreateDialog(IfThen(AJob.Id = 0, 'Nova tarefa', 'Tarefa'), 640, 640);
  try
    Name := NewInput(F, 'Nome');
    Name.Value := AJob.Name;
    Cmd := TUITextArea.Create(F);
    Cmd.LabelText := 'Comando (roda no cmd: pipe, && e wsl -d Distro -e ... funcionam)';
    Cmd.Rows := 3;
    Cmd.Value := AJob.Command;
    Cmd.AlignWithMargins := True;
    Cmd.Margins.SetBounds(0, 0, 0, F.ScaleValue(12));
    Cmd.Top := 100000;
    Cmd.Align := alTop;
    Cmd.Parent := F.Body;
    Dir := NewInput(F, 'Pasta onde roda (opcional)');
    Dir.Value := AJob.WorkDir;

    Kind := TUISelect.Create(F);
    Kind.Caption := 'Quando';
    Kind.Items.Add('A cada N minutos');
    Kind.Items.Add('Todo dia');
    Kind.Items.Add('Em dias da semana');
    Kind.ItemIndex := Ord(AJob.Kind);
    Kind.AlignWithMargins := True;
    Kind.Margins.SetBounds(0, 0, 0, F.ScaleValue(12));
    Kind.Top := 100000;
    Kind.Align := alTop;
    Kind.Parent := F.Body;

    Row := TPanel.Create(F);
    Row.BevelOuter := bvNone;
    Row.ParentBackground := False;
    Row.Height := F.ScaleValue(50);
    Row.Top := 100000;
    Row.Align := alTop;
    Row.Parent := F.Body;
    Every := TUINumberInput.Create(F);
    Every.LabelText := 'A cada (minutos)';
    Every.Min := 1;
    Every.Max := 10080;
    Every.Value := Max(AJob.EveryMin, 1);
    Every.Width := F.ScaleValue(200);
    Every.Align := alLeft;
    Every.Parent := Row;
    Clock := TUIInput.Create(F);
    Clock.LabelMode := ilmBorder;
    Clock.LabelText := 'Horário (hh:mm)';
    Clock.ReserveHintSpace := False;
    Clock.Value := ClockText(AJob.AtMin);
    Clock.Width := F.ScaleValue(200);
    Clock.AlignWithMargins := True;
    Clock.Margins.SetBounds(F.ScaleValue(16), 0, 0, 0);
    Clock.Left := 1000;
    Clock.Align := alLeft;
    Clock.Parent := Row;

    Row := TPanel.Create(F);
    Row.BevelOuter := bvNone;
    Row.ParentBackground := False;
    Row.Height := F.ScaleValue(36);
    Row.Top := 100000;
    Row.Align := alTop;
    Row.Parent := F.Body;
    for I := 0 to 6 do
    begin
      Days[I] := TUICheckbox.Create(F);
      Days[I].Caption := WeekdayNames[I];
      Days[I].Checked := AJob.Weekdays and (1 shl I) <> 0;
      Days[I].Width := F.ScaleValue(76);
      Days[I].Left := (I + 1) * 1000;
      Days[I].Align := alLeft;
      Days[I].Parent := Row;
    end;

    NotifyOk := TUICheckbox.Create(F);
    NotifyOk.Caption := 'Avisar também quando der certo (falha sempre avisa)';
    NotifyOk.Checked := AJob.NotifyOk;
    NotifyOk.Height := F.ScaleValue(32);
    NotifyOk.Top := 100000;
    NotifyOk.Align := alTop;
    NotifyOk.Parent := F.Body;

    Hint := TUILabel.Create(F);
    Hint.Caption := 'Roda com o Devbox aberto (na bandeja). Se estava fechado na hora, roda assim que abrir.';
    Hint.Variant := lvMuted;
    Hint.FontSize := 12;
    Hint.Italic := True;
    Hint.AutoSize := False;
    Hint.Height := F.ScaleValue(26);
    Hint.Top := 100000;
    Hint.Align := alTop;
    Hint.Parent := F.Body;

    F.OnValidate :=
      function: Boolean
      var
        I, Mask: Integer;
      begin
        Name.ErrorMessage := IfThen(Trim(Name.Value) = '', 'Dê um nome', '');
        Clock.ErrorMessage := '';
        if (Kind.ItemIndex > 0) and (ParseClock(Clock.Value) < 0) then
          Clock.ErrorMessage := 'Use hh:mm, ex.: 08:30';
        Mask := 0;
        for I := 0 to 6 do
          if Days[I].Checked then
            Mask := Mask or (1 shl I);
        if (Kind.ItemIndex = 2) and (Mask = 0) then
          Clock.ErrorMessage := 'Marque pelo menos um dia';
        Result := (Name.ErrorMessage = '') and (Clock.ErrorMessage = '') and (Trim(Cmd.Value) <> '');
      end;
    PaintPanels(F);
    Result := F.ShowModal = mrOk;
    if not Result then
      Exit;
    AJob.Name := Trim(Name.Value);
    AJob.Command := Trim(Cmd.Value);
    AJob.WorkDir := Trim(Dir.Value);
    AJob.Kind := TJobKind(Max(Kind.ItemIndex, 0));
    AJob.EveryMin := Round(Every.Value);
    AJob.AtMin := Max(ParseClock(Clock.Value), 0);
    AJob.Weekdays := 0;
    for I := 0 to 6 do
      if Days[I].Checked then
        AJob.Weekdays := AJob.Weekdays or (1 shl I);
    AJob.NotifyOk := NotifyOk.Checked;
  finally
    F.Free;
  end;
end;

const
  UrlIntervals: array[0..4] of Integer = (30, 60, 300, 900, 3600);

function EditUrlCheck(var ACheck: TUrlCheck): Boolean;
var
  F: TDialogForm;
  Name, Url: TUIInput;
  Every: TUISelect;
  I: Integer;
begin
  F := TDialogForm.CreateDialog(IfThen(ACheck.Id = 0, 'Nova URL', 'URL'), 560, 300);
  try
    Name := NewInput(F, 'Nome (ex.: API de homologação)');
    Name.Value := ACheck.Name;
    Url := NewInput(F, 'Endereço (https://...)');
    Url.Value := ACheck.Url;
    Every := TUISelect.Create(F);
    Every.Caption := 'Checar';
    for I in UrlIntervals do
      if I < 60 then
        Every.Items.Add(Format('a cada %d s', [I]))
      else if I < 3600 then
        Every.Items.Add(Format('a cada %d min', [I div 60]))
      else
        Every.Items.Add('a cada 1 h');
    Every.ItemIndex := 1;
    for I := 0 to High(UrlIntervals) do
      if UrlIntervals[I] = ACheck.IntervalSec then
        Every.ItemIndex := I;
    Every.Top := 100000;
    Every.Align := alTop;
    Every.Parent := F.Body;
    F.OnValidate :=
      function: Boolean
      begin
        Name.ErrorMessage := IfThen(Trim(Name.Value) = '', 'Dê um nome', '');
        Url.ErrorMessage := IfThen(StartsText('http://', Trim(Url.Value)) or StartsText('https://', Trim(Url.Value)),
          '', 'Comece com http:// ou https://');
        Result := (Name.ErrorMessage = '') and (Url.ErrorMessage = '');
      end;
    PaintPanels(F);
    Result := F.ShowModal = mrOk;
    if Result then
    begin
      ACheck.Name := Trim(Name.Value);
      ACheck.Url := Trim(Url.Value);
      ACheck.IntervalSec := UrlIntervals[Max(Every.ItemIndex, 0)];
    end;
  finally
    F.Free;
  end;
end;

function EditEnv(var AEnv: TEnv): Boolean;
var
  F: TDialogForm;
  Name: TUIInput;
  Script: TUITextArea;
  Help: TUILabel;
begin
  F := TDialogForm.CreateDialog(IfThen(AEnv.Id = 0, 'Novo ambiente', 'Ambiente'), 720, 640);
  try
    Name := NewInput(F, 'Nome (ex.: API de pagamentos)');
    Name.Value := AEnv.Name;
    Help := TUILabel.Create(F);
    Help.Caption := EnvHelp;
    Help.Variant := lvMuted;
    Help.FontSize := 12;
    Help.WordWrap := True;
    Help.AutoSize := False;
    Help.Height := F.ScaleValue(190);
    Help.Top := 100000;
    Help.Align := alTop;
    Help.Parent := F.Body;
    Script := TUITextArea.Create(F);
    Script.LabelText := 'Passos';
    Script.Value := AEnv.Script;
    Script.Rows := 10;
    Script.Top := 100000;
    Script.Align := alClient;
    Script.Parent := F.Body;
    F.OnValidate :=
      function: Boolean
      var
        Steps: TEnvSteps;
        Error: string;
      begin
        Name.ErrorMessage := IfThen(Trim(Name.Value) = '', 'Dê um nome', '');
        Result := Name.ErrorMessage = '';
        if not ParseEnvScript(Script.Value, Steps, Error) then
        begin
          TUIToastManager.Show(Error, ttError, 5000);
          Result := False;
        end
        else if Steps = nil then
        begin
          TUIToastManager.Show('Escreva pelo menos um passo', ttError, 4000);
          Result := False;
        end;
      end;
    PaintPanels(F);
    Result := F.ShowModal = mrOk;
    if Result then
    begin
      AEnv.Name := Trim(Name.Value);
      AEnv.Script := Script.Value;
    end;
  finally
    F.Free;
  end;
end;

end.
