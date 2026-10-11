unit Devbox.UI.Git;

{ Ferramentas › Git: os repositórios locais com branch, mudanças sem commit e quanto
  está à frente ou atrás do remoto. Por linha: abrir a pasta, abrir o terminal e pedir
  ao assistente a mensagem de commit e a descrição do PR (ele lê o diff). PRs esperando
  revisão ficam nas Issues (review pedido). }

interface

uses
  System.Classes,
  System.SysUtils,
  Vcl.Controls,
  Vcl.ExtCtrls,
  UI.Labels,
  UI.Input,
  UI.DataTable,
  UI.ProgressBar,
  Devbox.Git,
  Devbox.UI.Kit;

type
  TGitPage = class(TDevPage)
  private
    FRoots: TUIInput;
    FTable: TUIDataTable;
    FProgress: TUIProgressBar;
    FStatus: TUILabel;
    FRepos: TGitRepos;
    FBusy: Boolean;
    FLoaded: Boolean;
    procedure ScanClick(Sender: TObject);
    procedure ActionClick(Sender: TObject; ARowIdx, AActionIdx: Integer);
    procedure Fill;
    procedure OpenFolder(AIndex: Integer);
    procedure OpenTerminal(AIndex: Integer);
    procedure AskCommit(AIndex: Integer);
  public
    constructor Create(AOwner: TComponent); override;
    procedure PageShown; override;
    procedure PageRefresh; override;
    function PageKey(var AKey: Word; AShift: TShiftState): Boolean; override;
    function PageShortcuts: TArray<TDevShortcut>; override;
    function PageContext: string; override;
    { Para o assistente: os repositórios da última leitura (lê se ainda não leu). }
    function ReposText: string;
    function RepoByName(const AName: string; out ARepo: TGitRepo): Boolean;
    property Busy: Boolean read FBusy;
  end;

implementation

uses
  System.Math,
  System.StrUtils,
  UI.Button,
  UI.Toast,
  UI.Tokens,
  UI.Theme,
  Devbox.Model,
  Devbox.Sys,
  Devbox.Store;

const
  ActionFolder = 'M3 6.75h6l2 2.25h10v9.75H3z';
  ActionCommit = 'M12 8.25a3.75 3.75 0 1 0 0 7.5 3.75 3.75 0 0 0 0-7.5z M3 12h5.25 M15.75 12H21';

constructor TGitPage.Create(AOwner: TComponent);
var
  LBar: TPanel;
  C: TUIColorTokens;
begin
  inherited Create(AOwner);
  FRefreshable := True;
  Caption := 'Git';
  Hint := 'Seus repositórios: branch, o que falta commitar e o que falta enviar ou puxar';
  C := UITheme.Tokens.Color;

  LBar := NewPanel(Self, alTop, 52);
  LBar.Padding.SetBounds(0, 0, 0, ScaleValue(8));
  NewButton(LBar, 'Procurar', ScanClick, bvPrimary, alRight);
  FRoots := TUIInput.Create(Self);
  FRoots.LabelMode := ilmBorder;
  FRoots.LabelText := 'Onde procurar (pastas separadas por ;)';
  FRoots.ReserveHintSpace := False;
  FRoots.Value := Store.GetSetting('git_roots', Store.GetSetting('junk_roots', GetEnvironmentVariable('USERPROFILE')));
  FRoots.AlignWithMargins := True;
  FRoots.Margins.SetBounds(0, 0, ScaleValue(8), 0);
  FRoots.Align := alClient;
  FRoots.Parent := LBar;

  FProgress := TUIProgressBar.Create(Self);
  FProgress.Indeterminate := True;
  FProgress.TrackHeight := 3;
  FProgress.Height := 3;
  FProgress.Visible := False;
  FProgress.Top := 100000;
  FProgress.Align := alTop;
  FProgress.Parent := Self;
  FStatus := NewHint(Self, '', alBottom);

  FTable := TUIDataTable.Create(Self);
  FTable.Density := tdCompact;
  FTable.SelectionMode := tsmSingle;
  FTable.AddColumn('name', 'Repositório', 'name', 200);
  FTable.AddColumn('branch', 'Branch', 'branch', 180);
  FTable.AddColumn('changed', 'Sem commit', 'changed', 110);
  FTable.AddColumn('sync', 'Remoto', 'sync', 150);
  FTable.AddColumn('acoes', '', 'acoes', 110);
  FTable.AddColumn('path', 'Pasta', 'path', 260);
  FTable.SetColType('changed', ctBadge);
  FTable.AddBadgeMap('changed', 'limpo', C.SuccessSubtle, C.Success);
  FTable.SetColType('sync', ctBadge);
  FTable.AddBadgeMap('sync', 'em dia', C.SuccessSubtle, C.Success);
  FTable.AddBadgeMap('sync', 'sem remoto', C.BGMuted, C.FGMuted);
  FTable.SetColType('acoes', ctAction);
  FTable.AddActionToCol('acoes', LineIcon(ActionFolder), 'Abrir a pasta');
  FTable.AddActionToCol('acoes', LineIcon(IconTerminal), 'Abrir terminal aqui');
  FTable.AddActionToCol('acoes', LineIcon(ActionCommit), 'Commit e PR com o assistente');
  FTable.OnActionClick := ActionClick;
  FTable.EmptyState.Title := 'Nenhum repositório';
  FTable.EmptyState.Description := 'Escolha as pastas acima e clique em Procurar.';
  FTable.Top := 100000;
  FTable.Align := alClient;
  FTable.Parent := Self;
end;

procedure TGitPage.PageShown;
begin
  inherited;
  if not FLoaded then
    ScanClick(nil);
end;

procedure TGitPage.PageRefresh;
begin
  ScanClick(nil);
end;

procedure TGitPage.ScanClick(Sender: TObject);
var
  LRoots: string;
begin
  if FBusy then
    Exit;
  FBusy := True;
  FLoaded := True;
  LRoots := FRoots.Value;
  Store.SetSetting('git_roots', LRoots);
  FProgress.Visible := True;
  FStatus.Caption := 'Procurando repositórios...';
  RunTask(
    procedure
    var
      LRepos: TGitRepos;
      LPath: string;
    begin
      LRepos := nil;
      for LPath in FindGitRepos(LRoots) do
        LRepos := LRepos + [ReadGitRepo(LPath)];
      QueueUI(
        procedure
        begin
          FBusy := False;
          FProgress.Visible := False;
          FRepos := LRepos;
          Fill;
        end);
    end);
end;

procedure TGitPage.Fill;
var
  LRepo: TGitRepo;
  LSync: string;
  LDirty: Integer;
begin
  LDirty := 0;
  FTable.BeginRowUpdate;
  try
    FTable.ClearMemRows;
    for LRepo in FRepos do
    begin
      if LRepo.Error <> '' then
        LSync := 'erro'
      else if LRepo.Upstream = '' then
        LSync := 'sem remoto'
      else if (LRepo.Ahead = 0) and (LRepo.Behind = 0) then
        LSync := 'em dia'
      else
        LSync := Trim(IfThen(LRepo.Ahead > 0, Format('↑ %d enviar  ', [LRepo.Ahead])) +
          IfThen(LRepo.Behind > 0, Format('↓ %d puxar', [LRepo.Behind])));
      if LRepo.Changed > 0 then
        Inc(LDirty);
      FTable.AddMemRow([LRepo.Name, LRepo.Branch, IfThen(LRepo.Changed = 0, 'limpo',
        Format('%d arquivo%s', [LRepo.Changed, IfThen(LRepo.Changed > 1, 's')])), LSync, '', LRepo.Path]);
    end;
  finally
    FTable.EndRowUpdate;
  end;
  FStatus.Caption := Format('%d repositórios  ·  %d com mudanças sem commit', [Length(FRepos), LDirty]);
end;

procedure TGitPage.ActionClick(Sender: TObject; ARowIdx, AActionIdx: Integer);
begin
  if (ARowIdx < 0) or (ARowIdx > High(FRepos)) then
    Exit;
  case AActionIdx of
    0: OpenFolder(ARowIdx);
    1: OpenTerminal(ARowIdx);
    2: AskCommit(ARowIdx);
  end;
end;

procedure TGitPage.OpenFolder(AIndex: Integer);
begin
  Launch('explorer.exe', '"' + FRepos[AIndex].Path + '"');
end;

procedure TGitPage.OpenTerminal(AIndex: Integer);
begin
  Launch('cmd.exe', Format('/k cd /d "%s" && git status -sb', [FRepos[AIndex].Path]));
end;

{ O diff vai para o assistente (sem segredos) e ele escreve a mensagem e o PR. }
procedure TGitPage.AskCommit(AIndex: Integer);
var
  LRepo: TGitRepo;
begin
  LRepo := FRepos[AIndex];
  if LRepo.Changed = 0 then
  begin
    TUIToastManager.Show(LRepo.Name + ' não tem nada para commitar', ttInfo, 3000);
    Exit;
  end;
  if not Assigned(AskAssistant) then
    Exit;
  FStatus.Caption := 'Lendo o diff de ' + LRepo.Name + '...';
  RunTask(
    procedure
    var
      LDiff: string;
    begin
      LDiff := HideSecrets(GitDiffText(LRepo.Path));
      QueueUI(
        procedure
        begin
          FStatus.Caption := '';
          AskAssistant(Format('Escreva a mensagem de commit (Conventional Commits, em português, assunto até ' +
            '72 caracteres e corpo curto) e uma descrição de PR (o que muda e como testar) para este diff do ' +
            'repositório %s, branch %s. Ofereça copiar com devbox_copiar.', [LRepo.Name, LRepo.Branch]) +
            sLineBreak + sLineBreak + '```diff' + sLineBreak + LDiff + sLineBreak + '```');
        end);
    end);
end;

function TGitPage.PageKey(var AKey: Word; AShift: TShiftState): Boolean;
begin
  Result := TableKey(FTable, AKey, nil, nil, nil);
end;

function TGitPage.PageShortcuts: TArray<TDevShortcut>;
begin
  Result := TableShortcuts(FTable, nil, nil, nil);
end;

function TGitPage.ReposText: string;
var
  LRepo: TGitRepo;
begin
  Result := '';
  for LRepo in FRepos do
    Result := Result + Format('- %s (%s): branch %s, %d sem commit, %d para enviar, %d para puxar%s',
      [LRepo.Name, LRepo.Path, LRepo.Branch, LRepo.Changed, LRepo.Ahead, LRepo.Behind,
      IfThen(LRepo.Upstream = '', ', sem remoto')]) + sLineBreak;
  if Result = '' then
    Result := 'Nenhum repositório lido. Abra a tela Git ou procure em outras pastas.';
end;

function TGitPage.RepoByName(const AName: string; out ARepo: TGitRepo): Boolean;
var
  LRepo: TGitRepo;
begin
  for LRepo in FRepos do
    if SameText(LRepo.Name, AName) or SameText(LRepo.Path, AName) then
    begin
      ARepo := LRepo;
      Exit(True);
    end;
  Result := False;
end;

function TGitPage.PageContext: string;
begin
  Result := 'Repositórios Git:' + sLineBreak + ReposText;
end;

end.
