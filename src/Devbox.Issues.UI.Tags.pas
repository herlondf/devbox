unit Devbox.Issues.UI.Tags;

{ Modal das tags (agrupadores do usuário, ex.: "Pagamentos", "Mobile"), em duas abas:
  Tags (lista com editar/excluir) e Cadastro (nome e palavras do título).
  Um FAB no canto troca de papel com a aba: "+" na lista, disquete no cadastro.
  Cancelar: botão "×" ao lado do FAB, Esc ou clicar na aba Tags. }

interface

uses
  System.Classes,
  Devbox.Issues.Model;

{ True quando algo mudou. AItem/AHasItem: issue que recebe a tag nova. }
function ManageTags(AOwner: TComponent; const AItem: TItem; AHasItem: Boolean): Boolean;

implementation

uses
  Devbox.I18n,
  System.SysUtils,
  System.Math,
  System.UITypes,
  Winapi.Windows,
  Vcl.Controls,
  Vcl.Forms,
  Vcl.ExtCtrls,
  UI.Theme,
  UI.Tokens,
  UI.Painter.Vcl,
  UI.Labels,
  UI.Button,
  UI.Input,
  UI.VirtualList,
  System.Types,
  System.Skia,
  UI.Painter,
  UI.Fonts,
  UI.Tabs,
  UI.FAB,
  UI.PageTransition,
  UI.Toast,
  Devbox.Issues.Store,
  Devbox.Issues.UI.Common;

const
  CPad = 16;
  CRowH = 60;
  CIconSz = 18;
  CIconHit = 32;
  CSvgEdit = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" ' +
    'stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 20h9"/>' +
    '<path d="M16.5 3.5a2.1 2.1 0 0 1 3 3L7 19l-4 1 1-4Z"/></svg>';
  CSvgTrash = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" ' +
    'stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M3 6h18"/>' +
    '<path d="M8 6V4h8v2"/><path d="M19 6l-1 14H6L5 6"/><path d="M10 11v6M14 11v6"/></svg>';
  CFabGap = 20;
  // viewBox maior que o desenho: o FAB pinta o SVG no botão inteiro.
  CSvgHead = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="-12 -12 48 48" fill="none" ' +
    'stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">';
  CSvgPlus = CSvgHead + '<path d="M12 5v14M5 12h14"/></svg>';
  CSvgSave = CSvgHead + '<path d="M19 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h11l5 5v11a2 2 0 0 1-2 2z"/>' +
    '<path d="M17 21v-8H7v8"/><path d="M7 3v5h8"/></svg>';
  CSvgClose = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" ' +
    'stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M6 6l12 12M18 6L6 18"/></svg>';

type
  TListAccess = class(TUIVirtualList);

  TTagsForm = class(TForm)
  private
    FItem: TItem;
    FHasItem: Boolean;
    FChanged: Boolean;
    FEditId: Integer;
    FConfirmId: Integer;          // excluir pede um segundo clique
    FTab: Integer;                // 0 = lista, 1 = cadastro
    FTabs: TUITabs;
    FContent: TPanel;
    FPages: array[0..1] of TPanel;
    FTransition: TUIPageTransition;
    FFab: TUIFAB;
    FCancel: TUIButton;
    FHeading: TUILabel;
    FName: TUIInput;
    FKeywords: TUIInput;
    FList: TUIVirtualList;
    FTags: TTags;                 // linhas da lista, na ordem
    FEmpty: TUILabel;
    procedure Build;
    procedure Reload;
    procedure ShowTab(AIndex: Integer);
    procedure StartEdit(AId: Integer);
    procedure Save;
    procedure TabChange(Sender: TObject; AIndex: Integer);
    procedure FabClick(Sender: TObject);
    procedure CancelClick(Sender: TObject);
    procedure ListDraw(Sender: TObject; AIndex: Integer; const AItem: TUIVListItem;
      const ACanvas: ISkCanvas; const ARowRect: TRectF);
    procedure ListMouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
    procedure FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
  protected
    procedure CreateWnd; override;
  public
    destructor Destroy; override;
  end;

function ManageTags(AOwner: TComponent; const AItem: TItem; AHasItem: Boolean): Boolean;
var
  F: TTagsForm;
begin
  F := TTagsForm.CreateNew(AOwner);
  try
    F.FItem := AItem;
    F.FHasItem := AHasItem;
    F.Build;
    F.ShowModal;
    Result := F.FChanged;
  finally
    F.Free;
  end;
end;

function NewPanel(AOwner: TComponent; AParent: TWinControl; AHeight: Integer): TPanel;
begin
  Result := TPanel.Create(AOwner);
  Result.BevelOuter := bvNone;
  Result.ParentBackground := False;
  Result.Color := UIThemeVclBackground;
  Result.Height := AHeight;
  Result.Parent := AParent;
end;

destructor TTagsForm.Destroy;
begin
  FTransition.Free;
  inherited;
end;

procedure TTagsForm.CreateWnd;
begin
  inherited;
  ApplyTitleBarTheme(Self);
  FadeInOnShow(Self);
end;

procedure TTagsForm.Build;
var
  Lbl: TUILabel;
  P: TPanel;
begin
  Caption := Tr('Tags');
  ClientWidth := ScaleValue(480);
  ClientHeight := ScaleValue(500);
  Position := poOwnerFormCenter;
  BorderStyle := bsDialog;
  DoubleBuffered := True;
  Color := UIThemeVclBackground;
  KeyPreview := True;
  OnKeyDown := FormKeyDown;
  FTransition := TUIPageTransition.Create;
  FTransition.Style := ttSlide;

  FTabs := TUITabs.Create(Self);
  FTabs.AddTab(Tr('Consulta'));
  FTabs.AddTab(Tr('Cadastro'));
  FTabs.ActiveIndex := 0;
  FTabs.OnChange := TabChange;
  FTabs.AlignWithMargins := True;
  FTabs.Margins.SetBounds(CPad, 8, CPad, 0);
  FTabs.Parent := Self;
  FTabs.Align := alTop;

  FContent := NewPanel(Self, Self, 100);
  FContent.Top := 1000;
  FContent.Align := alClient;

  // Aba 1: lista.
  P := NewPanel(Self, FContent, 100);
  P.Padding.SetBounds(CPad, CPad, CPad, 0);
  P.Align := alClient;
  FPages[0] := P;
  Lbl := TUILabel.Create(Self);
  Lbl.Caption := Tr('Agrupe issues por projeto. A issue entra na tag pelo título ou pelo ' +
    'botão direito na lista (Tag).');
  Lbl.Variant := lvMuted;
  Lbl.WordWrap := True;
  Lbl.AutoSize := False;
  Lbl.Height := ScaleValue(40);
  Lbl.Parent := P;
  Lbl.Top := 0;
  Lbl.Align := alTop;
  // Mesma lista virtual da aba Issues; ações desenhadas na linha.
  FList := TUIVirtualList.Create(Self);
  FList.RowHeight := CRowH;
  FList.OnCustomDraw := ListDraw;
  TListAccess(FList).OnMouseDown := ListMouseDown;
  FList.AlignWithMargins := True;
  FList.Margins.SetBounds(0, 8, 0, 0);
  FList.Parent := P;
  FList.Top := 1000;
  FList.Align := alClient;
  FEmpty := TUILabel.Create(Self);
  FEmpty.Caption := Tr('Nenhuma tag ainda. Clique no + para criar.');
  FEmpty.Variant := lvMuted;
  FEmpty.AutoSize := False;
  FEmpty.Height := ScaleValue(24);
  FEmpty.Parent := P;
  FEmpty.Top := 500;
  FEmpty.Align := alTop;

  // Aba 2: cadastro.
  P := NewPanel(Self, FContent, 100);
  P.Padding.SetBounds(CPad, CPad, CPad, 0);
  P.Align := alClient;
  P.Visible := False;
  FPages[1] := P;
  FHeading := TUILabel.Create(Self);
  FHeading.Bold := True;
  FHeading.FontSize := 14;
  FHeading.AutoSize := False;
  FHeading.Height := ScaleValue(24);
  FHeading.Parent := P;
  FHeading.Top := 0;
  FHeading.Align := alTop;
  FName := TUIInput.Create(Self);
  FName.LabelText := Tr('Nome da tag (ex.: Pagamentos)');
  FName.LabelMode := ilmBorder;  // rótulo na borda: texto inteiro sem fonte maior
  FName.ReserveHintSpace := False;  // a dica vai dentro do campo; embaixo duplicava
  FName.AlignWithMargins := True;
  FName.Margins.SetBounds(0, 14, 0, 0);
  FName.Parent := P;
  FName.Top := 1000;
  FName.Align := alTop;
  FKeywords := TUIInput.Create(Self);
  FKeywords.LabelText := Tr('Palavras no título (opcional, separadas por vírgula ou ;)');
  FKeywords.LabelMode := ilmBorder;  // rótulo na borda: texto inteiro sem fonte maior
  FKeywords.ReserveHintSpace := False;  // a dica vai dentro do campo; embaixo duplicava
  FKeywords.AlignWithMargins := True;
  FKeywords.Margins.SetBounds(0, 12, 0, 0);
  FKeywords.Parent := P;
  FKeywords.Top := 2000;
  FKeywords.Align := alTop;
  Lbl := TUILabel.Create(Self);
  Lbl.Caption := Tr('Ex.: "pagamento, pix" pega toda issue com uma dessas palavras no título. ' +
    'Sem palavras, a tag vale só para as issues marcadas à mão.');
  Lbl.Variant := lvMuted;
  Lbl.FontSize := HintFontSize;
  Lbl.Italic := True;
  Lbl.WordWrap := True;
  Lbl.AutoSize := False;
  Lbl.Height := ScaleValue(40);
  Lbl.AlignWithMargins := True;
  Lbl.Margins.SetBounds(0, 10, 0, 0);
  Lbl.Parent := P;
  Lbl.Top := 3000;
  Lbl.Align := alTop;

  // FAB fora do conteúdo: não desliza junto na troca de aba.
  FFab := TUIFAB.Create(Self);
  FFab.IconSvg := CSvgPlus;
  FFab.Hint := Tr('Nova tag');
  FFab.OnClick := FabClick;
  FFab.Parent := Self;
  FFab.SetBounds(ClientWidth - FFab.Width - ScaleValue(CFabGap),
    ClientHeight - FFab.Height - ScaleValue(CFabGap), FFab.Width, FFab.Height);
  FFab.Anchors := [akRight, akBottom];
  FFab.BringToFront;

  FCancel := TUIButton.Create(Self);
  FCancel.Variant := bvSecondary;
  FCancel.IconSvg := CSvgClose;
  FCancel.CornerRadius := 20;
  FCancel.Hint := Tr('Cancelar (Esc)');
  FCancel.ShowHint := True;
  FCancel.OnClick := CancelClick;
  FCancel.Parent := Self;
  FCancel.SetBounds(FFab.Left - ScaleValue(52), FFab.Top + (FFab.Height - ScaleValue(40)) div 2,
    ScaleValue(40), ScaleValue(40));
  FCancel.Anchors := [akRight, akBottom];
  FCancel.Visible := False;
  FCancel.BringToFront;

  Reload;
end;

{ Troca de aba com deslize; o FAB vira disquete no cadastro e "+" na lista. }
procedure TTagsForm.ShowTab(AIndex: Integer);
var
  Dir: TUIPageTransitionDirection;
begin
  if AIndex = FTab then
    Exit;
  if AIndex > FTab then
    Dir := tdForward
  else
    Dir := tdBackward;
  FTab := AIndex;
  if Visible and FContent.HandleAllocated then
    FTransition.Run(FContent, Dir,
      procedure
      begin
        FPages[0].Visible := FTab = 0;
        FPages[1].Visible := FTab = 1;
      end)
  else
  begin
    FPages[0].Visible := FTab = 0;
    FPages[1].Visible := FTab = 1;
  end;
  if FTabs.ActiveIndex <> AIndex then
  begin
    FTabs.OnChange := nil;
    FTabs.ActiveIndex := AIndex;
    FTabs.OnChange := TabChange;
  end;
  if AIndex = 1 then
  begin
    FFab.IconSvg := CSvgSave;
    FFab.Hint := Tr('Salvar (Enter)');
    FCancel.Visible := True;
    FName.SetFocus;
  end
  else
  begin
    FFab.IconSvg := CSvgPlus;
    FFab.Hint := Tr('Nova tag');
    FCancel.Visible := False;
    FConfirmId := 0;
    Reload;
  end;
end;

{ AId = 0: tag nova. }
procedure TTagsForm.StartEdit(AId: Integer);
var
  T: TTag;
begin
  FEditId := 0;
  FName.Value := '';
  FKeywords.Value := '';
  FHeading.Caption := Tr('Nova tag');
  if AId <> 0 then
    for T in IssueStore.ListTags do
      if T.Id = AId then
      begin
        FEditId := T.Id;
        FName.Value := T.Name;
        FKeywords.Value := T.Keywords;
        FHeading.Caption := Tr('Editando #') + T.Name;
      end;
  ShowTab(1);
end;

procedure TTagsForm.Save;
var
  T: TTag;
  Created: Boolean;
begin
  T := Default(TTag);
  T.Id := FEditId;
  T.AccountId := FItem.AccountId;
  T.Name := FName.Value.Trim.TrimLeft(['#']);
  T.Keywords := FKeywords.Value.Trim;
  if T.Name = '' then
  begin
    TUIToastManager.Show(Tr('Dê um nome para a tag'), ttWarning);
    FName.SetFocus;
    Exit;
  end;
  Created := T.Id = 0;
  try
    IssueStore.SaveTag(T);
  except
    on E: Exception do
    begin
      TUIToastManager.Show(Tr('Já existe uma tag com esse nome nesta conta'), ttWarning);
      Exit;
    end;
  end;
  if Created and FHasItem then
  begin
    IssueStore.SetItemTag(T.Id, FItem.AccountId, FItem.Key, True);
    FHasItem := False;  // só a primeira tag criada marca a issue
  end;
  FChanged := True;
  FEditId := 0;
  ShowTab(0);
end;

procedure TTagsForm.TabChange(Sender: TObject; AIndex: Integer);
begin
  // Clicar em "Cadastro" começa uma tag nova; em "Tags" cancela a edição.
  if AIndex = 1 then
    StartEdit(0)
  else
    ShowTab(0);
end;

procedure TTagsForm.FabClick(Sender: TObject);
begin
  if FTab = 0 then
    StartEdit(0)
  else
    Save;
end;

procedure TTagsForm.CancelClick(Sender: TObject);
begin
  FEditId := 0;
  ShowTab(0);
end;

procedure TTagsForm.FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if Key = VK_ESCAPE then
  begin
    Key := 0;
    if FTab = 1 then
      CancelClick(nil)
    else
      ModalResult := mrClose;
  end
  else if (Key = VK_RETURN) and (FTab = 1) then
  begin
    Key := 0;
    Save;
  end;
end;

{ Recarrega as tags na lista virtual. }
procedure TTagsForm.Reload;
var
  T: TTag;
  V: TUIVListItem;
begin
  // Só as tags da conta da issue: a do Jira não aparece no GitHub.
  FTags := nil;
  for T in IssueStore.ListTags do
    if T.AccountId = FItem.AccountId then
      FTags := FTags + [T];
  FList.ClearItems;
  for T in FTags do
  begin
    V := Default(TUIVListItem);
    V.ID := IntToStr(T.Id);
    FList.AddItem(V);
  end;
  FEmpty.Visible := FTags = nil;
  FList.Visible := FTags <> nil;
  FList.Invalidate;
end;

{ Retângulos dos ícones de ação (canetinha e lixeira) à direita da linha. }
function IconRect(const ARowRect: TRectF; ASlot: Integer): TRectF;
var
  Cx: Single;
begin
  Cx := ARowRect.Right - 14 - CIconHit / 2 - ASlot * (CIconHit + 6);
  Result := TRectF.Create(Cx - CIconHit / 2, ARowRect.CenterPoint.Y - CIconHit / 2,
    Cx + CIconHit / 2, ARowRect.CenterPoint.Y + CIconHit / 2);
end;

{ Linha: #nome em cima, regra embaixo; à direita canetinha (azul) e lixeira
  (vermelha). Primeiro clique na lixeira pede confirmação na própria linha. }
procedure TTagsForm.ListDraw(Sender: TObject; AIndex: Integer; const AItem: TUIVListItem;
  const ACanvas: ISkCanvas; const ARowRect: TRectF);
const
  PadX = 14;
var
  Tk: TUITokens;
  T: TTag;
  L, R: Single;
  Rule: string;
  NameFont, SubFont: ISkFont;
  Ic: TRectF;
  Confirm: Boolean;
  SubColor: TAlphaColor;
begin
  if AIndex > High(FTags) then
    Exit;
  Tk := UITheme.Tokens;
  T := FTags[AIndex];
  Confirm := FConfirmId = T.Id;
  L := ARowRect.Left + PadX;
  R := IconRect(ARowRect, 1).Left - 8;
  NameFont := TUIFontManager.GetFont(Tk.Typography.FamilyPrimary, 13, Tk.Typography.WeightSemiBold);
  SubFont := TUIFontManager.GetFont(Tk.Typography.FamilyPrimary, 11.5, Tk.Typography.WeightRegular);
  UIDrawText(ACanvas, '#' + T.Name, TRectF.Create(L, ARowRect.Top + 10, R, ARowRect.Top + 30),
    NameFont, Tk.Color.Primary);
  if Confirm then
    Rule := Tr('Clique de novo na lixeira para excluir')
  else if T.Keywords.Trim <> '' then
    Rule := Tr('Título com: ') + T.Keywords
  else
    Rule := Tr('Só marcação manual');
  if (not Confirm) and (T.Manual <> nil) then
    Rule := Rule + Format(Tr('  ·  %d marcada(s) à mão'), [Length(T.Manual)]);
  if Confirm then
    SubColor := Tk.Color.Error
  else
    SubColor := Tk.Color.FGMuted;
  UIDrawText(ACanvas, Rule, TRectF.Create(L, ARowRect.Top + 32, R, ARowRect.Top + 50), SubFont, SubColor);

  Ic := IconRect(ARowRect, 1);
  UIDrawRRectFill(ACanvas, Ic, Ic.Height / 2, UIColorWithAlpha(Tk.Color.Primary, 0.10));
  Ic.Inflate(-(CIconHit - CIconSz) / 2, -(CIconHit - CIconSz) / 2);
  UIDrawSvg(ACanvas, CSvgEdit, Ic, 1, Tk.Color.Primary);
  Ic := IconRect(ARowRect, 0);
  UIDrawRRectFill(ACanvas, Ic, Ic.Height / 2, UIColorWithAlpha(Tk.Color.Error, IfThen(Confirm, 0.28, 0.10)));
  Ic.Inflate(-(CIconHit - CIconSz) / 2, -(CIconHit - CIconSz) / 2);
  UIDrawSvg(ACanvas, CSvgTrash, Ic, 1, Tk.Color.Error);
end;

procedure TTagsForm.ListMouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
var
  Lst: TListAccess;
  I: Integer;
  Row: TRectF;
  P: TPointF;
begin
  if Button <> mbLeft then
    Exit;
  Lst := TListAccess(FList);
  P := PointF(X, Y);
  for I := Lst.FirstVisible to Min(Lst.LastVisible, High(FTags)) do
  begin
    Row := Lst.RowRect(I);
    if not Row.Contains(P) then
      Continue;
    if IconRect(Row, 1).Contains(P) then
      StartEdit(FTags[I].Id)
    else if IconRect(Row, 0).Contains(P) then
    begin
      if FConfirmId = FTags[I].Id then
      begin
        IssueStore.DeleteTag(FTags[I].Id);
        FConfirmId := 0;
        FChanged := True;
        Reload;
      end
      else
      begin
        FConfirmId := FTags[I].Id;
        FList.Invalidate;
      end;
    end
    else if FConfirmId <> 0 then
    begin
      FConfirmId := 0;  // clique fora da lixeira desiste de excluir
      FList.Invalidate;
    end;
    Exit;
  end;
end;

end.
