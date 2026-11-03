# Starts Windows' own OpenSSH Server on a hosted runner for the in-process
# SSH tests, and writes what they need to $env:GITHUB_ENV.
# usage: start-windows-sshd.ps1 -Out <dir>

param([Parameter(Mandatory)][string]$Out)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$client = Get-WindowsCapability -Online -Name 'OpenSSH.Client*'
$server = Get-WindowsCapability -Online -Name 'OpenSSH.Server*'
"OpenSSH client: $($client.State); server: $($server.State)"
if ($server.State -ne 'Installed') {
    Add-WindowsCapability -Online -Name $server.Name | Out-Null
}
$openssh = Join-Path $env:WINDIR 'System32\OpenSSH'
& (Join-Path $openssh 'ssh.exe') -V

New-Item -ItemType Directory -Force $Out | Out-Null
$user = 'tpssh'
$password = 'Tp-' + [guid]::NewGuid().ToString('N')
"::add-mask::$password"
$secure = ConvertTo-SecureString $password -AsPlainText -Force
New-LocalUser -Name $user -Password $secure -PasswordNeverExpires -AccountNeverExpires | Out-Null

$keygen = Join-Path $openssh 'ssh-keygen.exe'
$plain = Join-Path $Out 'id_ed25519'
$locked = Join-Path $Out 'id_ecdsa'
$passphrase = 'correct horse battery'
& $keygen -q -t ed25519 -N '' -C tablepro-windows -f $plain
if ($LASTEXITCODE -ne 0) { throw "ssh-keygen failed with $LASTEXITCODE" }
& $keygen -q -t ecdsa -b 256 -N $passphrase -C tablepro-windows-locked -f $locked
if ($LASTEXITCODE -ne 0) { throw "ssh-keygen failed with $LASTEXITCODE" }

# One key file for every user, ahead of the default config's Match block,
# owned and writable only by SYSTEM and Administrators as sshd requires.
$programData = Join-Path $env:ProgramData 'ssh'
New-Item -ItemType Directory -Force $programData | Out-Null
$authorized = Join-Path $programData 'tablepro_authorized_keys'
(Get-Content "$plain.pub", "$locked.pub") | Set-Content -Encoding ascii $authorized
& icacls.exe $authorized /inheritance:r /grant 'SYSTEM:F' /grant 'BUILTIN\Administrators:F' /grant "${user}:R" | Out-Null

$config = Join-Path $programData 'sshd_config'
if (-not (Test-Path $config)) {
    Copy-Item (Join-Path $openssh 'sshd_config_default') $config
}
# The log goes to __PROGRAMDATA__/ssh/logs/sshd.log, which the workflow prints when a test fails.
$lines = @(
    "AuthorizedKeysFile __PROGRAMDATA__/ssh/tablepro_authorized_keys",
    'PasswordAuthentication yes',
    'AllowTcpForwarding yes',
    'SyslogFacility LOCAL0',
    'LogLevel DEBUG2'
)
Set-Content -Encoding ascii $config ($lines + (Get-Content $config))
Set-Service sshd -StartupType Manual
Restart-Service sshd

Set-Service ssh-agent -StartupType Manual
Start-Service ssh-agent
& (Join-Path $openssh 'ssh-add.exe') $plain
if ($LASTEXITCODE -ne 0) { throw "ssh-add failed with $LASTEXITCODE" }

$deadline = (Get-Date).AddSeconds(30)
while (-not (Test-NetConnection -ComputerName 127.0.0.1 -Port 22 -InformationLevel Quiet)) {
    if ((Get-Date) -gt $deadline) { throw 'sshd did not listen on port 22' }
    Start-Sleep -Seconds 1
}

@(
    "TABLEPRO_TEST_SSHD_USER=$user",
    "TABLEPRO_TEST_SSHD_PASSWORD=$password",
    "TABLEPRO_TEST_SSHD_KEY=$plain",
    "TABLEPRO_TEST_SSHD_LOCKED_KEY=$locked",
    "TABLEPRO_TEST_SSHD_PASSPHRASE=$passphrase"
) | Add-Content -Encoding utf8 $env:GITHUB_ENV
