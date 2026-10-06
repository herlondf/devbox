unit Devbox.UI.Clipboard;

{ Histórico do clipboard (texto, imagem, arquivos) e snippets. Busca, prévia,
  colar na janela de antes, conversores, OCR, salvar PNG, hash e zip. }

interface

uses
  Winapi.Windows,
  System.Classes,
  System.SysUtils,
  Vcl.Controls,
  Vcl.ExtCtrls,
  UI.Tokens,
  UI.Button,
  UI.Input,
  UI.FilterChip,
  UI.EmptyState,
  UI.Code,
  UI.Image,
  UI.ScrollArea,
  UI.VirtualList,
  UI.Dropdown,
  Devbox.Model,
  Devbox.Sys,
  Devbox.AI,
  Devbox.UI.Kit;

type
  TClipEditEvent = procedure(AId: Integer) of object;

  TClipboardPage = class(TDevPage)
  private
    FOnEditSnippet: TClipEditEvent;
    FWatcher: TClipboardWatcher;
    FClips: TClips;
    FShown: TClips;
    FSearch: TUIInput;
    FSnippetChip: TUIFilterChip;
    FList: TUIVirtualList;
    FEmpty: TUIEmptyState;
    FPreviewScroll: TUIScrollArea;
    FPreview: TUICode;
    FImage: TUIImage;
    FPinBtn: TUIButton;
    FTextBar, FImageBar, FFilesBar: TPanel;
    FActionsBar: TPanel;               // Colar, Copiar...: sempre a última embaixo
    FConvertBtn: TUIButton;
    FConvertMenu: TUIDropdown;
    FAIBtn: TUIButton;
    FAIMenu: TUIDropdown;
    FPasteTimer: TTimer;
    FPrevWnd: HWND;
    procedure ClipCopied(AKind: TClipKind; const AText: string; const AData: TBytes);
    procedure FilterClips;
    function SelectedClip(out AClip: TClip): Boolean;
    procedure UpdatePreview;
    procedure MoveSelection(ADelta: Integer);
    { Põe o clip no clipboard do jeito certo para o tipo dele. }
    procedure PutOnClipboard(const AClip: TClip);
    { Texto novo (conversão, OCR, hash): entra no histórico e no clipboard. }
    procedure AddResult(const AText, AMessage: string);
    function ImageFile(const AClip: TClip): string;
    procedure SearchChange(Sender: TObject);
    procedure ListClick(Sender: TObject; AIndex: Integer; const AItem: TUIVListItem);
    procedure ListDblClick(Sender: TObject; AIndex: Integer; const AItem: TUIVListItem);
    procedure PasteClick(Sender: TObject);
    procedure PasteTimerTick(Sender: TObject);
    procedure CopyClick(Sender: TObject);
    procedure PinClick(Sender: TObject);
    procedure DeleteClick(Sender: TObject);
    procedure ConvertClick(Sender: TObject);
    procedure ConvertItemClick(Sender: TObject; const AID: string);
    procedure SavePngClick(Sender: TObject);
    procedure OcrClick(Sender: TObject);
    procedure CopyPathsClick(Sender: TObject);
    procedure HashFilesClick(Sender: TObject);
    procedure ZipClick(Sender: TObject);
    procedure EditSnippetClick(Sender: TObject);
    procedure AIClick(Sender: TObject);
    procedure AIItemClick(Sender: TObject; const AID: string);
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure ReloadClips;
    { Abre pela tecla global: guarda a janela de antes e limpa a busca. }
    procedure OpenFromHotkey(APrevWnd: HWND);
    function PageKey(var AKey: Word; AShift: TShiftState): Boolean; override;
    property Watcher: TClipboardWatcher read FWatcher;
    { Botão "Snippet e atalho…": quem abre o diálogo é a tela do Expansor. }
    property OnEditSnippet: TClipEditEvent read FOnEditSnippet write FOnEditSnippet;
  end;

implementation

uses
  System.StrUtils,
  System.Math,
  System.IOUtils,
  System.Threading,
  System.Hash,
  System.Zip,
  Vcl.Forms,
  Vcl.Dialogs,
  UI.Toast,
  Devbox.Store,
  Devbox.Focus,
  Devbox.Convert;

const
  CPreviewWidth = 440;
  CMaxTitle = 140;
  CLineHeight = 17;
  CPad = 24;

function LineCount(const AText: string): Integer;
begin
  Result := Length(AText) - Length(StringReplace(AText, #10, '', [rfReplaceAll])) + 1;
end;

function SizeText(ABytes: Int64): string;
begin
  if ABytes < 1024 then
    Result := Format('%d B', [ABytes])
  else if ABytes < 1024 * 1024 then
    Result := Format('%.1f KB', [ABytes / 1024])
  else if ABytes < Int64(1024) * 1024 * 1024 then
    Result := Format('%.1f MB', [ABytes / (1024 * 1024)])
  else
    Result := Format('%.2f GB', [ABytes / (1024 * 1024 * 1024)]);
end;

{ Tamanho do arquivo, ou da pasta somando tudo dentro. -1 = não existe mais. }
function PathSize(const APath: string): Int64;
var
  F: string;
begin
  if TFile.Exists(APath) then
    Exit(TFile.GetSize(APath));
  if not TDirectory.Exists(APath) then
    Exit(-1);
  Result := 0;
  for F in TDirectory.GetFiles(APath, '*', TSearchOption.soAllDirectories) do
    Inc(Result, TFile.GetSize(F));
end;

constructor TClipboardPage.Create(AOwner: TComponent);
var
  Bar, Right, Buttons: TPanel;
  K: TConvertKind;
  A: TAIAction;
begin
  inherited Create(AOwner);
  Caption := 'Clipboard';
  Hint := 'Tudo que você copia: texto, imagem e arquivos. Win+Alt+B abre daqui de qualquer programa.';

  Bar := NewPanel(Self, alTop, 48);
  Bar.Padding.SetBounds(0, 0, 0, ScaleValue(8));
  FSnippetChip := TUIFilterChip.Create(Self);
  FSnippetChip.Caption := 'Snippets';
  FSnippetChip.Tone := btPrimary;
  FSnippetChip.OnToggle := SearchChange;
  FSnippetChip.AlignWithMargins := True;
  FSnippetChip.Margins.SetBounds(ScaleValue(8), ScaleValue(4), 0, ScaleValue(4));
  FSnippetChip.Align := alRight;
  FSnippetChip.Parent := Bar;
  FSearch := TUIInput.Create(Self);
  FSearch.LabelMode := ilmBorder;
  FSearch.LabelText := 'Buscar no histórico e nos snippets';
  FSearch.ReserveHintSpace := False;
  FSearch.ShowClearButton := True;
  FSearch.OnChange := SearchChange;
  FSearch.Align := alClient;
  FSearch.Parent := Bar;

  NewHint(Self, 'Enter cola na janela de antes  ·  ↑↓ escolhem  ·  Esc fecha  ·  ' +
    'senhas de gerenciador e textos com cara de token não entram', alBottom);

  Right := NewPanel(Self, alRight);
  Right.Width := ScaleValue(CPreviewWidth);
  Right.Padding.SetBounds(ScaleValue(12), 0, 0, 0);

  // Ações do tipo do item (uma barra por tipo) e, embaixo, as de todos.
  // alBottom: quem é criado depois fica mais embaixo.
  FTextBar := NewPanel(Right, alBottom, 44);
  FTextBar.Padding.SetBounds(0, ScaleValue(8), 0, 0);
  FConvertBtn := NewButton(FTextBar, 'Converter…', ConvertClick, bvGhost);
  NewButton(FTextBar, 'Snippet e atalho…', EditSnippetClick, bvGhost);
  FAIBtn := NewButton(FTextBar, 'IA…', AIClick, bvGhost);
  FAIMenu := TUIDropdown.Create(Self);
  FAIMenu.AnchorControl := FAIBtn;
  FAIMenu.AnchorPos := dapTopLeft;
  FAIMenu.OnItemClick := AIItemClick;
  for A := Low(AIActionNames) to High(AIActionNames) do
    FAIMenu.AddItem(IntToStr(Ord(A)), AIActionNames[A]);
  FConvertMenu := TUIDropdown.Create(Self);
  FConvertMenu.AnchorControl := FConvertBtn;
  FConvertMenu.AnchorPos := dapTopLeft;
  FConvertMenu.MaxHeight := 460;
  FConvertMenu.OnItemClick := ConvertItemClick;
  for K := Low(TConvertKind) to High(TConvertKind) do
    FConvertMenu.AddItem(IntToStr(Ord(K)), ConvertNames[K]);

  FImageBar := NewPanel(Right, alBottom, 44);
  FImageBar.Padding.SetBounds(0, ScaleValue(8), 0, 0);
  NewButton(FImageBar, 'Extrair texto (OCR)', OcrClick, bvGhost);
  NewButton(FImageBar, 'Salvar PNG…', SavePngClick, bvGhost);

  FFilesBar := NewPanel(Right, alBottom, 44);
  FFilesBar.Padding.SetBounds(0, ScaleValue(8), 0, 0);
  NewButton(FFilesBar, 'Copiar caminhos', CopyPathsClick, bvGhost);
  NewButton(FFilesBar, 'SHA-256', HashFilesClick, bvGhost);
  NewButton(FFilesBar, 'Compactar (zip)', ZipClick, bvGhost);

  Buttons := NewPanel(Right, alBottom, 44);
  FActionsBar := Buttons;
  Buttons.Padding.SetBounds(0, ScaleValue(8), 0, 0);
  NewButton(Buttons, 'Colar', PasteClick, bvPrimary);
  NewButton(Buttons, 'Copiar', CopyClick);
  FPinBtn := NewButton(Buttons, 'Fixar como snippet', PinClick);
  NewButton(Buttons, 'Excluir', DeleteClick, bvGhost, alRight);

  FImage := TUIImage.Create(Self);
  FImage.Align := alClient;
  FImage.Visible := False;
  FImage.Parent := Right;
  FPreviewScroll := TUIScrollArea.Create(Self);
  FPreviewScroll.Align := alClient;
  FPreviewScroll.Parent := Right;
  FPreview := TUICode.Create(Self);
  FPreview.Align := alTop;
  FPreview.Parent := FPreviewScroll.InnerPanel;

  FList := TUIVirtualList.Create(Self);
  FList.RowHeight := 56;
  FList.Align := alClient;
  FList.OnItemClick := ListClick;
  FList.OnItemDblClick := ListDblClick;
  FList.Parent := Self;

  FEmpty := TUIEmptyState.Create(Self);
  FEmpty.Title := 'Nada copiado ainda';
  FEmpty.Description := 'Copie um texto, uma imagem ou arquivos em qualquer programa. Fica a um Win+Alt+B de distância.';
  FEmpty.Visible := False;
  FEmpty.Align := alClient;
  FEmpty.Parent := Self;

  FPasteTimer := TTimer.Create(Self);
  FPasteTimer.Enabled := False;
  FPasteTimer.Interval := 80;
  FPasteTimer.OnTimer := PasteTimerTick;

  FWatcher := TClipboardWatcher.Create(
    procedure(AKind: TClipKind; const AText: string; const AData: TBytes)
    begin
      ClipCopied(AKind, AText, AData);
    end);
  ReloadClips;
end;

destructor TClipboardPage.Destroy;
begin
  FWatcher.Free;
  inherited;
end;

procedure TClipboardPage.OpenFromHotkey(APrevWnd: HWND);
begin
  FPrevWnd := APrevWnd;
  FSearch.Value := '';
  // CanFocus não olha se o form está visível.
  if FSearch.CanFocus and GetParentForm(FSearch).Visible then
    FSearch.SetFocus;
end;

function TClipboardPage.PageKey(var AKey: Word; AShift: TShiftState): Boolean;
begin
  Result := True;
  case AKey of
    VK_UP, VK_DOWN:
      if not FList.Focused then
        MoveSelection(IfThen(AKey = VK_UP, -1, 1))
      else
        Result := False;
    VK_RETURN: PasteClick(nil);
  else
    Result := False;
  end;
end;

procedure TClipboardPage.ClipCopied(AKind: TClipKind; const AText: string; const AData: TBytes);
begin
  if (Store.GetSetting('clip_on', '1') <> '1') or (FocusActive and FocusPauseClipboard) then
    Exit;
  if (AKind = ckText) and LooksSecret(AText) then
    Exit;
  Store.AddClip(AText, AKind, AData);
  ReloadClips;
end;

procedure TClipboardPage.ReloadClips;
begin
  FClips := Store.ListClips;
  FilterClips;
end;

procedure TClipboardPage.FilterClips;
const
  KindIcons: array[TClipKind] of string = ('', '🖼', '📁');
var
  C: TClip;
  Q, Sub: string;
  Item: TUIVListItem;
  Pins: Integer;
begin
  Q := Trim(FSearch.Value);
  FShown := nil;
  Pins := 0;
  for C in FClips do
  begin
    if C.Pinned then
      Inc(Pins);
    if (not FSnippetChip.Active or C.Pinned) and ((Q = '') or ContainsText(C.Text, Q)) then
      FShown := FShown + [C];
  end;
  FList.ClearItems;
  for C in FShown do
  begin
    Item := Default(TUIVListItem);
    Item.ID := IntToStr(C.Id);
    Item.Title := Copy(ClipCaption(C), 1, CMaxTitle);
    Item.Icon := KindIcons[C.Kind];
    Sub := Ago(C.CreatedAt, Now);
    case C.Kind of
      ckText:
        if LineCount(C.Text) > 1 then
          Sub := Sub + Format('  ·  %d linhas', [LineCount(C.Text)])
        else
          Sub := Sub + Format('  ·  %d caracteres', [Length(C.Text)]);
      ckImage: Sub := Sub + '  ·  imagem';
      ckFiles: Sub := Sub + IfThen(Length(ClipFiles(C)) = 1, '  ·  arquivo', '  ·  arquivos');
    end;
    Item.Subtitle := Sub;
    if C.Pinned then
      Item.MetaText := 'snippet';
    FList.AddItem(Item);
  end;
  FList.Visible := FShown <> nil;
  FEmpty.Visible := FShown = nil;
  if (Q <> '') or FSnippetChip.Active then
    FEmpty.Title := 'Nada encontrado'
  else
    FEmpty.Title := 'Nada copiado ainda';
  if FShown <> nil then
    FList.SelectIndex(0);
  FSnippetChip.Count := Pins;
  UpdatePreview;
end;

function TClipboardPage.SelectedClip(out AClip: TClip): Boolean;
var
  Sel: TArray<Integer>;
begin
  Sel := FList.GetSelectedIndices;
  Result := (Sel <> nil) and (Sel[0] >= 0) and (Sel[0] <= High(FShown));
  if Result then
    AClip := FShown[Sel[0]];
end;

{ Cache em disco: o TUIImage lê de arquivo. Um por clip, nome pelo id. }
function TClipboardPage.ImageFile(const AClip: TClip): string;
var
  Dir: string;
begin
  Dir := TPath.Combine(DataDir, 'cache');
  ForceDirectories(Dir);
  Result := TPath.Combine(Dir, Format('clip-%d.png', [AClip.Id]));
  if not TFile.Exists(Result) then
    TFile.WriteAllBytes(Result, Store.ClipData(AClip.Id));
end;

procedure TClipboardPage.UpdatePreview;
var
  C: TClip;
  S, F: string;
  Size: Int64;
  Has: Boolean;
begin
  Has := SelectedClip(C);
  FTextBar.Visible := Has and (C.Kind = ckText);
  FImageBar.Visible := Has and (C.Kind = ckImage);
  FFilesBar.Visible := Has and (C.Kind = ckFiles);
  // Barra que reaparece vai para o fim da fila do alBottom: devolve a principal para baixo.
  FActionsBar.Top := FActionsBar.Parent.Height;  // ClientHeight pediria handle antes de ter pai
  FImage.Visible := Has and (C.Kind = ckImage);
  FPreviewScroll.Visible := not FImage.Visible;
  if not Has then
  begin
    FPreview.Text := '';
    FPreview.Height := ScaleValue(CPad * 2);
    Exit;
  end;
  FPinBtn.Caption := IfThen(C.Pinned, 'Desafixar', 'Fixar como snippet');
  case C.Kind of
    ckImage:
      begin
        FImage.ImagePath := ImageFile(C);
        Exit;
      end;
    ckFiles:
      begin
        S := '';
        for F in ClipFiles(C) do
        begin
          Size := PathSize(F);
          S := S + F + #10 + IfThen(Size < 0, '   (não existe mais)', '   ' + SizeText(Size)) + #10;
        end;
      end;
  else
    S := StringReplace(C.Text, #13, '', [rfReplaceAll]);  // texto copiado no Windows vem com CR+LF
  end;
  FPreview.Text := TrimRight(S);
  FPreview.Height := ScaleValue(Max(LineCount(FPreview.Text) * CLineHeight + CPad, 120));
end;

procedure TClipboardPage.MoveSelection(ADelta: Integer);
var
  Sel: TArray<Integer>;
  I: Integer;
begin
  if FShown = nil then
    Exit;
  Sel := FList.GetSelectedIndices;
  if Sel = nil then
    I := 0
  else
    I := EnsureRange(Sel[0] + ADelta, 0, High(FShown));
  FList.SelectIndex(I);
  FList.ScrollToIndex(I);
  UpdatePreview;
end;

procedure TClipboardPage.SearchChange(Sender: TObject);
begin
  FilterClips;
end;

procedure TClipboardPage.ListClick(Sender: TObject; AIndex: Integer; const AItem: TUIVListItem);
begin
  UpdatePreview;
end;

procedure TClipboardPage.ListDblClick(Sender: TObject; AIndex: Integer; const AItem: TUIVListItem);
begin
  PasteClick(nil);
end;

procedure TClipboardPage.PutOnClipboard(const AClip: TClip);
begin
  case AClip.Kind of
    ckImage: FWatcher.SetImage(Store.ClipData(AClip.Id));
    ckFiles: FWatcher.SetFiles(ClipFiles(AClip));
  else
    FWatcher.SetText(AClip.Text);
  end;
end;

procedure TClipboardPage.AddResult(const AText, AMessage: string);
var
  I: Integer;
begin
  Store.AddClip(AText);
  FWatcher.SetText(AText);
  FSearch.Value := '';
  ReloadClips;
  // O resultado fica selecionado, logo abaixo dos snippets.
  for I := 0 to High(FShown) do
    if FShown[I].Text = AText then
    begin
      FList.SelectIndex(I);
      FList.ScrollToIndex(I);
      UpdatePreview;
      Break;
    end;
  TUIToastManager.Show(AMessage, ttSuccess, 2500);
end;

procedure TClipboardPage.CopyClick(Sender: TObject);
var
  C: TClip;
begin
  if not SelectedClip(C) then
    Exit;
  PutOnClipboard(C);
  TUIToastManager.Show('Copiado', ttSuccess, 1500);
end;

{ Cola na janela que estava na frente quando o atalho abriu o Devbox. Aberto
  pela bandeja, não há janela de antes: só copia. }
procedure TClipboardPage.PasteClick(Sender: TObject);
var
  C: TClip;
begin
  if not SelectedClip(C) then
    Exit;
  PutOnClipboard(C);
  Store.AddClip(C.Text, C.Kind);  // usado agora sobe para o topo
  if (FPrevWnd = 0) or not IsWindow(FPrevWnd) then
  begin
    ReloadClips;
    TUIToastManager.Show('Copiado. Abra pelo Win+Alt+B para colar direto.', ttSuccess, 3000);
    Exit;
  end;
  GetParentForm(Self).Hide;
  FPasteTimer.Enabled := True;
end;

procedure TClipboardPage.PasteTimerTick(Sender: TObject);
begin
  FPasteTimer.Enabled := False;
  PasteInto(FPrevWnd);
  FPrevWnd := 0;
  ReloadClips;
end;

procedure TClipboardPage.PinClick(Sender: TObject);
var
  C: TClip;
begin
  if not SelectedClip(C) then
    Exit;
  Store.SetPinned(C.Id, not C.Pinned);
  ReloadClips;
end;

procedure TClipboardPage.DeleteClick(Sender: TObject);
var
  C: TClip;
begin
  if not SelectedClip(C) then
    Exit;
  Store.DeleteClip(C.Id);
  ReloadClips;
end;

procedure TClipboardPage.EditSnippetClick(Sender: TObject);
var
  C: TClip;
begin
  if SelectedClip(C) and Assigned(FOnEditSnippet) then
    FOnEditSnippet(C.Id);
end;

procedure TClipboardPage.AIClick(Sender: TObject);
begin
  FAIMenu.Open;
end;

{ Manda o texto selecionado para a IA. Só sai daqui com o clique: o histórico
  nunca vai sozinho para a internet. }
procedure TClipboardPage.AIItemClick(Sender: TObject; const AID: string);
var
  C: TClip;
  Action: TAIAction;
  Prompt, System_: string;
  Config: TAIConfig;
begin
  if not SelectedClip(C) then
    Exit;
  Config := LoadAIConfig;
  if not Config.Ready then
  begin
    TUIToastManager.Show('Configure a IA em Configurações › IA', ttWarning, 4000);
    Exit;
  end;
  Action := TAIAction(StrToInt(AID));
  Prompt := ActionPrompt(Action, C.Text, System_);
  TUIToastManager.Show('Perguntando à IA...', ttLoading, 3000);
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
        begin
          if Ok then
            AddResult(Answer, AIActionNames[Action] + ': resposta copiada')
          else
            TUIToastManager.Show('A IA não respondeu: ' + Answer, ttError, 6000);
        end);
    end);
end;

procedure TClipboardPage.ConvertClick(Sender: TObject);
begin
  FConvertMenu.Open;
end;

procedure TClipboardPage.ConvertItemClick(Sender: TObject; const AID: string);
var
  C: TClip;
  Kind: TConvertKind;
  Output, Error: string;
begin
  if not SelectedClip(C) then
    Exit;
  Kind := TConvertKind(StrToInt(AID));
  if ConvertText(Kind, C.Text, Output, Error) then
    AddResult(Output, ConvertNames[Kind] + ': pronto e copiado')
  else
    TUIToastManager.Show(Error, ttError, 5000);
end;

procedure TClipboardPage.SavePngClick(Sender: TObject);
var
  C: TClip;
  Dlg: TFileSaveDialog;
begin
  if not SelectedClip(C) then
    Exit;
  Dlg := TFileSaveDialog.Create(nil);
  try
    Dlg.Title := 'Salvar imagem';
    Dlg.DefaultExtension := 'png';
    Dlg.FileName := FormatDateTime('"imagem-"yyyymmdd"-"hhnnss".png"', C.CreatedAt);
    with Dlg.FileTypes.Add do
    begin
      DisplayName := 'Imagem PNG';
      FileMask := '*.png';
    end;
    if Dlg.Execute then
    begin
      TFile.WriteAllBytes(Dlg.FileName, Store.ClipData(C.Id));
      TUIToastManager.Show('Imagem salva', ttSuccess, 2000);
    end;
  finally
    Dlg.Free;
  end;
end;

procedure TClipboardPage.OcrClick(Sender: TObject);
var
  C: TClip;
  Path: string;
begin
  if not SelectedClip(C) then
    Exit;
  Path := ImageFile(C);
  TUIToastManager.Show('Lendo o texto da imagem...', ttLoading, 2000);
  TTask.Run(
    procedure
    var
      Text: string;
      Ok: Boolean;
    begin
      Ok := OcrImage(Path, Text);
      System.Classes.TThread.Queue(nil,
        procedure
        begin
          if Ok and (Text <> '') then
            AddResult(Text, 'Texto extraído e copiado')
          else if Ok then
            TUIToastManager.Show('Não achei texto na imagem', ttWarning, 4000)
          else
            TUIToastManager.Show('O OCR falhou: ' + Text, ttError, 6000);
        end);
    end);
end;

procedure TClipboardPage.CopyPathsClick(Sender: TObject);
var
  C: TClip;
begin
  if SelectedClip(C) then
    AddResult(string.Join(#13#10, ClipFiles(C)), 'Caminhos copiados');
end;

procedure TClipboardPage.HashFilesClick(Sender: TObject);
var
  C: TClip;
  Files: TArray<string>;
begin
  if not SelectedClip(C) then
    Exit;
  Files := ClipFiles(C);
  TUIToastManager.Show('Calculando SHA-256...', ttLoading, 2000);
  TTask.Run(
    procedure
    var
      F, Output: string;
    begin
      Output := '';
      for F in Files do
        if TFile.Exists(F) then
          Output := Output + THashSHA2.GetHashStringFromFile(F) + '  ' + ExtractFileName(F) + #13#10;
      System.Classes.TThread.Queue(nil,
        procedure
        begin
          if Output = '' then
            TUIToastManager.Show('Nenhum arquivo para calcular (pastas ficam de fora)', ttWarning, 4000)
          else
            AddResult(TrimRight(Output), 'SHA-256 copiado');
        end);
    end);
end;

{ Zip ao lado do primeiro item; pastas entram com o que tem dentro. No fim, o
  zip vai para o clipboard como arquivo: dá para colar no e-mail ou no chat. }
procedure TClipboardPage.ZipClick(Sender: TObject);
var
  C: TClip;
  Files: TArray<string>;
  Target: string;
begin
  if not SelectedClip(C) then
    Exit;
  Files := ClipFiles(C);
  if Files = nil then
    Exit;
  Target := TPath.Combine(ExtractFilePath(ExcludeTrailingPathDelimiter(Files[0])),
    FormatDateTime('"devbox-"yyyymmdd"-"hhnnss".zip"', Now));
  TUIToastManager.Show('Compactando...', ttLoading, 2000);
  TTask.Run(
    procedure
    var
      Zip: TZipFile;
      F, Inner, Base: string;
      Error: string;
    begin
      Error := '';
      Zip := TZipFile.Create;
      try
        try
          Zip.Open(Target, zmWrite);
          for F in Files do
            if TFile.Exists(F) then
              Zip.Add(F, ExtractFileName(F))
            else if TDirectory.Exists(F) then
            begin
              Base := ExtractFilePath(ExcludeTrailingPathDelimiter(F));
              for Inner in TDirectory.GetFiles(F, '*', TSearchOption.soAllDirectories) do
                Zip.Add(Inner, StringReplace(Copy(Inner, Length(Base) + 1, MaxInt), '\', '/', [rfReplaceAll]));
            end;
          Zip.Close;
        except
          on E: Exception do
            Error := E.Message;
        end;
      finally
        Zip.Free;
      end;
      System.Classes.TThread.Queue(nil,
        procedure
        begin
          if Error <> '' then
          begin
            TUIToastManager.Show('Não deu para compactar: ' + Error, ttError, 6000);
            Exit;
          end;
          FWatcher.SetFiles([Target]);
          Store.AddClip(Target, ckFiles);
          ReloadClips;
          TUIToastManager.Show('Zip criado e copiado: ' + ExtractFileName(Target), ttSuccess, 4000);
        end);
    end);
end;

end.
