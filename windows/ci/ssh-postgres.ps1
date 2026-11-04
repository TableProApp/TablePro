$ErrorActionPreference = 'Stop'

# The x64 runner ships PostgreSQL; a missing fixture must fail setup rather than skip its tests.
if (-not $env:PGBIN -or -not (Test-Path (Join-Path $env:PGBIN 'psql.exe'))) {
    throw 'The runner must provide PostgreSQL in PGBIN.'
}
$service = Get-Service 'postgresql-x64-*' | Select-Object -First 1
Set-Service $service.Name -StartupType Manual
Start-Service $service.Name
$env:PGPASSWORD = 'root'
$password = 'Tp-' + [guid]::NewGuid().ToString('N')
"::add-mask::$password"
$psql = Join-Path $env:PGBIN 'psql.exe'
& $psql -h 127.0.0.1 -U postgres -d postgres -v ON_ERROR_STOP=1 -c "CREATE ROLE tablepro_ssh LOGIN PASSWORD '$password'"
if ($LASTEXITCODE -ne 0) { throw 'Creating the SSH test database user failed.' }
& $psql -h 127.0.0.1 -U postgres -d postgres -v ON_ERROR_STOP=1 -c 'CREATE DATABASE tablepro_ssh OWNER tablepro_ssh'
if ($LASTEXITCODE -ne 0) { throw 'Creating the SSH test database failed.' }
$env:PGPASSWORD = $password
& $psql -h 127.0.0.1 -U tablepro_ssh -d tablepro_ssh -v ON_ERROR_STOP=1 -c "CREATE TABLE ssh_proof (answer integer PRIMARY KEY); INSERT INTO ssh_proof VALUES (42)"
if ($LASTEXITCODE -ne 0) { throw 'Seeding the SSH test database failed.' }
Remove-Item Env:PGPASSWORD

# Separate ports give both themes their own first-use host trust prompt without changing known_hosts.
$config = Join-Path $env:ProgramData 'ssh\sshd_config'
$ports = @('Port 22', 'Port 22220', 'Port 22221', 'Port 22222')
Set-Content -Encoding ascii $config ($ports + (Get-Content $config))
Restart-Service sshd

@(
    'TABLEPRO_TEST_SSH_POSTGRES_PORT=5432',
    "TABLEPRO_TEST_SSH_POSTGRES_PASSWORD=$password",
    "TABLEPRO_TEST_SSH_ROTATE_SCRIPT=$(Join-Path $PSScriptRoot 'rotate-ssh-test-key.ps1')"
) | Add-Content -Encoding utf8 $env:GITHUB_ENV
