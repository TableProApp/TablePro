<#
.SYNOPSIS
Adds a release to the Windows update feed and rewrites the App Installer files.

.DESCRIPTION
The site folder is windows/ on the gh-pages branch, served at https://updates.tablepro.app/windows/. This script
writes there:

  feed.json                  every recent release, read by the app's UpdateService (TablePro.Core.Updates.UpdateFeed)
  TablePro.appinstaller      the stable channel, for MSIX installs; written by a stable release only
  TablePro-beta.appinstaller the beta channel, which takes stables too; written by every release

A release already in the feed is replaced, so a re-run of the workflow is safe. A stable rolls out in phases of
6 hours across 7 groups, as the macOS appcast does; a beta and a critical release go to everyone at once.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Version,
    [Parameter(Mandatory)][string]$AssetDirectory,
    # Where the assets are downloaded from: the GitHub release's download folder.
    [Parameter(Mandatory)][string]$DownloadBaseUrl,
    [Parameter(Mandatory)][string]$SiteDirectory,
    [string]$SiteUrl = 'https://updates.tablepro.app/windows',
    [string]$ReleaseNotesUrl,
    [string]$NotesFile,
    [switch]$Critical,
    [int]$PhasedRolloutInterval = 21600,
    [int]$MinimumWindowsBuild = 19041,
    [int]$Keep = 20
)

. "$PSScriptRoot/common.ps1"

$release = ConvertTo-ReleaseVersion $Version
$AssetDirectory = [System.IO.Path]::GetFullPath($AssetDirectory)
New-Item -ItemType Directory -Force -Path $SiteDirectory | Out-Null
$feedPath = Join-Path $SiteDirectory 'feed.json'
$DownloadBaseUrl = $DownloadBaseUrl.TrimEnd('/')
$SiteUrl = $SiteUrl.TrimEnd('/')

$assets = foreach ($kind in 'zip', 'msix') {
    foreach ($arch in 'x64', 'arm64') {
        $name = "TablePro-$($release.Version)-$arch.$kind"
        $path = Join-Path $AssetDirectory $name
        if (-not (Test-Path -LiteralPath $path)) { continue }
        [ordered]@{
            kind         = $kind
            architecture = $arch
            url          = "$DownloadBaseUrl/$name"
            size         = (Get-Item -LiteralPath $path).Length
            sha256       = Get-Sha256 $path
        }
    }
}
if (-not $assets) { throw "No release files for $($release.Version) in $AssetDirectory." }

$item = [ordered]@{
    version             = $release.Version
    channel             = $release.Channel
    published           = [DateTimeOffset]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture)
    critical            = [bool]$Critical
    minimumWindowsBuild = $MinimumWindowsBuild
}
if (-not $release.IsBeta -and -not $Critical -and $PhasedRolloutInterval -gt 0) {
    $item.phasedRolloutInterval = $PhasedRolloutInterval
}
if ($ReleaseNotesUrl) { $item.releaseNotesUrl = $ReleaseNotesUrl }
if ($NotesFile -and (Test-Path -LiteralPath $NotesFile)) {
    $notes = (Get-Content -LiteralPath $NotesFile -Raw -Encoding utf8).Trim()
    if ($notes) { $item.notes = $notes }
}
$item.assets = @($assets)

$items = [System.Collections.Generic.List[object]]::new()
$items.Add($item)
if (Test-Path -LiteralPath $feedPath) {
    $existing = Get-Content -LiteralPath $feedPath -Raw -Encoding utf8 | ConvertFrom-Json
    if ($existing.schema -ne 1) { throw "$feedPath has schema $($existing.schema); this script writes schema 1." }
    foreach ($old in @($existing.items)) {
        if ($old.version -ne $release.Version) {
            $items.Add($old)
        }
        else {
            # A re-run keeps the first publish time, so the rollout phases do not start over.
            $item.published = ([DateTimeOffset]$old.published).UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture)
        }
    }
}

# Newest published first; the app sorts by version itself, so this order only decides what is kept.
$kept = @($items | Select-Object -First $Keep)
$feed = [ordered]@{ schema = 1; items = $kept }
$json = ConvertTo-Json -InputObject $feed -Depth 10
[System.IO.File]::WriteAllText($feedPath, $json + "`n", [System.Text.UTF8Encoding]::new($false))
Write-Host "Wrote $feedPath with $($kept.Count) releases"

# App Installer files, from the bundle's own identity so they always match what was signed.
$bundleName = "TablePro-$($release.Version).msixbundle"
$bundle = Join-Path $AssetDirectory $bundleName
if (-not (Test-Path -LiteralPath $bundle)) {
    Write-Host "No $bundleName, so the App Installer files are left as they are"
    return
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [System.IO.Compression.ZipFile]::OpenRead($bundle)
try {
    $entry = $archive.GetEntry('AppxMetadata/AppxBundleManifest.xml')
    $reader = [System.IO.StreamReader]::new($entry.Open())
    [xml]$manifest = $reader.ReadToEnd()
    $reader.Dispose()
}
finally {
    $archive.Dispose()
}
$identity = $manifest.Bundle.Identity

function Write-AppInstaller([string]$FileName) {
    $settings = [System.Xml.XmlWriterSettings]::new()
    $settings.Indent = $true
    $settings.Encoding = [System.Text.UTF8Encoding]::new($false)
    $path = Join-Path $SiteDirectory $FileName
    $writer = [System.Xml.XmlWriter]::Create($path, $settings)
    try {
        $ns = 'http://schemas.microsoft.com/appx/appinstaller/2018'
        $writer.WriteStartElement('AppInstaller', $ns)
        $writer.WriteAttributeString('Uri', "$SiteUrl/$FileName")
        $writer.WriteAttributeString('Version', $identity.Version)
        $writer.WriteStartElement('MainBundle', $ns)
        $writer.WriteAttributeString('Name', $identity.Name)
        $writer.WriteAttributeString('Publisher', $identity.Publisher)
        $writer.WriteAttributeString('Version', $identity.Version)
        $writer.WriteAttributeString('Uri', "$DownloadBaseUrl/$bundleName")
        $writer.WriteEndElement()
        $writer.WriteStartElement('UpdateSettings', $ns)
        # A check on every launch lets "Restart to update" in the app apply what Windows found; a critical
        # release, like [CRITICAL] on macOS, installs before the app opens.
        $writer.WriteStartElement('OnLaunch', $ns)
        $writer.WriteAttributeString('HoursBetweenUpdateChecks', '0')
        $writer.WriteAttributeString('ShowPrompt', 'true')
        $writer.WriteAttributeString('UpdateBlocksActivation', $(if ($Critical) { 'true' } else { 'false' }))
        $writer.WriteEndElement()
        $writer.WriteElementString('AutomaticBackgroundTask', $ns, '')
        $writer.WriteEndElement()
        $writer.WriteEndElement()
    }
    finally {
        $writer.Dispose()
    }
    Write-Host "Wrote $path"
}

Write-AppInstaller 'TablePro-beta.appinstaller'
if (-not $release.IsBeta) {
    Write-AppInstaller 'TablePro.appinstaller'
}
