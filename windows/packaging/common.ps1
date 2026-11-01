# Helpers the packaging scripts share. Dot-source it: . "$PSScriptRoot/common.ps1"

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:WindowsRoot = Split-Path -Parent $PSScriptRoot
$script:AppProject = Join-Path $script:WindowsRoot 'src/TablePro.App/TablePro.App.csproj'
$script:PackageIdentityName = 'TableProApp.TablePro'

# The same rules as TablePro.Core.Updates.AppVersion: X.Y.Z or X.Y.Z-beta.N, N from 1 to 98, each part an MSIX field.
function ConvertTo-ReleaseVersion {
    param([Parameter(Mandatory)][string]$Text)
    $match = [regex]::Match($Text, '^(?:windows-)?v?(\d{1,5})\.(\d{1,5})\.(\d{1,5})(?:-beta\.(\d{1,2}))?$')
    if (-not $match.Success) {
        throw "'$Text' is not a release version such as 0.2.0 or 0.2.0-beta.1."
    }
    $parts = 1..3 | ForEach-Object { [int]$match.Groups[$_].Value }
    if ($parts | Where-Object { $_ -gt 65535 }) {
        throw "'$Text' has a part above 65535, which an MSIX version cannot hold."
    }
    $beta = if ($match.Groups[4].Success) { [int]$match.Groups[4].Value } else { 0 }
    if ($match.Groups[4].Success -and ($beta -lt 1 -or $beta -gt 98)) {
        throw "'$Text' has beta $beta; a beta is numbered 1 to 98."
    }
    $core = '{0}.{1}.{2}' -f $parts
    [pscustomobject]@{
        Version        = if ($beta) { "$core-beta.$beta" } else { $core }
        Channel        = if ($beta) { 'beta' } else { 'stable' }
        IsBeta         = [bool]$beta
        # A beta's revision is its number and a stable's is 99, so Windows orders packages as the app orders versions.
        PackageVersion = '{0}.{1}' -f $core, $(if ($beta) { $beta } else { 99 })
    }
}

# makeappx and signtool come with the Microsoft.Windows.SDK.BuildTools package the app restores, so a machine
# without the Windows SDK installed still has them.
function Find-SdkTool {
    param([Parameter(Mandatory)][string]$Name)
    $hostArch = if ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq 'Arm64') { 'arm64' } else { 'x64' }
    $packages = if ($env:NUGET_PACKAGES) { $env:NUGET_PACKAGES } else { Join-Path $HOME '.nuget/packages' }
    $roots = @(
        (Join-Path $packages 'microsoft.windows.sdk.buildtools'),
        (Join-Path ${env:ProgramFiles(x86)} 'Windows Kits/10/bin')
    )
    foreach ($root in $roots) {
        if (-not (Test-Path $root)) { continue }
        $found = Get-ChildItem -Path $root -Recurse -Filter "$Name.exe" -ErrorAction SilentlyContinue |
            Where-Object { $_.Directory.Name -eq $hostArch } |
            Sort-Object FullName -Descending |
            Select-Object -First 1
        if ($found) { return $found.FullName }
    }
    throw "$Name.exe was not found. Restore the app once (dotnet restore) or install the Windows SDK."
}

# Signs files with the certificate in Cert:\CurrentUser\My whose thumbprint is given, timestamped so the signature
# outlives the certificate. No thumbprint means an unsigned build, which the caller has already said in the log.
function Invoke-CodeSign {
    param(
        [string]$Thumbprint,
        [Parameter(Mandatory)][string[]]$Path,
        [string]$TimestampUrl = 'http://timestamp.digicert.com'
    )
    if (-not $Thumbprint -or -not $Path) { return }
    $signtool = Find-SdkTool 'signtool'
    & $signtool sign /fd SHA256 /sha1 $Thumbprint /tr $TimestampUrl /td SHA256 /q @Path
    if ($LASTEXITCODE -ne 0) { throw "signtool failed with exit code $LASTEXITCODE." }
}

function Get-Sha256 {
    param([Parameter(Mandatory)][string]$Path)
    (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}
