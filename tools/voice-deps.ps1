# Baixa o que a voz do Devbox precisa para a pasta "voice" ao lado do exe (fora do git):
#   Vosk win64 + modelo pequeno pt (confere a frase de ativação, ~80 MB),
#   WebRTC AEC3 (livekit_ffi.dll: tira a voz do Devbox do microfone, ~25 MB),
#   whisper.cpp x64 (whisper-server, processo à parte) e o modelo base (pedido em texto, processador).
#   -Gpu: também o whisper.cpp com CUDA e o modelo large-v3-turbo (placa NVIDIA, ~1,2 GB).
# Roda de novo sem baixar o que já está lá.
param(
  [string]$Out = (Join-Path $PSScriptRoot '..\bin\Win64\Debug\voice'),
  [switch]$Gpu
)
$ErrorActionPreference = 'Stop'
$WhisperTag = 'b5454'
$VoskTag = 'v0.3.45'
$LiveKitVersion = '1.1.20'   # pacote Python da LiveKit: traz a livekit_ffi.dll (Apache 2.0)
New-Item -ItemType Directory -Force $Out | Out-Null
$Out = (Resolve-Path $Out).Path
$tmp = Join-Path $env:TEMP 'devbox-voice-deps'
New-Item -ItemType Directory -Force $tmp | Out-Null

function Get-File([string]$Url, [string]$Dest) {
  if (Test-Path $Dest) { Write-Host "ok (já existe) $(Split-Path $Dest -Leaf)"; return }
  Write-Host "baixando $(Split-Path $Dest -Leaf)..."
  Invoke-WebRequest -Uri $Url -OutFile "$Dest.part" -UseBasicParsing
  Move-Item "$Dest.part" $Dest -Force
}

# Copia só o servidor e as dlls de um pacote do whisper.cpp.
function Get-Whisper([string]$Package, [string]$Dest) {
  if (Test-Path (Join-Path $Dest 'whisper-server.exe')) { return }
  $zip = Join-Path $tmp "$Package-$WhisperTag.zip"
  Get-File "https://github.com/ggml-org/whisper.cpp/releases/download/$WhisperTag/$Package.zip" $zip
  $ex = Join-Path $tmp $Package
  Expand-Archive $zip $ex -Force
  $server = Get-ChildItem $ex -Recurse -Filter 'whisper-server.exe' | Select-Object -First 1
  if (-not $server) { throw "whisper-server.exe não veio em $Package" }
  New-Item -ItemType Directory -Force $Dest | Out-Null
  Copy-Item $server.FullName $Dest -Force
  Copy-Item (Join-Path $server.DirectoryName '*.dll') $Dest -Force
}

$wdir = Join-Path $Out 'whisper'
Get-Whisper 'whisper-bin-x64' $wdir
Get-File 'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base-q5_1.bin' (Join-Path $wdir 'ggml-base-q5_1.bin')

if ($Gpu) {
  Get-Whisper 'whisper-bin-win-cuda-12.4.0-x64' (Join-Path $Out 'whisper-cuda')
  Get-File 'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin' (Join-Path $wdir 'ggml-large-v3-turbo-q5_0.bin')
}

# Vosk
$vdir = Join-Path $Out 'vosk'
if (-not (Test-Path (Join-Path $vdir 'libvosk.dll'))) {
  $zip = Join-Path $tmp "vosk-win64-$VoskTag.zip"
  Get-File "https://github.com/alphacep/vosk-api/releases/download/$VoskTag/vosk-win64-$($VoskTag.TrimStart('v')).zip" $zip
  $ex = Join-Path $tmp "vosk-$VoskTag"
  Expand-Archive $zip $ex -Force
  New-Item -ItemType Directory -Force $vdir | Out-Null
  Get-ChildItem $ex -Recurse -Filter '*.dll' | Copy-Item -Destination $vdir -Force
}
if (-not (Test-Path (Join-Path $vdir 'model\final.mdl'))) {
  $zip = Join-Path $tmp 'vosk-model-small-pt-0.3.zip'
  Get-File 'https://alphacephei.com/vosk/models/vosk-model-small-pt-0.3.zip' $zip
  $ex = Join-Path $tmp 'vosk-model'
  Expand-Archive $zip $ex -Force
  $model = Get-ChildItem $ex -Recurse -Filter 'final.mdl' | Select-Object -First 1
  New-Item -ItemType Directory -Force (Join-Path $vdir 'model') | Out-Null
  Copy-Item (Join-Path $model.DirectoryName '*') (Join-Path $vdir 'model') -Recurse -Force
}

# WebRTC AEC3: a dll vem dentro do wheel win_amd64 do pacote livekit no PyPI.
$adir = Join-Path $Out 'aec'
if (-not (Test-Path (Join-Path $adir 'livekit_ffi.dll'))) {
  $info = Invoke-RestMethod "https://pypi.org/pypi/livekit/$LiveKitVersion/json"
  $wheel = $info.urls | Where-Object { $_.filename -like '*win_amd64.whl' } | Select-Object -First 1
  if (-not $wheel) { throw "livekit $LiveKitVersion sem wheel win_amd64" }
  $zip = Join-Path $tmp "livekit-$LiveKitVersion.zip"
  Get-File $wheel.url $zip
  $ex = Join-Path $tmp 'livekit'
  Expand-Archive $zip $ex -Force
  New-Item -ItemType Directory -Force $adir | Out-Null
  Get-ChildItem $ex -Recurse -Filter 'livekit_ffi.dll' | Select-Object -First 1 | Copy-Item -Destination $adir -Force
}

Write-Host "pronto em $Out"
Get-ChildItem $Out -Directory | ForEach-Object {
  [pscustomobject]@{ pasta = $_.Name; MB = [math]::Round((Get-ChildItem $_.FullName -Recurse -File | Measure-Object Length -Sum).Sum / 1MB) }
} | Format-Table -AutoSize
