unit Devbox.Envs;

{ Ambientes de projeto: uma lista de passos em texto, um por linha, que liga
  (e desliga) tudo de um projeto. Também a detecção de reunião (câmera ou
  microfone em uso) do modo foco. }

interface

uses
  System.SysUtils;

type
  TEnvStepKind = (eskDistro, eskContainer, eskCommand, eskTerminal, eskEditor, eskOpen, eskWait, eskStop);

  TEnvStep = record
    Kind: TEnvStepKind;
    Value: string;       // o texto depois do "tipo:"
    Target: string;      // container: nome; terminal: pasta; esperar: host
    Distro: string;      // container: @Distro ('' = Docker do Windows)
    Extra: string;       // terminal: comando depois do "|"; esperar: porta
    function Caption: string;
  end;
  TEnvSteps = TArray<TEnvStep>;

const
  EnvHelp =
    'Um passo por linha, na ordem:'#13#10 +
    '  distro: Ubuntu              liga a distro WSL'#13#10 +
    '  container: api-db @Ubuntu   sobe o container (sem @ = Docker do Windows)'#13#10 +
    '  esperar: localhost:5432         espera a porta abrir (ou esperar: 5 = 5 segundos)'#13#10 +
    '  cmd: npm install                roda e espera terminar'#13#10 +
    '  terminal: D:\proj | npm run dev abre um terminal na pasta, com o comando'#13#10 +
    '  editor: D:\proj                 abre no VS Code'#13#10 +
    '  abrir: http://localhost:5173    abre endereço, pasta ou arquivo'#13#10 +
    '  parar: comando                  só roda no Desligar'#13#10 +
    'Linha com # é comentário. Desligar para os containers e desliga as distros da lista.';

{ Lê o roteiro. False com AError na primeira linha que não dá para entender. }
function ParseEnvScript(const AScript: string; out ASteps: TEnvSteps; out AError: string): Boolean;

{ Roda um passo de ligar. Bloqueia (usar fora da thread de UI). AMessage diz o que aconteceu. }
function RunEnvStep(const AStep: TEnvStep; out AMessage: string): Boolean;

{ Passos de desligar, na ordem certa (containers, depois distros, mais os "parar:"). }
function StopSteps(const ASteps: TEnvSteps): TEnvSteps;

{ Desliga um passo: container para, distro desliga, "parar:" roda. }
function RunStopStep(const AStep: TEnvStep; out AMessage: string): Boolean;

{ Programas usando câmera ou microfone agora (pela permissão do Windows). }
function AppsInMeeting: TArray<string>;

implementation

uses
  Winapi.Windows,
  System.Classes,
  System.StrUtils,
  System.Math,
  System.Win.Registry,
  Devbox.Model,
  Devbox.Sys,
  Devbox.Net;

const
  KindNames: array[TEnvStepKind] of string = ('distro', 'container', 'cmd', 'terminal', 'editor', 'abrir',
    'esperar', 'parar');
  CWaitPortMs = 60000;
  CCmdTimeoutMs = 10 * 60 * 1000;

function TEnvStep.Caption: string;
begin
  case Kind of
    eskDistro: Result := 'Ligar a distro ' + Value;
    eskContainer: Result := 'Subir ' + Target + IfThen(Distro <> '', ' em ' + Distro, '');
    eskCommand: Result := 'Rodar ' + Value;
    eskTerminal: Result := 'Terminal em ' + ExtractFileName(ExcludeTrailingPathDelimiter(Target)) +
      IfThen(Extra <> '', ': ' + Extra, '');
    eskEditor: Result := 'Abrir no VS Code: ' + ExtractFileName(ExcludeTrailingPathDelimiter(Value));
    eskOpen: Result := 'Abrir ' + Value;
    eskWait:
      if Extra <> '' then
        Result := 'Esperar ' + Target + ':' + Extra
      else
        Result := 'Esperar ' + Value + ' s';
  else
    Result := 'Ao desligar: ' + Value;
  end;
end;

function ParseEnvScript(const AScript: string; out ASteps: TEnvSteps; out AError: string): Boolean;
var
  Lines: TStringList;
  I, K, P, N: Integer;
  Line, Key: string;
  S: TEnvStep;
begin
  ASteps := nil;
  AError := '';
  Lines := TStringList.Create;
  try
    Lines.Text := AScript;
    for I := 0 to Lines.Count - 1 do
    begin
      Line := Trim(Lines[I]);
      if (Line = '') or Line.StartsWith('#') then
        Continue;
      P := Pos(':', Line);
      K := -1;
      if P > 1 then
        K := IndexText(Trim(Copy(Line, 1, P - 1)), KindNames);
      if K < 0 then
      begin
        AError := Format('Linha %d: comece com um tipo (distro:, container:, cmd:...)', [I + 1]);
        Exit(False);
      end;
      Key := Trim(Copy(Line, P + 1, MaxInt));
      if Key = '' then
      begin
        AError := Format('Linha %d: falta o valor depois de "%s:"', [I + 1, KindNames[TEnvStepKind(K)]]);
        Exit(False);
      end;
      S := Default(TEnvStep);
      S.Kind := TEnvStepKind(K);
      S.Value := Key;
      case S.Kind of
        eskContainer:
          begin
            P := Pos('@', Key);
            if P > 0 then
            begin
              S.Target := Trim(Copy(Key, 1, P - 1));
              S.Distro := Trim(Copy(Key, P + 1, MaxInt));
              if SameText(S.Distro, 'Windows') then
                S.Distro := '';
            end
            else
              S.Target := Key;
          end;
        eskTerminal:
          begin
            P := Pos('|', Key);
            if P > 0 then
            begin
              S.Target := Trim(Copy(Key, 1, P - 1));
              S.Extra := Trim(Copy(Key, P + 1, MaxInt));
            end
            else
              S.Target := Key;
          end;
        eskWait:
          if not TryStrToInt(Key, N) then
          begin
            if not ParseHostPort(Key, S.Target, N) then
            begin
              AError := Format('Linha %d: esperar: segundos (5) ou host:porta (localhost:5432)', [I + 1]);
              Exit(False);
            end;
            S.Extra := IntToStr(N);
          end;
      end;
      ASteps := ASteps + [S];
    end;
  finally
    Lines.Free;
  end;
  Result := True;
end;

function StopSteps(const ASteps: TEnvSteps): TEnvSteps;
var
  I: Integer;
begin
  Result := nil;
  for I := 0 to High(ASteps) do
    if ASteps[I].Kind = eskStop then
      Result := Result + [ASteps[I]];
  for I := High(ASteps) downto 0 do
    if ASteps[I].Kind = eskContainer then
      Result := Result + [ASteps[I]];
  for I := High(ASteps) downto 0 do
    if ASteps[I].Kind = eskDistro then
      Result := Result + [ASteps[I]];
end;

function EngineCli(const ADistro, AEngine: string): string;
begin
  if ADistro = '' then
    Result := AEngine
  else
    Result := Format('wsl.exe -d %s -e %s', [ADistro, AEngine]);
end;

function RunEnvStep(const AStep: TEnvStep; out AMessage: string): Boolean;
var
  Output: string;
  Start: UInt64;
  Secs: Integer;
begin
  Result := True;
  AMessage := 'ok';
  case AStep.Kind of
    eskDistro:
      begin
        // Um "true" dentro da distro basta para ela subir.
        Result := RunCapture(Format('wsl.exe -d %s -e true', [AStep.Value]), Output, 60000) = 0;
        AMessage := IfThen(Result, 'distro ligada', Trim(Output));
      end;
    eskContainer:
      begin
        Result := RunCapture(EngineCli(AStep.Distro, 'podman') + ' start ' + AStep.Target, Output, 120000) = 0;
        if not Result and (AStep.Distro <> '') then
          Result := RunCapture(EngineCli(AStep.Distro, 'docker') + ' start ' + AStep.Target, Output, 120000) = 0
        else if not Result then
          Result := RunCapture('docker start ' + AStep.Target, Output, 120000) = 0;
        AMessage := IfThen(Result, 'no ar', Trim(Output));
      end;
    eskCommand:
      begin
        Result := RunCapture('cmd.exe /c ' + AStep.Value, Output, CCmdTimeoutMs) = 0;
        AMessage := Trim(Output);
      end;
    eskTerminal:
      if AStep.Extra <> '' then
        Launch('cmd.exe', Format('/k cd /d "%s" && %s', [AStep.Target, AStep.Extra]))
      else
        Launch('cmd.exe', Format('/k cd /d "%s"', [AStep.Target]));
    eskEditor:
      Result := RunCapture(Format('cmd.exe /c code "%s"', [AStep.Value]), Output, 30000) = 0;
    eskOpen:
      OpenUrl(AStep.Value);
    eskWait:
      if AStep.Extra = '' then
        Sleep(StrToIntDef(AStep.Value, 1) * 1000)
      else
      begin
        Start := GetTickCount64;
        Result := False;
        while (GetTickCount64 - Start < CWaitPortMs) and not Result do
        begin
          Result := TcpReachable(AStep.Target, StrToInt(AStep.Extra), 1000);
          if not Result then
            Sleep(1000);
        end;
        Secs := (GetTickCount64 - Start) div 1000;
        AMessage := IfThen(Result, Format('abriu em %d s', [Secs]), 'não abriu em 60 s');
      end;
    eskStop:
      begin
        Result := RunCapture('cmd.exe /c ' + AStep.Value, Output, CCmdTimeoutMs) = 0;
        AMessage := Trim(Output);
      end;
  end;
end;

function RunStopStep(const AStep: TEnvStep; out AMessage: string): Boolean;
var
  Output: string;
begin
  case AStep.Kind of
    eskContainer:
      begin
        Result := RunCapture(EngineCli(AStep.Distro, 'podman') + ' stop ' + AStep.Target, Output, 120000) = 0;
        if not Result then
          Result := RunCapture(EngineCli(AStep.Distro, 'docker') + ' stop ' + AStep.Target, Output, 120000) = 0;
        AMessage := IfThen(Result, 'parado', Trim(Output));
      end;
    eskDistro:
      begin
        Result := RunCapture('wsl.exe --terminate ' + AStep.Value, Output, 60000) = 0;
        AMessage := IfThen(Result, 'distro desligada', Trim(Output));
      end;
  else
    Result := RunEnvStep(AStep, AMessage);
  end;
end;

{ HKCU\...\CapabilityAccessManager\ConsentStore\<webcam|microphone>: cada app
  tem LastUsedTimeStart e LastUsedTimeStop. Start > 0 e Stop = 0 = em uso. }
function AppsInMeeting: TArray<string>;
const
  Base = 'Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\';
  Devices: array[0..1] of string = ('webcam', 'microphone');

  function InUse(R: TRegistry; const AKey: string): Boolean;
  var
    Start, Stop: Int64;
  begin
    Result := False;
    if not R.OpenKeyReadOnly(AKey) then
      Exit;
    try
      if R.ValueExists('LastUsedTimeStart') and R.ValueExists('LastUsedTimeStop') then
      begin
        R.ReadBinaryData('LastUsedTimeStart', Start, SizeOf(Start));
        R.ReadBinaryData('LastUsedTimeStop', Stop, SizeOf(Stop));
        Result := (Start > 0) and (Stop = 0);
      end;
    finally
      R.CloseKey;
    end;
  end;

  procedure AddApp(const AName: string);
  var
    N: string;
  begin
    // NonPackaged guarda o caminho com # no lugar de \.
    N := ExtractFileName(StringReplace(AName, '#', '\', [rfReplaceAll]));
    if IndexText(N, Result) < 0 then
      Result := Result + [N];
  end;

var
  R: TRegistry;
  Names, Sub: TStringList;
  D, N, M: string;
begin
  Result := nil;
  R := TRegistry.Create(KEY_READ);
  Names := TStringList.Create;
  Sub := TStringList.Create;
  try
    R.RootKey := HKEY_CURRENT_USER;
    for D in Devices do
    begin
      if not R.OpenKeyReadOnly(Base + D) then
        Continue;
      R.GetKeyNames(Names);
      R.CloseKey;
      for N in Names do
        if SameText(N, 'NonPackaged') then
        begin
          if R.OpenKeyReadOnly(Base + D + '\NonPackaged') then
          begin
            R.GetKeyNames(Sub);
            R.CloseKey;
            for M in Sub do
              if InUse(R, Base + D + '\NonPackaged\' + M) then
                AddApp(M);
          end;
        end
        else if InUse(R, Base + D + '\' + N) then
          AddApp(N);
    end;
  finally
    Sub.Free;
    Names.Free;
    R.Free;
  end;
end;

end.
