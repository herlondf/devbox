<#
.SYNOPSIS
    Compila o Devbox em Release (Win64), roda o self-check e gera o instalador por usuário.
.DESCRIPTION
    Compila pelo delphi-build (DevTools\Delphi-Build três pastas acima do repositório, ou DEVBOX_DELPHI_BUILD).
    Precisa do Inno Setup 6. Saída: dist\Devbox-Setup-<versão>.exe
    Assinatura (opcional): DEVBOX_SIGN_THUMBPRINT (certificado no repositório do usuário) ou
    DEVBOX_SIGN_PFX + DEVBOX_SIGN_PASSWORD. Sem nenhum, sai sem assinar (o Smart App Control do
    Windows pode barrar o exe sem assinatura).
.EXAMPLE
    pwsh ci/build-release.ps1
#>
#Requires -Version 7.0
[CmdletBinding()]
param(
    [string]$DelphiBuild = $(if ($env:DEVBOX_DELPHI_BUILD) { $env:DEVBOX_DELPHI_BUILD } else { Join-Path $PSScriptRoot '..\..\..\DevTools\Delphi-Build\delphi-build.ps1' }),
    [switch]$SkipTests
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

function Step($text) { Write-Host "==> $text" -ForegroundColor Cyan }

# Versão: única fonte é AppVersion em Devbox.Model.pas.
$model = Get-Content (Join-Path $root 'src\Devbox.Model.pas') -Raw
$version = [regex]::Match($model, "AppVersion\s*=\s*'([^']+)'").Groups[1].Value
if (-not $version) { throw 'AppVersion não encontrado em src\Devbox.Model.pas' }
Step "Devbox $version"
if (-not (Test-Path $DelphiBuild)) { throw "delphi-build não encontrado: $DelphiBuild (use -DelphiBuild ou DEVBOX_DELPHI_BUILD)" }

function Build($alias, $cfg) {
    Step "build $alias ($cfg, Win64)"
    $raw = pwsh -NoProfile -File $DelphiBuild build -Project $alias -BuildConfig $cfg -Platform Win64 -Raw 2>&1 | Out-String
    $result = $raw | ConvertFrom-Json
    if (-not $result.success) {
        $result.errors | Select-Object -First 20 | ForEach-Object { Write-Host "    $($_.file):$($_.line) $($_.message)" -ForegroundColor Red }
        throw "build de $alias falhou"
    }
    Write-Host "    ok, $($result.warning_count) aviso(s)"
}

Build 'devbox' 'Release'
Build 'devbox-helper' 'Release'
if (-not $SkipTests) {
    Build 'devbox-tests' 'Debug'
    Step 'self-check'
    $out = & (Join-Path $root 'bin\tests\Win64\Debug\DevboxTests.exe') 2>&1
    $out | Select-Object -Last 2 | ForEach-Object { Write-Host "    $_" }
    if (($out | Select-Object -Last 1) -notmatch 'TUDO OK') { throw 'self-check falhou' }
}

$bin = Join-Path $root 'bin\Win64\Release'

# Assinatura de código: Windows SDK signtool, SHA-256 com carimbo de tempo.
function Sign($file) {
    if (-not ($env:DEVBOX_SIGN_THUMBPRINT -or $env:DEVBOX_SIGN_PFX)) { return }
    $signtool = Get-ChildItem 'C:\Program Files (x86)\Windows Kits\10\bin' -Recurse -Filter signtool.exe -ErrorAction SilentlyContinue |
        Where-Object FullName -like '*\x64\*' | Sort-Object FullName | Select-Object -Last 1 -ExpandProperty FullName
    if (-not $signtool) { throw 'signtool.exe não encontrado (instale o Windows SDK)' }
    $signArgs = @('sign', '/fd', 'SHA256', '/tr', 'http://timestamp.digicert.com', '/td', 'SHA256')
    if ($env:DEVBOX_SIGN_THUMBPRINT) { $signArgs += @('/sha1', $env:DEVBOX_SIGN_THUMBPRINT) }
    else { $signArgs += @('/f', $env:DEVBOX_SIGN_PFX, '/p', $env:DEVBOX_SIGN_PASSWORD) }
    & $signtool @signArgs $file | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "assinatura falhou: $file" }
    Write-Host "    assinado: $(Split-Path $file -Leaf)"
}
if ($env:DEVBOX_SIGN_THUMBPRINT -or $env:DEVBOX_SIGN_PFX) {
    Step 'assinatura'
    Sign (Join-Path $bin 'Devbox.exe')
    Sign (Join-Path $bin 'DevboxHelper.exe')
} else {
    Write-Host '    sem certificado (DEVBOX_SIGN_THUMBPRINT/DEVBOX_SIGN_PFX): sai sem assinatura' -ForegroundColor DarkYellow
}

# Inno Setup: instalado por usuário (winget --scope user) ou no PATH.
$iscc = @(
    (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe'),
    'C:\Program Files (x86)\Inno Setup 6\ISCC.exe'
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $iscc) { $iscc = (Get-Command ISCC.exe -ErrorAction SilentlyContinue).Source }
if (-not $iscc) { throw 'ISCC.exe não encontrado. Instale: winget install JRSoftware.InnoSetup --scope user' }

Step 'instalador'
$dist = Join-Path $root 'dist'
New-Item -ItemType Directory -Force $dist | Out-Null
& $iscc /Q "/DAppVersion=$version" "/DBinDir=$bin" "/DOutDir=$dist" (Join-Path $root 'installer\Devbox.iss')
if ($LASTEXITCODE -ne 0) { throw "ISCC saiu com $LASTEXITCODE" }

$setup = Join-Path $dist "Devbox-Setup-$version.exe"
if (-not (Test-Path $setup)) { throw "instalador não gerado: $setup" }
Sign $setup
Step ("pronto: {0} ({1:N1} MB)" -f $setup, ((Get-Item $setup).Length / 1MB))

if ($env:GITHUB_OUTPUT) {
    "version=$version" | Add-Content $env:GITHUB_OUTPUT
    "setup=$setup" | Add-Content $env:GITHUB_OUTPUT
}
