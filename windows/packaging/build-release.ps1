<#
.SYNOPSIS
Builds the release files of TablePro for Windows for one architecture.

.DESCRIPTION
Writes to the output folder:
  TablePro-<version>-<arch>.zip   the self-contained app with install.ps1, uninstall.ps1 and Install.cmd
  TablePro-<version>-<arch>.msix  the MSIX package

Each build gets its own artifacts folder, so the MSIX and the unpackaged build never share intermediate files with
each other or with a developer's bin and obj folders. With -CertificateThumbprint, the executables, the scripts and
the package are signed with that certificate from Cert:\CurrentUser\My; without it, everything is unsigned.

.EXAMPLE
./build-release.ps1 -Version 0.2.0-beta.1 -Architecture arm64
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Version,
    [ValidateSet('x64', 'arm64')][string]$Architecture = 'x64',
    [string]$OutputDirectory,
    [string]$CertificateThumbprint,
    # The MSIX Publisher. It must equal the signing certificate's subject; empty takes it from the certificate,
    # or keeps the unsigned development publisher from Package.appxmanifest.
    [string]$Publisher,
    [switch]$SkipZip,
    [switch]$SkipMsix
)

. "$PSScriptRoot/common.ps1"

$release = ConvertTo-ReleaseVersion $Version
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $WindowsRoot 'artifacts/release' }
$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
# Short folder names: the XAML compiler fails on paths longer than 260 characters.
$work = Join-Path $WindowsRoot "artifacts/w-$Architecture"
$runtime = "win-$Architecture"
$baseName = "TablePro-$($release.Version)-$Architecture"
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
if (Test-Path $work) { Remove-Item -Recurse -Force $work }

if ($CertificateThumbprint -and -not $Publisher) {
    $Publisher = (Get-Item "Cert:\CurrentUser\My\$CertificateThumbprint").Subject
}

$common = @(
    '-c', 'Release',
    '-r', $runtime,
    "-p:Version=$($release.Version)",
    '-p:ContinuousIntegrationBuild=true',
    '--nologo'
)

if (-not $SkipZip) {
    Write-Host "Publishing $runtime, unpackaged"
    $app = Join-Path $work 'zip/TablePro'
    dotnet publish $AppProject @common --artifacts-path (Join-Path $work 'a') -o $app
    if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed with exit code $LASTEXITCODE." }

    foreach ($file in 'install.ps1', 'uninstall.ps1', 'Install.cmd') {
        Copy-Item (Join-Path $PSScriptRoot "installer/$file") $app
    }
    # TablePro's own binaries and the scripts; the bundled runtime and Windows App SDK files carry Microsoft's signatures.
    # Recursive, so the libraries' translations in fr\, ko\ and the other language folders are signed as well.
    $ownFiles = Get-ChildItem $app -File -Recurse | Where-Object { $_.Name -like 'TablePro*.exe' -or $_.Name -like 'TablePro*.dll' -or $_.Extension -eq '.ps1' }
    Invoke-CodeSign -Thumbprint $CertificateThumbprint -Path $ownFiles.FullName

    $zip = Join-Path $OutputDirectory "$baseName.zip"
    if (Test-Path $zip) { Remove-Item $zip }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::CreateFromDirectory($app, $zip, [System.IO.Compression.CompressionLevel]::Optimal, $true)
    Write-Host "$zip $(Get-Sha256 $zip)"
}

if (-not $SkipMsix) {
    Write-Host "Packaging $runtime as MSIX $($release.PackageVersion)"
    $packageDir = Join-Path $work 'msix/'
    $msixArgs = @(
        '-p:TableProPackage=msix',
        "-p:TableProPackageVersion=$($release.PackageVersion)",
        "-p:AppxPackageDir=$packageDir"
    )
    if ($Publisher) { $msixArgs += "-p:TableProPublisher=$Publisher" }
    dotnet publish $AppProject @common @msixArgs --artifacts-path (Join-Path $work 'm')
    if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed with exit code $LASTEXITCODE." }

    $built = Get-ChildItem $packageDir -Recurse -Filter '*.msix' | Select-Object -First 1
    if (-not $built) { throw "No .msix was written under $packageDir." }
    $msix = Join-Path $OutputDirectory "$baseName.msix"
    Copy-Item $built.FullName $msix -Force
    Invoke-CodeSign -Thumbprint $CertificateThumbprint -Path $msix
    Write-Host "$msix $(Get-Sha256 $msix)"
}
