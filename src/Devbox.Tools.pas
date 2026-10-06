unit Devbox.Tools;

{ Ferramentas: comparar arquivos .env e ler o fim de um log que cresce.

  Histórico dos terminais ficou de fora de propósito: ler o histórico do
  PowerShell (PSReadLine) e o .bash_history é o que ladrão de senha faz, e o
  antivírus apagava o Devbox.exe logo depois. }

interface

uses
  System.SysUtils,
  System.Classes,
  System.Generics.Collections;

type
  TEnvEntry = record
    Key: string;
    Value: string;
  end;
  TEnvEntries = TArray<TEnvEntry>;

  TEnvState = (esMissing, esEmpty, esSet);

  TEnvRow = record
    Key: string;
    States: TArray<TEnvState>;     // um por arquivo, na ordem dos arquivos
    function MissingSomewhere: Boolean;
  end;
  TEnvRows = TArray<TEnvRow>;

{ Linhas CHAVE=valor; comentário (#), linha vazia e "export " ficam de fora.
  Aspas em volta do valor saem. }
function ParseEnvText(const AText: string): TEnvEntries;

{ Uma linha por chave que aparece em algum arquivo, em ordem alfabética. }
function CompareEnvs(const AFiles: TArray<TEnvEntries>): TEnvRows;

{ Arquivos .env* de uma pasta (.env, .env.example, .env.local...). }
function FindEnvFiles(const AFolder: string): TArray<string>;

{ Lê o que entrou em AFile desde APosition e atualiza a posição. Arquivo que
  encolheu (rotacionou ou foi truncado) volta do começo. }
function ReadNewText(const AFile: string; var APosition: Int64; out ATruncated: Boolean): string;

implementation

uses
  System.IOUtils,
  System.StrUtils,
  System.Math,
  System.Generics.Defaults,
  Devbox.Model,
  Devbox.Sys;

function TEnvRow.MissingSomewhere: Boolean;
var
  S: TEnvState;
begin
  for S in States do
    if S = esMissing then
      Exit(True);
  Result := False;
end;

function ParseEnvText(const AText: string): TEnvEntries;
var
  L: TStringList;
  Line: string;
  P: Integer;
  E: TEnvEntry;
begin
  Result := nil;
  L := TStringList.Create;
  try
    L.Text := AText;
    for Line in L do
    begin
      E.Key := Trim(Line);
      if (E.Key = '') or E.Key.StartsWith('#') then
        Continue;
      if StartsText('export ', E.Key) then
        E.Key := Trim(Copy(E.Key, 8, MaxInt));
      P := Pos('=', E.Key);
      if P < 2 then
        Continue;
      E.Value := Trim(Copy(E.Key, P + 1, MaxInt));
      E.Key := Trim(Copy(E.Key, 1, P - 1));
      if (Length(E.Value) >= 2) and CharInSet(E.Value[1], ['"', '''']) and (E.Value[Length(E.Value)] = E.Value[1]) then
        E.Value := Copy(E.Value, 2, Length(E.Value) - 2);
      Result := Result + [E];
    end;
  finally
    L.Free;
  end;
end;

function CompareEnvs(const AFiles: TArray<TEnvEntries>): TEnvRows;
var
  Keys: TList<string>;
  Seen: TDictionary<string, Boolean>;
  I, F: Integer;
  E: TEnvEntry;
  Row: TEnvRow;
begin
  Keys := TList<string>.Create;
  Seen := TDictionary<string, Boolean>.Create;
  try
    for F := 0 to High(AFiles) do
      for E in AFiles[F] do
        if not Seen.ContainsKey(E.Key) then
        begin
          Seen.Add(E.Key, True);
          Keys.Add(E.Key);
        end;
    Keys.Sort(TIStringComparer.Ordinal);
    SetLength(Result, Keys.Count);
    for I := 0 to Keys.Count - 1 do
    begin
      Row.Key := Keys[I];
      SetLength(Row.States, Length(AFiles));
      for F := 0 to High(AFiles) do
      begin
        Row.States[F] := esMissing;
        for E in AFiles[F] do
          if E.Key = Row.Key then
            if E.Value = '' then
              Row.States[F] := esEmpty
            else
              Row.States[F] := esSet;
      end;
      Result[I] := Row;
      Row.States := nil;
    end;
  finally
    Seen.Free;
    Keys.Free;
  end;
end;

function FindEnvFiles(const AFolder: string): TArray<string>;
var
  F, Name: string;
begin
  Result := nil;
  if not TDirectory.Exists(AFolder) then
    Exit;
  for F in TDirectory.GetFiles(AFolder) do
  begin
    Name := ExtractFileName(F);
    if SameText(Name, '.env') or StartsText('.env.', Name) or EndsText('.env', Name) then
      Result := Result + [F];
  end;
  TArray.Sort<string>(Result, TIStringComparer.Ordinal);
end;

function ReadNewText(const AFile: string; var APosition: Int64; out ATruncated: Boolean): string;
const
  CMaxRead = 1024 * 1024;   // primeira leitura de arquivo grande: só o fim
var
  S: TFileStream;
  Size: Int64;
  Bytes: TBytes;
begin
  Result := '';
  ATruncated := False;
  // fmShareDenyNone: o programa que escreve o log continua escrevendo.
  S := TFileStream.Create(AFile, fmOpenRead or fmShareDenyNone);
  try
    Size := S.Size;
    if Size < APosition then
    begin
      ATruncated := True;
      APosition := 0;
    end;
    if Size - APosition > CMaxRead then
      APosition := Size - CMaxRead;
    if Size = APosition then
      Exit;
    S.Position := APosition;
    SetLength(Bytes, Size - APosition);
    S.ReadBuffer(Bytes[0], Length(Bytes));
    APosition := Size;
  finally
    S.Free;
  end;
  try
    Result := TEncoding.UTF8.GetString(Bytes);
  except
    on EEncodingError do
      Result := TEncoding.ANSI.GetString(Bytes);
  end;
end;

end.
