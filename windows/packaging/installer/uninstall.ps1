<#
.SYNOPSIS
Removes TablePro installed by install.ps1: the program folder, the Start menu shortcut and the uninstall entry.

.DESCRIPTION
Settings > Apps > Installed apps runs this script. Your connections, settings and history in
%LOCALAPPDATA%\TablePro and the passwords in Windows Credential Manager stay, so a later install picks them up.
Delete that folder yourself to remove them too.
#>
[CmdletBinding()]
param([switch]$Quiet)

Set-StrictMode -Version 3
$ErrorActionPreference = 'Stop'

$installDir = [System.IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
$uninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\TablePro'

# The folder this script is in is about to go; nothing may keep it open.
Set-Location -LiteralPath $env:TEMP

$running = @(Get-Process -Name 'TablePro' -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -and $_.Path.StartsWith($installDir + '\', [System.StringComparison]::OrdinalIgnoreCase) })
if ($running.Count -gt 0) {
    $message = 'TablePro is running. Close it, then uninstall again.'
    if (-not $Quiet) {
        Add-Type -AssemblyName PresentationFramework
        [void][System.Windows.MessageBox]::Show($message, 'Uninstall TablePro')
    }
    Write-Error $message
    exit 1
}

$shortcut = Join-Path ([Environment]::GetFolderPath('Programs')) 'TablePro.lnk'
if (Test-Path -LiteralPath $shortcut) { Remove-Item -LiteralPath $shortcut -Force }

# Only the entry that points at this folder is removed, so uninstalling a stray copy leaves the real one registered.
$entry = Get-ItemProperty -Path $uninstallKey -Name 'InstallLocation' -ErrorAction SilentlyContinue
$location = if ($entry) { $entry.InstallLocation } else { $null }
if ($location -and ([System.IO.Path]::GetFullPath($location).TrimEnd('\') -ieq $installDir)) {
    Remove-Item -Path $uninstallKey -Recurse -Force
}

Remove-Item -LiteralPath $installDir -Recurse -Force

if (-not $Quiet) {
    Write-Host "TablePro is uninstalled. Your data is still in $env:LOCALAPPDATA\TablePro."
}
