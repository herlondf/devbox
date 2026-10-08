unit Devbox.I18n;

{ Tradução da interface. O texto em português é a chave; Tr devolve a versão
  do idioma ativo (hoje: inglês). Sem tradução para a frase, fica o português.
  O dicionário é gerado de tools/i18n_en.tsv (tools/i18n.py). }

interface

{ Texto na língua da interface. }
function Tr(const S: string): string;

{ 'pt', 'en' ou '' (segue o idioma do Windows). Vale para o que for criado depois. }
procedure SetLanguage(const ACode: string);
function IsEnglish: Boolean;

implementation

uses
  Winapi.Windows,
  System.SysUtils,
  System.Generics.Collections,
  Devbox.I18n.En;

var
  FEn: TDictionary<string, string>;
  FEnglish: Boolean;

function Tr(const S: string): string;
begin
  if not FEnglish or not FEn.TryGetValue(S, Result) then
    Result := S;
end;

procedure SetLanguage(const ACode: string);
const
  LANG_PORTUGUESE = $16;
begin
  if ACode = '' then
    FEnglish := (GetUserDefaultUILanguage and $3FF) <> LANG_PORTUGUESE
  else
    FEnglish := SameText(ACode, 'en');
end;

function IsEnglish: Boolean;
begin
  Result := FEnglish;
end;

procedure LoadEnglish;
var
  I: Integer;
begin
  FEn := TDictionary<string, string>.Create(Length(EnPairs));
  for I := Low(EnPairs) to High(EnPairs) do
    FEn.AddOrSetValue(EnPairs[I, 0], EnPairs[I, 1]);
end;

initialization
  LoadEnglish;

finalization
  FEn.Free;

end.
