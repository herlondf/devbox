unit Devbox.UI.HostPage;

{ Tela de abas que hospeda painéis criados por outra tela (os eventos ficam lá).
  Usada em Configuração › Issues: contas e preferências vêm da tela Issues. }

interface

uses
  System.Classes,
  Vcl.Controls,
  Vcl.ExtCtrls,
  UI.Tabs,
  Devbox.UI.Kit;

type
  THostPage = class(TDevPage)
  private
    FTabs: TUITabs;
    FViews: TArray<TControl>;
    procedure TabChange(Sender: TObject; AIndex: Integer);
  public
    constructor Create(AOwner: TComponent); override;
    { AView vira a aba ACaption (ocupa a área toda). }
    procedure AddView(const ACaption: string; AView: TControl);
    procedure ShowTab(AIndex: Integer);
  end;

implementation

constructor THostPage.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FTabs := TUITabs.Create(Self);
  FTabs.Align := alTop;
  FTabs.Parent := Self;
  FTabs.OnChange := TabChange;
end;

procedure THostPage.AddView(const ACaption: string; AView: TControl);
begin
  FTabs.AddTab(ACaption);
  AView.Parent := Self;
  AView.Align := alClient;
  AView.Visible := Length(FViews) = 0;
  FViews := FViews + [AView];
  if Length(FViews) = 1 then
    FTabs.ActiveIndex := 0;
end;

procedure THostPage.TabChange(Sender: TObject; AIndex: Integer);
var
  LIndex: Integer;
begin
  for LIndex := 0 to High(FViews) do
    FViews[LIndex].Visible := LIndex = AIndex;
end;

procedure THostPage.ShowTab(AIndex: Integer);
begin
  FTabs.ActiveIndex := AIndex;
  TabChange(nil, AIndex);
end;

end.
