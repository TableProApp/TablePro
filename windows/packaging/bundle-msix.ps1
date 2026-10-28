<#
.SYNOPSIS
Bundles the x64 and arm64 MSIX packages of a release into one .msixbundle.

.DESCRIPTION
The .appinstaller files point at the bundle, so App Installer picks the architecture of the PC it runs on.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Version,
    [Parameter(Mandatory)][string]$Directory,
    [string]$CertificateThumbprint
)

. "$PSScriptRoot/common.ps1"

$release = ConvertTo-ReleaseVersion $Version
$Directory = [System.IO.Path]::GetFullPath($Directory)
$packages = foreach ($arch in 'x64', 'arm64') {
    $path = Join-Path $Directory "TablePro-$($release.Version)-$arch.msix"
    if (-not (Test-Path -LiteralPath $path)) { throw "$path is missing." }
    $path
}

# makeappx bundles every package in a folder, so the two are copied into one of their own.
$staging = Join-Path ([System.IO.Path]::GetTempPath()) "tablepro-bundle-$PID"
New-Item -ItemType Directory -Force -Path $staging | Out-Null
try {
    Copy-Item -LiteralPath $packages -Destination $staging
    $bundle = Join-Path $Directory "TablePro-$($release.Version).msixbundle"
    $makeappx = Find-SdkTool 'makeappx'
    & $makeappx bundle /o /d $staging /p $bundle /bv $release.PackageVersion
    if ($LASTEXITCODE -ne 0) { throw "makeappx failed with exit code $LASTEXITCODE." }
}
finally {
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
}

Invoke-CodeSign -Thumbprint $CertificateThumbprint -Path $bundle
Write-Host "$bundle $(Get-Sha256 $bundle)"
