<#
.SYNOPSIS
    Publica uma release do Devbox: gera o instalador nesta máquina e cria a release no GitHub.
.DESCRIPTION
    Sem runner self-hosted (o repositório é público: runner próprio em repositório público
    deixa código de terceiros rodar na máquina). Passos:
      1. confere árvore limpa, branch enviado e tag nova (v<AppVersion>);
      2. roda ci/build-release.ps1 (Release Win64, self-check, instalador);
      3. cria e envia a tag e publica a release com o instalador e as notas do CHANGELOG.
    O atualizador do Devbox procura Devbox-Setup-*.exe na última release de herlondf/devbox.
.EXAMPLE
    pwsh ci/release.ps1
#>
#Requires -Version 7.0
[CmdletBinding()]
param(
    [string]$Repo = 'herlondf/devbox'
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Set-Location $root

function Step($text) { Write-Host "==> $text" -ForegroundColor Cyan }

$model = Get-Content (Join-Path $root 'src\Devbox.Model.pas') -Raw
$version = [regex]::Match($model, "AppVersion\s*=\s*'([^']+)'").Groups[1].Value
$tag = "v$version"
if (git status --porcelain) { throw 'Há mudanças sem commit. Faça o commit antes da release.' }
git fetch origin --tags --quiet
if (git tag --list $tag) { throw "A tag $tag já existe. Suba AppVersion em src\Devbox.Model.pas." }
$branch = git rev-parse --abbrev-ref HEAD
git push origin $branch --quiet

Step 'build e instalador'
& (Join-Path $PSScriptRoot 'build-release.ps1')
$setup = Join-Path $root "dist\Devbox-Setup-$version.exe"
if (-not (Test-Path $setup)) { throw "instalador não gerado: $setup" }

# Notas = seção da versão no CHANGELOG.
$log = Get-Content (Join-Path $root 'docs\CHANGELOG.md') -Raw
$m = [regex]::Match($log, "(?s)## \[$([regex]::Escape($version))\][^\n]*\n(.*?)(?=\n## \[|\z)")
$notes = if ($m.Success) { $m.Groups[1].Value.Trim() } else { "Devbox $version" }
$notesFile = Join-Path ([IO.Path]::GetTempPath()) "devbox-notes-$version.md"
$notes | Set-Content $notesFile -Encoding utf8

Step "tag $tag e release"
git tag $tag
git push origin $tag --quiet
gh release create $tag $setup --repo $Repo --title "Devbox $version" --notes-file $notesFile
Step "publicada: https://github.com/$Repo/releases/tag/$tag"
