# Starts one database server on the x64 runner for tests/TablePro.Interop.Tests/Live and names it to them in
# TABLEPRO_TEST_LIVE_<ENGINE>_PORT, _USER and _PASSWORD. How each one runs: docs/decisions/0013-live-server-tests.md.
param(
    [Parameter(Mandatory)]
    [ValidateSet('MySql', 'SqlServer', 'MongoDb', 'Redis', 'Cassandra', 'Wsl', 'ClickHouse')]
    [string]$Server
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$Distribution = 'tablepro'

function Wait-Listening([int]$Port, [int]$Minutes, [scriptblock]$Log) {
    $deadline = (Get-Date).AddMinutes($Minutes)
    while ($true) {
        $client = [System.Net.Sockets.TcpClient]::new()
        try {
            if ($client.ConnectAsync('127.0.0.1', $Port).Wait(1000)) { return }
        } catch {
        } finally {
            $client.Dispose()
        }
        if ((Get-Date) -gt $deadline) {
            & $Log
            throw "nothing listens on $Port after $Minutes minutes"
        }
        Start-Sleep -Milliseconds 500
    }
}

function Get-Pinned([string]$Url, [string]$Sha256) {
    $file = Join-Path $env:RUNNER_TEMP ([uri]$Url).Segments[-1]
    Invoke-WebRequest $Url -OutFile $file
    $actual = (Get-FileHash $file -Algorithm SHA256).Hash
    if ($actual -ne $Sha256) { throw "$Url has SHA-256 $actual" }
    $file
}

function Set-Live([string]$Engine, [int]$Port, [string]$User = '', [string]$Password = '') {
    $lines = @("TABLEPRO_TEST_LIVE_${Engine}_PORT=$Port", "TABLEPRO_TEST_LIVE_${Engine}_USER=$User")
    if ($Password) {
        "::add-mask::$Password"
        $lines += "TABLEPRO_TEST_LIVE_${Engine}_PASSWORD=$Password"
    }
    $lines | Add-Content -Encoding utf8 $env:GITHUB_ENV
}

function New-Password { 'Tp-' + [guid]::NewGuid().ToString('N') }

function Invoke-Wsl([string]$Command) {
    wsl --distribution $Distribution --user root -- sh -c $Command
    if ($LASTEXITCODE -ne 0) { throw "``$Command`` exited $LASTEXITCODE in WSL" }
}

function ConvertTo-WslPath([string]$Path) {
    '/mnt/' + $Path.Substring(0, 1).ToLowerInvariant() + $Path.Substring(2).Replace('\', '/')
}

switch ($Server) {
    # The image ships MySQL 8.4 without a data folder or a running service.
    'MySql' {
        $mysqld = (Get-Command mysqld).Source
        $data = Join-Path $env:RUNNER_TEMP 'mysql-data'
        $log = Join-Path $env:RUNNER_TEMP 'mysqld.log'
        & $mysqld --initialize-insecure "--datadir=$data" --console
        if ($LASTEXITCODE -ne 0) { throw "mysqld --initialize-insecure exited $LASTEXITCODE" }
        Start-Process $mysqld -ArgumentList "--datadir=$data", '--port=3306', '--bind-address=127.0.0.1', "--log-error=$log" -WindowStyle Hidden
        Wait-Listening 3306 2 { Get-Content $log }
        $password = New-Password
        mysql --user=root --host=127.0.0.1 --execute="CREATE DATABASE tablepro; CREATE USER 'tablepro'@'%' IDENTIFIED BY '$password'; GRANT ALL ON tablepro.* TO 'tablepro'@'%'"
        if ($LASTEXITCODE -ne 0) { throw 'Creating the MySQL test user failed.' }
        Set-Live MYSQL 3306 tablepro $password
    }
    'SqlServer' {
        $password = New-Password
        & (Join-Path $PSScriptRoot '../../core/crates/drivers/mssql/tests/windows/sql-server.ps1') -Install -SaPassword $password
        Set-Live MSSQL 1433 sa $password
    }
    # The image ships MongoDB 7.0 as a disabled service.
    'MongoDb' {
        Set-Service MongoDB -StartupType Manual
        Start-Service MongoDB
        Wait-Listening 27017 2 { Get-Content "$env:ProgramFiles\MongoDB\Server\7.0\log\mongod.log" -Tail 50 }
        Set-Live MONGODB 27017
    }
    'Redis' {
        $zip = Get-Pinned 'https://github.com/redis-windows/redis-windows/releases/download/8.10.3/Redis-8.10.3-Windows-x64-msys2.zip' `
            'AF16DF340525B431E9EC8DABFD625D5E7A233F82805B5418819904EA909C447F'
        Expand-Archive $zip -DestinationPath $env:RUNNER_TEMP
        $folder = Join-Path $env:RUNNER_TEMP 'Redis-8.10.3-Windows-x64-msys2'
        Start-Process (Join-Path $folder 'redis-server.exe') -ArgumentList '--port', '6379', '--bind', '127.0.0.1' -WorkingDirectory $folder -WindowStyle Hidden
        Wait-Listening 6379 1 { }
        Set-Live REDIS 6379
    }
    # Cassandra 4.1 and later refuse to start on Windows; 4.0 still runs there on the image's Java 11. Its launch script is
    # for Unix, so this is the java command it builds.
    'Cassandra' {
        $archive = Get-Pinned 'https://archive.apache.org/dist/cassandra/4.0.21/apache-cassandra-4.0.21-bin.tar.gz' `
            'B5916619A0F64A414F838BC99A90540B60D057FE028C84C575A05F7D0A9CE15F'
        tar -xzf $archive -C $env:RUNNER_TEMP
        $root = Join-Path $env:RUNNER_TEMP 'apache-cassandra-4.0.21'
        $conf = Join-Path $root 'conf'
        # Windows cannot delete a file while it is mapped, and dropping a table deletes its files.
        Add-Content (Join-Path $conf 'cassandra.yaml') 'disk_access_mode: standard'
        $options = @('jvm-server.options', 'jvm11-server.options') |
            ForEach-Object { Get-Content (Join-Path $conf $_) } |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -match '^-' -and $_ -ne '-XX:+UseNUMA' } |
            ForEach-Object { $_ -replace '^(--add-(exports|opens)) ', '$1=' }
        $logs = Join-Path $env:RUNNER_TEMP 'cassandra-logs'
        $arguments = @($options) + @(
            '-Xms1g', '-Xmx1g',
            '-Dlogback.configurationFile=logback.xml',
            "-Dcassandra.logdir=$logs",
            "-Dcassandra.storagedir=$root\data",
            '-cp', "`"$conf;$root\lib\*`"",
            'org.apache.cassandra.service.CassandraDaemon'
        )
        # Redirected output would tie java to this step's console, whose close at the step's end stops it.
        Start-Process (Join-Path $env:JAVA_HOME_11_X64 'bin\java.exe') -ArgumentList $arguments -WorkingDirectory $root -WindowStyle Hidden
        Wait-Listening 9042 5 { Get-Content (Join-Path $logs 'system.log') -Tail 80 }
        Set-Live CASSANDRA 9042
    }
    # ClickHouse has no Windows build. WSL 1 runs its Linux binary on the runner, which cannot nest a WSL 2 VM.
    'Wsl' {
        $rootfs = Get-Pinned 'https://cdimage.ubuntu.com/ubuntu-base/releases/24.04/release/ubuntu-base-24.04.5-base-amd64.tar.gz' `
            'E77B6F10C2590CEF872B33EE9F635A0E3FD1F57FB074C0E52B5C7F56147A0C86'
        $folder = Join-Path $env:RUNNER_TEMP 'wsl'
        New-Item -ItemType Directory -Force $folder | Out-Null
        wsl --import $Distribution $folder $rootfs --version 1
        if ($LASTEXITCODE -ne 0) { throw "wsl --import exited $LASTEXITCODE" }
    }
    'ClickHouse' {
        $archive = Get-Pinned 'https://github.com/ClickHouse/ClickHouse/releases/download/v26.8.39.19-lts/clickhouse-common-static-26.8.39.19-amd64.tgz' `
            'EA26B63D9C533513F27D5D92A43BA054C6A05DFBB1D58B86B7A96920184082B6'
        Invoke-Wsl "mkdir -p /opt/clickhouse /var/lib/clickhouse && tar -xzf $(ConvertTo-WslPath $archive) -C /opt/clickhouse --strip-components=1"
        Start-Process wsl -ArgumentList '--distribution', $Distribution, '--user', 'root', '--', 'sh', '-c', `
            '"cd /var/lib/clickhouse && exec /opt/clickhouse/usr/bin/clickhouse server > /var/lib/clickhouse/server.log 2>&1"' -WindowStyle Hidden
        Wait-Listening 8123 3 { wsl --distribution $Distribution --user root -- tail -n 80 /var/lib/clickhouse/server.log }
        Set-Live CLICKHOUSE 8123 default
    }
}
