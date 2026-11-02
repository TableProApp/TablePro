# Builds and runs the data grid gate on a Windows runner (windows/docs/decisions/0003-data-grid-control.md, Gate).
# The core must already be built with Cargo's release profile in target/<triple>/release.
param(
    [Parameter(Mandatory)][ValidateSet('arm64', 'x64')][string]$Arch,
    [string]$Out = "$env:RUNNER_TEMP\gate",
    [ValidateSet('full', 'perf')][string]$Set = 'full'
)

$ErrorActionPreference = 'Stop'
$windows = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$rid = "win-$Arch"
$platform = if ($Arch -eq 'arm64') { 'ARM64' } else { 'x64' }
New-Item -ItemType Directory -Force -Path $Out, "$Out\shots" | Out-Null
$build = [ordered]@{ arch = $Arch }

. (Join-Path $PSScriptRoot 'desktop.ps1')
$build.first_logon = Clear-FirstLogon
$build.display = Set-Display -Width 1920 -Height 1080
$build.dotnet = (dotnet --version)

$sw = [Diagnostics.Stopwatch]::StartNew()
dotnet publish "$windows\tests\TablePro.DataGrid.Gate\TablePro.DataGrid.Gate.csproj" -c Release -r $rid "-p:Platform=$platform" -p:SkipCoreBuild=true -o "$env:RUNNER_TEMP\gate-app" | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'gate publish failed' }
dotnet publish "$windows\tests\TablePro.DataGrid.Gate.Uia\TablePro.DataGrid.Gate.Uia.csproj" -c Release -r $rid -o "$env:RUNNER_TEMP\gate-uia" | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'uia publish failed' }
$build.publish_s = [math]::Round($sw.Elapsed.TotalSeconds, 1)
$build | ConvertTo-Json | Set-Content "$Out\build-$Arch.json"

$uia = Start-Process "$env:RUNNER_TEMP\gate-uia\TablePro.DataGrid.Gate.Uia.exe" -ArgumentList "serve `"$Out`" 5400" -PassThru `
    -RedirectStandardOutput "$Out\uia-stdout.txt" -RedirectStandardError "$Out\uia-stderr.txt"

function Run-Gate([string]$name, [string]$arguments, [int]$timeout) {
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $p = Start-Process "$env:RUNNER_TEMP\gate-app\TablePro.DataGrid.Gate.exe" -ArgumentList "$arguments --name $name --out `"$Out`"" -PassThru
    if (-not $p.WaitForExit($timeout * 1000)) {
        Write-Host "!! $name timed out"
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        'timeout' | Set-Content "$Out\$name.timeout"
    }
    Write-Host "== $name exit=$($p.ExitCode) in $([int]$clock.Elapsed.TotalSeconds) s"
}

# The first process on a fresh runner pays any first-use cost, such as loading fallback fonts; the repeat shows drift.
Run-Gate 'first' '--perf-only' 1200
if ($Set -eq 'full') {
    Run-Gate 'gate' '' 2400
}
Run-Gate 'repeat' '--perf-only' 1200

New-Item -ItemType File -Force "$Out\stop" | Out-Null
Start-Sleep 2
Stop-Process -Id $uia.Id -Force -ErrorAction SilentlyContinue

$phases = 'v_smooth', 'v_page', 'v_random', 'h_smooth', 'h_page', 'xy_random', 'v_page_verify', 'xy_random_verify'
foreach ($name in 'first', 'gate', 'repeat') {
    $file = "$Out\$name.json"
    if (-not (Test-Path $file)) { continue }
    $json = Get-Content $file -Raw | ConvertFrom-Json -AsHashtable
    Write-Host "== $name"
    foreach ($phase in $phases) {
        $hb = $json["$phase.heartbeat_wait_ms"]
        if ($null -eq $hb) { continue }
        Write-Host ("{0,-18} block p50={1} p95={2} max={3} | gc {4} | worst {5}" -f $phase, $hb.p50, $hb.p95, $hb.max, $json["$phase.gc"], $json["$phase.worst_step"])
        if ($json.ContainsKey("$phase.verify")) { Write-Host ("{0,-18} verify {1}" -f '', ($json["$phase.verify"] | ConvertTo-Json -Compress -Depth 5)) }
    }
    foreach ($key in $json.Keys | Where-Object { $_ -match '^(error|unhandled|keyboard\.summary|keyboard\.shift|keyboard\.ctrl_a|selection\.|large_copy\.summary|high_contrast\.|text_scale\.|dpi\.|device_loss|content\.|font_warmup|core_query_ms|idle\.realized|xy_random_verify\.realized|insets|rendering|first_cells)' } | Sort-Object) {
        Write-Host ("{0}: {1}" -f $key, ($json[$key] | ConvertTo-Json -Compress -Depth 5))
    }
}
foreach ($file in Get-ChildItem "$Out\uia-*.json") { Write-Host "== $($file.Name)"; Get-Content $file.FullName | Out-Host }

# The bars: a UI-thread block of at most 50 ms in every phase, no stale, missing or misplaced cell, realized cells
# within the viewport, and the behavior checks of the full process.
$failures = @()
foreach ($name in 'first', 'gate', 'repeat') {
    $file = "$Out\$name.json"
    if (-not (Test-Path $file)) { if ($name -ne 'gate' -or $Set -eq 'full') { $failures += "${name}: no report" }; continue }
    $json = Get-Content $file -Raw | ConvertFrom-Json -AsHashtable
    if ($json.ContainsKey('error')) { $failures += "${name}: $($json['error'])" }
    foreach ($phase in $phases) {
        $hb = $json["$phase.heartbeat_wait_ms"]
        if ($null -ne $hb -and $hb.max -gt 50) { $failures += "$name $phase block max $($hb.max) ms" }
        $verify = $json["$phase.verify"]
        foreach ($part in 'right_after_step', 'one_frame_later') {
            if ($null -ne $verify -and ($verify[$part].stale + $verify[$part].missing + $verify[$part].misplaced + $verify[$part].header_problems) -gt 0) {
                $failures += "$name $phase $part $($verify[$part] | ConvertTo-Json -Compress)"
            }
        }
        $realized = $json["$phase.realized"]
        if ($null -ne $realized -and -not $realized.within_bound) { $failures += "$name $phase realized $($realized.cells) of $($realized.bound_cells)" }
    }
    if ($name -eq 'gate') {
        foreach ($check in @{ 'keyboard.summary' = 'wrong_cell=0 not_visible=0 timeouts=0'; 'keyboard.shift_extend' = 'ok=True'; 'keyboard.ctrl_a' = 'ok=True';
                'selection.shift_click' = 'ok=True'; 'selection.ctrl_c' = 'tsv_matches=True'; 'selection.frozen_click' = 'ok=True';
                'large_copy.summary' = 'matches=True'; 'content.emoji' = 'in_color=True'; 'content.rtl' = 'right_aligned=True';
                'content.null' = 'drawn=True'; 'content.two_lines_copy' = 'copied_ok=True' }.GetEnumerator()) {
            $value = "$($json[$check.Key])"
            if (-not $value.Contains($check.Value)) { $failures += "gate $($check.Key): $value" }
        }
    }
}
if ($failures.Count -gt 0) {
    Write-Host "== FAIL"
    $failures | ForEach-Object { Write-Host "  $_" }
    exit 1
}
Write-Host "== PASS"
