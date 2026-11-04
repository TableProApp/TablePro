Add-Type -AssemblyName System.Windows.Forms
Add-Type -Namespace TpGate -Name Display -MemberDefinition @'
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern bool EnumDisplaySettings(string device, int mode, ref DEVMODE dm);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int ChangeDisplaySettings(ref DEVMODE dm, int flags);
[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
public struct DEVMODE {
  [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
  public short dmSpecVersion; public short dmDriverVersion; public short dmSize; public short dmDriverExtra; public int dmFields;
  public int dmPositionX; public int dmPositionY; public int dmDisplayOrientation; public int dmDisplayFixedOutput;
  public short dmColor; public short dmDuplex; public short dmYResolution; public short dmTTOption; public short dmCollate;
  [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
  public short dmLogPixels; public int dmBitsPerPel; public int dmPelsWidth; public int dmPelsHeight; public int dmDisplayFlags; public int dmDisplayFrequency;
  public int dmICMMethod; public int dmICMIntent; public int dmMediaType; public int dmDitherType; public int dmReserved1; public int dmReserved2; public int dmPanningWidth; public int dmPanningHeight;
}
'@

function Set-Display([int]$Width, [int]$Height) {
    $before = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $dm = New-Object TpGate.Display+DEVMODE
    $dm.dmSize = [Runtime.InteropServices.Marshal]::SizeOf($dm)
    [TpGate.Display]::EnumDisplaySettings($null, -1, [ref]$dm) | Out-Null
    $dm.dmPelsWidth = $Width
    $dm.dmPelsHeight = $Height
    $dm.dmFields = 0x80000 -bor 0x100000
    $code = [TpGate.Display]::ChangeDisplaySettings([ref]$dm, 0)
    Start-Sleep 2
    $after = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    "before=$($before.Width)x$($before.Height) change=$code after=$($after.Width)x$($after.Height)"
}

Add-Type -Namespace TpGate -Name Foreground -MemberDefinition @'
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
'@

function Get-ForegroundProcess {
    [uint32]$owner = 0
    [TpGate.Foreground]::GetWindowThreadProcessId([TpGate.Foreground]::GetForegroundWindow(), [ref]$owner) | Out-Null
    $p = Get-Process -Id $owner -ErrorAction SilentlyContinue
    if ($p) { "$($p.ProcessName) ($owner)" } else { "pid $owner" }
}

# The Arm64 image opens "Choose privacy settings for your device" over the desktop; the policy stops it reopening.
function Clear-FirstLogon {
    $log = @("foreground before: $(Get-ForegroundProcess)")
    New-Item -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OOBE' -Force | Out-Null
    Set-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OOBE' -Name 'DisablePrivacyExperience' -Value 1 -Type DWord
    foreach ($name in 'WWAHost', 'CloudExperienceHostBroker', 'UserOOBEBroker') {
        foreach ($p in Get-Process -Name $name -ErrorAction SilentlyContinue) {
            $log += "stopping $($p.ProcessName) ($($p.Id)) title='$($p.MainWindowTitle)'"
            Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        }
    }
    Start-Sleep 3
    $log += "foreground after: $(Get-ForegroundProcess)"
    $log -join '; '
}

Add-Type -Namespace TpGate -Name Desktop -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SystemParametersInfo(uint action, uint param, IntPtr value, uint flags);
[DllImport("user32.dll")] public static extern bool SystemParametersInfo(uint action, uint param, ref int value, uint flags);
'@

# windows-2025 moves a dragged window as an outline, so a tab merged into another strip only on release.
function Set-DragFullWindows {
    $before = 0
    [TpGate.Desktop]::SystemParametersInfo(0x0026, 0, [ref]$before, 0) | Out-Null
    # SPI_SETDRAGFULLWINDOWS, saved and broadcast as the Performance Options dialog does.
    [TpGate.Desktop]::SystemParametersInfo(0x0025, 1, [IntPtr]::Zero, 3) | Out-Null
    $after = 0
    [TpGate.Desktop]::SystemParametersInfo(0x0026, 0, [ref]$after, 0) | Out-Null
    "drag full windows before=$before after=$after"
}

# The Arm64 image runs wsl.exe a minute after first logon, and its update prompt opens over the desktop.
function Start-WslWatch([string]$Log, [int]$Minutes = 20) {
    $script = @"
`$end = (Get-Date).AddMinutes($Minutes)
while ((Get-Date) -lt `$end) {
    foreach (`$p in Get-CimInstance Win32_Process -Filter "Name='wsl.exe'") {
        `$parent = Get-CimInstance Win32_Process -Filter "ProcessId=`$(`$p.ParentProcessId)"
        Add-Content -Path '$Log' -Value "`$(Get-Date -Format o) stopping wsl.exe `$(`$p.ProcessId) from `$(`$parent.Name): `$(`$parent.CommandLine)"
        Stop-Process -Id `$p.ProcessId -Force -ErrorAction SilentlyContinue
    }
    foreach (`$w in Get-Process WindowsTerminal, conhost -ErrorAction SilentlyContinue | Where-Object { `$_.MainWindowTitle -like '*wsl.exe*' }) {
        Add-Content -Path '$Log' -Value "`$(Get-Date -Format o) closing `$(`$w.ProcessName) `$(`$w.Id) '`$(`$w.MainWindowTitle)'"
        Stop-Process -Id `$w.Id -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Milliseconds 500
}
"@
    New-Item -ItemType File -Path $Log -Force | Out-Null
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
    Start-Process pwsh -WindowStyle Hidden -ArgumentList '-NoProfile', '-EncodedCommand', $encoded
}
