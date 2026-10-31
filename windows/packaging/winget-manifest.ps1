<#
.SYNOPSIS
Fills the winget manifest templates in winget/ for one stable release.

.DESCRIPTION
Reads the release's MSIX packages and zips from the asset folder for their SHA-256, the MSIX signature digest and
the package family name, and writes the three manifests to
<OutputDirectory>/manifests/t/TableProApp/TablePro/<version>/, the layout of the winget-pkgs repository.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Version,
    [Parameter(Mandatory)][string]$AssetDirectory,
    [Parameter(Mandatory)][string]$DownloadBaseUrl,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [string]$ReleaseNotesUrl
)

. "$PSScriptRoot/common.ps1"

$release = ConvertTo-ReleaseVersion $Version
if ($release.IsBeta) { throw 'winget lists stable releases only.' }
$AssetDirectory = [System.IO.Path]::GetFullPath($AssetDirectory)
$DownloadBaseUrl = $DownloadBaseUrl.TrimEnd('/')
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Get-MsixIdentity([string]$Path) {
    $archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $reader = [System.IO.StreamReader]::new($archive.GetEntry('AppxManifest.xml').Open())
        [xml]$manifest = $reader.ReadToEnd()
        $reader.Dispose()
        $signature = $archive.GetEntry('AppxSignature.p7x')
        $signatureSha = if ($signature) {
            $stream = $signature.Open()
            try { [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($stream)) } finally { $stream.Dispose() }
        }
        else { '' }
        [pscustomobject]@{ Identity = $manifest.Package.Identity; SignatureSha256 = $signatureSha }
    }
    finally {
        $archive.Dispose()
    }
}

# Windows' publisher id: the first 8 bytes of the SHA-256 of the UTF-16 publisher, in 13 base32 digits.
function Get-PackageFamilyName([string]$Name, [string]$Publisher) {
    $hash = [System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::Unicode.GetBytes($Publisher))
    $bits = (-join ($hash[0..7] | ForEach-Object { [Convert]::ToString($_, 2).PadLeft(8, '0') })) + '0'
    $alphabet = '0123456789abcdefghjkmnpqrstvwxyz'
    $id = -join (0..12 | ForEach-Object { $alphabet[[Convert]::ToInt32($bits.Substring($_ * 5, 5), 2)] })
    "${Name}_$id"
}

$values = @{
    Version         = $release.Version
    ReleaseDate     = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd')
    ReleaseNotesUrl = if ($ReleaseNotesUrl) { $ReleaseNotesUrl } else { "https://github.com/TableProApp/TablePro/releases/tag/windows-v$($release.Version)" }
}
foreach ($arch in 'x64', 'arm64') {
    $prefix = if ($arch -eq 'x64') { 'X64' } else { 'Arm64' }
    foreach ($kind in 'msix', 'zip') {
        $name = "TablePro-$($release.Version)-$arch.$kind"
        $path = Join-Path $AssetDirectory $name
        if (-not (Test-Path -LiteralPath $path)) { throw "$path is missing." }
        $kindName = (Get-Culture).TextInfo.ToTitleCase($kind)
        $values["$prefix${kindName}Url"] = "$DownloadBaseUrl/$name"
        $values["$prefix${kindName}Sha256"] = (Get-Sha256 $path).ToUpperInvariant()
        if ($kind -eq 'msix') {
            $msix = Get-MsixIdentity $path
            if (-not $msix.SignatureSha256) { throw "$name is unsigned; winget accepts signed MSIX packages only." }
            $values["$prefix${kindName}SignatureSha256"] = $msix.SignatureSha256.ToUpperInvariant()
            $values['PackageFamilyName'] = Get-PackageFamilyName $msix.Identity.Name $msix.Identity.Publisher
        }
    }
}

$target = Join-Path $OutputDirectory "manifests/t/TableProApp/TablePro/$($release.Version)"
New-Item -ItemType Directory -Force -Path $target | Out-Null
foreach ($template in Get-ChildItem (Join-Path $PSScriptRoot 'winget') -Filter '*.yaml') {
    $text = Get-Content -LiteralPath $template.FullName -Raw -Encoding utf8
    $text = [regex]::Replace($text, '\{\{(\w+)\}\}', {
            param($match)
            $key = $match.Groups[1].Value
            if (-not $values.ContainsKey($key)) { throw "The template $($template.Name) names {{$key}}, which has no value." }
            $values[$key]
        })
    # The first line says it is a template; a filled manifest is not.
    $text = ($text -split "`n", 2)[1]
    $path = Join-Path $target $template.Name
    [System.IO.File]::WriteAllText($path, $text, [System.Text.UTF8Encoding]::new($false))
    Write-Host "Wrote $path"
}
