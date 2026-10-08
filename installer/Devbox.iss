; Instalador por usuário do Devbox (não pede administrador), 64 bits.
; Gerado por ci/build-release.ps1, que passa a versão e a pasta do build:
;   ISCC /DAppVersion=0.3.0 /DBinDir=..\bin\Win64\Release /DOutDir=..\dist Devbox.iss
; Os arquivos de voz (Vosk, whisper, cancelamento de eco; ~200 MB) não vão no instalador:
; a tarefa "Baixar a voz" roda tools\voice-deps.ps1 no fim.

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef BinDir
  #define BinDir "..\bin\Win64\Release"
#endif
#ifndef OutDir
  #define OutDir "..\dist"
#endif

[Setup]
AppId={{8E2A6C41-3D7B-4F0A-9B65-1C4E7D2A9F13}
AppName=Devbox
AppVersion={#AppVersion}
AppVerName=Devbox {#AppVersion}
AppPublisher=Herlon Filgueira
AppPublisherURL=https://github.com/herlondf/devbox
DefaultDirName={localappdata}\Programs\Devbox
DefaultGroupName=Devbox
DisableProgramGroupPage=yes
DisableDirPage=yes
PrivilegesRequired=lowest
OutputDir={#OutDir}
OutputBaseFilename=Devbox-Setup-{#AppVersion}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
UninstallDisplayIcon={app}\Devbox.exe
UninstallDisplayName=Devbox
CloseApplications=force
RestartApplications=no
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
ShowLanguageDialog=auto

[Languages]
Name: "ptbr"; MessagesFile: "compiler:Languages\BrazilianPortuguese.isl"
Name: "en"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked
Name: "voice"; Description: "Baixar os arquivos de voz (~200 MB: Vosk, whisper e cancelamento de eco)"; GroupDescription: "Assistente de voz"; Flags: unchecked

[Files]
Source: "{#BinDir}\Devbox.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#BinDir}\DevboxHelper.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#BinDir}\sk4d.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#BinDir}\ocr.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#BinDir}\assets\assistant\*.json"; DestDir: "{app}\assets\assistant"; Flags: ignoreversion
Source: "..\tools\voice-deps.ps1"; DestDir: "{app}\tools"; Flags: ignoreversion

[Icons]
Name: "{userprograms}\Devbox"; Filename: "{app}\Devbox.exe"; Parameters: "-show"
Name: "{userdesktop}\Devbox"; Filename: "{app}\Devbox.exe"; Parameters: "-show"; Tasks: desktopicon

[Registry]
; O app grava aqui quando "Iniciar com o Windows" está ligado; sai junto na desinstalação.
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueName: "Devbox"; ValueType: none; Flags: uninsdeletevalue dontcreatekey

[Run]
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\tools\voice-deps.ps1"" -Out ""{app}\voice"""; StatusMsg: "Baixando os arquivos de voz..."; Flags: runhidden; Tasks: voice
Filename: "{app}\Devbox.exe"; Parameters: "-show"; Description: "{cm:LaunchProgram,Devbox}"; Flags: nowait postinstall skipifsilent
; Atualização pelo próprio app (/RELAUNCH=1): reabre o Devbox no fim da instalação silenciosa.
Filename: "{app}\Devbox.exe"; Parameters: "{code:RelaunchArgs}"; Flags: nowait skipifnotsilent; Check: RelaunchRequested

[UninstallRun]
Filename: "{sys}\taskkill.exe"; Parameters: "/F /IM Devbox.exe /FI ""USERNAME eq {username}"""; Flags: runhidden; RunOnceId: "StopDevbox"
Filename: "{sys}\taskkill.exe"; Parameters: "/F /IM DevboxHelper.exe /FI ""USERNAME eq {username}"""; Flags: runhidden; RunOnceId: "StopDevboxHelper"

[UninstallDelete]
; Arquivos de voz baixados depois (não vieram no instalador).
Type: filesandordirs; Name: "{app}\voice"

[Code]
function RelaunchRequested: Boolean;
begin
  Result := ExpandConstant('{param:RELAUNCH|0}') = '1';
end;

function RelaunchArgs(Param: string): string;
begin
  if ExpandConstant('{param:SHOW|0}') = '1' then
    Result := '-show'
  else
    Result := '';
end;
