unit Devbox.Issues.UI.Detail;

{ Painel lateral de uma issue. Cabeçalho fixo com caminho e ações; o resto
  rola junto: título, selos, prazo e as abas Comentários / Histórico.
  A caixa de comentário fica no rodapé, com o botão de enviar dentro dela. }

interface

uses
  System.Classes,
  Vcl.Controls,
  Vcl.ExtCtrls,
  UI.Tokens,
  UI.Button,
  UI.Labels,
  UI.Badge,
  UI.Breadcrumbs,
  UI.Timeline,
  UI.ScrollArea,
  UI.Loading,
  UI.TextArea,
  UI.Tabs,
  Devbox.Issues.Model;

type
  TDetailPanel = class(TPanel)
  private
    FItem: TItem;
    FAccount: TAccount;
    FCrumbs: TUIBreadcrumbs;
    FTitle: TUILabel;
    FBadgeRow: TPanel;
    FInfo: TUILabel;
    FScroll: TUIScrollArea;
    FTabs: TUITabs;
    FTab: Integer;  // 0 = comentários, 1 = histórico, 2 = detalhes
    FEventCount: Integer;
    FCommentCount: Integer;
    FSeen: array[0..2] of Boolean;  // aba já aberta nesta issue: sem contador
    FCi: TUILabel;                  // PR: job que falhou (clique abre)
    FTriage: TUILabel;              // sugestão da triagem da IA
    FDetails: TUILabel;             // descrição, anexos e links
    FDetailsLoaded: Boolean;
    FLoadSeq: Integer;              // descarta resposta de uma busca antiga
    FComments: TComments;           // última leitura, para o resumo da IA
    FAiBtn: TUIButton;
    FTimeline: TUITimeline;
    FCommentsLabel: TUILabel;
    FLoading: TUILoading;
    FBubbles: TList;
    FCompose: TPanel;
    FCommentBox: TUITextArea;
    FCommentBtn: TUIButton;
    FTimeBtn: TUIButton;
    FOnClose: TNotifyEvent;
    FOnChanged: TNotifyEvent;
    function NewIconButton(AParent: TWinControl; const ASvg, AHint: string;
      AClick: TNotifyEvent): TUIButton;
    procedure AddBadge(const ACaption: string; ATone: TUIBadgeTone; const ATip: string);
    procedure CommentClick(Sender: TObject);
    procedure TimeClick(Sender: TObject);
    procedure TabChange(Sender: TObject; AIndex: Integer);
    procedure UpdateTabs;
    procedure ClearBubbles;
    procedure LoadComments;
    procedure LoadDetails;
    procedure ShowTriage;
    procedure AiSummaryClick(Sender: TObject);
    procedure CiClick(Sender: TObject);
    procedure Relayout;
    procedure CloseClick(Sender: TObject);
    procedure OpenClick(Sender: TObject);
    procedure ComposeResize(Sender: TObject);
  protected
    procedure Resize; override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure ShowItem(const AItem: TItem; const AAccount: TAccount);
    procedure ApplyTheme;
    property Item: TItem read FItem;
    property OnClose: TNotifyEvent read FOnClose write FOnClose;
    { Comentou ou registrou tempo: o dono busca de novo. }
    property OnChanged: TNotifyEvent read FOnChanged write FOnChanged;
  end;

implementation

uses
  Devbox.UI.Kit,
  Devbox.I18n,
  System.SysUtils,
  System.StrUtils,
  System.DateUtils,
  System.Math,
  System.Threading,
  System.UITypes,
  System.Skia,
  Winapi.Windows,
  Winapi.ShellAPI,
  UI.Theme,
  UI.Painter,
  UI.Painter.Vcl,
  UI.Fonts,
  UI.ChatBubble,
  UI.Tooltip,
  UI.Toast,
  Devbox.Issues.UI.Status,
  Devbox.Issues.Store,
  Devbox.Secrets,
  Devbox.Issues.Providers,
  Devbox.Issues.UI.Common,
  Devbox.Issues.UI.Views,
  Devbox.Issues.AI,
  System.JSON;

const
  CPad = 16;
  CGap = 8;
  CSendSize = 32;
  CSvgHead = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" ' +
    'stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">';
  CSvgSend = CSvgHead + '<path d="M7.9 20A9 9 0 1 0 4 16.1L2 22Z"/></svg>';  // balão de mensagem
  CSvgClock = CSvgHead + '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/></svg>';
  CSvgOpen = CSvgHead + '<path d="M14 4h6v6M20 4l-9 9M18 14v5a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V7' +
    'a1 1 0 0 1 1-1h5"/></svg>';
  CSvgClose = CSvgHead + '<path d="M6 6l12 12M18 6L6 18"/></svg>';
  CSvgSpark = CSvgHead + '<path d="M12 3l1.8 5.2L19 10l-5.2 1.8L12 17l-1.8-5.2L5 10l5.2-1.8z"/>' +
    '<path d="M19 15l.7 2.3L22 18l-2.3.7L19 21l-.7-2.3L16 18l2.3-.7z"/></svg>';

function StatusTip(const ACategory: string): string;
begin
  if ACategory = 'indeterminate' then
    Result := Tr('Em andamento: alguém está trabalhando nela.')
  else if ACategory = 'done' then
    Result := Tr('Concluída.')
  else
    Result := Tr('Ainda não começou (a fazer).');
end;

function DueTip(ADue: TDateTime; const AAccount: TAccount): string;
var
  Left: Integer;
begin
  Left := Trunc(DateOf(ADue) - Date);
  if Left < 0 then
    Result := Format(Tr('Venceu há %d dia(s).'), [-Left])
  else if Left = 0 then
    Result := Tr('Vence hoje.')
  else
    Result := Format(Tr('Faltam %d dia(s).'), [Left]);
  Result := Result + Format(Tr(' Fica laranja com %d e vermelho com %d dias.'),
    [AAccount.WarnDays, AAccount.CriticalDays]);
end;

function TDetailPanel.NewIconButton(AParent: TWinControl; const ASvg, AHint: string;
  AClick: TNotifyEvent): TUIButton;
begin
  Result := TUIButton.Create(Self);
  Result.Caption := '';  // sem isto aparecia o "Button" padrão ao lado do ícone
  Result.Variant := bvGhost;
  Result.Size := UI.Button.bsSM;
  Result.IconSvg := ASvg;
  Result.Width := 34;
  Result.Hint := AHint;
  Result.ShowHint := True;
  Result.OnClick := AClick;
  Result.AlignWithMargins := True;
  Result.Margins.SetBounds(2, 0, 0, 0);
  Result.Parent := AParent;
  Result.Left := AParent.ControlCount * 1000;
  Result.Align := alRight;
end;

constructor TDetailPanel.Create(AOwner: TComponent);
var
  Head, Crumbs: TPanel;
  Inner: TWinControl;
begin
  inherited;
  BevelOuter := bvNone;
  ParentBackground := False;
  DoubleBuffered := True;
  FBubbles := TList.Create;

  // Cabeçalho fixo: ações numa linha, caminho na de baixo (a chave não fica
  // embaixo dos ícones).
  Head := TPanel.Create(Self);
  Head.BevelOuter := bvNone;
  Head.ParentBackground := False;
  Head.Height := 40;
  Head.Padding.SetBounds(CPad, CGap, CGap, 0);
  Head.Align := alTop;
  Head.Parent := Self;
  FAiBtn := NewIconButton(Head, CSvgSpark, Tr('Resumir a conversa e sugerir resposta (IA)'), AiSummaryClick);
  FTimeBtn := NewIconButton(Head, CSvgClock, Tr('Registrar tempo'), TimeClick);
  NewIconButton(Head, CSvgOpen, Tr('Abrir no navegador'), OpenClick);
  NewIconButton(Head, CSvgClose, Tr('Fechar (Esc)'), CloseClick);
  Crumbs := TPanel.Create(Self);
  Crumbs.BevelOuter := bvNone;
  Crumbs.ParentBackground := False;
  Crumbs.Height := 30;
  Crumbs.Padding.SetBounds(CPad, 0, CGap, 0);
  Crumbs.Parent := Self;
  Crumbs.Top := 500;
  Crumbs.Align := alTop;
  FCrumbs := TUIBreadcrumbs.Create(Self);
  FCrumbs.Separator := '›';
  FCrumbs.Align := alClient;
  FCrumbs.Parent := Crumbs;

  // Rodapé: caixa de comentário com o botão redondo de enviar por cima.
  FCompose := TPanel.Create(Self);
  FCompose.BevelOuter := bvNone;
  FCompose.ParentBackground := False;
  FCompose.Height := 112;
  FCompose.Padding.SetBounds(CPad, CGap, CPad, CPad);
  FCompose.Align := alBottom;
  FCompose.Parent := Self;
  FCompose.OnResize := ComposeResize;
  FCommentBox := TUITextArea.Create(Self);
  FCommentBox.LabelText := Tr('Escrever um comentário');
  FCommentBox.Rows := 3;
  FCommentBox.Align := alClient;
  FCommentBox.Parent := FCompose;
  FCommentBtn := TUIButton.Create(Self);
  FCommentBtn.Size := UI.Button.bsSM;
  FCommentBtn.Variant := TUIButtonVariant.bvSoft;
  FCommentBtn.IconSvg := CSvgSend;
  FCommentBtn.CornerRadius := CSendSize / 2;
  FCommentBtn.Hint := Tr('Comentar');
  FCommentBtn.ShowHint := True;
  FCommentBtn.OnClick := CommentClick;
  FCommentBtn.SetBounds(0, 0, CSendSize, CSendSize);
  FCommentBtn.Parent := FCompose;
  FCommentBtn.BringToFront;

  FScroll := TUIScrollArea.Create(Self);
  FScroll.Align := alClient;
  FScroll.Parent := Self;
  Inner := FScroll.InnerPanel;

  FTitle := TUILabel.Create(Self);
  FTitle.Bold := True;
  FTitle.FontSize := 13;
  FTitle.WordWrap := True;
  FTitle.AutoSize := False;
  FTitle.Parent := Inner;

  FBadgeRow := TPanel.Create(Self);
  FBadgeRow.BevelOuter := bvNone;
  FBadgeRow.ParentBackground := False;
  FBadgeRow.Parent := Inner;

  FInfo := TUILabel.Create(Self);
  FInfo.Variant := lvMuted;
  FInfo.AutoSize := False;
  FInfo.Parent := Inner;

  FCi := TUILabel.Create(Self);
  FCi.AutoSize := False;
  FCi.Cursor := crHandPoint;
  FCi.OnClick := CiClick;
  FCi.Parent := Inner;

  FTriage := TUILabel.Create(Self);
  FTriage.Variant := lvMuted;
  FTriage.FontSize := HintFontSize;
  FTriage.Italic := True;
  FTriage.AutoSize := False;
  FTriage.Parent := Inner;

  FTabs := TUITabs.Create(Self);
  FTabs.Parent := Inner;

  FDetails := TUILabel.Create(Self);
  FDetails.WordWrap := True;
  FDetails.AutoSize := False;
  FDetails.Parent := Inner;

  FTimeline := TUITimeline.Create(Self);
  FTimeline.Parent := Inner;

  FCommentsLabel := TUILabel.Create(Self);
  FCommentsLabel.Variant := lvMuted;
  FCommentsLabel.WordWrap := True;
  FCommentsLabel.AutoSize := False;
  FCommentsLabel.Parent := Inner;

  FLoading := TUILoading.Create(Self);
  FLoading.Size := ssSM;
  FLoading.Width := 28;
  FLoading.Height := 28;
  FLoading.Parent := Inner;

  UpdateTabs;
  ApplyTheme;
end;

destructor TDetailPanel.Destroy;
begin
  FBubbles.Free;
  inherited;
end;

procedure TDetailPanel.ApplyTheme;
var
  I: Integer;
begin
  Color := UIThemeVclBackground;
  for I := 0 to ControlCount - 1 do
    if Controls[I] is TPanel then
      TPanel(Controls[I]).Color := UIThemeVclBackground;
  FBadgeRow.Color := UIThemeVclBackground;
end;

procedure TDetailPanel.ComposeResize(Sender: TObject);
begin
  // Canto de baixo à direita, dentro da caixa de texto.
  FCommentBtn.SetBounds(FCompose.ClientWidth - CPad - CSendSize - CGap,
    FCompose.ClientHeight - CPad - CSendSize - CGap, CSendSize, CSendSize);
end;

{ ponytail: TUITabs não troca a legenda depois de criada; recria as duas abas. }
procedure TDetailPanel.UpdateTabs;
begin
  FTabs.OnChange := nil;
  FTabs.RemoveTab(2);
  FTabs.RemoveTab(1);
  FTabs.RemoveTab(0);
  FSeen[FTab] := True;
  FTabs.AddTab(Tr('Comentários'), IfThen(FSeen[0], 0, FCommentCount));
  FTabs.AddTab(Tr('Histórico'), IfThen(FSeen[1], 0, FEventCount));
  FTabs.AddTab(Tr('Detalhes'), 0);
  FTabs.ActiveIndex := FTab;
  FTabs.OnChange := TabChange;
end;

procedure TDetailPanel.TabChange(Sender: TObject; AIndex: Integer);
begin
  FTab := AIndex;
  if (FTab = 2) and not FDetailsLoaded then
    LoadDetails;
  // Abriu a aba: o contador dela some.
  ForceQueueUI( UpdateTabs);
  FScroll.ScrollTo(0, 0);
  Relayout;
end;

procedure TDetailPanel.AddBadge(const ACaption: string; ATone: TUIBadgeTone; const ATip: string);
var
  B: TUIBadge;
  Tip: TUITooltip;
begin
  B := TUIBadge.Create(Self);
  B.Caption := ACaption;
  B.Tone := ATone;
  B.Variant := TUIBadgeVariant.bvSoft;
  B.Parent := FBadgeRow;
  B.AutoSize;
  B.AlignWithMargins := True;
  B.Margins.SetBounds(0, 0, 6, 0);
  B.Left := (FBadgeRow.ControlCount + 1) * 1000;
  B.Align := alLeft;
  if ATip <> '' then
  begin
    // Tooltip da suíte; dono = selo, some junto quando o selo é trocado.
    Tip := TUITooltip.Create(B);
    Tip.AttachTo(B, ATip, tpBottom);
  end;
end;

procedure TDetailPanel.ClearBubbles;
var
  I: Integer;
begin
  for I := 0 to FBubbles.Count - 1 do
    TObject(FBubbles[I]).Free;
  FBubbles.Clear;
end;

procedure TDetailPanel.ShowItem(const AItem: TItem; const AAccount: TAccount);
var
  Events: TIssueEvents;
  E: TIssueEvent;
begin
  FItem := AItem;
  FAccount := AAccount;

  FCrumbs.Items.Clear;
  // Conta e chave; o projeto já está na chave e cortava o caminho.
  FCrumbs.Items.Add(AAccount.Name);
  FCrumbs.Items.Add(AItem.Key);
  FCrumbs.Invalidate;

  FTitle.Caption := AItem.Title;

  while FBadgeRow.ControlCount > 0 do
    FBadgeRow.Controls[0].Free;
  AddBadge(AItem.Status, StatusTone(AItem.StatusCategory), StatusTip(AItem.StatusCategory));
  if AItem.Flagged then
    AddBadge(Tr('Impedida'), btError, Tr('Marcada com Flagged no Jira: alguém sinalizou um impedimento.'));
  if AItem.DueDate > 0 then
    AddBadge(Tr('Entrega ') + FormatDateTime('dd/mm/yyyy', AItem.DueDate), DueTone(AItem.DueDate, AAccount),
      DueTip(AItem.DueDate, AAccount));
  // alRight reordena pelo Left na hora de mostrar: entre a IA e o abrir.
  FTimeBtn.Left := FAiBtn.Left + FAiBtn.Width - 1;
  FTimeBtn.Visible := AAccount.Kind in WorklogKinds;
  FCommentBox.Value := '';

  // Data de atualização já aparece na lista.
  FInfo.Caption := IfThen(AItem.Assignee <> '', Tr('Responsável: ') + AItem.Assignee, Tr('Sem responsável'));
  if AItem.Reviewers <> '' then
    FInfo.Caption := FInfo.Caption + '  ·  ' + AItem.Reviewers;
  FCi.Visible := AItem.CiState <> '';
  if SameText(AItem.CiState, 'FAILURE') or SameText(AItem.CiState, 'ERROR') then
  begin
    FCi.Caption := Tr('✕ CI falhou') + IfThen(AItem.CiDetail <> '', ': ' + AItem.CiDetail, '') +
      IfThen(AItem.CiUrl <> '', Tr('  (abrir)'), '');
    FCi.Color := UITheme.Tokens.Color.Error;
  end
  else if SameText(AItem.CiState, 'SUCCESS') then
  begin
    FCi.Caption := Tr('✓ CI passou');
    FCi.Color := UITheme.Tokens.Color.Success;
  end
  else
  begin
    FCi.Caption := Tr('CI rodando');
    FCi.Color := UITheme.Tokens.Color.FGMuted;
  end;
  FDetailsLoaded := False;
  FDetails.Caption := '';
  ShowTriage;

  FTimeline.ClearEvents;
  Events := IssueStore.ListEvents(AItem.AccountId, AItem.Key);
  for E in Events do
    FTimeline.AddEvent(FormatDateTime('dd/mm hh:nn', E.At), Tr(EventNames[E.Kind]), E.Body, '',
      EventTone(E.Kind));
  FEventCount := Length(Events);
  FCommentCount := 0;
  FTab := 0;
  FSeen[0] := False;
  FSeen[1] := False;
  FSeen[2] := False;
  UpdateTabs;

  ClearBubbles;
  FComments := nil;
  FScroll.ScrollTo(0, 0);
  LoadComments;
  Relayout;
end;

{ Resumo da conversa no topo dos comentários e rascunho da resposta na caixa.
  Nada é enviado: o usuário revisa e clica em enviar. }
procedure TDetailPanel.AiSummaryClick(Sender: TObject);
var
  Txt, Key: string;
  C: TComment;
begin
  if FComments = nil then
  begin
    TUIToastManager.Show(Tr('Sem comentários para resumir'), ttInfo);
    Exit;
  end;
  Txt := Tr('Issue ') + FItem.Key + ': ' + FItem.Title + sLineBreak;
  for C in FComments do
    Txt := Txt + Format('[%s] %s: %s', [FormatDateTime('dd/mm hh:nn', C.At), C.Author, C.Text]) + sLineBreak;
  Key := FItem.Key;
  FAiBtn.Loading := True;
  AiAsk(Tr('Você ajuda a acompanhar issues. Responda em português, sem markdown, exatamente neste formato:') +
    sLineBreak + Tr('RESUMO: até 3 frases sobre o estado da conversa e o que estão esperando do usuário.') +
    sLineBreak + Tr('RESPOSTA: um rascunho curto de resposta, em primeira pessoa, no tom da conversa.'),
    Txt, False,
    procedure(AText: string)
    var
      I: Integer;
    begin
      if csDestroying in ComponentState then
        Exit;
      FAiBtn.Loading := False;
      if not SameText(FItem.Key, Key) then
        Exit;
      I := Pos(Tr('RESPOSTA:'), AText);
      if I > 0 then
      begin
        FCommentBox.Value := Trim(Copy(AText, I + Length(Tr('RESPOSTA:')), MaxInt));
        AText := Copy(AText, 1, I - 1);
      end;
      FCommentsLabel.Caption := Trim(StringReplace(AText, Tr('RESUMO:'), Tr('Resumo (IA):'), []));
      FTab := 0;
      UpdateTabs;
      FScroll.ScrollTo(0, 0);
      Relayout;
    end,
    procedure(AErr: string)
    begin
      if csDestroying in ComponentState then
        Exit;
      FAiBtn.Loading := False;
      TUIToastManager.Show(Tr('IA: ') + AErr, ttError, 6000);
    end);
end;

procedure TDetailPanel.ShowTriage;
var
  J: TJSONValue;
  Tag: string;
begin
  FTriage.Visible := False;
  J := TJSONObject.ParseJSONValue(IssueStore.GetSetting(TriageSettingName(FItem.AccountId, FItem.Key)));
  try
    if not (J is TJSONObject) then
      Exit;
    Tag := J.GetValue<string>('tag', '').TrimLeft(['#']).Trim;
    FTriage.Caption := Tr('IA sugere: ') + IfThen(Tag <> '', '#' + Tag + ' · ', '') +
      J.GetValue<string>('prioridade', '') + ' · ' + J.GetValue<string>('motivo', '');
    FTriage.Hint := Tr('Aplicar: botão direito na issue › Ações › Aplicar sugestão da IA');
    FTriage.ShowHint := True;
    FTriage.Visible := True;
  finally
    J.Free;
  end;
end;

procedure TDetailPanel.CiClick(Sender: TObject);
begin
  if FItem.CiUrl <> '' then
    ShellExecute(0, 'open', PChar(FItem.CiUrl), nil, nil, SW_SHOWNORMAL);
end;

{ Aba Detalhes: busca na hora, uma vez por issue aberta. }
procedure TDetailPanel.LoadDetails;
var
  A: TAccount;
  Key: string;
begin
  FDetailsLoaded := True;
  A := FAccount;
  Key := FItem.Key;
  FDetails.Caption := Tr('Carregando...');
  RunTask(
    procedure
    var
      Info: TIssueInfo;
      Txt: string;
      At: TAttachment;
      L: TIssueLink;
    begin
      try
        Info := FetchIssueInfo(A, LoadSecret(A.SecretTarget), Key);
        Txt := IfThen(Info.Description.Trim <> '', Info.Description.Trim, Tr('Sem descrição.'));
        if Info.Attachments <> nil then
        begin
          Txt := Txt + sLineBreak + sLineBreak + Tr('Anexos');
          for At in Info.Attachments do
            Txt := Txt + sLineBreak + Format(Tr('• %s (%d KB)'), [At.Name, (At.Size + 1023) div 1024]);
        end;
        if Info.Links <> nil then
        begin
          Txt := Txt + sLineBreak + sLineBreak + Tr('Ligações');
          for L in Info.Links do
            Txt := Txt + sLineBreak + Format('• %s %s: %s', [L.Kind, L.Key, L.Summary]);
        end;
      except
        on E: Exception do
          Txt := Tr('Não deu para buscar os detalhes: ') + E.Message;
      end;
      QueueUI(
        procedure
        begin
          if (csDestroying in ComponentState) or not SameText(FItem.Key, Key) then
            Exit;
          FDetails.Caption := Txt;
          Relayout;
        end);
    end);
end;

procedure TDetailPanel.LoadComments;
var
  A: TAccount;
  Key, Token: string;
  Seq: Integer;
begin
  A := FAccount;
  Key := FItem.Key;
  Token := LoadSecret(A.SecretTarget);
  FLoading.Visible := True;
  FCommentsLabel.Caption := '';
  Inc(FLoadSeq);
  Seq := FLoadSeq;
  RunTask(
    procedure
    var
      Comments: TComments;
      Me: TIdentity;
      Err: string;
    begin
      try
        Me := WhoAmI(A, Token);
        Comments := FetchComments(A, Token, Key, 15);
      except
        on Ex: Exception do
          Err := Ex.Message;
      end;
      QueueUI(
        procedure
        var
          C: TComment;
          B: TUIChatBubble;
        begin
          // Outra busca começou depois (troca de issue ou painel aberto de novo).
          if (csDestroying in ComponentState) or (Seq <> FLoadSeq) then
            Exit;
          FLoading.Visible := False;
          if Err <> '' then
            FCommentsLabel.Caption := Tr('Não deu para buscar os comentários: ') + Err
          else if Comments = nil then
            FCommentsLabel.Caption := Tr('Ninguém comentou ainda.')
          else
            FCommentsLabel.Caption := '';
          // Lista de leitura, não chat: todos à esquerda, cor neutra.
          for C in Comments do
          begin
            B := TUIChatBubble.Create(Self);
            B.Time := FormatDateTime('dd/mm hh:nn', TTimeZone.Local.ToLocalTime(C.At));
            B.Message := C.Text.Trim;
            B.AvatarInitials := Initials(C.Author);
            if SameText(C.AuthorId, Me.Id) then
            begin
              B.AuthorName := Tr('Você');
              B.AvatarColor := UITheme.Tokens.Color.Primary;
            end
            else
              B.AuthorName := C.Author;
            B.Parent := FScroll.InnerPanel;
            FBubbles.Add(B);
          end;
          FComments := Comments;
          FCommentCount := Length(Comments);
          UpdateTabs;
          Relayout;
        end);
    end);
end;

{ Tudo dentro da área de rolagem, com posição absoluta (o ScrollArea pede
  ContentHeight). Só a aba ativa aparece. }
procedure TDetailPanel.Relayout;
var
  Y, W, I, H: Integer;
  B: TUIChatBubble;
  Comments: Boolean;
  TitleFont: ISkFont;
begin
  if (FScroll = nil) or (FBubbles = nil) then
    Exit;
  W := FScroll.InnerPanel.ClientWidth - 2 * CPad;
  if W <= 0 then
    Exit;
  Y := 4;
  TitleFont := TUIFontManager.GetFont(UITheme.Tokens.Typography.FamilyPrimary, 13,
    UITheme.Tokens.Typography.WeightBold);
  H := Ceil(UIMeasureTextMultiLine(FTitle.Caption, W, TitleFont)) + 6;
  FTitle.SetBounds(CPad, Y, W, H);
  Inc(Y, H + CGap);
  FBadgeRow.SetBounds(CPad, Y, W, 24);
  Inc(Y, 24 + CGap);
  FInfo.SetBounds(CPad, Y, W, 20);
  Inc(Y, 20 + CGap);
  if FCi.Visible then
  begin
    FCi.SetBounds(CPad, Y, W, 20);
    Inc(Y, 20 + CGap);
  end;
  if FTriage.Visible then
  begin
    FTriage.SetBounds(CPad, Y, W, 18);
    Inc(Y, 18 + CGap);
  end;
  FTabs.SetBounds(CPad, Y, W, FTabs.Height);
  Inc(Y, FTabs.Height + CGap * 2);

  Comments := FTab = 0;
  FDetails.Visible := FTab = 2;
  if FDetails.Visible then
  begin
    H := Ceil(UIMeasureTextMultiLine(FDetails.Caption, W, TUIFontManager.GetFont(
      UITheme.Tokens.Typography.FamilyPrimary, FDetails.FontSize, UITheme.Tokens.Typography.WeightRegular))) + 24;
    FDetails.SetBounds(CPad, Y, W, H);
    Inc(Y, H + CGap);
  end;
  FTimeline.Visible := (FTab = 1) and (FEventCount > 0);
  FCommentsLabel.Visible := (Comments and (FCommentsLabel.Caption <> '')) or
    ((FTab = 1) and (FEventCount = 0));
  if (FTab = 1) and (FEventCount = 0) then
    FCommentsLabel.Caption := Tr('Nenhum aviso desta issue ainda.');
  FLoading.Visible := FLoading.Visible and Comments;
  for I := 0 to FBubbles.Count - 1 do
    TUIChatBubble(FBubbles[I]).Visible := Comments;

  if FTimeline.Visible then
  begin
    FTimeline.SetBounds(CPad, Y, W, FTimeline.Height);
    Inc(Y, FTimeline.Height + CGap);
  end;
  if FCommentsLabel.Visible then
  begin
    H := Max(40, Ceil(UIMeasureTextMultiLine(FCommentsLabel.Caption, W, TUIFontManager.GetFont(
      UITheme.Tokens.Typography.FamilyPrimary, FCommentsLabel.FontSize,
      UITheme.Tokens.Typography.WeightRegular))) + 12);
    FCommentsLabel.SetBounds(CPad, Y, W, H);
    Inc(Y, H + CGap);
  end;
  if FLoading.Visible then
  begin
    FLoading.SetBounds(CPad, Y, 28, 28);
    Inc(Y, 28 + CGap);
  end;
  if Comments then
    for I := 0 to FBubbles.Count - 1 do
    begin
      B := TUIChatBubble(FBubbles[I]);
      B.MaxBubbleWidth := W;
      B.SetBounds(CPad - 6, Y, W + 6, B.Height);
      B.AutoSizeHeight;
      Inc(Y, B.Height + CGap);
    end;
  FScroll.ContentHeight := Y + CPad;
end;

procedure TDetailPanel.Resize;
begin
  inherited;
  Relayout;
end;

procedure TDetailPanel.CommentClick(Sender: TObject);
var
  A: TAccount;
  Key, Text, Token: string;
begin
  Text := FCommentBox.Value.Trim;
  if Text = '' then
  begin
    TUIToastManager.Show(Tr('Escreva o comentário antes'), ttWarning);
    Exit;
  end;
  A := FAccount;
  Key := FItem.Key;
  Token := LoadSecret(A.SecretTarget);
  FCommentBtn.Loading := True;
  RunTask(
    procedure
    var
      Err: string;
    begin
      try
        PostComment(A, Token, Key, Text);
      except
        on E: Exception do
          Err := E.Message;
      end;
      QueueUI(
        procedure
        begin
          if csDestroying in ComponentState then
            Exit;
          FCommentBtn.Loading := False;
          if Err <> '' then
          begin
            TUIToastManager.Show(Tr('Não comentou: ') + Err, ttError, 6000);
            Exit;
          end;
          TUIToastManager.Show(Tr('Comentário publicado em ') + Key, ttSuccess);
          if SameText(FItem.Key, Key) then
          begin
            FCommentBox.Value := '';
            ClearBubbles;
            LoadComments;
          end;
          if Assigned(FOnChanged) then
            FOnChanged(Self);
        end);
    end);
end;

procedure TDetailPanel.TimeClick(Sender: TObject);
begin
  if LogTime(Self, FAccount, FItem) and Assigned(FOnChanged) then
    FOnChanged(Self);
end;

procedure TDetailPanel.CloseClick(Sender: TObject);
begin
  if Assigned(FOnClose) then
    FOnClose(Self);
end;

procedure TDetailPanel.OpenClick(Sender: TObject);
begin
  if FItem.Url <> '' then
    ShellExecute(0, 'open', PChar(FItem.Url), nil, nil, SW_SHOWNORMAL);
end;

end.
