# APIKOmicReader setup: copies the plugin to a USB-connected Kindle.
# Run it through unsetup.bat.

$ErrorActionPreference = 'Stop'

$Root       = Split-Path -Parent $PSScriptRoot
$PluginName = 'APIKOmicReader.koplugin'
$PluginSrc  = Join-Path $Root $PluginName

function Step($text) { Write-Host ''; Write-Host "== $text" -ForegroundColor Cyan }
function Ok($text)   { Write-Host "   OK  $text" -ForegroundColor Green }
function Warn($text) { Write-Host "   !!  $text" -ForegroundColor Yellow }
function Fail($text) { Write-Host "   XX  $text" -ForegroundColor Red; exit 1 }

if (-not (Test-Path (Join-Path $PluginSrc 'main.lua'))) {
    Fail "Plugin folder not found at $PluginSrc"
}

Step 'Installing the plugin on the Kindle'

function Find-DrivePlugins {
    foreach ($d in Get-PSDrive -PSProvider FileSystem) {
        $p = Join-Path $d.Root 'koreader\plugins'
        if (Test-Path $p) { return $p }
    }
    return $null
}

# Kindles from 2021 on (including the 11th gen) connect over MTP, without a drive letter.
function Find-MtpPlugins {
    $shell = New-Object -ComObject Shell.Application
    foreach ($device in $shell.NameSpace(17).Items()) {
        if ($device.Name -notmatch 'Kindle') { continue }
        foreach ($storage in $device.GetFolder.Items()) {
            $koreader = $storage.GetFolder.Items() | Where-Object { $_.Name -eq 'koreader' } | Select-Object -First 1
            if (-not $koreader) { continue }
            $plugins = $koreader.GetFolder.Items() | Where-Object { $_.Name -eq 'plugins' } | Select-Object -First 1
            if ($plugins) { return $plugins.GetFolder }
        }
    }
    return $null
}

$installed = $false
while (-not $installed) {
    $drivePlugins = Find-DrivePlugins
    if ($drivePlugins) {
        Remove-Item (Join-Path $drivePlugins $PluginName) -Recurse -Force -ErrorAction SilentlyContinue
        Copy-Item $PluginSrc -Destination $drivePlugins -Recurse
        Ok "Copied to $drivePlugins"
        $installed = $true
        break
    }

    $mtpPlugins = $null
    try { $mtpPlugins = Find-MtpPlugins } catch { $mtpPlugins = $null }
    if ($mtpPlugins) {
        Write-Host '   Copying over USB. If Windows asks about existing files, choose "Replace" for all.'
        $mtpPlugins.CopyHere($PluginSrc, 16)
        Read-Host '   Press Enter once the Windows copy window has closed'
        Ok 'Copied to the Kindle.'
        $installed = $true
        break
    }

    Warn 'No Kindle with KOReader found.'
    $answer = Read-Host '   Connect the Kindle by USB and press Enter to retry, or type S to skip'
    if ($answer -match '^[sS]') {
        Warn "Skipped. To install by hand, copy this folder to koreader/plugins/ on the Kindle:`n       $PluginSrc"
        break
    }
}

Step 'Done'
Write-Host '   On the Kindle: eject and unplug it, restart KOReader, connect to Wi-Fi, then'
Write-Host '   Tools > APIKOmicReader > Settings > Test connection.'
