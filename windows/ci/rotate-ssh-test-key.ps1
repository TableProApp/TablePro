param([Parameter(Mandatory)][ValidateSet('Rotate', 'Restore')][string]$Action)

$ErrorActionPreference = 'Stop'
$directory = Join-Path $env:ProgramData 'ssh'
$config = Join-Path $directory 'sshd_config'
$backup = Join-Path $directory 'tablepro_ui_sshd_config'
$key = Join-Path $directory 'tablepro_ui_host_key'
$keygen = Join-Path $env:WINDIR 'System32\OpenSSH\ssh-keygen.exe'

if ($Action -eq 'Rotate') {
    if (Test-Path $backup) { throw 'The previous SSH key rotation was not restored.' }
    Copy-Item $config $backup
    Remove-Item $key, "$key.pub" -ErrorAction SilentlyContinue
    & $keygen -q -t ed25519 -N '' -f $key
    if ($LASTEXITCODE -ne 0) { throw 'Generating the replacement SSH host key failed.' }
    & icacls.exe $key /setowner SYSTEM | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Setting the SSH host key owner failed.' }
    # ssh-keygen grants its creator explicitly; sshd must see only SYSTEM and Administrators on a host key.
    $permissions = [System.Security.AccessControl.FileSecurity]::new()
    $permissions.SetAccessRuleProtection($true, $false)
    foreach ($sid in 'S-1-5-18', 'S-1-5-32-544') {
        $principal = [System.Security.Principal.SecurityIdentifier]::new($sid)
        $rule = [System.Security.AccessControl.FileSystemAccessRule]::new($principal, 'FullControl', 'Allow')
        $permissions.AddAccessRule($rule)
    }
    [System.IO.FileSystemAclExtensions]::SetAccessControl([System.IO.FileInfo]::new($key), $permissions)
    $lines = Get-Content $config | Where-Object { $_ -notmatch '^\s*HostKey\s' }
    Set-Content -Encoding ascii $config (@("HostKey `"$($key.Replace('\', '/'))`"") + $lines)
}
elseif (Test-Path $backup) {
    Copy-Item $backup $config -Force
}
else {
    return
}

# Existing child sessions must close too, so the app sees a lost tunnel and reconnects to the new key.
Stop-Service sshd
Get-Process sshd* -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Service sshd

if ($Action -eq 'Rotate') {
    $fingerprint = & $keygen -lf "$key.pub" -E sha256
    if ($LASTEXITCODE -ne 0) { throw 'Reading the replacement SSH fingerprint failed.' }
    ($fingerprint -split '\s+')[1]
}
else {
    Remove-Item $backup, $key, "$key.pub" -ErrorAction SilentlyContinue
}
