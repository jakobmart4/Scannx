# Regenerates the synthetic -Summarize fixtures: powershell -ExecutionPolicy Bypass -File tests\make-fixtures.ps1
param($Root = '')
if (-not $Root) { $Root = Join-Path $PSScriptRoot 'fixtures' }   # $PSScriptRoot is empty inside param defaults under powershell -File
# h1 keeps gameCpuPct on purpose: the logger dropped it on 2026-10-25 (it was always 0), logs from before still carry it and the summary must ignore it
$h1 = 'time,cpu,cpuQueue,availMB,commitPct,pgIn,pgOut,faults,modMB,netMBs,gpuMaxPct,vramMB,gameOn,gameCpuPct,gameMB,mark'
$h2 = '0 c: latMs,0 c: busyPct,0 c: queue,0 c: MBs,1 e: latMs,1 e: busyPct,1 e: queue,1 e: MBs'
$h3 = 'cpuMHz,pingGwMs,pingNetMs,gpuTempC,gpuClockMHz,gpuThrottle'
# $mem = standbyMB,freeMB,pagefilePct after mark; $new = also the clock/ping/GPU columns (ping and GPU only on every 3rd row, blank otherwise).
# Without them the fixture is an older log format (back-compat test).
function Build($case, $n, $f, $spikes, $mem, $new, $base = '10:00:00') {
  $d = Join-Path $Root $case; New-Item $d -ItemType Directory -Force | Out-Null
  $head = $h1; if ($mem) { $head += ',standbyMB,freeMB,pagefilePct' }; if ($new) { $head += ",$h3" }
  $rows = for ($i = 0; $i -lt $n; $i++) { $r = & $f $i; $t = ([datetime]"2000-01-01 $base").AddSeconds(2 * $i).ToString('HH:mm:ss')
    $v = @($t, $r.cpu, 0, $r.avail, $r.commit, $r.pgIn, 0, 5000, 1, 0.1, $r.gpu, 3000, 1, 30, $r.game, $r.mark)
    if ($mem) { $v += $r.standby, $r.free, $r.pf }
    if ($new) { $v += $r.mhz; $v += if ($i % 3 -eq 0) { $r.gw, $r.net, $r.temp, $r.clk, $r.thr } else { '', '', '', '', '' } }
    ($v + @(0.2, 1, 0, 1, 0.2, 1, 0, 1)) -join ',' }
  (@("$head,$h2") + $rows) | Set-Content (Join-Path $d 'log.csv') -Encoding utf8
  (@('Logging for 60 min (synthetic fixture).') + $spikes) | Set-Content (Join-Path $d 'events.txt') -Encoding utf8
}
# pressure: game already running, memory trimmed 7000 -> 4500 MB, free RAM ~450 MB (300 standby + 150 free), commit 97 %, one mark under pressure
Build 'pressure' 60 { param($i) @{ cpu = 40; avail = 450; commit = 97; pgIn = $(if ($i -in 5, 20) { 60000 } elseif ($i -eq 10) { 3000 } else { 100 }); gpu = 60; game = [int](7000 - 2500 * $i / 59); mark = $(if ($i -eq 10) { 'MARK' } else { '' }); standby = 300; free = 150; pf = 45 } } @('10:00:10 SPIKE RAM  cpu 40%  queue 0  availMB 450') $true
# clean: OLD log format (no memory-composition columns), plenty of RAM, one mark with everything normal
Build 'clean' 60 { param($i) @{ cpu = 40; avail = 5000; commit = 70; pgIn = 100; gpu = 60; game = 5000; mark = $(if ($i -eq 30) { 'MARK' } else { '' }) } } @() $false
# launch: logger started while the game loads (200 000 pages/s read burst, low free RAM) for 2 min, then steady; last 5 rows = game closing
Build 'launch' 120 { param($i) if ($i -lt 60) { @{ cpu = 50; avail = 500; commit = 60; pgIn = 200000; gpu = 20; game = [int](300 + 6200 * $i / 59); mark = ''; standby = 300; free = 200; pf = 20 } }
  elseif ($i -ge 115) { @{ cpu = 20; avail = 9000; commit = 50; pgIn = 100; gpu = 5; game = 40; mark = ''; standby = 6000; free = 3000; pf = 20 } }
  else { @{ cpu = 40; avail = 3000; commit = 60; pgIn = 100; gpu = 60; game = 6500; mark = ''; standby = 2000; free = 1000; pf = 20 } } } @('10:00:02 SPIKE RAM+PAGING  cpu 50%') $true
# throttle: healthy RAM/disk; CPU clock 2000 MHz under 60 % load on rows 40-55, GPU SW thermal slowdown (bit 32) on rows 30-60, pings lost on rows 60-66.
# Marks: row 45 (CPU clock + GPU throttle) and row 63 (NET).
Build 'throttle' 90 { param($i) @{ cpu = 60; avail = 4000; commit = 60; pgIn = 100; gpu = 60; game = 6500; mark = $(if ($i -in 45, 63) { 'MARK' } else { '' }); standby = 2500; free = 1500; pf = 20
  mhz = $(if ($i -ge 40 -and $i -le 55) { 2000 } else { 4300 }); gw = $(if ($i -ge 60 -and $i -le 66) { -1 } else { 1 }); net = $(if ($i -ge 60 -and $i -le 66) { -1 } else { 6 })
  temp = 70; clk = 1800; thr = $(if ($i -ge 30 -and $i -le 60) { 32 } else { 0 }) } } @() $true $true
# steady: everything healthy; rows 0-29 idle (cpu 5 %, 800 MHz, GPU idle bit 1) must not count as throttling; under load the GPU sits at its
# power limit (bit 4, typical at ordinary load): info only, no verdict, no mark cause. One mark at row 60.
Build 'steady' 90 { param($i) $idle = $i -lt 30; @{ cpu = $(if ($idle) { 5 } else { 60 }); avail = 4000; commit = 60; pgIn = 100; gpu = 60; game = 6500; mark = $(if ($i -eq 60) { 'MARK' } else { '' }); standby = 2500; free = 1500; pf = 20
  mhz = $(if ($idle) { 800 } else { 4300 }); gw = 1; net = 6; temp = 60; clk = 1800; thr = $(if ($idle) { 1 } else { 4 }) } } @() $true $true
# Single-fault fixtures (each fires exactly one new rule). Healthy base: cpu 60 %, 4300 MHz, gw 1 ms, internet 6 ms, GPU 60 C, no throttle bits.
function Ok($x) { $b = @{ cpu = 60; avail = 4000; commit = 60; pgIn = 100; gpu = 60; game = 6500; mark = ''; standby = 2500; free = 1500; pf = 20; mhz = 4300; gw = 1; net = 6; temp = 60; clk = 1800; thr = 0 }; foreach ($k in $x.Keys) { $b[$k] = $x[$k] }; $b }
# gwlag: gateway RTT 60 and 70 ms on 2 measured rows (30, 60), no loss. Mark at row 31.
Build 'gwlag' 90 { param($i) Ok @{ gw = $(if ($i -eq 30) { 60 } elseif ($i -eq 60) { 70 } else { 1 }); mark = $(if ($i -eq 31) { 'MARK' } else { '' }) } } @() $true $true
# netlag: no gateway (blank), internet 160/170/180 ms on 3 measured rows (30, 45, 60). Near misses that must NOT fire the CPU clock rule:
# 2 low rows (10, 11), blank cpuMHz at row 20, 3500 MHz (0.81 of peak) on rows 70-75, idle rows 0-5 (cpu 5 %, 800 MHz).
# Marks: row 2 (idle), 21 (blank clock), 46 (NET), 78 (3500 MHz): all but 46 are normal.
Build 'netlag' 90 { param($i) Ok @{ gw = ''; net = $(if ($i -eq 30) { 160 } elseif ($i -eq 45) { 170 } elseif ($i -eq 60) { 180 } else { 6 })
  cpu = $(if ($i -le 5) { 5 } else { 60 }); mhz = $(if ($i -le 5) { 800 } elseif ($i -in 10, 11) { 2000 } elseif ($i -eq 20) { '' } elseif ($i -ge 70 -and $i -le 75) { 3500 } else { 4300 })
  mark = $(if ($i -in 2, 21, 46, 78) { 'MARK' } else { '' }) } } @() $true $true
# gpubits: one measured row each with 9 (idle 1 + HW slowdown 8), 32, 64, 128 (count) and 2, 256 (must not count): 4 of 29 = 14 %. Temp 83 C on row 9.
Build 'gpubits' 90 { param($i) Ok @{ thr = $(switch ($i) { 3 { 9 } 6 { 32 } 9 { 64 } 12 { 128 } 15 { 2 } 18 { 256 } default { 0 } }); temp = $(if ($i -eq 9) { 83 } else { 60 }) } } @() $true $true
# cpuclock: exactly 3 rows at 2000 MHz under load (fires); one HW slowdown sample of 39 (2.6 %, under the 3 % edge).
Build 'cpuclock' 120 { param($i) Ok @{ mhz = $(if ($i -in 40, 41, 42) { 2000 } else { 4300 }); thr = $(if ($i -eq 30) { 8 } else { 0 }) } } @() $true $true
# frames.csv in PresentMon 2.x --date_time format (only the columns the summary reads). $f gives the frame time in ms for a frame
# starting $t ms after 10:00:00 on swap chain 0x1; $slow adds a second chain 0x2 with one 1000 ms frame per second (must be ignored).
# $shiftH moves the written clock by whole hours, like PresentMon 2.3.1 (its "local" time can come out hours ahead).
# $broken replaces the time of 0x1 frames 100 and 200 with 'NA' and blank (must be skipped).
function Frames($case, $from, $to, $f, $slow, $shiftH = 0, $base = '10:00:00', $broken = $false) {
  $line = { param($sc, $t, $ms) 'r5apex_dx12.exe,1,{0},{1}000000,{2}' -f $sc, ([datetime]"2000-01-01 $base").AddHours($shiftH).AddMilliseconds($t).ToString('yyyy-M-d H:mm:ss.fff', [Globalization.CultureInfo]::InvariantCulture), $ms }
  $t = $from; $rows = @(while ($t -lt $to) { $ms = & $f $t; & $line '0x1' $t $ms; $t += $ms })
  if ($broken) { $rows[100] = 'r5apex_dx12.exe,1,0x1,NA,50'; $rows[200] = 'r5apex_dx12.exe,1,0x1,,50' }
  if ($slow) { $rows += for ($s = $from; $s -lt $to; $s += 1000) { & $line '0x2' $s 1000 } }
  (@('Application,ProcessID,SwapChainAddress,CPUStartDateTime,MsBetweenPresents') + $rows) | Set-Content (Join-Path $Root "$case\frames.csv") -Encoding utf8
}
# frames: healthy system, 20 fps (50 ms). Hitches 400/300/200 ms at 60/100/140 s count (over 3 x 50 = 150 ms); a 150 ms frame at 120 s (the edge) does not;
# a 500 ms frame at 175 s falls in the game-exit rows the summary skips. Marks: row 30 (10:01:00, hitch) and row 60 (10:02:00, edge frame only).
# All frame times are multiples of 50 so every listed start time is hit exactly.
Build 'frames' 90 { param($i) Ok @{ mark = $(if ($i -in 30, 60) { 'MARK' } else { '' }) } } @() $true $true
Frames 'frames' 0 180000 { param($t) switch ($t) { 60000 { 400 } 100000 { 300 } 140000 { 200 } 120000 { 150 } 175000 { 500 } default { 50 } } } $true
# steady also gets smooth 50 ms frames over the whole log: no hitches, so the none line names the frame time instead of "next step: PresentMon".
# Its frame clock is 2 h ahead (real PresentMon 2.3.1 bug): the summary must still line the frames up with the 10:02:00 mark.
Frames 'steady' 0 180000 { param($t) 50 } $false 2
# loading: like Apex, the game loads for 150 s (longer than the 120 s rule): paging 60 000/s and 2 fps (500 ms frames), then plays 300 s
# at 10 fps (100 ms) with one 400 ms hitch at 300 s (10:05:00, marked), then 30 s of exit loading (2 fps, one more paging burst at row 226).
# The frame rate must cut both loading parts: 10:02:30-10:07:30 used, no MEMORY verdict, exactly 1 hitch.
Build 'loading' 240 { param($i) Ok @{ game = $(if ($i -lt 30) { 300 + 200 * $i } else { 6500 }); pgIn = $(if ($i -lt 75 -or $i -eq 226) { 60000 } else { 100 }); mark = $(if ($i -eq 150) { 'MARK' } else { '' }) } } @() $true $true
Frames 'loading' 0 480000 { param($t) if ($t -lt 150000 -or $t -ge 450000) { 500 } elseif ($t -eq 300000) { 400 } else { 100 } } $false
# midnight: evening play 21:58:01-22:00:59 (odd-second rows), frame clock 2 h ahead so it passes midnight (23:58 -> 00:01) while the real clock does not.
# 20 fps with a 400 ms hitch at 22:00:00 (mark on the 22:00:01 row), exit loading (500 ms frames) from 22:00:30: the row + 2 s slice would reach
# the 500 ms frame at 22:00:30, the span end must stop it. Two frames have an NA / blank time.
# lateframes: the game runs from the first row but presents nothing for 460 s (logger started with the game idle), clock 2 h ahead.
# The alignment must still find +2 h (whole half hours; quarter hours would land 15 min off). 10 fps, 400 ms hitch at 540 s (10:09:00, marked).
Build 'lateframes' 300 { param($i) Ok @{ mark = $(if ($i -eq 270) { 'MARK' } else { '' }) } } @() $true $true
Frames -case 'lateframes' -from 460000 -to 600000 -f { param($t) if ($t -eq 540000) { 400 } else { 100 } } -slow $false -shiftH 2
Build 'midnight' 90 { param($i) Ok @{ mark = $(if ($i -eq 60) { 'MARK' } else { '' }) } } @() $true $true '21:58:01'
Frames -case 'midnight' -from 0 -to 180000 -f { param($t) if ($t -ge 150000) { 500 } elseif ($t -eq 120000) { 400 } else { 50 } } -slow $false -shiftH 2 -base '21:58:00' -broken $true
