<#
    Copy BGGlance.prg onto a USB-connected Venu over MTP.

    The watch is NOT a drive letter. It mounts as an MTP "portable device", so
    there is no path to cp/copy to and Get-CimInstance Win32_LogicalDisk never
    shows it even when it is plugged in and working. The only programmatic route
    is the Shell COM automation that Explorer itself uses, which is what this
    does -- the scripted equivalent of dragging the file into GARMIN\Apps\.

    Usage (from the repo root, watch plugged in and awake):

        powershell -ExecutionPolicy Bypass -File tools\sideload.ps1

    Exit 0 only if the copy landed and the on-watch size matches the source.
#>

[CmdletBinding()]
param(
    # Defaults to ..\BGGlance.prg, resolved in the body: $PSScriptRoot is NOT
    # bound while parameter defaults are evaluated, so using it here silently
    # yields an empty string and Join-Path throws.
    [string] $Prg,
    # Substring match: the device shows up as "Venu 4" (or similar per model).
    [string] $DeviceMatch = 'Venu'
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($Prg)) {
    $here = Split-Path -Parent $MyInvocation.MyCommand.Path
    $Prg = Join-Path $here '..\BGGlance.prg'
}
if (-not (Test-Path $Prg)) { Write-Error "PRG not found: $Prg"; exit 1 }
# .ProviderPath, NOT .Path: for a UNC source Resolve-Path returns the
# provider-qualified form ("Microsoft.PowerShell.Core\FileSystem::\\host\share\...")
# which does not start with "\\", so the remote-source test below silently
# reads as local and the staging step never runs.
$Prg = (Resolve-Path -LiteralPath $Prg).ProviderPath
$srcSize = (Get-Item $Prg).Length
Write-Output "source : $Prg ($srcSize bytes)"

# Stage a remote source locally before pushing it to the watch. Two reasons:
# the shell copy engine is unreliable driving an MTP target straight from a
# UNC/VPN path (it can stall, or half-write with no error), and the PRG has the
# watchToken baked in, so the fewer places it travels the better. Removed again
# in the finally block at the bottom, whatever happens in between.
#
# NOTE the staging dir: the file must keep its exact name, because that name is
# what lands in GARMIN\Apps and what the watch loads. Staging to
# "$env:TEMP\sideload-BGGlance.prg" would install an app called
# sideload-BGGlance.prg alongside the old one and change nothing on the wrist.
$stageDir = $null
$item = Get-Item -LiteralPath $Prg
$isRemote = $Prg.StartsWith('\\') -or
            ($null -ne $item.PSDrive -and $null -ne $item.PSDrive.DisplayRoot)
if ($isRemote) {
    $stageDir = Join-Path $env:TEMP ('sideload-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $stageDir | Out-Null
    $staged = Join-Path $stageDir ([IO.Path]::GetFileName($Prg))
    Copy-Item -LiteralPath $Prg -Destination $staged -Force
    $stagedSize = (Get-Item -LiteralPath $staged).Length
    if ($stagedSize -ne $srcSize) {
        Remove-Item -LiteralPath $stageDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Error "Staged copy is $stagedSize bytes, expected $srcSize - the network read was truncated."
        exit 1
    }
    Write-Output "staged : $staged ($stagedSize bytes, matches source)"
    $Prg = $staged
}

# The staged PRG carries the baked-in watchToken, so it does not get to linger
# in %TEMP% after the copy. Called on every exit path below.
function Remove-StageDir {
    if ($null -ne $script:stageDir -and (Test-Path $script:stageDir)) {
        Remove-Item -LiteralPath $script:stageDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Output "cleaned: removed staging copy from %TEMP%"
    }
}

# The Build row on the watch is the only LOCAL proof the overwrite took, so read
# the version this PRG was built from instead of hardcoding one. The literal
# "v7" that used to be printed here went stale nine builds ago, which meant the
# check told you to confirm a version the source had not produced since July --
# a failed flash would have sailed through it.
$expectedVersion = $null
try {
    $srcFile = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) '..\source\BGData.mc'
    if (Test-Path $srcFile) {
        $m = Select-String -Path $srcFile -Pattern 'BUILD_VERSION\s*=\s*"([^"]+)"' | Select-Object -First 1
        if ($null -ne $m) { $expectedVersion = $m.Matches[0].Groups[1].Value }
    }
} catch {}

$shell = New-Object -ComObject Shell.Application

# 17 = ssfDRIVES ("This PC"), which is where portable devices appear.
$pc = $shell.NameSpace(17)
if ($null -eq $pc) { Write-Error 'Cannot open the This PC shell namespace.'; exit 1 }

$device = $pc.Items() | Where-Object { $_.Name -like "*$DeviceMatch*" } | Select-Object -First 1
if ($null -eq $device) {
    Write-Output ''
    Write-Output "No portable device matching '*$DeviceMatch*' in the shell view. Saw:"
    foreach ($i in $pc.Items()) { Write-Output ("  {0}  [{1}]" -f $i.Name, $i.Type) }

    # The shell view alone cannot tell three very different problems apart, so
    # ask the driver layer directly. Get-PnpDevice reports REMEMBERED devices
    # too (Present=$false, CM_PROB_PHANTOM), which is what a watch that was
    # plugged in last week looks like -- indistinguishable, from the shell
    # namespace, from one that is plugged in but not enumerating.
    Write-Output ''
    Write-Output '--- driver-layer check ---'
    $anyPresent = $null
    $ghost = $null
    try {
        $wpd = Get-PnpDevice -Class WPD -ErrorAction Stop
        $anyPresent = $wpd | Where-Object { $_.Present }
        $ghost = $wpd | Where-Object { $_.FriendlyName -like "*$DeviceMatch*" -and -not $_.Present }
    } catch {
        Write-Output "  (Get-PnpDevice unavailable: $($_.Exception.Message))"
    }

    if ($null -ne $ghost) {
        Write-Output "  '$($ghost[0].FriendlyName)' is KNOWN to Windows but NOT connected"
        Write-Output '  (Present=False / CM_PROB_PHANTOM = a record of a past connection).'
        Write-Output '  => The watch is not plugged in. Connect it and re-run.'
    } elseif ($null -eq $anyPresent -or $anyPresent.Count -eq 0) {
        Write-Output '  No portable device is present at the driver layer either.'
        Write-Output '  => Not plugged in, or the cable is charge-only (a very common'
        Write-Output '     failure -- try the cable you know syncs, not a spare).'
    } else {
        Write-Output '  A portable device IS present at the driver layer but did not'
        Write-Output '  appear in the shell view above:'
        foreach ($d in $anyPresent) { Write-Output ("    {0}" -f $d.FriendlyName) }
        Write-Output '  => Wake the watch and give it a few seconds to finish the MTP'
        Write-Output '     handshake, then re-run.'
    }

    # Elevation is worth calling out whatever the cause: an elevated shell has
    # its own session view, which drops mapped network drives and can hide MTP
    # devices entirely. If a mapped network drive you expect is missing from
    # the drive list above, that is why.
    $idn = [Security.Principal.WindowsIdentity]::GetCurrent()
    $prin = New-Object Security.Principal.WindowsPrincipal($idn)
    if ($prin.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Output ''
        Write-Output '  NOTE: this shell is ELEVATED. Run it as a normal user --'
        Write-Output '  elevated sessions lose mapped drives and may not see MTP at all.'
    }
    Remove-StageDir
    exit 1
}
Write-Output "device : $($device.Name)"

# Walk down to GARMIN\Apps. The Venu exposes one storage root whose name varies
# by firmware ("Internal Storage" / "Primary"), so descend by structure rather
# than by a hardcoded label: take the first child folder that contains GARMIN.
function Get-Child([object] $folder, [string] $name) {
    if ($null -eq $folder) { return $null }
    return $folder.Items() | Where-Object { $_.Name -eq $name } | Select-Object -First 1
}

$root = $device.GetFolder
$garmin = Get-Child $root 'GARMIN'
if ($null -eq $garmin) {
    foreach ($storage in $root.Items()) {
        if (-not $storage.IsFolder) { continue }
        $candidate = Get-Child $storage.GetFolder 'GARMIN'
        if ($null -ne $candidate) { $garmin = $candidate; break }
    }
}
if ($null -eq $garmin) {
    Write-Output 'GARMIN folder not found on the device.'
    Remove-StageDir
    exit 1
}

$apps = Get-Child $garmin.GetFolder 'Apps'
if ($null -eq $apps) {
    Write-Output 'GARMIN\Apps not found on the device.'
    Remove-StageDir
    exit 1
}
$appsFolder = $apps.GetFolder
Write-Output 'target : GARMIN\Apps'

$leaf = Split-Path $Prg -Leaf
$before = $appsFolder.Items() | Where-Object { $_.Name -eq $leaf } | Select-Object -First 1
if ($null -ne $before) { Write-Output "note   : overwriting an existing $leaf on the watch" }

# 16 = "Yes to all" on any overwrite prompt. MTP providers are free to ignore
# the flags, so a confirmation dialog can still appear -- if one does, accept it.
$appsFolder.CopyHere($Prg, 16)

# CopyHere is asynchronous with no completion handle: poll until the on-watch
# size matches the source rather than sleeping a guessed interval.
$deadline = (Get-Date).AddSeconds(90)
$landed = $null
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 750
    $entry = $appsFolder.Items() | Where-Object { $_.Name -eq $leaf } | Select-Object -First 1
    if ($null -eq $entry) { continue }
    # ExtendedProperty('System.Size') is the only reliable size on MTP.
    $size = $null
    try { $size = $entry.ExtendedProperty('System.Size') } catch {}
    if ($null -ne $size -and [int64] $size -eq [int64] $srcSize) { $landed = $entry; break }
}

if ($null -eq $landed) {
    Write-Output ''
    Write-Output "Copy did not confirm within 90s. Check the watch for a prompt, then verify GARMIN\Apps\$leaf by hand."
    Remove-StageDir
    exit 1
}
Remove-StageDir

Write-Output "result : OK -- $leaf on watch matches source ($srcSize bytes)"
Write-Output ''
Write-Output 'Now unplug and OPEN THE WIDGET ONCE straight away: registerForTemporalEvent'
Write-Output 'runs only from getInitialView / getGlanceView, so a freshly copied PRG has'
Write-Output 'no background service at all until it has been opened.'
if ($null -ne $expectedVersion) {
    Write-Output "Then swipe up to the menu -- the Build row MUST read `"$expectedVersion - personal`"."
    Write-Output 'If it reads an older version the overwrite did not take: delete the app'
    Write-Output 'on the watch and re-run.'
} else {
    Write-Output 'Then swipe up to the menu and check the Build row against BUILD_VERSION in'
    Write-Output 'source\BGData.mc. If it is older, the overwrite did not take: delete the app'
    Write-Output 'on the watch and re-run.'
}
exit 0
