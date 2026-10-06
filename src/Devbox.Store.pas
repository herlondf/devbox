unit Devbox.Store;

{ SQLite em %LOCALAPPDATA%\Devbox\devbox.db: clips (histórico e snippets) e
  preferências. Só usar na thread de UI. }

interface

uses
  FireDAC.Comp.Client,
  Devbox.Model;

type
  TStore = class
  private
    FConn: TFDConnection;
  public
    constructor Create(const ADbPath: string);
    destructor Destroy; override;
    { Texto repetido sobe para o topo em vez de duplicar. Corta o histórico
      (não os snippets) em HistoryLimit. }
    procedure AddClip(const AText: string);
    { Snippets primeiro, depois o histórico, mais novos no topo. }
    function ListClips: TClips;
    procedure SetPinned(AId: Integer; APinned: Boolean);
    procedure DeleteClip(AId: Integer);
    { Apaga o histórico; snippets ficam. }
    procedure ClearHistory;
    function GetSetting(const AName: string; const ADefault: string = ''): string;
    procedure SetSetting(const AName, AValue: string);
  end;

function Store: TStore;
function DataDir: string;

implementation

uses
  System.SysUtils,
  System.IOUtils,
  System.Variants,
  FireDAC.Stan.Def,
  FireDAC.Stan.Async,
  FireDAC.Stan.Intf,
  FireDAC.DApt,
  FireDAC.Phys.SQLite,
  FireDAC.Phys.SQLiteDef,
  FireDAC.Stan.ExprFuncs,
  FireDAC.VCLUI.Wait;

var
  GStore: TStore;

function DataDir: string;
begin
  Result := TPath.Combine(GetEnvironmentVariable('LOCALAPPDATA'), 'Devbox');
  ForceDirectories(Result);
end;

function Store: TStore;
begin
  if GStore = nil then
    GStore := TStore.Create(TPath.Combine(DataDir, 'devbox.db'));
  Result := GStore;
end;

constructor TStore.Create(const ADbPath: string);
begin
  inherited Create;
  FConn := TFDConnection.Create(nil);
  FConn.DriverName := 'SQLite';
  FConn.Params.Values['Database'] := ADbPath;
  FConn.Params.Values['LockingMode'] := 'Normal';
  FConn.ResourceOptions.SilentMode := True;
  FConn.LoginPrompt := False;
  FConn.Connected := True;
  FConn.ExecSQL('CREATE TABLE IF NOT EXISTS clip (id INTEGER PRIMARY KEY AUTOINCREMENT, ' +
    'text TEXT NOT NULL UNIQUE, pinned INTEGER NOT NULL DEFAULT 0, created_at REAL NOT NULL)');
  FConn.ExecSQL('CREATE TABLE IF NOT EXISTS setting (name TEXT PRIMARY KEY, value TEXT)');
end;

destructor TStore.Destroy;
begin
  FConn.Free;
  inherited;
end;

procedure TStore.AddClip(const AText: string);
begin
  // O SQLite do FireDAC não tem upsert (ON CONFLICT): atualiza e, se não achou, insere.
  if FConn.ExecSQL('UPDATE clip SET created_at = :d WHERE text = :t', [Now, AText]) = 0 then
    FConn.ExecSQL('INSERT INTO clip (text, created_at) VALUES (:t, :d)', [AText, Now]);
  FConn.ExecSQL('DELETE FROM clip WHERE pinned = 0 AND id NOT IN ' +
    '(SELECT id FROM clip WHERE pinned = 0 ORDER BY created_at DESC LIMIT :n)', [HistoryLimit]);
end;

function TStore.ListClips: TClips;
var
  Q: TFDQuery;
  C: TClip;
begin
  Result := nil;
  Q := TFDQuery.Create(nil);
  try
    Q.Connection := FConn;
    Q.Open('SELECT id, text, pinned, created_at FROM clip ORDER BY pinned DESC, created_at DESC');
    while not Q.Eof do
    begin
      C.Id := Q.Fields[0].AsInteger;
      C.Text := Q.Fields[1].AsString;
      C.Pinned := Q.Fields[2].AsInteger <> 0;
      C.CreatedAt := Q.Fields[3].AsFloat;
      Result := Result + [C];
      Q.Next;
    end;
  finally
    Q.Free;
  end;
end;

procedure TStore.SetPinned(AId: Integer; APinned: Boolean);
begin
  FConn.ExecSQL('UPDATE clip SET pinned = :p WHERE id = :i', [Ord(APinned), AId]);
end;

procedure TStore.DeleteClip(AId: Integer);
begin
  FConn.ExecSQL('DELETE FROM clip WHERE id = :i', [AId]);
end;

procedure TStore.ClearHistory;
begin
  FConn.ExecSQL('DELETE FROM clip WHERE pinned = 0');
end;

function TStore.GetSetting(const AName, ADefault: string): string;
var
  V: Variant;
begin
  V := FConn.ExecSQLScalar('SELECT value FROM setting WHERE name = :n', [AName]);
  if VarIsNull(V) or VarIsEmpty(V) then
    Result := ADefault
  else
    Result := V;
end;

procedure TStore.SetSetting(const AName, AValue: string);
begin
  FConn.ExecSQL('INSERT OR REPLACE INTO setting (name, value) VALUES (:n, :v)', [AName, AValue]);
end;

initialization

finalization
  GStore.Free;

end.
