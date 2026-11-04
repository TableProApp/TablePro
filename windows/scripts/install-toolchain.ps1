# Needs admin rights: every installer here writes machine-wide.
# usage: install-toolchain.ps1 [-Only git,dotnet,rust,vs]
param([string]$Only = 'git,dotnet,rust,vs')
$Only = $Only -split ','

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$dl = Join-Path $env:TEMP 'tablepro-toolchain'
New-Item -ItemType Directory -Force $dl | Out-Null

$hostArch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
$rustHost = if ($hostArch -eq 'arm64') { 'aarch64-pc-windows-msvc' } else { 'x86_64-pc-windows-msvc' }

function Get-File($url, $name) {
    $out = Join-Path $dl $name
    if (-not (Test-Path $out)) { Invoke-WebRequest -Uri $url -OutFile $out -UseBasicParsing }
    $out
}

function Invoke-Installer($exe, [string[]]$arguments) {
    $p = Start-Process -FilePath $exe -ArgumentList $arguments -Wait -PassThru -NoNewWindow
    "$([IO.Path]::GetFileName($exe)) exit $($p.ExitCode)"
    if ($p.ExitCode -notin 0, 3010) { throw "$exe failed with $($p.ExitCode)" }
}

if ('git' -in $Only) {
    $exe = Get-File "https://github.com/git-for-windows/git/releases/download/v2.56.0.windows.4/Git-2.56.0.4-$hostArch.exe" 'git.exe'
    Invoke-Installer $exe @('/VERYSILENT', '/NORESTART', '/NOCANCEL', '/SP-', '/SUPPRESSMSGBOXES')
}

if ('dotnet' -in $Only) {
    $exe = Get-File "https://builds.dotnet.microsoft.com/dotnet/Sdk/10.0.403/dotnet-sdk-10.0.403-win-$hostArch.exe" 'dotnet-sdk.exe'
    Invoke-Installer $exe @('/install', '/quiet', '/norestart')
}

if ('rust' -in $Only) {
    # One machine-wide toolchain, so SYSTEM and the desktop user share it.
    [Environment]::SetEnvironmentVariable('RUSTUP_HOME', 'C:\rust\rustup', 'Machine')
    [Environment]::SetEnvironmentVariable('CARGO_HOME', 'C:\rust\cargo', 'Machine')
    $env:RUSTUP_HOME = 'C:\rust\rustup'; $env:CARGO_HOME = 'C:\rust\cargo'
    $exe = Get-File "https://static.rust-lang.org/rustup/dist/$rustHost/rustup-init.exe" 'rustup-init.exe'
    Invoke-Installer $exe @('-y', '--no-modify-path', '--profile', 'minimal', '--default-toolchain', 'stable', '--default-host', $rustHost)
    & C:\rust\cargo\bin\rustup.exe target add aarch64-pc-windows-msvc x86_64-pc-windows-msvc
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    if ($machinePath -notlike '*C:\rust\cargo\bin*') {
        [Environment]::SetEnvironmentVariable('Path', "$machinePath;C:\rust\cargo\bin", 'Machine')
    }
}

if ('vs' -in $Only) {
    # The stable channel resolves to Build Tools for Visual Studio 2026.
    $exe = Get-File 'https://aka.ms/vs/stable/vs_buildtools.exe' 'vs_buildtools.exe'
    Invoke-Installer $exe @(
        '--quiet', '--wait', '--norestart', '--nocache',
        '--add', 'Microsoft.VisualStudio.Workload.VCTools',
        '--add', 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64',
        '--add', 'Microsoft.VisualStudio.Component.VC.Tools.ARM64',
        '--add', 'Microsoft.VisualStudio.Component.Windows11SDK.26100'
    )
}
