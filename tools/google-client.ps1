# Gera o include com o cliente OAuth do Google embutido no Devbox.
# Lê GOOGLE_OAUTH_CLIENT_ID e GOOGLE_OAUTH_CLIENT_SECRET de um arquivo fora do repo
# (padrão: Vault\Devbox.md três pastas acima do repositório; outro caminho em DEVBOX_VAULT) ou das variáveis de
# ambiente de mesmo nome (CI). Sem eles, gera constantes vazias: o app pede o cliente
# na tela Contas Google. O include sai na pasta de build (dcu), que não vai para o git.
param([Parameter(Mandatory)][string]$Out)

$id = $env:GOOGLE_OAUTH_CLIENT_ID
$secret = $env:GOOGLE_OAUTH_CLIENT_SECRET
$vault = if ($env:DEVBOX_VAULT) { $env:DEVBOX_VAULT } else { Join-Path $PSScriptRoot '..\..\..\Vault\Devbox.md' }
if ((-not $id) -and (Test-Path $vault)) {
  foreach ($line in Get-Content $vault) {
    if ($line -match '^\s*GOOGLE_OAUTH_CLIENT_ID\s*=\s*(\S+)') { $id = $Matches[1] }
    if ($line -match '^\s*GOOGLE_OAUTH_CLIENT_SECRET\s*=\s*(\S+)') { $secret = $Matches[1] }
  }
}

function Pas([string]$s) { "'" + ($s -replace "'", "''") + "'" }

$text = @"
// Gerado por tools\google-client.ps1 a cada build (nao editar nem versionar).
const
  CEmbeddedGoogleClientId = $(Pas $id);
  CEmbeddedGoogleClientSecret = $(Pas $secret);
"@
New-Item -ItemType Directory -Force (Split-Path $Out) | Out-Null
# Só regrava quando muda: não força recompilar a unit à toa.
if (-not (Test-Path $Out) -or (Get-Content $Out -Raw) -ne $text) {
  Set-Content -Path $Out -Value $text -NoNewline -Encoding utf8
}
if ($id) { Write-Host 'google-client: cliente embutido' } else { Write-Host 'google-client: sem cliente embutido' }
