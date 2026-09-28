<#
    Reads config.local.json (copy config.example.json and fill it in), writes
    the gitignored resources-personal/ overlay, and builds BGGlance.prg with
    personal.jungle -- the sideload variant with your server URL and token
    baked in. See README.md for the generic (store) build, which ships empty
    defaults and is configured from the Garmin Connect phone app instead.

    Usage: powershell -ExecutionPolicy Bypass -File tools\build.ps1 [config.local.json]
#>
[CmdletBinding()]
param(
    [string] $Config = "config.local.json"
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

if (-not (Test-Path $Config)) {
    Write-Error "Missing $Config -- copy config.example.json to config.local.json and fill it in."
    exit 1
}

python tools/render_overlay.py $Config
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$cfg = Get-Content $Config -Raw | ConvertFrom-Json

monkeyc -d $cfg.device -f personal.jungle -o BGGlance.prg -y $cfg.developerKey
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
Write-Output "Built BGGlance.prg for $($cfg.device)"
