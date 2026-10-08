unit Devbox.Issues.UI.Status;

{ Modal pequeno para mudar o status de uma issue: lista as transições que o
  Jira permite agora (ou fechar/reabrir no GitHub) e aplica a escolhida. }

interface

uses
  System.Classes,
  Devbox.Issues.Model;

{ True quando aplicou (o chamador deve buscar de novo). }
function ChangeStatus(AOwner: TComponent; const AAccount: TAccount; const AItem: TItem): Boolean;

{ Jira: registra horas na issue. True quando gravou. }
function LogTime(AOwner: TComponent; const AAccount: TAccount; const AItem: TItem): Boolean;

{ Modais curtos para as ações de escrita. }
function AskConfirm(AOwner: TComponent; const ATitle, AMessage, AOkCaption: string): Boolean;
function AskText(AOwner: TComponent; const ATitle, AMessage, ALabel: string; var AValue: string): Boolean;
function AskChoice(AOwner: TComponent; const ATitle, AMessage, ALabel: string;
  const AChoices: TArray<string>; var AIndex: Integer): Boolean;

implementation

uses
  Devbox.UI.Kit,
  Devbox.I18n,
  System.SysUtils,
  System.StrUtils,
  System.Threading,
  Vcl.Controls,
  Vcl.Forms,
  Vcl.ExtCtrls,
  UI.Theme,
  UI.Painter.Vcl,
  UI.Labels,
  UI.Select,
  UI.Button,
  UI.Alert,
  UI.Loading,
  UI.NumberInput,
  UI.DatePicker,
  UI.TimePicker,
  UI.Input,
  UI.TextArea,
  UI.Tokens,
  UI.Toast,
  Devbox.Secrets,
  Devbox.Issues.Providers,
  Devbox.Issues.UI.Common;

type
  TStatusForm = class(TForm)
  private
    FAccount: TAccount;
    FItem: TItem;
    FToken: string;
    FTransitions: TTransitions;
    FSelect: TUISelect;
    FFields: TPanel;                  // campos que a transição escolhida pede
    FFieldCtrls: TArray<TControl>;
    FBaseHeight: Integer;
    FApply: TUIButton;
    FAlert: TUIAlert;
    FLoading: TUILoading;
    procedure Load;
    procedure SelectChange(Sender: TObject);
    procedure ApplyClick(Sender: TObject);
    procedure CancelClick(Sender: TObject);
  protected
    procedure CreateWnd; override;
  public
    constructor CreateFor(AOwner: TComponent; const AAccount: TAccount; const AItem: TItem);
  end;

const
  CPad = 16;

function ChangeStatus(AOwner: TComponent; const AAccount: TAccount; const AItem: TItem): Boolean;
var
  F: TStatusForm;
begin
  F := TStatusForm.CreateFor(AOwner, AAccount, AItem);
  try
    Result := F.ShowModal = mrOk;
  finally
    F.Free;
  end;
end;

constructor TStatusForm.CreateFor(AOwner: TComponent; const AAccount: TAccount; const AItem: TItem);
var
  Lbl: TUILabel;
  Foot: TPanel;
  Btn: TUIButton;
begin
  inherited CreateNew(AOwner);
  FAccount := AAccount;
  FItem := AItem;
  FToken := LoadSecret(AAccount.SecretTarget);
  Caption := Tr('Mudar status: ') + AItem.Key;
  ClientWidth := ScaleValue(420);
  ClientHeight := ScaleValue(250);
  Position := poOwnerFormCenter;
  BorderStyle := bsDialog;
  DoubleBuffered := True;
  Color := UIThemeVclBackground;

  Foot := TPanel.Create(Self);
  Foot.BevelOuter := bvNone;
  Foot.ParentBackground := False;
  Foot.Color := UIThemeVclBackground;
  Foot.Height := ScaleValue(60);
  Foot.Padding.SetBounds(CPad, 12, CPad, 12);
  Foot.Align := alBottom;
  Foot.Parent := Self;
  FApply := TUIButton.Create(Self);
  FApply.Caption := Tr('Aplicar');
  FApply.AutoWidth := True;
  FApply.Default := True;
  FApply.Enabled := False;
  FApply.OnClick := ApplyClick;
  FApply.Align := alRight;
  FApply.Parent := Foot;
  Btn := TUIButton.Create(Self);
  Btn.Caption := Tr('Cancelar');
  Btn.Variant := bvOutline;
  Btn.AutoWidth := True;
  Btn.Cancel := True;
  Btn.OnClick := CancelClick;
  Btn.AlignWithMargins := True;
  Btn.Margins.SetBounds(0, 0, 8, 0);
  Btn.Align := alRight;
  Btn.Parent := Foot;

  Lbl := TUILabel.Create(Self);
  Lbl.Caption := AItem.Title;
  Lbl.Bold := True;
  Lbl.AutoSize := False;
  Lbl.Height := 22;
  Lbl.AlignWithMargins := True;
  Lbl.Margins.SetBounds(CPad, CPad, CPad, 0);
  Lbl.Parent := Self;
  Lbl.Top := 1000;
  Lbl.Align := alTop;

  Lbl := TUILabel.Create(Self);
  Lbl.Caption := Tr('Status atual: ') + AItem.Status;
  Lbl.Variant := lvMuted;
  Lbl.AutoSize := False;
  Lbl.Height := 20;
  Lbl.AlignWithMargins := True;
  Lbl.Margins.SetBounds(CPad, 4, CPad, 0);
  Lbl.Parent := Self;
  Lbl.Top := 2000;
  Lbl.Align := alTop;

  FSelect := TUISelect.Create(Self);
  FSelect.Caption := Tr('Mover para');
  FSelect.Placeholder := Tr('Carregando transições...');
  FSelect.OnChange := SelectChange;
  FSelect.AlignWithMargins := True;
  FSelect.Margins.SetBounds(CPad, 12, CPad, 0);
  FSelect.Parent := Self;
  FSelect.Top := 3000;
  FSelect.Align := alTop;

  FFields := TPanel.Create(Self);
  FFields.BevelOuter := bvNone;
  FFields.ParentBackground := False;
  FFields.Color := UIThemeVclBackground;
  FFields.Height := 0;
  FFields.Parent := Self;
  FFields.Top := 3500;
  FFields.Align := alTop;
  FBaseHeight := ClientHeight;

  FLoading := TUILoading.Create(Self);
  FLoading.Size := ssSM;
  FLoading.SetBounds(ClientWidth - ScaleValue(CPad + 64), ScaleValue(96), ScaleValue(28), ScaleValue(28));
  FLoading.Parent := Self;

  FAlert := TUIAlert.Create(Self);
  FAlert.Tone := atError;
  FAlert.Style_ := asSoft;
  FAlert.Visible := False;
  FAlert.AlignWithMargins := True;
  FAlert.Margins.SetBounds(CPad, 12, CPad, 0);
  FAlert.Parent := Self;
  FAlert.Top := 4000;
  FAlert.Align := alTop;

  Load;
end;

procedure TStatusForm.CreateWnd;
begin
  inherited;
  ApplyTitleBarTheme(Self);
  FadeInOnShow(Self);
end;

procedure TStatusForm.Load;
var
  A: TAccount;
  Key, Token: string;
begin
  A := FAccount;
  Key := FItem.Key;
  Token := FToken;
  RunTask(
    procedure
    var
      List: TTransitions;
      Err: string;
    begin
      try
        List := FetchTransitions(A, Token, Key);
      except
        on E: Exception do
          Err := E.Message;
      end;
      QueueUI(
        procedure
        var
          T: TTransition;
        begin
          if csDestroying in ComponentState then
            Exit;
          FLoading.Visible := False;
          FTransitions := List;
          if Err <> '' then
          begin
            FAlert.Title := Tr('Não carregou as transições');
            FAlert.Message_ := Err;
            FAlert.Visible := True;
            Exit;
          end;
          for T in List do
            if SameText(T.Name, T.ToStatus) then
              FSelect.Items.Add(T.ToStatus)
            else
              FSelect.Items.Add(T.ToStatus + '  (' + T.Name + ')');
          FSelect.Placeholder := Tr('Escolha o novo status');
          if List = nil then
            FSelect.Placeholder := Tr('Nenhuma transição disponível');
          FSelect.ItemsLoaded;
          FApply.Enabled := List <> nil;
        end);
    end);
end;

{ Transição com tela no Jira (ex.: Resolver pede Resolução): um campo por item. }
procedure TStatusForm.SelectChange(Sender: TObject);
const
  CRowH = 64;
var
  C: TControl;
  F: TTransitionField;
  Sel: TUISelect;
  Inp: TUIInput;
  V: string;
begin
  for C in FFieldCtrls do
    C.Free;
  FFieldCtrls := nil;
  if (FSelect.ItemIndex < 0) or (FSelect.ItemIndex > High(FTransitions)) then
    Exit;
  for F in FTransitions[FSelect.ItemIndex].Fields do
  begin
    if F.Allowed <> nil then
    begin
      Sel := TUISelect.Create(Self);
      Sel.Caption := F.Name + ' *';
      Sel.Placeholder := Tr('Escolha');
      for V in F.Allowed do
        Sel.Items.Add(V);
      Sel.ItemsLoaded;
      C := Sel;
    end
    else
    begin
      Inp := TUIInput.Create(Self);
      Inp.LabelMode := ilmBorder;
      Inp.ReserveHintSpace := False;
      Inp.LabelText := F.Name + ' *';
      C := Inp;
    end;
    C.Hint := F.Id;
    C.AlignWithMargins := True;
    C.Margins.SetBounds(CPad, 10, CPad, 0);
    C.Parent := FFields;
    C.Top := (Length(FFieldCtrls) + 1) * 1000;
    C.Align := alTop;
    FFieldCtrls := FFieldCtrls + [C];
  end;
  FFields.Height := ScaleValue(CRowH) * Length(FFieldCtrls);
  ClientHeight := FBaseHeight + FFields.Height;
end;

procedure TStatusForm.ApplyClick(Sender: TObject);
var
  A: TAccount;
  Key, Token, V: string;
  T: TTransition;
  Values: TArray<string>;
  C: TControl;
begin
  if (FSelect.ItemIndex < 0) or (FSelect.ItemIndex > High(FTransitions)) then
  begin
    FAlert.Tone := atWarning;
    FAlert.Title := Tr('Escolha o novo status');
    FAlert.Message_ := '';
    FAlert.Visible := True;
    Exit;
  end;
  A := FAccount;
  Key := FItem.Key;
  Token := FToken;
  T := FTransitions[FSelect.ItemIndex];
  Values := nil;
  for C in FFieldCtrls do
  begin
    if C is TUISelect then
    begin
      if TUISelect(C).ItemIndex >= 0 then
        V := TUISelect(C).Items[TUISelect(C).ItemIndex]
      else
        V := '';
    end
    else
      V := TUIInput(C).Value.Trim;
    if V = '' then
    begin
      FAlert.Tone := atWarning;
      FAlert.Title := Tr('Preencha os campos obrigatórios');
      FAlert.Message_ := '';
      FAlert.Visible := True;
      Exit;
    end;
    Values := Values + [C.Hint + '=' + V];
  end;
  FApply.Loading := True;
  FAlert.Visible := False;
  RunTask(
    procedure
    var
      Err: string;
    begin
      try
        ApplyTransitionWith(A, Token, Key, T, Values);
      except
        on E: Exception do
          Err := E.Message;
      end;
      QueueUI(
        procedure
        begin
          if csDestroying in ComponentState then
            Exit;
          FApply.Loading := False;
          if Err = '' then
            ModalResult := mrOk
          else
          begin
            FAlert.Tone := atError;
            FAlert.Title := Tr('O servidor recusou');
            FAlert.Message_ := Err;
            FAlert.Visible := True;
          end;
        end);
    end);
end;

procedure TStatusForm.CancelClick(Sender: TObject);
begin
  ModalResult := mrCancel;
end;

{ ── Registrar tempo ───────────────────────────────────────────────────── }

type
  TTimeForm = class(TForm)
  private
    FAccount: TAccount;
    FItem: TItem;
    FHours: TUINumberInput;
    FDay: TUIDatePicker;
    FStart: TUITimePicker;
    FNote: TUITextArea;
    FSave: TUIButton;
    FAlert: TUIAlert;
    FWeek: TUILabel;
    procedure LoadWeek;
    procedure SaveClick(Sender: TObject);
    procedure CancelClick(Sender: TObject);
    procedure QuickClick(Sender: TObject);
  protected
    procedure CreateWnd; override;
  end;

procedure TTimeForm.QuickClick(Sender: TObject);
const
  Hours: array[0..4] of Double = (0.5, 1, 2, 4, 8);
begin
  FHours.Value := Hours[TComponent(Sender).Tag];
end;

procedure TTimeForm.LoadWeek;
var
  A: TAccount;
begin
  A := FAccount;
  RunTask(
    procedure
    var
      Today, Week: Double;
      Txt: string;
    begin
      try
        FetchWeekHours(A, LoadSecret(A.SecretTarget), Today, Week);
        Txt := Format(Tr('Você já lançou %.1fh hoje e %.1fh nesta semana'), [Today, Week]);
      except
        on E: Exception do
          Txt := '';
      end;
      QueueUI(
        procedure
        begin
          if not (csDestroying in ComponentState) then
            FWeek.Caption := Txt;
        end);
    end);
end;

procedure TTimeForm.CancelClick(Sender: TObject);
begin
  ModalResult := mrCancel;
end;

procedure TTimeForm.CreateWnd;
begin
  inherited;
  ApplyTitleBarTheme(Self);
  FadeInOnShow(Self);
end;

procedure TTimeForm.SaveClick(Sender: TObject);
var
  A: TAccount;
  Key, Token, Note: string;
  Hours: Double;
  Started: TDateTime;
begin
  A := FAccount;
  Key := FItem.Key;
  Token := LoadSecret(A.SecretTarget);
  Hours := FHours.Value;
  Note := FNote.Value;
  Started := FDay.Value + EncodeTime(FStart.Hour, FStart.Minute, 0, 0);
  if Hours <= 0 then
  begin
    FAlert.Title := Tr('Informe as horas');
    FAlert.Message_ := '';
    FAlert.Visible := True;
    Exit;
  end;
  FSave.Loading := True;
  RunTask(
    procedure
    var
      Err: string;
    begin
      try
        AddWorklog(A, Token, Key, Hours, Started, Note);
      except
        on E: Exception do
          Err := E.Message;
      end;
      QueueUI(
        procedure
        begin
          if csDestroying in ComponentState then
            Exit;
          FSave.Loading := False;
          if Err = '' then
          begin
            TUIToastManager.Show(Format(Tr('%.1fh registradas em %s'), [Hours, Key]), ttSuccess);
            ModalResult := mrOk;
          end
          else
          begin
            FAlert.Title := Tr('O servidor recusou');
            FAlert.Message_ := Err;
            FAlert.Visible := True;
          end;
        end);
    end);
end;

function LogTime(AOwner: TComponent; const AAccount: TAccount; const AItem: TItem): Boolean;
const
  Quick: array[0..4] of string = ('30 min', '1h', '2h', '4h', '8h');
var
  F: TTimeForm;
  Foot, Row, Line: TPanel;
  Btn: TUIButton;
  Lbl: TUILabel;
  I: Integer;

  procedure Stack(AControl: TControl; AGap: Integer);
  begin
    AControl.AlignWithMargins := True;
    AControl.Margins.SetBounds(CPad, AGap, CPad, 0);
    AControl.Parent := F;
    AControl.Top := F.ControlCount * 1000;
    AControl.Align := alTop;
  end;

  function NewRow(AHeight: Integer): TPanel;
  begin
    Result := TPanel.Create(F);
    Result.BevelOuter := bvNone;
    Result.ParentBackground := False;
    Result.Color := UIThemeVclBackground;
    Result.Height := F.ScaleValue(AHeight);
  end;

begin
  F := TTimeForm.CreateNew(AOwner);
  try
    F.FAccount := AAccount;
    F.FItem := AItem;
    F.Caption := Tr('Registrar tempo');
    F.ClientWidth := F.ScaleValue(460);
    F.ClientHeight := F.ScaleValue(432);
    F.Position := poOwnerFormCenter;
    F.BorderStyle := bsDialog;
    F.DoubleBuffered := True;
    F.Color := UIThemeVclBackground;

    // Rodapé: divisória + Cancelar e Registrar à direita, com respiro entre eles.
    Foot := NewRow(64);
    Foot.Padding.SetBounds(CPad, 14, CPad, 14);
    Foot.Align := alBottom;
    Foot.Parent := F;
    Line := NewRow(1);
    Line.Color := UIAlphaToVclColor(UITheme.Tokens.Color.Border);
    Line.Parent := F;
    Foot.Top := 200000;
    Line.Top := 100000;
    Line.Align := alBottom;
    F.FSave := TUIButton.Create(F);
    F.FSave.Caption := Tr('Registrar');
    F.FSave.Width := F.ScaleValue(120);
    F.FSave.Default := True;
    F.FSave.OnClick := F.SaveClick;
    F.FSave.Parent := Foot;
    F.FSave.Left := 2000;
    F.FSave.Align := alRight;
    Btn := TUIButton.Create(F);
    Btn.Caption := Tr('Cancelar');
    Btn.Variant := bvGhost;
    Btn.Width := F.ScaleValue(100);
    Btn.OnClick := F.CancelClick;
    Btn.Cancel := True;
    Btn.AlignWithMargins := True;
    Btn.Margins.SetBounds(0, 0, 10, 0);
    Btn.Parent := Foot;
    Btn.Left := 1000;
    Btn.Align := alRight;

    // Cabeçalho: chave pequena e título da issue em até 2 linhas.
    Lbl := TUILabel.Create(F);
    Lbl.Caption := AItem.Key;
    Lbl.Variant := lvMuted;
    Lbl.AutoSize := False;
    Lbl.Height := F.ScaleValue(18);
    Stack(Lbl, CPad);
    Lbl := TUILabel.Create(F);
    Lbl.Caption := AItem.Title;
    Lbl.Bold := True;
    Lbl.FontSize := 14;
    Lbl.WordWrap := True;
    Lbl.AutoSize := False;
    Lbl.Height := F.ScaleValue(42);
    Stack(Lbl, 2);
    F.FWeek := TUILabel.Create(F);
    F.FWeek.Caption := Tr('Somando suas horas da semana...');
    F.FWeek.Variant := lvMuted;
    F.FWeek.AutoSize := False;
    F.FWeek.Height := F.ScaleValue(18);
    Stack(F.FWeek, 4);
    F.LoadWeek;

    // Atalhos de duração.
    Row := NewRow(30);
    Stack(Row, 12);
    for I := 0 to High(Quick) do
    begin
      Btn := TUIButton.Create(F);
      Btn.Caption := Quick[I];
      Btn.Variant := bvOutline;
      Btn.Size := bsSM;
      Btn.AutoWidth := True;
      Btn.Tag := I;
      Btn.OnClick := F.QuickClick;
      Btn.AlignWithMargins := True;
      Btn.Margins.SetBounds(0, 0, 6, 0);
      Btn.Parent := Row;
      Btn.Left := (I + 1) * 1000;
      Btn.Align := alLeft;
    end;

    Row := NewRow(66);
    Stack(Row, 12);
    F.FHours := TUINumberInput.Create(F);
    F.FHours.LabelText := Tr('Horas');
    F.FHours.Min := 0;
    F.FHours.Max := 24;
    F.FHours.Step := 0.5;
    F.FHours.DecimalPlaces := 1;
    F.FHours.Value := 1;
    F.FHours.Width := F.ScaleValue(118);
    F.FHours.Parent := Row;
    F.FHours.Left := 1000;
    F.FHours.Align := alLeft;
    F.FDay := TUIDatePicker.Create(F);
    F.FDay.LabelText := Tr('Dia');
    F.FDay.Value := Date;
    F.FDay.AlignWithMargins := True;
    F.FDay.Margins.SetBounds(10, 0, 0, 0);
    F.FDay.Parent := Row;
    F.FDay.Left := 2000;
    F.FDay.Align := alClient;
    F.FStart := TUITimePicker.Create(F);
    F.FStart.LabelText := Tr('Início');
    F.FStart.Hour := 9;
    F.FStart.Minute := 0;
    F.FStart.Width := F.ScaleValue(118);
    F.FStart.AlignWithMargins := True;
    F.FStart.Margins.SetBounds(10, 0, 0, 0);
    F.FStart.Parent := Row;
    F.FStart.Left := 3000;
    F.FStart.Align := alRight;

    F.FNote := TUITextArea.Create(F);
    F.FNote.LabelText := Tr('O que foi feito (opcional)');
    F.FNote.Rows := 4;
    Stack(F.FNote, 14);

    F.FAlert := TUIAlert.Create(F);
    F.FAlert.Tone := atError;
    F.FAlert.Style_ := asSoft;
    F.FAlert.Visible := False;
    Stack(F.FAlert, 10);

    Result := F.ShowModal = mrOk;
  finally
    F.Free;
  end;
end;

{ ── Confirmar / perguntar ─────────────────────────────────────────────── }

type
  TAskForm = class(TForm)
  protected
    procedure CreateWnd; override;
  public
    procedure OkClick(Sender: TObject);
    procedure CancelClick(Sender: TObject);
  end;

procedure TAskForm.CreateWnd;
begin
  inherited;
  ApplyTitleBarTheme(Self);
  FadeInOnShow(Self);
end;

procedure TAskForm.OkClick(Sender: TObject);
begin
  ModalResult := mrOk;
end;

procedure TAskForm.CancelClick(Sender: TObject);
begin
  ModalResult := mrCancel;
end;

{ AKind: 0 = só confirmar, 1 = texto, 2 = escolha. }
function Ask(AOwner: TComponent; AKind: Integer; const ATitle, AMessage, ALabel, AOk: string;
  const AChoices: TArray<string>; var AText: string; var AIndex: Integer): Boolean;
var
  F: TAskForm;
  Foot: TPanel;
  Btn, Ok: TUIButton;
  Lbl: TUILabel;
  Inp: TUIInput;
  Sel: TUISelect;
  C: string;
begin
  Inp := nil;
  Sel := nil;
  F := TAskForm.CreateNew(AOwner);
  try
    F.Caption := ATitle;
    F.ClientWidth := F.ScaleValue(440);
    F.ClientHeight := F.ScaleValue(150 + Ord(AKind <> 0) * 64);
    F.Position := poOwnerFormCenter;
    F.BorderStyle := bsDialog;
    F.DoubleBuffered := True;
    F.Color := UIThemeVclBackground;

    Foot := TPanel.Create(F);
    Foot.BevelOuter := bvNone;
    Foot.ParentBackground := False;
    Foot.Color := UIThemeVclBackground;
    Foot.Height := F.ScaleValue(60);
    Foot.Padding.SetBounds(CPad, 12, CPad, 12);
    Foot.Align := alBottom;
    Foot.Parent := F;
    Ok := TUIButton.Create(F);
    Ok.Caption := AOk;
    Ok.AutoWidth := True;
    Ok.Default := True;
    Ok.OnClick := F.OkClick;
    Ok.Parent := Foot;
    Ok.Left := 2000;
    Ok.Align := alRight;
    Btn := TUIButton.Create(F);
    Btn.Caption := Tr('Cancelar');
    Btn.Variant := bvGhost;
    Btn.AutoWidth := True;
    Btn.Cancel := True;
    Btn.OnClick := F.CancelClick;
    Btn.AlignWithMargins := True;
    Btn.Margins.SetBounds(0, 0, 8, 0);
    Btn.Parent := Foot;
    Btn.Left := 1000;
    Btn.Align := alRight;

    Lbl := TUILabel.Create(F);
    Lbl.Caption := AMessage;
    Lbl.WordWrap := True;
    Lbl.AutoSize := False;
    Lbl.Height := F.ScaleValue(60);
    Lbl.AlignWithMargins := True;
    Lbl.Margins.SetBounds(CPad, CPad, CPad, 0);
    Lbl.Parent := F;
    Lbl.Top := 1000;
    Lbl.Align := alTop;

    if AKind = 1 then
    begin
      Inp := TUIInput.Create(F);
      Inp.LabelMode := ilmBorder;
      Inp.ReserveHintSpace := False;
      Inp.LabelText := ALabel;
      Inp.Value := AText;
      Inp.AlignWithMargins := True;
      Inp.Margins.SetBounds(CPad, 8, CPad, 0);
      Inp.Parent := F;
      Inp.Top := 2000;
      Inp.Align := alTop;
      F.ActiveControl := Inp;
    end
    else if AKind = 2 then
    begin
      Sel := TUISelect.Create(F);
      Sel.Caption := ALabel;
      for C in AChoices do
        Sel.Items.Add(C);
      Sel.ItemsLoaded;
      Sel.ItemIndex := AIndex;
      Sel.AlignWithMargins := True;
      Sel.Margins.SetBounds(CPad, 8, CPad, 0);
      Sel.Parent := F;
      Sel.Top := 2000;
      Sel.Align := alTop;
    end;

    Result := F.ShowModal = mrOk;
    if Result and (Inp <> nil) then
    begin
      AText := Inp.Value.Trim;
      Result := AText <> '';
    end;
    if Result and (Sel <> nil) then
    begin
      AIndex := Sel.ItemIndex;
      Result := AIndex >= 0;
    end;
  finally
    F.Free;
  end;
end;

function AskConfirm(AOwner: TComponent; const ATitle, AMessage, AOkCaption: string): Boolean;
var
  T: string;
  I: Integer;
begin
  I := -1;
  Result := Ask(AOwner, 0, ATitle, AMessage, '', AOkCaption, nil, T, I);
end;

function AskText(AOwner: TComponent; const ATitle, AMessage, ALabel: string; var AValue: string): Boolean;
var
  I: Integer;
begin
  I := -1;
  Result := Ask(AOwner, 1, ATitle, AMessage, ALabel, Tr('Confirmar'), nil, AValue, I);
end;

function AskChoice(AOwner: TComponent; const ATitle, AMessage, ALabel: string;
  const AChoices: TArray<string>; var AIndex: Integer): Boolean;
var
  T: string;
begin
  Result := Ask(AOwner, 2, ATitle, AMessage, ALabel, Tr('Confirmar'), AChoices, T, AIndex);
end;

end.
