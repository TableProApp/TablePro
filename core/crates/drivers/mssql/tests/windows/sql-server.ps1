# SQL Server 2022 Express for tests/integration/windows_server.rs. -Install: TCP 1433, Windows logins, the
# current account as sysadmin, a self-signed certificate written as PEM to TABLEPRO_TEST_MSSQL_WINDOWS_CA and
# trusted by no Windows store. -ForceStrict: only TDS 8.0 logins get in.
param(
    [switch]$Install,
    [switch]$ForceStrict
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Get-NetLibKey {
    $instance = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL').MSSQLSERVER
    "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$instance\MSSQLServer\SuperSocketNetLib"
}

function Restart-SqlServer {
    Restart-Service MSSQLSERVER -Force
    # The service reports Running before the listener takes connections.
    $deadline = (Get-Date).AddMinutes(2)
    while (-not (Get-NetTCPConnection -LocalPort 1433 -State Listen -ErrorAction SilentlyContinue)) {
        if ((Get-Date) -gt $deadline) { throw 'SQL Server is not listening on 1433' }
        Start-Sleep -Seconds 1
    }
}

if ($Install) {
    $exe = Join-Path $env:RUNNER_TEMP 'SQLEXPR_x64_ENU.exe'
    $extract = Join-Path $env:RUNNER_TEMP 'sqlexpr'
    Invoke-WebRequest 'https://download.microsoft.com/download/3/8/d/38de7036-2433-4207-8eae-06e247e17b25/SQLEXPR_x64_ENU.exe' -OutFile $exe
    $sha256 = (Get-FileHash $exe -Algorithm SHA256).Hash
    if ($sha256 -ne '2E61C8BBDE6021F9026C54AD9DB4BBB1227E68761D4C00A6A50A2C70FE7AFE05') { throw "SQLEXPR_x64_ENU.exe has SHA-256 $sha256" }
    Start-Process $exe -ArgumentList '/q', "/x:$extract" -Wait

    $account = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $setup = @(
        '/Q', '/ACTION=Install', '/FEATURES=SQLEngine', '/INSTANCENAME=MSSQLSERVER',
        "/SQLSYSADMINACCOUNTS=$account", '/TCPENABLED=1', '/UPDATEENABLED=0',
        '/IACCEPTSQLSERVERLICENSETERMS', '/SUPPRESSPRIVACYSTATEMENTNOTICE'
    )
    $process = Start-Process (Join-Path $extract 'setup.exe') -ArgumentList $setup -Wait -PassThru -NoNewWindow
    if ($process.ExitCode -ne 0) {
        Get-Content 'C:\Program Files\Microsoft SQL Server\160\Setup Bootstrap\Log\Summary.txt'
        exit 1
    }

    # SQL Server reads the key through the legacy CryptoAPI, so the key lives in an SChannel CSP container
    # that its service account is then allowed to read.
    $cert = New-SelfSignedCertificate -Subject 'CN=localhost' -DnsName 'localhost', $env:COMPUTERNAME `
        -CertStoreLocation Cert:\LocalMachine\My -KeyExportPolicy Exportable -KeySpec KeyExchange `
        -KeyLength 2048 -KeyAlgorithm RSA -HashAlgorithm SHA256 -Provider 'Microsoft RSA SChannel Cryptographic Provider' `
        -TextExtension @('2.5.29.37={text}1.3.6.1.5.5.7.3.1') -NotAfter (Get-Date).AddDays(2)
    $rsa = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($cert)
    $container = if ($rsa -is [System.Security.Cryptography.RSACng]) { $rsa.Key.UniqueName } else { $rsa.CspKeyContainerInfo.UniqueKeyContainerName }
    $keyFile = @("Microsoft\Crypto\RSA\MachineKeys\$container", "Microsoft\Crypto\Keys\$container") |
        ForEach-Object { Join-Path $env:ProgramData $_ } | Where-Object { Test-Path $_ } | Select-Object -First 1
    icacls $keyFile /grant 'NT Service\MSSQLSERVER:R' | Out-Null
    Set-ItemProperty (Get-NetLibKey) -Name Certificate -Value $cert.Thumbprint.ToLowerInvariant()

    $pem = Join-Path $env:RUNNER_TEMP 'sql-server.pem'
    $body = [Convert]::ToBase64String($cert.RawData, 'InsertLineBreaks') -replace "`r", ''
    "-----BEGIN CERTIFICATE-----`n$body`n-----END CERTIFICATE-----`n" | Set-Content -Path $pem -Encoding ascii -NoNewline
    "TABLEPRO_TEST_MSSQL_WINDOWS_CA=$pem" | Out-File -FilePath $env:GITHUB_ENV -Append -Encoding utf8
    Restart-SqlServer
}

if ($ForceStrict) {
    Set-ItemProperty (Get-NetLibKey) -Name ForceStrict -Value 1 -Type DWord
    Restart-SqlServer
}
