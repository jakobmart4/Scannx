# Full-system stutter logger, Task Manager style. Read-only: changes nothing.
# Samples about every 1-2 s: CPU (load + real clock), queue, RAM, commit, paging, network, GPU, every disk, and the game process.
# Every 3rd sample also pings the gateway and 1.1.1.1 and reads nvidia-smi (temperature, clock, throttle bits).
# F9 = mark a stutter (works while the game has focus). Each mark and each automatic spike also writes a snapshot of the top
# processes (CPU, RAM, disk IO, GPU) to events.txt. Summary.txt ends with a verdict and a per-mark diagnosis.
# Each run gets its own folder: Desktop\disk-log\run-<date_time>\ . Asks for the duration unless -Minutes is given.
# Frame times: when run as admin and an Intel-signed PresentMon-<version>-x64.exe is found (-PresentMon, this folder, or RivaTuner's plugin folder),
# PresentMon records the game's frames to frames.csv and the summary adds frame-time hitches.
# -Summarize <run folder> re-creates summary.txt for an existing run (also handy to test the verdict logic).
param([double]$Minutes = 0, [string[]]$Game = @('r5apex_dx12','r5apex'), [string]$Dir = (Join-Path ([Environment]::GetFolderPath('Desktop')) 'disk-log'), [string]$Summarize = '', [string]$PresentMon = '')
$ErrorActionPreference = 'SilentlyContinue'
$Game = @($Game | ForEach-Object { $_ -replace '\.exe$', '' })   # 'r5apex.exe' would become --process_name r5apex.exe.exe and never match
$PSDefaultParameterValues['Set-Content:Encoding'] = 'utf8'; $PSDefaultParameterValues['Add-Content:Encoding'] = 'utf8'   # PS 5.1 would write ANSI (Add-Content) / UTF-16 (Tee-Object): grep and editors choke on it

function Write-Summary($run) {
  $csvF = Join-Path $run 'log.csv'; $evF = Join-Path $run 'events.txt'; $sumF = Join-Path $run 'summary.txt'
  $rows = @(Import-Csv $csvF)
  if (-not $rows.Count) { 'No samples.'; return }
  $cols = (Get-Content $csvF -TotalCount 1) -split ','
  $dcols = @($cols | Where-Object { $_ -match ' latMs$' } | ForEach-Object { $_ -replace ' latMs$','' })
  $g = @($rows | Where-Object gameOn -eq '1'); $use = @(if ($g.Count) { $g } else { $rows })   # @(): a 1-row log would unroll to a scalar without .Count
  $warm = ''
  $secs = { param($t) $q = $t -split ':'; [int]$q[0] * 3600 + [int]$q[1] * 60 + [int]$q[2] }   # note: seconds of the day, a run across midnight is not handled
  $clock = { param($s) [timespan]::FromSeconds([math]::Floor($s)).ToString('hh\:mm\:ss') }
  # frame times from PresentMon (frames.csv): only the game's busiest swap chain, sorted by time
  $fT = [double[]]@(); $fMs = [double[]]@(); $fs = @(); $frF = Join-Path $run 'frames.csv'
  if (Test-Path $frF) {
    $by = @{}; $iT = -1; $iF = -1; $iS = -1
    foreach ($ln in [IO.File]::ReadLines($frF)) {
      $fc = $ln.Split(',')
      # the last *DateTime column wins: CPUStartDateTime when TimeInDateTime is there too (PresentMon 2.x)
      if ($iT -lt 0) { for ($j = 0; $j -lt $fc.Count; $j++) { if ($fc[$j] -match 'DateTime$') { $iT = $j } elseif ($fc[$j] -eq 'MsBetweenPresents') { $iF = $j } elseif ($fc[$j] -eq 'SwapChainAddress') { $iS = $j } }
        if ($iT -lt 0 -or $iF -lt 0) { break }; continue }   # header without --date_time / frame times: nothing to read
      $ms = 0.0
      if ($fc.Count -le [math]::Max($iT, $iF) -or -not [double]::TryParse($fc[$iF], [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$ms)) { continue }
      $hms = $fc[$iT].Split(' ')[-1].Split(':')   # "2026-10-25 9:03:07.123456789", local time
      if ($hms.Count -ne 3) { continue }   # 'NA' or blank time: skip the row, or T and F lose step
      $sc = if ($iS -ge 0) { $fc[$iS] } else { '' }
      if (-not $by.ContainsKey($sc)) { $by[$sc] = [pscustomobject]@{ T = New-Object Collections.Generic.List[double]; F = New-Object Collections.Generic.List[double] } }
      $by[$sc].T.Add([int]$hms[0] * 3600 + [int]$hms[1] * 60 + [double]$hms[2]); $by[$sc].F.Add($ms)
    }
    $best = $by.Values | Sort-Object { $_.F.Count } -Descending | Select-Object -First 1
    if ($best) { $fT = $best.T.ToArray(); $fMs = $best.F.ToArray()
      # PresentMon 2.3.1 writes its "local" time shifted by the UTC offset (seen: +2 h). Align with log.csv by the whole half hours between
      # the first frame in the file and the first game row (the game presents within seconds of starting; time zones are whole or half hours).
      # Shift and wrap BEFORE sorting: the skewed clock passes midnight at 22:00 real time.
      $g0 = if ($g.Count) { $g[0] } else { $rows[0] }; $sh = 1800 * [math]::Round(($fT[0] - (& $secs $g0.time)) / 1800)
      if ($sh) { for ($j = 0; $j -lt $fT.Count; $j++) { $fT[$j] = ((($fT[$j] - $sh) % 86400) + 86400) % 86400 } }
      [array]::Sort($fT, $fMs) }
  }
  $FrameAt = { param($t) $x = [array]::BinarySearch($fT, [double]$t); if ($x -lt 0) { -bnot $x } else { $x } }   # first frame at or after second $t
  # playing span from the frame rate: first to last 30 s (6 windows of 5 s) at >= 80 % of the median 5 s frame count. This cuts the
  # loading screens at the start and the end (Apex loads ~3 min, longer than the 120 s rule below); loading screens mid-session stay in.
  # 5 s windows: the real Apex exit went from 137 fps to a 966 ms frame within one 10 s window.
  $span = $null
  if ($fT.Count) {
    $w0 = [math]::Floor($fT[0] / 5); $wc = New-Object int[] ([math]::Floor($fT[-1] / 5) - $w0 + 1)
    foreach ($x in $fT) { $wc[[int]([math]::Floor($x / 5) - $w0)]++ }
    $srt = [int[]]$wc.Clone(); [array]::Sort($srt); $thr = 0.8 * $srt[[int][math]::Floor(($srt.Count - 1) / 2)]
    $ok = @(if ($wc.Count -ge 6) { 0..($wc.Count - 6) | Where-Object { $i0 = $_; @($wc[$i0..($i0 + 5)] | Where-Object { $_ -lt $thr }).Count -eq 0 } })
    if ($ok.Count) { $span = @((5 * ($w0 + $ok[0])), (5 * ($w0 + $ok[-1] + 6))) }
  }
  if ($g.Count) {
    # the game's launch (a 200 000 pages/s read burst) and its exit (working set falls to ~0) are normal, not stutter: leave them out of the verdict.
    # With frame times the playing span decides; without them, skip 120 s after a launch seen in the log.
    $from = if ([double]$g[0].gameMB -lt 1500) { (& $secs $g[0].time) + 120 } else { 0 }
    # (the last 5 samples are cut off too: that is the game closing)
    $core = @($g[0..([math]::Max(0, $g.Count - 6))] | Where-Object { $t = & $secs $_.time; [double]$_.gameMB -ge 200 -and $(if ($span) { $t -ge $span[0] -and $t -lt $span[1] } else { $t -ge $from }) })
    if ($core.Count) { $use = $core; if ($core.Count -lt $g.Count) { $warm = if ($span) { ", loading skipped by frame rate: $(& $clock $span[0])-$(& $clock $span[1]) used" } else { ", game start-up/exit skipped" } } }
  }
  $Vals = { param($r, $name) @($r | ForEach-Object { [double]$_.$name }) }   # not $N/$n: PowerShell variables are case-insensitive
  $Got = { param($r, $name) @($r | ForEach-Object { "$($_.$name)" } | Where-Object { $_ -ne '' } | ForEach-Object { [double]$_ }) }   # skips blanks (= not measured); [double]'' would be 0
  $P95 = { param($s) $s = @($s | Sort-Object); if ($s.Count) { $s[[math]::Ceiling(0.95 * $s.Count) - 1] } else { 0 } }
  $Rt = { param($s) if ($s.Count) { "max $(($s | Measure-Object -Maximum).Maximum) / p95 $(& $P95 $s) ms" } else { 'n/a' } }   # n/a = no successful ping
  $spikes = @(Get-Content $evF | Where-Object { $_ -match ' SPIKE ' }).Count
  $L = @("summary $(Get-Date) | $($rows.Count) samples, $($use.Count) used ($(if ($g.Count) { 'game running' } else { 'game NOT detected: all rows' })$warm) | marks (F9): $(@($rows | Where-Object mark -eq 'MARK').Count) | auto spikes: $spikes")
  # gpuMaxPct is clamped when logged; older logs may hold a counter glitch (1.8e14): drop values over 100 here too
  $stat = @('cpu','cpuQueue','availMB','commitPct','pgIn','pgOut','faults','netMBs','gpuMaxPct','vramMB') + @('standbyMB','freeMB','pagefilePct' | Where-Object { $cols -contains $_ }) + @($cols | Where-Object { $_ -match ' latMs$| busyPct$' }) + @('cpuMHz','gpuTempC','gpuClockMHz','pingGwMs','pingNetMs' | Where-Object { $cols -contains $_ })
  foreach ($n in $stat) {
    $v = & $Vals $use $n; if ($n -match 'busyPct$|^gpuMaxPct$|^cpu$') { $v = @($v | Where-Object { $_ -le 100 } | ForEach-Object { $_ }) }
    if ($n -match '^(cpuMHz|gpuTempC|gpuClockMHz|ping)') { $v = @(& $Got $use $n | Where-Object { $_ -ge 0 }) }   # ping -1 = lost, counted below
    if ($v.Count) { $m = $v | Measure-Object -Average -Minimum -Maximum; $L += '{0,-16} min {1,9:N1}  avg {2,9:N1}  max {3,9:N1}' -f $n, $m.Minimum, $m.Average, $m.Maximum }
  }
  if ($cols -contains 'pingNetMs') {
    $pg1 = @(& $Got $use pingGwMs); $pn1 = @(& $Got $use pingNetMs)
    $L += "pingLoss   gateway lost $(@($pg1 | Where-Object { $_ -lt 0 }).Count) of $($pg1.Count), internet lost $(@($pn1 | Where-Object { $_ -lt 0 }).Count) of $($pn1.Count)"
  }
  # frame stats only over the time span of the rows used above
  if ($fT.Count) {
    $f0 = & $FrameAt (& $secs $use[0].time); $f1 = (& $FrameAt ((& $secs $use[-1].time) + 2)) - 1
    if ($span) { $f0 = [math]::Max($f0, (& $FrameAt $span[0])); $f1 = [math]::Min($f1, (& $FrameAt $span[1]) - 1) }   # row + 2 s can reach past the span end
    if ($f1 -ge $f0) { $fs = [double[]]$fMs[$f0..$f1] }
  }
  if ($fs.Count) {
    # hitch = a frame over 3x the median frame time (and over 25 ms, so a 300 fps game does not flag 10 ms frames)
    $srt = [double[]]$fs.Clone(); [array]::Sort($srt)
    $fMed = $srt[[int][math]::Floor(($srt.Count - 1) / 2)]; $fP99 = $srt[[int][math]::Ceiling(0.99 * $srt.Count) - 1]
    $hitchMs = [math]::Max(25, 3 * $fMed); $nHi = 0; $fSum = 0.0; $wI = 0
    for ($j = 0; $j -lt $fs.Count; $j++) { $fSum += $fs[$j]; if ($fs[$j] -gt $hitchMs) { $nHi++ }; if ($fs[$j] -gt $fs[$wI]) { $wI = $j } }
    $L += 'frames           {0} frames, avg {1:N0} fps, median {2:N1} ms, p99 {3:N1} ms, max {4:N1} ms, {5} hitches over {6:N0} ms' -f $fs.Count, (1000 * $fs.Count / $fSum), $fMed, $fP99, $fs[$wI], $nHi, $hitchMs
  }
  $availMin = ((& $Vals $use availMB) | Measure-Object -Minimum).Minimum; $pgInMax = ((& $Vals $use pgIn) | Measure-Object -Maximum).Maximum
  $commitMax = ((& $Vals $use commitPct) | Measure-Object -Maximum).Maximum
  $gp = @((& $Vals $use gpuMaxPct) | Where-Object { $_ -le 100 }); $gpuHi = if ($gp.Count) { 100 * @($gp | Where-Object { $_ -gt 95 }).Count / $gp.Count } else { 0 }
  $cp = & $Vals $use cpu; $cpuHi = 100 * @($cp | Where-Object { $_ -gt 90 -and $_ -le 100 }).Count / [math]::Max(1, $cp.Count)
  $memBad = ($availMin -lt 1000) -or ($pgInMax -gt 50000)
  $L += ''; $L += 'Verdict:'; $any = $false
  if ($memBad) { $any = $true; $L += " - MEMORY pressure: free RAM min $([int]$availMin) MB, paging in up to $([int]$pgInMax)/s. Close background apps (browser, dev tools, chat and AI apps) before the game, or add RAM." }
  if ($memBad -and ($cols -contains 'standbyMB')) {
    $low = $use[[array]::IndexOf(@(& $Vals $use availMB), $availMin)]
    $L += " - At the lowest point ($($low.time)) available RAM $([int]$low.availMB) MB = standby cache $([int]$low.standbyMB) MB + free $([int]$low.freeMB) MB. RAM cleaners / 'empty standby list' tools can only release the standby part, so they cannot fix this; the rest is held by programs."
  }
  if ($commitMax -ge 95) { $any = $true; $L += " - COMMIT charge reached $commitMax % (RAM + pagefile nearly full): the system has little room left; same cure as above." }
  if ($g.Count -and $availMin -lt 2000) {   # trimming = the game's working set shrinks after its peak while free RAM is short
    $gm = @(& $Vals $use gameMB); $mx = ($gm | Measure-Object -Maximum).Maximum; $pk = [array]::IndexOf($gm, $mx); $mn = (@($gm[$pk..($gm.Count - 1)]) | Measure-Object -Minimum).Minimum
    if ($mn -lt 0.8 * $mx) { $any = $true; $L += " - Windows trimmed the game's memory from $([int]$mx) to $([int]$mn) MB (the freed pages go to the pagefile/standby list). When you play again they are read back from disk = hitches right after alt-tab or a long AFK." } }
  foreach ($d in $dcols) { $lt = & $Vals $use "$d latMs"; $mx = ($lt | Measure-Object -Maximum).Maximum; $cnt = @($lt | Where-Object { $_ -gt 50 }).Count
    if ($mx -gt 50) { $any = $true; $L += " - DISK $d latency up to $([int]$mx) ms ($cnt samples over 50 ms). Check the disk (health, full drive, power saving) and the IO lines in events.txt." } }
  if ($gpuHi -ge 3) { $any = $true; $L += " - GPU above 95 % in $([int]$gpuHi) % of samples: likely GPU-bound (lower settings, set an FPS limit)." }
  if ($cpuHi -ge 3) { $any = $true; $L += " - CPU above 90 % in $([int]$cpuHi) % of samples: CPU-bound or background load (see CPU lines in events.txt)." }
  if ($cols -contains 'cpuMHz') {   # idle down-clocking is normal: only rows under >50 % load count
    $hzPeak = ((& $Got $use cpuMHz) | Measure-Object -Maximum).Maximum
    $hzLow = @($use | Where-Object { "$($_.cpuMHz)" -ne '' -and [double]$_.cpu -gt 50 -and [double]$_.cpuMHz -lt 0.6 * $hzPeak })
    if ($hzLow.Count -ge 3) { $any = $true; $L += " - CPU clock fell to $(((& $Got $hzLow cpuMHz) | Measure-Object -Minimum).Minimum) MHz (peak $hzPeak MHz) under >50 % load in $($hzLow.Count) samples: thermal or power throttling, or a power-plan limit." }
  }
  if ($cols -contains 'pingNetMs') {
    $okG = @($pg1 | Where-Object { $_ -ge 0 }); $okN = @($pn1 | Where-Object { $_ -ge 0 })
    $lossPct = 100 * @($pg1 + $pn1 | Where-Object { $_ -lt 0 }).Count / [math]::Max(1, $pg1.Count + $pn1.Count)
    if ($lossPct -ge 1 -or @($okG | Where-Object { $_ -gt 50 }).Count -ge 2 -or @($okN | Where-Object { $_ -gt 150 }).Count -ge 3) {
      $any = $true; $L += ' - NETWORK: {0:N1} % of pings lost, gateway RTT {1}, internet RTT {2}: lag spikes come from the connection (Wi-Fi, router, background downloads), not the PC.' -f $lossPct, (& $Rt $okG), (& $Rt $okN) }
  }
  # nvidia throttle bits that count: 8 HW slowdown, 32 SW thermal, 64 HW thermal, 128 HW power brake. NOT 1 idle, 2 app clocks, 256 display clocks, and NOT 4 SW power cap:
  # bit 4 is simply "GPU runs at its power limit" and is set all the time at ordinary load, even when the GPU is cool and below full load, so it is only reported as info.
  $thMask = 8 + 32 + 64 + 128
  if ($cols -contains 'gpuThrottle') {
    $th = @(& $Got $use gpuThrottle); $BitPct = { param($bits) 100 * @($th | Where-Object { ([long]$_ -band $bits) -ne 0 }).Count / [math]::Max(1, $th.Count) }
    $thPct = & $BitPct $thMask; $tMax = ((& $Got $use gpuTempC) | Measure-Object -Maximum).Maximum
    if ($thPct -ge 3) { $any = $true; $L += " - GPU throttling (thermal/HW slowdown) in $([int]$thPct) % of measured samples, GPU temperature max $(if ($null -ne $tMax) { "$tMax C" } else { 'n/a' }). Check cooling, fan curve and the power limit." }
    $pcPct = & $BitPct 4; if ($pcPct -gt 0) { $L += "   info: GPU power cap (SW power limit) was active in $([int]$pcPct) % of measured samples; normal when the GPU works at its power limit, not counted as trouble." }
  }
  if ($fs.Count -and $nHi) {
    $L += " - FRAME hitches: $nHi frames over $([int]$hitchMs) ms, worst $([int]$fs[$wI]) ms at $([timespan]::FromSeconds([math]::Floor($fT[$f0 + $wI])).ToString('hh\:mm\:ss'))" + $(if ($any) { '; compare their times with the lines above.' } else { ', while RAM, disk, CPU, GPU and network looked normal: they come from the game or the driver (for example shader compilation or asset streaming), not from a system bottleneck.' })
    $any = $true
  }
  if (-not $any) {
    if ($fs.Count) { $L += ' - no memory, disk, GPU, CPU or network trouble and no frame hitches visible (frame time p99 {0:N1} ms).' -f $fP99 }
    else { $L += ' - no memory, disk, GPU, CPU or network trouble visible; the stutter may come from the game, drivers or frame pacing itself (next step: PresentMon frame times). Mark it with F9 next time.' }
  }
  $mk = @(0..($rows.Count - 1) | Where-Object { $rows[$_].mark -eq 'MARK' })
  if ($mk.Count) {
    $L += ''; $L += 'F9 marks (numbers within +-3 samples; the cause list is empty when everything looked normal):'
    foreach ($i in $mk) {
      $w = $rows[[math]::Max(0, $i - 3)..[math]::Min($rows.Count - 1, $i + 3)]
      $a = ((& $Vals $w availMB) | Measure-Object -Minimum).Minimum; $pi = ((& $Vals $w pgIn) | Measure-Object -Maximum).Maximum
      $c = ((& $Vals $w cpu) | Measure-Object -Maximum).Maximum; $gv = @((& $Vals $w gpuMaxPct) | Where-Object { $_ -le 100 }); $gm2 = ($gv | Measure-Object -Maximum).Maximum
      $dl = 0; foreach ($d in $dcols) { $dl = [math]::Max($dl, ((& $Vals $w "$d latMs") | Measure-Object -Maximum).Maximum) }
      $why = @(); if ($a -lt 1000 -or $pi -gt 5000) { $why += 'RAM/paging' }; if ($dl -gt 50) { $why += 'DISK' }; if ($c -gt 90) { $why += 'CPU' }; if ($gm2 -gt 95) { $why += 'GPU' }
      if ($cols -contains 'pingNetMs') { $wg = @(& $Got $w pingGwMs); $wn = @(& $Got $w pingNetMs)
        if (@($wg + $wn | Where-Object { $_ -lt 0 }).Count -or @($wg | Where-Object { $_ -gt 50 }).Count -or @($wn | Where-Object { $_ -gt 150 }).Count) { $why += 'NET' } }
      if (($cols -contains 'cpuMHz') -and @($w | Where-Object { "$($_.cpuMHz)" -ne '' -and [double]$_.cpu -gt 50 -and [double]$_.cpuMHz -lt 0.6 * $hzPeak }).Count) { $why += 'CPU clock' }
      if (($cols -contains 'gpuThrottle') -and @(& $Got $w gpuThrottle | Where-Object { ([long]$_ -band $thMask) -ne 0 }).Count) { $why += 'GPU throttle' }
      $fx = ''; $fm = 0
      if ($fs.Count) { $wEnd = (& $secs $w[-1].time) + 1
        for ($j = & $FrameAt ((& $secs $w[0].time) - 1); $j -lt $fT.Count -and $fT[$j] -le $wEnd; $j++) { $fm = [math]::Max($fm, $fMs[$j]) }
        $fx = ', frame max {0:N0} ms' -f $fm }
      $res = if ($why) { $why -join ' + ' } elseif ($fs.Count -and $fm -gt $hitchMs) { 'frame hitch while RAM, disk, CPU, GPU and network were normal: game or driver side' }
        else { 'RAM, disk, CPU, GPU and network all normal: not a system bottleneck' + $(if ($fs.Count) { '; no frame hitch either' } else { '' }) }
      $L += ('  {0}  free {1:N0} MB, pgIn {2:N0}/s, cpu {3:N0}%, gpu {4:N0}%, disk {5:N0} ms' -f $rows[$i].time, $a, $pi, $c, $gm2, $dl) + $fx + "  ->  $res"
    }
  }
  $L += ''; $L += 'Details of every mark and spike, with top processes: events.txt'
  $L | Set-Content $sumF; $L | Write-Host; Write-Host "Files: $run"
}

if ($Summarize) { Write-Summary $Summarize; return }
Add-Type -Namespace W -Name K -MemberDefinition '[DllImport("user32.dll")] public static extern short GetAsyncKeyState(int k);'

if ($Minutes -le 0) {
  $ans = Read-Host 'How many minutes to log? Enter = 60'
  $Minutes = 60; $p = 0.0
  if ([double]::TryParse($ans, [ref]$p) -and $p -gt 0) { $Minutes = $p }
}

$run = Join-Path $Dir ('run-' + (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'))
New-Item $run -ItemType Directory -Force | Out-Null
$csv = Join-Path $run 'log.csv'; $ev = Join-Path $run 'events.txt'

$cores = [math]::Max(1, [int]$env:NUMBER_OF_PROCESSORS)
$disks = (Get-Counter '\PhysicalDisk(*)\% Disk Time').CounterSamples | Where-Object InstanceName -ne '_total' | ForEach-Object InstanceName
if (-not $disks) { 'Cannot read performance counters. Run "lodctr /r" as admin.'; return }

$paths = @('\Processor(_Total)\% Processor Time','\System\Processor Queue Length','\Memory\Available MBytes','\Memory\% Committed Bytes In Use','\Memory\Pages Input/sec','\Memory\Pages Output/sec','\Memory\Page Faults/sec','\Memory\Modified Page List Bytes','\Memory\Standby Cache Normal Priority Bytes','\Memory\Standby Cache Reserve Bytes','\Memory\Standby Cache Core Bytes','\Memory\Free & Zero Page List Bytes','\Paging File(_Total)\% Usage','\Processor Information(_Total)\Processor Frequency','\Processor Information(_Total)\% Processor Performance','\Network Interface(*)\Bytes Total/sec','\GPU Engine(*)\Utilization Percentage','\GPU Adapter Memory(*)\Dedicated Usage')
foreach ($d in $disks) { $paths += "\PhysicalDisk($d)\Avg. Disk sec/Transfer","\PhysicalDisk($d)\% Disk Time","\PhysicalDisk($d)\Current Disk Queue Length","\PhysicalDisk($d)\Disk Bytes/sec" }

$cols = @('time','cpu','cpuQueue','availMB','commitPct','pgIn','pgOut','faults','modMB','netMBs','gpuMaxPct','vramMB','gameOn','gameMB','mark','standbyMB','freeMB','pagefilePct','cpuMHz','pingGwMs','pingNetMs','gpuTempC','gpuClockMHz','gpuThrottle')
foreach ($d in $disks) { $cols += "$d latMs","$d busyPct","$d queue","$d MBs" }
($cols -join ',') | Set-Content $csv

# value helpers for the current sample ($script:cs)
function One($pat) { $x = $script:cs | Where-Object { $_.Path -like $pat } | Select-Object -First 1; if ($x) { [double]$x.CookedValue } else { 0 } }
function Sum($pat) { $x = $script:cs | Where-Object { $_.Path -like $pat }; if ($x) { [double]($x | Measure-Object CookedValue -Sum).Sum } else { 0 } }
function Max($pat) { $x = $script:cs | Where-Object { $_.Path -like $pat }; if ($x) { [double]($x | Measure-Object CookedValue -Maximum).Maximum } else { 0 } }
function Rtt($t) { if ($t -and $t.Status -eq 'RanToCompletion' -and $t.Result.Status -eq 'Success') { [int]$t.Result.RoundtripTime } else { -1 } }   # -1 = lost/timeout/error

# resolved once: default gateway (blank pingGwMs if none) and nvidia-smi (blank gpu columns if absent)
$gw = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' | Sort-Object RouteMetric | Select-Object -First 1).NextHop
$smi = Get-Command nvidia-smi | Select-Object -First 1
$pingHosts = @(@($gw, '1.1.1.1') | Where-Object { $_ })
$k = 0

function Snapshot($tag, $ts) {
  $ps = (Get-Counter '\Process(*)\% Processor Time','\Process(*)\Working Set','\Process(*)\IO Data Bytes/sec','\GPU Engine(*)\Utilization Percentage' -SampleInterval 1 -MaxSamples 1).CounterSamples
  $ps = $ps | Where-Object { $_.InstanceName -notmatch '^(_total|idle)$' }
  $lines = @("--- $ts $tag")
  $lines += $ps | Where-Object { $_.Path -like '*\process(*)\% processor time' } | Sort-Object CookedValue -Descending | Select-Object -First 5 |
    ForEach-Object { '    CPU  {0,-28} {1,6:N1}%' -f $_.InstanceName, ($_.CookedValue / $cores) }
  $lines += $ps | Where-Object { $_.Path -like '*\process(*)\working set' } | Sort-Object CookedValue -Descending | Select-Object -First 5 |
    ForEach-Object { '    RAM  {0,-28} {1,6:N0} MB' -f $_.InstanceName, ($_.CookedValue / 1MB) }
  $lines += $ps | Where-Object { $_.Path -like '*\process(*)\io data bytes/sec' } | Sort-Object CookedValue -Descending | Select-Object -First 3 |
    ForEach-Object { '    IO   {0,-28} {1,6:N1} MB/s' -f $_.InstanceName, ($_.CookedValue / 1MB) }
  $gp = $ps | Where-Object { $_.Path -like '*gpu engine*' -and $_.InstanceName -match 'pid_(\d+)' } |
    ForEach-Object { [pscustomobject]@{ ProcId = [int]($_.InstanceName -replace '^.*pid_(\d+).*$','$1'); V = $_.CookedValue } } |
    Group-Object ProcId | ForEach-Object { [pscustomobject]@{ ProcId = [int]$_.Name; V = ($_.Group | Measure-Object V -Sum).Sum } } |
    Sort-Object V -Descending | Select-Object -First 3
  $lines += $gp | ForEach-Object { $n = (Get-Process -Id $_.ProcId -ErrorAction SilentlyContinue).ProcessName; '    GPU  {0,-28} {1,6:N1}%' -f $n, [math]::Min(100, $_.V) }
  $lines | Add-Content $ev
}

# frame times: run PresentMon only if Intel signed it (this script runs as admin) and we are admin (ETW tracing needs it); stopped in finally,
# and --timed (run length + 60 s) stops it too if this window is closed with X (finally does not run then)
$pm = if ($PresentMon) { Get-Item $PresentMon } else { Get-ChildItem $PSScriptRoot, "${env:ProgramFiles(x86)}\RivaTuner Statistics Server\Plugins\Client\PresentMonDataProvider" -Filter 'PresentMon-*-x64.exe' |
  Sort-Object { [version](($_.Name -split '-')[1]) } -Descending | Select-Object -First 1 }
$pmP = $null; $pmNote = 'off (no PresentMon found: put PresentMon-<version>-x64.exe from Intel next to this script)'
if ($pm) {
  $sig = Get-AuthenticodeSignature $pm.FullName
  if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'O=Intel Corporation') { $pmNote = "off ($($pm.Name) is not signed by Intel)" }
  elseif (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { $pmNote = 'off (needs admin: start with Scannx.cmd)' }
  else {
    $pmErr = Join-Path $run 'presentmon-err.txt'
    $pmP = Start-Process $pm.FullName -ArgumentList (@($Game | ForEach-Object { "--process_name $_.exe" }) + "--output_file `"$run\frames.csv`" --date_time --no_console_stats --stop_existing_session --session_name Scannx --timed $([int]($Minutes * 60) + 60) --terminate_after_timed") -WindowStyle Hidden -RedirectStandardError $pmErr -PassThru
    if ($pmP) { [void]$pmP.Handle; Start-Sleep 2 }   # holding the handle keeps ExitCode readable; exiting within 2 s = it could not record
    if (-not $pmP) { $pmNote = "off ($($pm.Name) did not start)" }
    elseif ($pmP.HasExited) { $pmNote = "off ($($pm.Name) exited with code $($pmP.ExitCode): $(@(Get-Content $pmErr | Where-Object { $_ -match 'error' })[0]))"; $pmP = $null
      # an anti-cheat that is already running (EA Javelin in Apex) makes every new trace session fail, even for admin: PresentMon issue #573
      if (Get-Process EAAntiCheat* -ErrorAction SilentlyContinue) { $pmNote += ' EA AntiCheat is running: close the game and start disk-log BEFORE the game.' } }
    else { $pmNote = "$($pm.Name) -> frames.csv" }
  }
}

$end = (Get-Date).AddMinutes($Minutes)
$lastSnap = [datetime]::MinValue
$hello = "Logging for $([math]::Round($Minutes,1)) min to $run. Play; F9 = mark stutter; Ctrl+C = stop."
@($hello, "Frame times: $pmNote") | Set-Content $ev; Write-Host $hello; Write-Host "Frame times: $pmNote"

try {
  while ((Get-Date) -lt $end) {
    $pressed = ([W.K]::GetAsyncKeyState(0x78) -band 1) -ne 0   # F9 pressed since the previous check
    $script:cs = (Get-Counter $paths -SampleInterval 1 -MaxSamples 1).CounterSamples
    $ts = (Get-Date).ToString('HH:mm:ss')

    $cpuV   = One '*\processor(_Total)\% processor time'
    $queueV = One '*\system\processor queue length'
    $avail  = One '*\memory\available mbytes'
    $commit = One '*\memory\% committed bytes in use'
    $pgIn   = [math]::Round((One '*\memory\pages input/sec'), 0)
    $pgOut  = [math]::Round((One '*\memory\pages output/sec'), 0)
    $faults = [math]::Round((One '*\memory\page faults/sec'), 0)
    $modMB  = [math]::Round((One '*\memory\modified page list bytes') / 1MB, 0)
    # available = free + standby: a RAM "cleaner" can only release the standby part, and only if it is big
    $standby = [math]::Round(((One '*\memory\standby cache normal priority bytes') + (One '*\memory\standby cache reserve bytes') + (One '*\memory\standby cache core bytes')) / 1MB, 0)
    $freeMB = [math]::Round((One '*\memory\free & zero page list bytes') / 1MB, 0)
    $pfPct  = [math]::Round((One '*\paging file(_total)\% usage'), 1)
    $net    = [math]::Round((Sum '*network interface*bytes total/sec') / 1MB, 2)
    $gpuMax = [math]::Round((Max '*gpu engine*utilization percentage'), 1); if ($gpuMax -gt 100) { $gpuMax = 0 }   # counter glitch (seen: 1.8e14), would poison averages
    $vram   = [math]::Round((Sum '*gpu adapter memory*dedicated usage') / 1MB, 0)
    $mhz    = [math]::Round((One '*\processor information(_total)\processor frequency') * (One '*\processor information(_total)\% processor performance') / 100, 0)

    # every 3rd sample: ping gateway + internet (async, max 0.5 s) while nvidia-smi runs; blank = not measured
    $pingGw = ''; $pingNet = ''; $gTemp = ''; $gClock = ''; $gThr = ''
    if ($k++ % 3 -eq 0) {
      $pt = @{}; foreach ($h in $pingHosts) { try { $pt[$h] = (New-Object Net.NetworkInformation.Ping).SendPingAsync($h, 300) } catch { } }
      if ($smi) {
        $sm = @((& $smi.Source '--query-gpu=temperature.gpu,clocks.sm,clocks_throttle_reasons.active' '--format=csv,noheader,nounits' | Select-Object -First 1) -split ',\s*')
        if ($sm.Count -ge 3 -and $sm[0] -match '^\d+(\.\d+)?$' -and $sm[1] -match '^\d+(\.\d+)?$' -and $sm[2] -match '^0x[0-9a-fA-F]+$') { $gTemp = $sm[0]; $gClock = $sm[1]; $gThr = [Convert]::ToInt64($sm[2].Substring(2), 16) }
      }
      try { [void][Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($pt.Values), 500) } catch { }
      if ($gw) { $pingGw = Rtt $pt[$gw] }; $pingNet = Rtt $pt['1.1.1.1']
    }

    $gName = $Game | Where-Object { Get-Process -Name $_ -ErrorAction SilentlyContinue } | Select-Object -First 1
    $gOn = [int]([bool]$gName); $gMB = ''
    if ($gName) { $gMB = [int]((Get-Process -Name $gName | Measure-Object WorkingSet64 -Sum).Sum / 1MB) }

    $dv = @(); $latMax = 0
    foreach ($d in $disks) {
      $lat  = [math]::Round((One "*\physicaldisk($d)\avg. disk sec/transfer") * 1000, 1)
      $busy = [math]::Min(100, [math]::Round((One "*\physicaldisk($d)\% disk time"), 1))   # Windows reports up to 180 %
      $q    = [math]::Round((One "*\physicaldisk($d)\current disk queue length"), 1)
      $mbs  = [math]::Round((One "*\physicaldisk($d)\disk bytes/sec") / 1MB, 1)
      $latMax = [math]::Max($latMax, $lat)
      $dv += $lat, $busy, $q, $mbs
    }

    $why = @()
    if ($cpuV -gt 90) { $why += 'CPU' }
    if ($avail -lt 1000) { $why += 'RAM' }
    if ($pgIn -gt 5000) { $why += 'PAGING' }
    if ($gpuMax -gt 95) { $why += 'GPU' }
    if ($latMax -gt 50) { $why += 'DISK-LAT' }

    $mark = if ($pressed) { 'MARK' } else { '' }
    $row = @($ts, [math]::Round($cpuV,1), $queueV, $avail, [math]::Round($commit,1), $pgIn, $pgOut, $faults, $modMB, $net, $gpuMax, $vram, $gOn, $gMB, $mark, $standby, $freeMB, $pfPct, $mhz, $pingGw, $pingNet, $gTemp, $gClock, $gThr) + $dv
    ($row -join ',') | Add-Content $csv

    if ($pressed -or $why.Count) {
      $tag = if ($pressed) { 'MARK' } else { 'SPIKE ' + ($why -join '+') }
      "$ts $tag  cpu $([math]::Round($cpuV,1))%  queue $queueV  availMB $avail  commit $([math]::Round($commit,1))%  pgIn $pgIn  gpu $gpuMax%  diskLat $latMax ms  game $gOn" | Add-Content $ev
      if ($pressed -or ((Get-Date) - $lastSnap).TotalSeconds -gt 10) { Snapshot $tag $ts; $lastSnap = Get-Date }
    }
  }
} finally {
  # stopping the trace session makes PresentMon flush frames.csv and exit; kill it only if it hangs
  if ($pmP) { & $pm.FullName --terminate_existing_session --session_name Scannx 2>&1 | Out-Null; if (-not $pmP.WaitForExit(5000)) { Stop-Process -Id $pmP.Id -Force } }
  Write-Summary $run
}
