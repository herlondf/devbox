unit Devbox.Convert;

{ Conversores de texto do clipboard. Sem I/O: testados no self-check. }

interface

type
  TConvertKind = (cvJsonPretty, cvJsonMin, cvBase64Enc, cvBase64Dec, cvUrlEnc, cvUrlDec,
    cvJwt, cvTimestamp, cvSha256, cvMd5, cvUpper, cvLower, cvSortLines, cvUniqueLines, cvGuid);

const
  ConvertNames: array[TConvertKind] of string = ('JSON formatado', 'JSON numa linha',
    'Base64: codificar', 'Base64: decodificar', 'URL: codificar', 'URL: decodificar',
    'JWT: ler token', 'Timestamp ↔ data', 'SHA-256', 'MD5', 'MAIÚSCULAS', 'minúsculas',
    'Ordenar linhas', 'Tirar linhas repetidas', 'Novo GUID');

{ False com AError quando a entrada não serve (JSON inválido, Base64 quebrado...). }
function ConvertText(AKind: TConvertKind; const AText: string; out AResult, AError: string): Boolean;

implementation

uses
  System.SysUtils,
  System.Classes,
  System.JSON,
  System.Hash,
  System.NetEncoding,
  System.DateUtils,
  System.StrUtils,
  System.Generics.Collections;

function Base64NoBreak: TBase64Encoding;
begin
  // O TNetEncoding.Base64 padrão quebra a linha a cada 76 caracteres.
  Result := TBase64Encoding.Create(0);
end;

function JsonFormat(const AText: string; APretty: Boolean; out AResult, AError: string): Boolean;
var
  V: TJSONValue;
begin
  V := TJSONObject.ParseJSONValue(Trim(AText));
  Result := V <> nil;
  if not Result then
  begin
    AError := 'Não é um JSON válido';
    Exit;
  end;
  try
    if APretty then
      AResult := V.Format(2)
    else
      AResult := V.ToJSON;
    // O Delphi escapa "/" como "\/": válido, mas ninguém escreve assim.
    AResult := AResult.Replace('\/', '/');
  finally
    V.Free;
  end;
end;

function Base64UrlDecode(const AText: string): TBytes;
var
  S: string;
  E: TBase64Encoding;
begin
  S := StringReplace(StringReplace(AText, '-', '+', [rfReplaceAll]), '_', '/', [rfReplaceAll]);
  while Length(S) mod 4 <> 0 do
    S := S + '=';
  E := Base64NoBreak;
  try
    Result := E.DecodeStringToBytes(S);
  finally
    E.Free;
  end;
end;

function Jwt(const AText: string; out AResult, AError: string): Boolean;
var
  Parts: TArray<string>;
  Header, Payload, HeaderJson, PayloadJson: string;
  V: TJSONValue;
  Exp: Int64;
begin
  Parts := Trim(AText).Split(['.']);
  Result := Length(Parts) = 3;
  if not Result then
  begin
    AError := 'Token JWT tem três partes separadas por ponto';
    Exit;
  end;
  try
    Header := TEncoding.UTF8.GetString(Base64UrlDecode(Parts[0]));
    Payload := TEncoding.UTF8.GetString(Base64UrlDecode(Parts[1]));
  except
    on E: Exception do
    begin
      AError := 'Não deu para decodificar o token: ' + E.Message;
      Exit(False);
    end;
  end;
  // Saída separada da entrada: o out zera a string antes de a função ler.
  Result := JsonFormat(Header, True, HeaderJson, AError) and JsonFormat(Payload, True, PayloadJson, AError);
  if not Result then
    Exit;
  AResult := '// cabeçalho'#10 + HeaderJson + #10#10'// conteúdo'#10 + PayloadJson;
  V := TJSONObject.ParseJSONValue(Payload);
  try
    if (V <> nil) and V.TryGetValue<Int64>('exp', Exp) then
      AResult := AResult + #10#10'// vence em ' +
        FormatDateTime('dd/mm/yyyy hh:nn:ss', UnixToDateTime(Exp, False)) +
        IfThen(UnixToDateTime(Exp, False) < Now, ' (já venceu)', '');
  finally
    V.Free;
  end;
  // A assinatura não é conferida: precisaria da chave.
  AResult := AResult + #10#10'// assinatura não conferida';
end;

function Timestamp(const AText: string; out AResult, AError: string): Boolean;
const
  CMsDigits = 13;
var
  S: string;
  N: Int64;
  D: TDateTime;
  Fmt: TFormatSettings;
begin
  S := Trim(AText);
  Result := True;
  if TryStrToInt64(S, N) then
  begin
    if Length(S) >= CMsDigits then
      N := N div 1000;
    AResult := FormatDateTime('dd/mm/yyyy hh:nn:ss', UnixToDateTime(N, False)) + ' (local)'#10 +
      FormatDateTime('yyyy-mm-dd"T"hh:nn:ss"Z"', UnixToDateTime(N, True)) + ' (UTC)';
    Exit;
  end;
  Fmt := TFormatSettings.Create('pt-BR');
  if TryStrToDateTime(S, D, Fmt) or TryISO8601ToDate(S, D, False) then
  begin
    AResult := IntToStr(DateTimeToUnix(D, False));
    Exit;
  end;
  AError := 'Esperava um número (segundos ou milissegundos) ou uma data';
  Result := False;
end;

function MapLines(const AText: string; ASort, AUnique: Boolean): string;
var
  L: TStringList;
  Seen: TDictionary<string, Boolean>;
  I: Integer;
begin
  L := TStringList.Create;
  Seen := TDictionary<string, Boolean>.Create;
  try
    L.Text := AText;
    // Fica a primeira ocorrência de cada linha, na ordem original.
    if AUnique then
    begin
      I := 0;
      while I < L.Count do
        if Seen.ContainsKey(L[I]) then
          L.Delete(I)
        else
        begin
          Seen.Add(L[I], True);
          Inc(I);
        end;
    end;
    if ASort then
    begin
      L.CaseSensitive := False;
      L.Sort;
    end;
    Result := TrimRight(L.Text);
  finally
    Seen.Free;
    L.Free;
  end;
end;

function ConvertText(AKind: TConvertKind; const AText: string; out AResult, AError: string): Boolean;
var
  E: TBase64Encoding;
begin
  AResult := '';
  AError := '';
  Result := True;
  try
    case AKind of
      cvJsonPretty: Result := JsonFormat(AText, True, AResult, AError);
      cvJsonMin: Result := JsonFormat(AText, False, AResult, AError);
      cvBase64Enc, cvBase64Dec:
        begin
          E := Base64NoBreak;
          try
            if AKind = cvBase64Enc then
              AResult := E.EncodeBytesToString(TEncoding.UTF8.GetBytes(AText))
            else
              AResult := TEncoding.UTF8.GetString(E.DecodeStringToBytes(Trim(AText)));
          finally
            E.Free;
          end;
        end;
      cvUrlEnc: AResult := TNetEncoding.URL.Encode(AText);
      cvUrlDec: AResult := TNetEncoding.URL.Decode(AText);
      cvJwt: Result := Jwt(AText, AResult, AError);
      cvTimestamp: Result := Timestamp(AText, AResult, AError);
      cvSha256: AResult := THashSHA2.GetHashString(AText);
      cvMd5: AResult := THashMD5.GetHashString(AText);
      cvUpper: AResult := AnsiUpperCase(AText);
      cvLower: AResult := AnsiLowerCase(AText);
      cvSortLines: AResult := MapLines(AText, True, False);
      cvUniqueLines: AResult := MapLines(AText, False, True);
      cvGuid: AResult := TGUID.NewGuid.ToString.Trim(['{', '}']).ToLower;
    end;
  except
    on Ex: Exception do
    begin
      AError := Ex.Message;
      Result := False;
    end;
  end;
end;

end.
