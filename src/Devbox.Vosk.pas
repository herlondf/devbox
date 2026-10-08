unit Devbox.Vosk;

{ Frase de ativação pelo Vosk (Kaldi), offline: o reconhecedor só conhece a
  frase e "[unk]" (gramática), então decide rápido (~60 ms por trecho) e não
  inventa outras palavras. libvosk.dll win32 0.3.42 e o modelo pequeno pt ficam
  em voice\vosk (tools\voice-deps.ps1). O modelo é carregado uma vez e serve a
  qualquer thread; cada chamada cria o próprio reconhecedor. }

{$WARN SYMBOL_PLATFORM OFF} // SetSSEExceptionMask: o Devbox é só Windows.

interface

{ Carrega a biblioteca e o modelo (uma vez; ~1 s). False com o motivo. }
function VoskLoad(out AError: string): Boolean;
{ Palavras da frase que o modelo não conhece (separadas por vírgula). '' = todas conhecidas. }
function VoskMissingWords(const APhrase: string): string;
{ Reconhece o trecho só contra a frase. AText vem com "[unk]" no lugar do que não é a frase. }
function VoskHear(const ASamples: TArray<SmallInt>; const APhrase: string; out AText: string): Boolean;

implementation

uses
  Winapi.Windows,
  System.SysUtils,
  System.IOUtils,
  System.SyncObjs,
  System.JSON,
  System.Character,
  System.StrUtils,
  System.Math,
  Devbox.Whisper;

type
  TVoskModelNew = function(APath: PAnsiChar): Pointer; cdecl;
  TVoskFindWord = function(AModel: Pointer; AWord: PAnsiChar): Integer; cdecl;
  TVoskRecNewGrm = function(AModel: Pointer; ARate: Single; AGrammar: PAnsiChar): Pointer; cdecl;
  TVoskAccept = function(ARec: Pointer; AData: Pointer; ALength: Integer): Integer; cdecl;
  TVoskFinal = function(ARec: Pointer): PAnsiChar; cdecl;
  TVoskRecFree = procedure(ARec: Pointer); cdecl;
  TVoskLogLevel = procedure(ALevel: Integer); cdecl;

const
  CRate = 16000;
  CQuiet = -1;

var
  GLock: TCriticalSection;
  GLib: HMODULE;
  GModel: Pointer;
  GError: string;
  ModelNew: TVoskModelNew;
  FindWord: TVoskFindWord;
  RecNewGrm: TVoskRecNewGrm;
  Accept: TVoskAccept;
  FinalResult: TVoskFinal;
  RecFree: TVoskRecFree;
  LogLevel: TVoskLogLevel;

{ O Kaldi faz conta com NaN e infinito de propósito: com as exceções de ponto
  flutuante do Delphi ligadas, cai em EInvalidOp. Desliga só durante a chamada. }
function QuietFpu: TArithmeticExceptionMask;
begin
  Result := GetExceptionMask;
  SetExceptionMask(exAllArithmeticExceptions);
  SetSSEExceptionMask(exAllArithmeticExceptions);
end;

procedure RestoreFpu(AMask: TArithmeticExceptionMask);
begin
  SetExceptionMask(AMask);
  SetSSEExceptionMask(AMask);
end;

function VoskLoad(out AError: string): Boolean;
var
  LDir, LModelDir: string;
  LMask: TArithmeticExceptionMask;
begin
  GLock.Enter;
  LMask := QuietFpu;
  try
    if GModel <> nil then
      Exit(True);
    if GError <> '' then
    begin
      AError := GError;
      Exit(False);
    end;
    LDir := TPath.Combine(VoiceDir, 'vosk');
    LModelDir := TPath.Combine(LDir, 'model');
    if not FileExists(TPath.Combine(LDir, 'libvosk.dll')) or not DirectoryExists(LModelDir) then
      GError := 'Vosk não está em ' + LDir + ' (rode tools\voice-deps.ps1)'
    else
    begin
      // As dependências (libstdc++ etc.) estão na mesma pasta da dll.
      GLib := LoadLibraryEx(PChar(TPath.Combine(LDir, 'libvosk.dll')), 0, LOAD_WITH_ALTERED_SEARCH_PATH);
      if GLib = 0 then
        GError := 'libvosk.dll não carregou: ' + SysErrorMessage(GetLastError)
      else
      begin
        @ModelNew := GetProcAddress(GLib, 'vosk_model_new');
        @FindWord := GetProcAddress(GLib, 'vosk_model_find_word');
        @RecNewGrm := GetProcAddress(GLib, 'vosk_recognizer_new_grm');
        @Accept := GetProcAddress(GLib, 'vosk_recognizer_accept_waveform');
        @FinalResult := GetProcAddress(GLib, 'vosk_recognizer_final_result');
        @RecFree := GetProcAddress(GLib, 'vosk_recognizer_free');
        @LogLevel := GetProcAddress(GLib, 'vosk_set_log_level');
        if not Assigned(ModelNew) or not Assigned(FindWord) or not Assigned(RecNewGrm) or not Assigned(Accept) or
          not Assigned(FinalResult) or not Assigned(RecFree) or not Assigned(LogLevel) then
          GError := 'libvosk.dll de outra versão (falta função)'
        else
        begin
          LogLevel(CQuiet);
          GModel := ModelNew(PAnsiChar(UTF8Encode(LModelDir)));
          if GModel = nil then
            GError := 'modelo do Vosk não carregou: ' + LModelDir;
        end;
      end;
    end;
    AError := GError;
    Result := GModel <> nil;
  finally
    RestoreFpu(LMask);
    GLock.Leave;
  end;
end;

{ Minúsculas, só letras e números, um espaço entre palavras (o acento fica: o vocabulário tem acento). }
function PhraseWords(const APhrase: string): TArray<string>;
var
  LChar: Char;
  LClean: string;
begin
  LClean := '';
  for LChar in APhrase.ToLower do
    if LChar.IsLetterOrDigit then
      LClean := LClean + LChar
    else
      LClean := LClean + ' ';
  Result := LClean.Split([' '], TStringSplitOptions.ExcludeEmpty);
end;

function VoskMissingWords(const APhrase: string): string;
var
  LWord, LError: string;
begin
  Result := '';
  if not VoskLoad(LError) then
    Exit(LError);
  for LWord in PhraseWords(APhrase) do
    if FindWord(GModel, PAnsiChar(UTF8Encode(LWord))) < 0 then
      Result := Result + IfThen(Result <> '', ', ', '') + LWord;
end;

{ Chamada ao Vosk, com as exceções de ponto flutuante já desligadas. }
function HearRaw(const ASamples: TArray<SmallInt>; const APhrase: string; out AText: string): Boolean;
var
  LGrammar: TJSONArray;
  LRec: Pointer;
  LJson: TJSONValue;
begin
  LGrammar := TJSONArray.Create;
  try
    LGrammar.Add(string.Join(' ', PhraseWords(APhrase)));
    LGrammar.Add('[unk]');
    LRec := RecNewGrm(GModel, CRate, PAnsiChar(UTF8Encode(LGrammar.ToJSON)));
  finally
    LGrammar.Free;
  end;
  if LRec = nil then
    Exit(False);
  try
    Accept(LRec, @ASamples[0], Length(ASamples) * SizeOf(SmallInt));
    LJson := TJSONObject.ParseJSONValue(UTF8ToString(FinalResult(LRec)));
    try
      if LJson <> nil then
        AText := LJson.GetValue<string>('text', '');
    finally
      LJson.Free;
    end;
    Result := True;
  finally
    RecFree(LRec);
  end;
end;

function VoskHear(const ASamples: TArray<SmallInt>; const APhrase: string; out AText: string): Boolean;
var
  LError: string;
  LMask: TArithmeticExceptionMask;
begin
  AText := '';
  if not VoskLoad(LError) or (Length(ASamples) = 0) then
    Exit(False);
  LMask := QuietFpu;
  try
    Result := HearRaw(ASamples, APhrase, AText);
  finally
    RestoreFpu(LMask);
  end;
end;

initialization
  GLock := TCriticalSection.Create;

finalization
  // O modelo e a dll ficam até o processo sair (liberar o Kaldi na saída só arrisca travar).
  GLock.Free;

end.
