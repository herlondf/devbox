unit Devbox.UI.Voice;

{ Assistente de voz (frase de ativação, ex.: "Oi Java"): liga o ouvido (Devbox.Voice), o whisper,
  a IA (Devbox.Voice.Agent) e a voz (Devbox.Speech), e mostra o HUD.
  O HUD é uma janela em camadas por cima de tudo, no canto inferior direito,
  que não pega foco nem clique, desenhada pelo Skia com transparência por
  pixel (o brilho do visualizador fica limpo sobre qualquer fundo). }

interface

uses
  System.Classes,
  System.SysUtils,
  Winapi.Windows,
  Winapi.Messages,
  Vcl.Controls,
  Vcl.Forms,
  Vcl.ExtCtrls,
  UI.AudioVisualizer,
  Devbox.Voice,
  Devbox.Voice.Agent,
  Devbox.Realtime,
  Devbox.Speech;

type
  THudForm = class(TForm)
  private
    FDib: HBITMAP;
    FDibBits: Pointer;
    FDibW, FDibH: Integer;
    FMemDC: HDC;
  protected
    procedure CreateParams(var Params: TCreateParams); override;
    procedure CreateWnd; override;
    procedure WMNCHitTest(var Message: TWMNCHitTest); message WM_NCHITTEST;
    procedure WMMouseActivate(var Message: TWMMouseActivate); message WM_MOUSEACTIVATE;
  public
    destructor Destroy; override;
    { Copia os pixels BGRA pré-multiplicados para a janela, com AAlpha (0 a 255) por cima. }
    procedure Present(APixels: Pointer; ARowBytes, AWidth, AHeight: Integer; AAlpha: Byte);
  end;

  TVoiceState = (vsOff, vsWaiting, vsListening, vsThinking, vsSpeaking);
  TVoiceContextFunc = reference to function: TVoiceContext;
  TVoiceActionProc = reference to procedure(const AReply: TVoiceReply);

  TVoiceAssistant = class(TComponent)
  private
    FListener: TVoiceListener;
    FHud: THudForm;
    FVis: TUIAudioVisualizer;
    FPlayer: TPcmPlayer;
    FTimer: TTimer;
    FState: TVoiceState;
    FCaption: string;
    FText: string;
    FAlpha: Single;
    FShowHud: Boolean;
    FHideAt: UInt64;
    FScale: Single;
    FFrame: Integer;
    FOnContext: TVoiceContextFunc;
    FOnAction: TVoiceActionProc;
    // Conversa ao vivo
    FLive: Boolean;
    FLiveConfig: TRealtimeConfig;
    FSession: TRealtimeSession;
    FStream: TPcmStream;
    FPending: TArray<SmallInt>;   // fala que chegou antes de a conexão abrir
    FPendingLock: TObject;
    FLastActivity: UInt64;
    FEndWhenQuiet: Boolean;
    procedure Wake;
    procedure StartConversation;
    procedure EndConversation(const ACaption: string);
    procedure StreamAudio(const ASamples: TArray<SmallInt>);
    procedure ToolCall(ASession: TRealtimeSession; const ACallId, AName, AArgs: string);
    procedure Recorded(const ASamples: TArray<SmallInt>);
    procedure NoSpeech;
    procedure Finish(const ACaption: string; AHoldMs: Integer);
    procedure Tick(Sender: TObject);
    procedure Render;
    procedure PlaceHud;
    procedure SetState(AState: TVoiceState; const ACaption: string);
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    { Liga ou desliga o microfone sempre ouvindo. False com o motivo. }
    function Enable(AOn: Boolean; out AError: string): Boolean;
    function Enabled: Boolean;
    { Pedido sem a palavra (menu da bandeja). }
    procedure Trigger;
    procedure SetPhrase(const APhrase: string; ASimilarity: Single);
    { Conversa ao vivo depois da frase (OpenAI Realtime ou Gemini Live). AOn=False volta ao pedido único. }
    procedure SetLive(AOn: Boolean; const AConfig: TRealtimeConfig);
    { Microfone (-1 = padrão). Ligado: reabre com o novo. }
    procedure SetInputDevice(ADeviceId: Integer);
    property State: TVoiceState read FState;
    property OnContext: TVoiceContextFunc read FOnContext write FOnContext;
    property OnAction: TVoiceActionProc read FOnAction write FOnAction;
  end;

implementation

uses
  System.Types,
  System.UITypes,
  System.Math,
  System.StrUtils,
  System.Threading,
  System.Skia,
  UI.Tokens,
  UI.Theme,
  UI.Painter,
  UI.Fonts,
  UI.Audio.Spectrum,
  System.IOUtils,
  Devbox.UI.Kit,
  Devbox.Vosk,
  Devbox.Whisper;

const
  CHudW = 300;
  CHudH = 470;
  CMargin = 24;
  CCircle = 260;
  CTickMs = 33;
  CFadeStep = 0.15;
  CHoldDoneMs = 1600;
  CHoldErrorMs = 3500;
  CSpectrumWindow = 1024;
  CSpectrumBands = 48;
  CSampleRate = 16000;
  CDiscRatio = 0.37;      // raio do disco escuro em relação ao lado do visualizador (cobre as barras em repouso)
  CDiscAlpha = 0.88;
  CPanelAlpha = 0.88;
  CShadowAlpha = 0.28;
  CShadowBlur = 8;
  CShadowDy = 3;
  CEdgeAlpha = 0.35;
  CHudInk = $FF0B0F19;
  CMaxTextLines = 8;
  CFullAlpha = 255;
  CIdleEndMs = 20000;     // conversa ao vivo: sem ninguém falar por 20 s, encerra
  CHudFrom = $FF22D3EE;   // ciano (estilo HUD)
  CHudTo = $FF6366F1;     // índigo

type
  TVisAccess = class(TUIAudioVisualizer);

{ THudForm }

procedure THudForm.CreateParams(var Params: TCreateParams);
begin
  inherited;
  Params.Style := WS_POPUP;
  Params.ExStyle := Params.ExStyle or WS_EX_LAYERED or WS_EX_TOPMOST or WS_EX_TOOLWINDOW or WS_EX_NOACTIVATE or
    WS_EX_TRANSPARENT;
  Params.WndParent := 0;
end;

{ O VCL tira o WS_EX_LAYERED na criação (SetLayeredAttribs, sem AlphaBlend nem
  TransparentColor): sem ele o UpdateLayeredWindow falha e sobra um form cinza. }
procedure THudForm.CreateWnd;
begin
  inherited;
  SetWindowLong(Handle, GWL_EXSTYLE, GetWindowLong(Handle, GWL_EXSTYLE) or WS_EX_LAYERED);
end;

procedure THudForm.WMNCHitTest(var Message: TWMNCHitTest);
begin
  Message.Result := HTTRANSPARENT;
end;

procedure THudForm.WMMouseActivate(var Message: TWMMouseActivate);
begin
  Message.Result := MA_NOACTIVATE;
end;

destructor THudForm.Destroy;
begin
  if FMemDC <> 0 then
    DeleteDC(FMemDC);
  if FDib <> 0 then
    DeleteObject(FDib);
  inherited;
end;

procedure THudForm.Present(APixels: Pointer; ARowBytes, AWidth, AHeight: Integer; AAlpha: Byte);
var
  LInfo: TBitmapInfo;
  LRow: Integer;
  LPos, LSrc: TPoint;
  LSize: TSize;
  LBlend: TBlendFunction;
begin
  if (FDib = 0) or (FDibW <> AWidth) or (FDibH <> AHeight) then
  begin
    if FDib <> 0 then
      DeleteObject(FDib);
    if FMemDC = 0 then
      FMemDC := CreateCompatibleDC(0);
    FillChar(LInfo, SizeOf(LInfo), 0);
    LInfo.bmiHeader.biSize := SizeOf(TBitmapInfoHeader);
    LInfo.bmiHeader.biWidth := AWidth;
    LInfo.bmiHeader.biHeight := -AHeight;   // de cima para baixo, como o Skia
    LInfo.bmiHeader.biPlanes := 1;
    LInfo.bmiHeader.biBitCount := 32;
    LInfo.bmiHeader.biCompression := BI_RGB;
    FDib := CreateDIBSection(0, LInfo, DIB_RGB_COLORS, FDibBits, 0, 0);
    SelectObject(FMemDC, FDib);
    FDibW := AWidth;
    FDibH := AHeight;
  end;
  for LRow := 0 to AHeight - 1 do
    Move(PByte(APixels)[LRow * ARowBytes], PByte(FDibBits)[LRow * AWidth * 4], AWidth * 4);
  LPos := Point(Left, Top);
  LSrc := Point(0, 0);
  LSize.cx := AWidth;
  LSize.cy := AHeight;
  LBlend.BlendOp := AC_SRC_OVER;
  LBlend.BlendFlags := 0;
  LBlend.SourceConstantAlpha := AAlpha;
  LBlend.AlphaFormat := AC_SRC_ALPHA;
  if not UpdateLayeredWindow(Handle, 0, @LPos, @LSize, FMemDC, @LSrc, 0, @LBlend, ULW_ALPHA) and
    (GetEnvironmentVariable('DEVBOX_VOICE_LOG') <> '') then
    TFile.AppendAllText(GetEnvironmentVariable('DEVBOX_VOICE_LOG'), 'HUD: UpdateLayeredWindow falhou: ' +
      SysErrorMessage(GetLastError) + sLineBreak, TEncoding.UTF8);
end;

{ TVoiceAssistant }

constructor TVoiceAssistant.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FScale := Screen.PixelsPerInch / 96;
  FListener := TVoiceListener.Create;
  FListener.OnWake := Wake;
  FListener.OnRecorded := Recorded;
  FListener.OnNoSpeech := NoSpeech;
  FListener.OnSpectrum :=
    procedure(const ABands: TArray<Single>; ALevel: Single)
    begin
      if FState = vsListening then
        FVis.SetSpectrum(ABands, ALevel);
    end;
  FPlayer := TPcmPlayer.Create;
  FStream := TPcmStream.Create;
  FPendingLock := TObject.Create;
  FListener.OnStream := StreamAudio;
  FVis := TUIAudioVisualizer.Create(nil);
  FVis.ColorFrom := CHudFrom;
  FVis.ColorTo := CHudTo;
  FVis.BarCount := 84;
  FTimer := TTimer.Create(Self);
  FTimer.Interval := CTickMs;
  FTimer.OnTimer := Tick;
  FTimer.Enabled := False;
end;

destructor TVoiceAssistant.Destroy;
begin
  FTimer.Enabled := False;
  FListener.Free;
  if FSession <> nil then
  begin
    FSession.OnClosed := nil;
    FSession.Free;
  end;
  FStream.Free;
  FPendingLock.Free;
  FPlayer.Free;
  FVis.Free;
  FHud.Free;
  inherited;
end;

function TVoiceAssistant.Enabled: Boolean;
begin
  Result := FListener.Active;
end;

function TVoiceAssistant.Enable(AOn: Boolean; out AError: string): Boolean;
var
  LPhrase: string;
begin
  AError := '';
  if not AOn then
  begin
    FListener.Stop;
    FState := vsOff;
    Exit(True);
  end;
  Result := FListener.Start(AError);
  if not Result then
    Exit;
  FState := vsWaiting;
  // Sobe o whisper agora (se for usado): o primeiro pedido não espera o modelo carregar.
  LPhrase := FListener.Phrase;
  TTask.Run(
    procedure
    var
      LErr: string;
    begin
      if not SttIsCloud(SttEngine) or (VoskMissingWords(LPhrase) <> '') then
        WhisperStart(LErr);
    end);
end;

procedure TVoiceAssistant.SetPhrase(const APhrase: string; ASimilarity: Single);
begin
  FListener.Phrase := APhrase;
  FListener.Similarity := ASimilarity;
end;

procedure TVoiceAssistant.Trigger;
var
  LError: string;
begin
  if not FListener.Active and not Enable(True, LError) then
  begin
    FCaption := LError;
    Exit;
  end;
  FListener.Trigger;
end;

procedure TVoiceAssistant.PlaceHud;
var
  LArea: TRect;
begin
  if FHud = nil then
  begin
    FHud := THudForm.CreateNew(nil);
    FHud.BorderStyle := bsNone;
  end;
  // No monitor em que está o mouse (com vários monitores, o principal pode estar fora de vista).
  LArea := Screen.MonitorFromPoint(Mouse.CursorPos, mdNearest).WorkareaRect;
  FHud.SetBounds(LArea.Right - Round(CHudW * FScale) - Round(CMargin * FScale),
    LArea.Bottom - Round(CHudH * FScale) - Round(CMargin * FScale), Round(CHudW * FScale), Round(CHudH * FScale));
  // Primeiro quadro (transparente) antes de mostrar: nada de fundo de form na tela.
  Render;
  ShowWindow(FHud.Handle, SW_SHOWNOACTIVATE);
end;

procedure TVoiceAssistant.SetState(AState: TVoiceState; const ACaption: string);
begin
  FState := AState;
  FCaption := ACaption;
  case AState of
    vsListening: FVis.Mode := avmListening;
    vsThinking: FVis.Mode := avmThinking;
    vsSpeaking: FVis.Mode := avmSpeaking;
  else
    FVis.Mode := avmIdle;
  end;
end;

procedure TVoiceAssistant.Wake;
begin
  FListener.Busy := True;
  FText := '';
  FHideAt := 0;
  SetState(vsListening, 'Ouvindo...');
  FShowHud := True;
  PlaceHud;
  VoiceLog(Format('HUD em %d,%d', [FHud.Left, FHud.Top]));
  FTimer.Enabled := True;
  if FLive then
    StartConversation;
end;

procedure TVoiceAssistant.SetInputDevice(ADeviceId: Integer);
var
  LError: string;
begin
  if FListener.DeviceId = ADeviceId then
    Exit;
  FListener.DeviceId := ADeviceId;
  if FListener.Active then
  begin
    FListener.Stop;
    if not FListener.Start(LError) then
      VoiceLog('microfone não abriu: ' + LError);
  end;
end;

procedure TVoiceAssistant.SetLive(AOn: Boolean; const AConfig: TRealtimeConfig);
begin
  FLive := AOn;
  FLiveConfig := AConfig;
  FLiveConfig.Instructions := RealtimeInstructions;
  FLiveConfig.Tools := RealtimeTools;
  // Teste: DEVBOX_REALTIME_URL aponta para o servidor falso (ws://127.0.0.1:4086).
  if GetEnvironmentVariable('DEVBOX_REALTIME_URL') <> '' then
    FLiveConfig.Url := GetEnvironmentVariable('DEVBOX_REALTIME_URL');
  FListener.Live := AOn;
end;

{ Microfone (thread de trabalho do ouvido): direto para a IA, ou guardado até a conexão abrir. }
procedure TVoiceAssistant.StreamAudio(const ASamples: TArray<SmallInt>);
var
  LSession: TRealtimeSession;
begin
  System.TMonitor.Enter(FPendingLock);
  try
    LSession := FSession;
    if (LSession = nil) or (FPending <> nil) then
    begin
      FPending := FPending + ASamples;
      Exit;
    end;
  finally
    System.TMonitor.Exit(FPendingLock);
  end;
  LSession.SendAudio(ASamples);
end;

procedure TVoiceAssistant.StartConversation;
var
  LSession: TRealtimeSession;
begin
  if FSession <> nil then
    Exit;
  SetState(vsThinking, 'Conectando...');
  FEndWhenQuiet := False;
  FLastActivity := TThread.GetTickCount64;
  FPending := nil;
  LSession := TRealtimeSession.Create(FLiveConfig);
  FSession := LSession;
  LSession.OnAudio :=
    procedure(const ASamples: TArray<SmallInt>)
    begin
      QueueUI(
        procedure
        begin
          if FSession <> LSession then
            Exit;
          if FState <> vsSpeaking then
            VoiceLog('voz da IA chegando');
          FStream.Write(ASamples);
          FLastActivity := TThread.GetTickCount64;
          if FState <> vsSpeaking then
            SetState(vsSpeaking, 'Devbox');
        end);
    end;
  LSession.OnSpeechStarted :=
    procedure
    begin
      QueueUI(
        procedure
        begin
          if FSession <> LSession then
            Exit;
          // Usuário falou por cima: corta a voz na hora.
          FStream.Clear;
          FLastActivity := TThread.GetTickCount64;
          SetState(vsListening, 'Ouvindo...');
        end);
    end;
  LSession.OnUserText :=
    procedure(const AText: string)
    begin
      VoiceLog('você: ' + AText);
      QueueUI(
        procedure
        begin
          if FSession = LSession then
          begin
            FText := AText;
            FLastActivity := TThread.GetTickCount64;
          end;
        end);
    end;
  LSession.OnAssistantText :=
    procedure(const AText: string)
    begin
      QueueUI(
        procedure
        begin
          if FSession = LSession then
            FText := AText;
        end);
    end;
  LSession.OnToolCall :=
    procedure(const ACallId, AName, AArgs: string)
    begin
      VoiceLog(Format('ferramenta %s %s', [AName, AArgs]));
      QueueUI(
        procedure
        begin
          if FSession = LSession then
            ToolCall(LSession, ACallId, AName, AArgs);
        end);
    end;
  LSession.OnError :=
    procedure(const AText: string)
    begin
      VoiceLog('erro da IA: ' + AText);
      QueueUI(
        procedure
        begin
          if FSession = LSession then
            FText := AText;
        end);
    end;
  LSession.OnClosed :=
    procedure(const AText: string)
    begin
      VoiceLog('conversa fechada: ' + AText);
      QueueUI(
        procedure
        begin
          if FSession = LSession then
            EndConversation(IfThen(AText <> '', AText, 'Conversa encerrada'));
        end);
    end;
  TTask.Run(
    procedure
    var
      LError: string;
      LOk: Boolean;
      LPending: TArray<SmallInt>;
    begin
      LOk := LSession.Start(LError);
      VoiceLog(IfThen(LOk, 'conversa aberta', 'conversa não abriu: ' + LError));
      if LOk then
      begin
        // Entrega o que foi dito enquanto conectava; dali em diante vai direto.
        System.TMonitor.Enter(FPendingLock);
        try
          LPending := FPending;
          FPending := nil;
          LSession.SendAudio(LPending);
        finally
          System.TMonitor.Exit(FPendingLock);
        end;
      end;
      QueueUI(
        procedure
        begin
          if FSession <> LSession then
            Exit;
          if LOk then
            SetState(vsListening, 'Pode falar')
          else
            EndConversation(LError);
        end);
    end);
end;

procedure TVoiceAssistant.ToolCall(ASession: TRealtimeSession; const ACallId, AName, AArgs: string);
var
  LCtx: TVoiceContext;
begin
  SetState(vsThinking, 'Buscando...');
  if Assigned(FOnContext) then
    LCtx := FOnContext()
  else
    LCtx := Default(TVoiceContext);
  TTask.Run(
    procedure
    var
      LReply: TVoiceReply;
      LResult: string;
    begin
      try
        LResult := RunRealtimeTool(AName, AArgs, LCtx, LReply);
      except
        on E: Exception do
          LResult := '{"erro":"' + StringReplace(E.Message, '"', '''', [rfReplaceAll]) + '"}';
      end;
      ASession.SendToolResult(ACallId, AName, LResult);
      QueueUI(
        procedure
        begin
          if FSession <> ASession then
            Exit;
          FLastActivity := TThread.GetTickCount64;
          if LReply.Action = vaEncerrar then
            FEndWhenQuiet := True
          else if (LReply.Action <> vaConversa) and Assigned(FOnAction) then
            FOnAction(LReply);
        end);
    end);
end;

procedure TVoiceAssistant.EndConversation(const ACaption: string);
var
  LSession: TRealtimeSession;
begin
  LSession := FSession;
  System.TMonitor.Enter(FPendingLock);
  try
    FSession := nil;
    FPending := nil;
  finally
    System.TMonitor.Exit(FPendingLock);
  end;
  FListener.EndStream;
  FStream.Clear;
  if LSession <> nil then
    // Fechar espera a thread de leitura: fora da tela.
    TTask.Run(
      procedure
      begin
        LSession.Free;
      end);
  Finish(ACaption, CHoldDoneMs);
end;

procedure TVoiceAssistant.NoSpeech;
begin
  Finish('Não ouvi nada', CHoldDoneMs);
end;

procedure TVoiceAssistant.Finish(const ACaption: string; AHoldMs: Integer);
begin
  SetState(vsWaiting, ACaption);
  FVis.ClearSpectrum;
  FHideAt := TThread.GetTickCount64 + UInt64(AHoldMs);
  FListener.Busy := False;
end;

procedure TVoiceAssistant.Recorded(const ASamples: TArray<SmallInt>);
var
  LCtx: TVoiceContext;
  LSamples: TArray<SmallInt>;
  LPhrase: string;
  LSimilarity: Single;
begin
  SetState(vsThinking, 'Pensando...');
  if Assigned(FOnContext) then
    LCtx := FOnContext()
  else
    LCtx := Default(TVoiceContext);
  LSamples := ASamples;
  LPhrase := FListener.Phrase;
  LSimilarity := FListener.Similarity;
  TTask.Run(
    procedure
    var
      LText, LErr, LRest: string;
      LReply: TVoiceReply;
      LPcm: TArray<SmallInt>;
      LOk: Boolean;
      LStart: UInt64;
    begin
      LOk := False;
      LPcm := nil;
      try
        LStart := TThread.GetTickCount64;
        if SttTranscribe(LSamples, LText, LErr, LPhrase) then
        begin
          VoiceLog(Format('pedido em texto (%s) em %d ms: "%s"', [SttEngineNames[SttEngine],
            TThread.GetTickCount64 - LStart, LText]));
          // O áudio começa com a frase de ativação: o pedido é o resto.
          if WakeMatch(LText, LPhrase, LSimilarity, LRest) then
            LText := LRest;
          QueueUI(
            procedure
            begin
              FText := LText;
            end);
          if Trim(LText) = '' then
            LErr := 'Não ouvi o pedido'
          else if RunVoiceCommand(LText, LCtx, LReply, LErr) then
            LOk := Synthesize(LReply.Speech, LPcm, LErr);
        end;
      except
        on E: Exception do
          LErr := E.Message;
      end;
      QueueUI(
        procedure
        begin
          if not LOk then
          begin
            VoiceLog('pedido falhou: ' + LErr);
            Finish(LErr, CHoldErrorMs);
            Exit;
          end;
          FText := LReply.Speech;
          SetState(vsSpeaking, 'Devbox');
          if Assigned(FOnAction) then
            FOnAction(LReply);
          VoiceLog(Format('resposta falada: %.1f s', [Length(LPcm) / CSampleRate]));
          FPlayer.Play(LPcm);
        end);
    end);
end;

procedure TVoiceAssistant.Tick(Sender: TObject);
var
  LWindow: TArray<SmallInt>;
begin
  if FSession <> nil then
  begin
    if FStream.Playing then
    begin
      LWindow := FStream.Window(CSpectrumWindow);
      FVis.SetSpectrum(UISpectrumBands(LWindow, CSpectrumBands, CSampleRate), UIAudioLevel(LWindow));
      FLastActivity := TThread.GetTickCount64;
    end
    else if FState = vsSpeaking then
    begin
      SetState(vsListening, 'Pode falar');
      FVis.ClearSpectrum;
    end;
    if not FStream.Playing and (FEndWhenQuiet or (TThread.GetTickCount64 - FLastActivity > CIdleEndMs)) then
      EndConversation('Até mais');
  end
  else if FState = vsSpeaking then
  begin
    if FPlayer.Playing then
    begin
      LWindow := FPlayer.Window(CSpectrumWindow);
      FVis.SetSpectrum(UISpectrumBands(LWindow, CSpectrumBands, CSampleRate), UIAudioLevel(LWindow));
    end
    else
      Finish('', CHoldDoneMs);
  end;
  if (FHideAt > 0) and (TThread.GetTickCount64 >= FHideAt) then
  begin
    FHideAt := 0;
    FShowHud := False;
  end;
  if FShowHud then
    FAlpha := Min(1, FAlpha + CFadeStep)
  else
    FAlpha := Max(0, FAlpha - CFadeStep);
  if (FAlpha <= 0) and not FShowHud then
  begin
    FTimer.Enabled := False;
    if FHud <> nil then
      ShowWindow(FHud.Handle, SW_HIDE);
    Exit;
  end;
  Render;
end;

procedure TVoiceAssistant.Render;
var
  LW, LH, LSide, LTop, LLine: Integer;
  LSurface: ISkSurface;
  LCanvas: ISkCanvas;
  LPaint, LShadow, LEdge: ISkPaint;
  LDisc: Single;
  LCenter: TPointF;
  LTitleFont, LTextFont: ISkFont;
  LLines: TArray<string>;
  LPanel, LRect: TRectF;
  LPixmap: ISkPixmap;
  LS: Single;
begin
  if FHud = nil then
    Exit;
  LS := FScale;
  LW := Round(CHudW * LS);
  LH := Round(CHudH * LS);
  LSurface := TSkSurface.MakeRaster(LW, LH);
  LCanvas := LSurface.Canvas;
  LCanvas.Clear(TAlphaColors.Null);
  LSide := Round(CCircle * LS);
  LTop := Round(4 * LS);
  LCenter := TPointF.Create(LW / 2, LTop + LSide / 2);
  // Disco escuro de borda nítida com sombra curta: legível em fundo claro sem mancha cinza.
  LDisc := LSide * CDiscRatio;
  LShadow := TSkPaint.Create;
  LShadow.AntiAlias := True;
  LShadow.Color := UIColorWithAlpha(TAlphaColors.Black, CShadowAlpha);
  LShadow.MaskFilter := TSkMaskFilter.MakeBlur(TSkBlurStyle.Normal, CShadowBlur * LS);
  LCanvas.DrawCircle(TPointF.Create(LCenter.X, LCenter.Y + CShadowDy * LS), LDisc, LShadow);
  LPaint := TSkPaint.Create;
  LPaint.AntiAlias := True;
  LPaint.Color := UIColorWithAlpha(CHudInk, CDiscAlpha);
  LCanvas.DrawCircle(LCenter, LDisc, LPaint);
  LEdge := TSkPaint.Create(TSkPaintStyle.Stroke);
  LEdge.AntiAlias := True;
  LEdge.StrokeWidth := LS;
  LEdge.Color := UIColorWithAlpha(CHudFrom, CEdgeAlpha);
  LCanvas.DrawCircle(LCenter, LDisc, LEdge);
  TVisAccess(FVis).DrawComponent(LCanvas, TRectF.Create(LCenter.X - LSide / 2, LTop, LCenter.X + LSide / 2,
    LTop + LSide), 1);
  // Legenda: estado e texto (o que ouviu ou o que vai falar).
  LTitleFont := TUIFontManager.GetFont(UITheme.Tokens.Typography.FamilyPrimary, 14 * LS,
    UITheme.Tokens.Typography.WeightSemiBold);
  LTextFont := TUIFontManager.GetFont(UITheme.Tokens.Typography.FamilyPrimary, 12 * LS,
    UITheme.Tokens.Typography.WeightRegular);
  LLines := nil;
  if FText <> '' then
  begin
    // Texto longo: mostra o fim (o que está sendo dito agora), não o começo.
    LLines := UIWrapTextLines(FText, LW - 56 * LS, LTextFont);   // painel (16 de cada lado) + folga do texto (8) + margem
    if Length(LLines) > CMaxTextLines then
      LLines := ['…'] + Copy(LLines, Length(LLines) - CMaxTextLines + 1, MaxInt);
  end;
  LPanel := TRectF.Create(16 * LS, LTop + LSide + 4 * LS, LW - 16 * LS,
    LTop + LSide + (30 + 18 * Length(LLines)) * LS);
  LRect := LPanel;
  LRect.Offset(0, CShadowDy * LS);
  LCanvas.DrawRoundRect(LRect, 12 * LS, 12 * LS, LShadow);
  LPaint.Color := UIColorWithAlpha(CHudInk, CPanelAlpha);
  LCanvas.DrawRoundRect(LPanel, 12 * LS, 12 * LS, LPaint);
  LCanvas.DrawRoundRect(LPanel, 12 * LS, 12 * LS, LEdge);
  LRect := TRectF.Create(LPanel.Left, LPanel.Top + 4 * LS, LPanel.Right, LPanel.Top + 26 * LS);
  UIDrawText(LCanvas, FCaption, LRect, LTitleFont, CHudFrom, taCenter);
  for LLine := 0 to High(LLines) do
  begin
    LRect := TRectF.Create(LPanel.Left + 8 * LS, LPanel.Top + (26 + 18 * LLine) * LS, LPanel.Right - 8 * LS,
      LPanel.Top + (44 + 18 * LLine) * LS);
    UIDrawText(LCanvas, LLines[LLine], LRect, LTextFont, $FFE5E7EB, taCenter);
  end;
  // Teste: DEVBOX_VOICE_SHOTS=pasta grava um quadro a cada 15 (a janela em camadas não sai em captura de tela).
  if GetEnvironmentVariable('DEVBOX_VOICE_SHOTS') <> '' then
  begin
    Inc(FFrame);
    if FFrame mod 15 = 0 then
      LSurface.MakeImageSnapshot.EncodeToFile(TPath.Combine(GetEnvironmentVariable('DEVBOX_VOICE_SHOTS'),
        Format('hud-%.3d-%d.png', [FFrame div 15, Ord(FState)])));
  end;
  LPixmap := LSurface.PeekPixels;
  FHud.Present(LPixmap.Pixels, LPixmap.RowBytes, LW, LH, Round(FAlpha * CFullAlpha));
end;

end.
