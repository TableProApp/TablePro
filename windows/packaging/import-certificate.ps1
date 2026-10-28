<#
.SYNOPSIS
Imports the release signing certificate for a workflow job and prints its thumbprint as the step output.

.DESCRIPTION
Reads the .pfx in base64 from $env:CERTIFICATE and its password from $env:PASSWORD, and imports it into
Cert:\CurrentUser\My, where signtool finds it by thumbprint. With no certificate it writes an empty thumbprint and
a notice, and the release is built unsigned.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $env:CERTIFICATE) {
    Write-Host '::notice::WINDOWS_CERTIFICATE is not set, so this release is unsigned: SmartScreen warns on the zip, the MSIX installs only with Add-AppxPackage -AllowUnsigned on Windows 11, and winget cannot take it.'
    "thumbprint=" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
    return
}

$pfx = Join-Path $env:RUNNER_TEMP 'signing.pfx'
try {
    [System.IO.File]::WriteAllBytes($pfx, [Convert]::FromBase64String($env:CERTIFICATE))
    $import = @{ FilePath = $pfx; CertStoreLocation = 'Cert:\CurrentUser\My' }
    if ($env:PASSWORD) { $import.Password = ConvertTo-SecureString -String $env:PASSWORD -AsPlainText -Force }
    $certificate = Import-PfxCertificate @import
}
finally {
    Remove-Item -LiteralPath $pfx -Force -ErrorAction SilentlyContinue
}

$days = ($certificate.NotAfter - (Get-Date)).Days
if ($days -lt 60) {
    Write-Host "::warning::The Windows signing certificate expires in $days days, on $($certificate.NotAfter.ToString('yyyy-MM-dd'))."
}
Write-Host "Signing as $($certificate.Subject)"
"thumbprint=$($certificate.Thumbprint)" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
