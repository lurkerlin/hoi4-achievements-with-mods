#Requires -Version 5.1
<#
.SYNOPSIS
  Build a source release zip for distribution (GitHub Releases / manual sharing).

.DESCRIPTION
  The zip contains scripts, docs, README and the launcher. It never contains
  binaries, game backups, or a patched exe.

.PARAMETER Version
  Version label embedded in the zip name. Default 1.0.0.

.PARAMETER OutDir
  Output directory. Default: <repo>/dist.
#>
[CmdletBinding()]
param(
    [string]$Version = '1.0.0',
    [string]$OutDir
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')

$root = Split-Path -Parent $PSScriptRoot
if (-not $OutDir) { $OutDir = Join-Path $root 'dist' }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$zip = Join-Path $OutDir "hoi4-achievements-with-mods-v$Version.zip"
if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }

$staging = Join-Path $env:TEMP ("hoi4-release-{0}" -f [guid]::NewGuid().ToString('N'))
$pkg = Join-Path $staging 'hoi4-achievements-with-mods'
New-Item -ItemType Directory -Force -Path $pkg | Out-Null

$items = @('README.md', 'LICENSE', '.gitattributes', '.gitignore', 'scripts', 'docs', '启动.bat')
foreach ($item in $items) {
    $src = Join-Path $root $item
    if (-not (Test-Path -LiteralPath $src)) { Write-Warning "skip missing: $item"; continue }
    Copy-Item -LiteralPath $src -Destination $pkg -Recurse -Force
}

try {
    Compress-Archive -Path $pkg -DestinationPath $zip -Force
} finally {
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
}

$sha = Get-Sha256Hex -Path $zip
$size = (Get-Item -LiteralPath $zip).Length
Write-Host "Created: $zip"
Write-Host ("Size:    {0:N0} bytes" -f $size)
Write-Host "SHA256:  $sha"
