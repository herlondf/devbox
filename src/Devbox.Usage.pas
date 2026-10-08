unit Devbox.Usage;

{ Uso e custo das IAs pagas: cada chamada registra tokens (texto e áudio) ou
  segundos de áudio; o custo sai do preço do modelo na hora. O registro chega de
  qualquer thread e espera numa fila; a tela grava no banco (FireDAC só na thread
  de UI). Preço em ai_price_<modelo> = "entrada;saída[;áudio entra;áudio sai;por minuto]"
  (USD; tokens por milhão), o mesmo formato do Vigia com o áudio a mais. }

interface

uses
  System.SysUtils;

type
  TAiUsage = record
    At: TDateTime;
    Provider: string;   // anthropic, openai, gemini, groq
    Model: string;
    Kind: string;       // pergunta, conversa, transcrição
    InputTokens: Int64;
    OutputTokens: Int64;
    AudioInTokens: Int64;
    AudioOutTokens: Int64;
    AudioSeconds: Double;
    Cost: Double;       // USD, preenchido ao gravar
  end;

  TAiPrice = record
    Input, Output, AudioIn, AudioOut, PerMinute: Double;
  end;

  TUsageTotal = record
    Model: string;
    Calls: Integer;
    InputTokens, OutputTokens, AudioTokens: Int64;
    AudioSeconds: Double;
    Cost: Double;
  end;
  TUsageTotals = TArray<TUsageTotal>;

{ Registra (qualquer thread). }
procedure UsageAdd(const AUsage: TAiUsage);
{ O que está na fila, para gravar (thread de UI). }
function UsageTake: TArray<TAiUsage>;

{ Preço padrão (páginas oficiais em 08/10/2026) ou o salvo pelo usuário. Lê o banco: thread de UI. }
function PriceFor(const AModel: string): TAiPrice;
procedure SavePrice(const AModel: string; const APrice: TAiPrice);
function PriceText(const APrice: TAiPrice): string;
function ParsePrice(const AText: string; out APrice: TAiPrice): Boolean;
function UsageCost(const AUsage: TAiUsage; const APrice: TAiPrice): Double;
{ Modelos com preço padrão conhecido. }
function KnownPriceModels: TArray<string>;

implementation

uses
  System.SyncObjs,
  Devbox.Store;

type
  TDefaultPrice = record
    Model: string;
    Price: TAiPrice;
  end;

const
  CMillion = 1000000;
  CSecondsPerMinute = 60;
  // Fonte: developers.openai.com/api/docs/pricing, ai.google.dev/gemini-api/docs/pricing,
  // claude.com/pricing (consultadas em 08/10/2026). Groq: a página não trouxe o preço; editar à mão.
  CDefaultPrices: array[0..8] of TDefaultPrice = (
    (Model: 'gpt-realtime-2.1'; Price: (Input: 4; Output: 24; AudioIn: 32; AudioOut: 64; PerMinute: 0)),
    (Model: 'gpt-realtime-2.1-mini'; Price: (Input: 0.6; Output: 2.4; AudioIn: 10; AudioOut: 20; PerMinute: 0)),
    (Model: 'gpt-realtime-mini'; Price: (Input: 0.6; Output: 2.4; AudioIn: 10; AudioOut: 20; PerMinute: 0)),
    (Model: 'gemini-3.8-live'; Price: (Input: 0.75; Output: 4.5; AudioIn: 3; AudioOut: 12; PerMinute: 0)),
    (Model: 'claude-opus-5-5'; Price: (Input: 4; Output: 20; AudioIn: 0; AudioOut: 0; PerMinute: 0)),
    (Model: 'claude-sonnet-5-5'; Price: (Input: 2; Output: 10; AudioIn: 0; AudioOut: 0; PerMinute: 0)),
    (Model: 'claude-fable-5-1'; Price: (Input: 10; Output: 50; AudioIn: 0; AudioOut: 0; PerMinute: 0)),
    (Model: 'gpt-4o-transcribe'; Price: (Input: 0; Output: 0; AudioIn: 0; AudioOut: 0; PerMinute: 0.006)),
    (Model: 'whisper-large-v3-turbo'; Price: (Input: 0; Output: 0; AudioIn: 0; AudioOut: 0; PerMinute: 0)));

var
  GLock: TCriticalSection;
  GPending: TArray<TAiUsage>;

procedure UsageAdd(const AUsage: TAiUsage);
var
  LUsage: TAiUsage;
begin
  LUsage := AUsage;
  if LUsage.At = 0 then
    LUsage.At := Now;
  GLock.Enter;
  try
    GPending := GPending + [LUsage];
  finally
    GLock.Leave;
  end;
end;

function UsageTake: TArray<TAiUsage>;
begin
  GLock.Enter;
  try
    Result := GPending;
    GPending := nil;
  finally
    GLock.Leave;
  end;
end;

function PriceText(const APrice: TAiPrice): string;
var
  LFmt: TFormatSettings;
begin
  LFmt := TFormatSettings.Invariant;
  Result := FloatToStr(APrice.Input, LFmt) + ';' + FloatToStr(APrice.Output, LFmt) + ';' +
    FloatToStr(APrice.AudioIn, LFmt) + ';' + FloatToStr(APrice.AudioOut, LFmt) + ';' +
    FloatToStr(APrice.PerMinute, LFmt);
end;

function ParsePrice(const AText: string; out APrice: TAiPrice): Boolean;
var
  LParts: TArray<string>;
  LFmt: TFormatSettings;

  function Part(AIndex: Integer): Double;
  begin
    if AIndex < Length(LParts) then
      Result := StrToFloatDef(Trim(LParts[AIndex]), 0, LFmt)
    else
      Result := 0;
  end;

begin
  APrice := Default(TAiPrice);
  LFmt := TFormatSettings.Invariant;
  LParts := AText.Split([';']);
  Result := Length(LParts) >= 2;
  if not Result then
    Exit;
  APrice.Input := Part(0);
  APrice.Output := Part(1);
  APrice.AudioIn := Part(2);
  APrice.AudioOut := Part(3);
  APrice.PerMinute := Part(4);
end;

function PriceFor(const AModel: string): TAiPrice;
var
  LDefault: TDefaultPrice;
begin
  if ParsePrice(Store.GetSetting('ai_price_' + AModel), Result) then
    Exit;
  for LDefault in CDefaultPrices do
    if SameText(LDefault.Model, AModel) then
      Exit(LDefault.Price);
  Result := Default(TAiPrice);
end;

procedure SavePrice(const AModel: string; const APrice: TAiPrice);
begin
  Store.SetSetting('ai_price_' + AModel, PriceText(APrice));
end;

function UsageCost(const AUsage: TAiUsage; const APrice: TAiPrice): Double;
begin
  Result := (AUsage.InputTokens * APrice.Input + AUsage.OutputTokens * APrice.Output +
    AUsage.AudioInTokens * APrice.AudioIn + AUsage.AudioOutTokens * APrice.AudioOut) / CMillion +
    AUsage.AudioSeconds / CSecondsPerMinute * APrice.PerMinute;
end;

function KnownPriceModels: TArray<string>;
var
  LDefault: TDefaultPrice;
begin
  Result := nil;
  for LDefault in CDefaultPrices do
    Result := Result + [LDefault.Model];
end;

initialization
  GLock := TCriticalSection.Create;

finalization
  GLock.Free;

end.
