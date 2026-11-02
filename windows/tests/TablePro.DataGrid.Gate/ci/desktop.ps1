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

# The Windows 11 Arm64 image signs in to "Choose privacy settings for your device", which covers the desktop and
# keeps the foreground. The policy keeps it from coming back; the open page still has to be closed.
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
