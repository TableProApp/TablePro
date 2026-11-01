<#
.SYNOPSIS
Installs TablePro for the current user, or replaces an installed copy with this one.

.DESCRIPTION
Copies the folder this script is in to the install folder, adds TablePro to the Start menu and registers it under
Settings > Apps > Installed apps so it can be uninstalled from there. It needs no administrator rights.

TablePro runs this script to apply an update: it passes its own folder and process id, quits, and the script waits
for it to end before it swaps the files and starts the new version.

Your connections, settings and history live in %LOCALAPPDATA%\TablePro and are never touched.

.EXAMPLE
.\install.ps1 -Launch
#>
[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'Programs\TablePro'),
    [int]$WaitForProcessId = 0,
    [switch]$Launch,
    [switch]$Quiet
)

# Windows PowerShell 5.1 runs this script, so it keeps to what 5.1 has.
Set-StrictMode -Version 3
$ErrorActionPreference = 'Stop'

$exeName = 'TablePro.exe'
$uninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\TablePro'
$source = [System.IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
$target = [System.IO.Path]::GetFullPath($InstallDir).TrimEnd('\')

function Write-Step([string]$Message) {
    if (-not $Quiet) { Write-Host $Message }
}

function Wait-ForExit([int]$ProcessId) {
    $process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if ($process -and -not $process.WaitForExit(120000)) {
        throw "TablePro (process $ProcessId) is still running. Close it and run the update again."
    }
}

# Retries a move a few times: antivirus scanners and Explorer briefly hold files that were just written.
function Move-WithRetry([string]$From, [string]$To) {
    for ($attempt = 1; ; $attempt++) {
        try {
            [System.IO.Directory]::Move($From, $To)
            return
        }
        catch [System.IO.IOException] {
            if ($attempt -ge 10) { throw }
            Start-Sleep -Milliseconds 500
        }
    }
}

if (-not (Test-Path -LiteralPath (Join-Path $source $exeName))) {
    throw "$exeName is not next to this script. Run install.ps1 from the unzipped TablePro folder."
}

if ($WaitForProcessId -gt 0) {
    Write-Step 'Waiting for TablePro to close...'
    Wait-ForExit $WaitForProcessId
}

$running = @(Get-Process -Name 'TablePro' -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -and $_.Path.StartsWith($target + '\', [System.StringComparison]::OrdinalIgnoreCase) })
if ($running.Count -gt 0) {
    throw "TablePro is running from $target. Close it and run the installer again."
}

if ($source -ine $target) {
    # The folder is replaced as a whole, so it must hold nothing but an earlier TablePro.
    if (Test-Path -LiteralPath $target) {
        $hasFiles = $null -ne (Get-ChildItem -LiteralPath $target -Force | Select-Object -First 1)
        if ($hasFiles -and -not (Test-Path -LiteralPath (Join-Path $target $exeName))) {
            throw "$target holds other files. Choose an empty folder with -InstallDir."
        }
    }

    Write-Step "Installing to $target"
    $staging = "$target.new"
    $backup = "$target.old"
    foreach ($leftover in $staging, $backup) {
        if (Test-Path -LiteralPath $leftover) { Remove-Item -LiteralPath $leftover -Recurse -Force }
    }

    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
    Copy-Item -LiteralPath $source -Destination $staging -Recurse

    # Swapping whole folders means a failure leaves either the old copy or the new one, never a mix of both.
    $hadPrevious = Test-Path -LiteralPath $target
    if ($hadPrevious) { Move-WithRetry $target $backup }
    try {
        Move-WithRetry $staging $target
    }
    catch {
        if ($hadPrevious) { Move-WithRetry $backup $target }
        throw
    }

    if ($hadPrevious) {
        Remove-Item -LiteralPath $backup -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$exe = Join-Path $target $exeName
$info = (Get-Item -LiteralPath $exe).VersionInfo
# The product version is the informational version, such as 0.2.0-beta.1+3f2a9c1; the part after + is the commit.
$version = ($info.ProductVersion -split '\+')[0]

Write-Step 'Adding TablePro to the Start menu'
$shortcutPath = Join-Path ([Environment]::GetFolderPath('Programs')) 'TablePro.lnk'
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = $exe
$shortcut.WorkingDirectory = $target
$shortcut.IconLocation = "$exe,0"
$shortcut.Description = 'TablePro database client'
$shortcut.Save()
[void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell)

Write-Step 'Registering the uninstaller'
$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$uninstall = "`"$powershell`" -NoProfile -ExecutionPolicy Bypass -File `"$target\uninstall.ps1`""
$sizeKb = [int]((Get-ChildItem -LiteralPath $target -Recurse -File | Measure-Object -Property Length -Sum).Sum / 1KB)
New-Item -Path $uninstallKey -Force | Out-Null
$values = [ordered]@{
    DisplayName          = 'TablePro'
    DisplayVersion       = $version
    Publisher            = 'TablePro'
    DisplayIcon          = "$exe,0"
    InstallLocation      = $target
    InstallDate          = (Get-Date -Format 'yyyyMMdd')
    UninstallString      = $uninstall
    QuietUninstallString = "$uninstall -Quiet"
    URLInfoAbout         = 'https://tablepro.app'
    HelpLink             = 'https://github.com/TableProApp/TablePro/issues'
}
foreach ($name in $values.Keys) {
    New-ItemProperty -Path $uninstallKey -Name $name -Value $values[$name] -PropertyType String -Force | Out-Null
}
foreach ($name in 'NoModify', 'NoRepair') {
    New-ItemProperty -Path $uninstallKey -Name $name -Value 1 -PropertyType DWord -Force | Out-Null
}
New-ItemProperty -Path $uninstallKey -Name 'EstimatedSize' -Value $sizeKb -PropertyType DWord -Force | Out-Null

Write-Step "TablePro $version is installed."
if ($Launch) {
    Start-Process -FilePath $exe -WorkingDirectory $target
}
