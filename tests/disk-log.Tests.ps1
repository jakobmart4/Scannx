# Run: Invoke-Pester tests   (Pester 3.x syntax, works on the Pester that ships with Windows PowerShell 5.1)
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$script = Join-Path (Split-Path -Parent $here) 'disk-log.ps1'

function Summarize($case) {
  $tmp = Join-Path $env:TEMP ('scannx-' + $case + '-' + [guid]::NewGuid().ToString('N'))
  Copy-Item (Join-Path $here "fixtures\$case") $tmp -Recurse
  try { & powershell -NoProfile -ExecutionPolicy Bypass -File $script -Summarize $tmp | Out-String } finally { Remove-Item $tmp -Recurse -Force }
}

Describe 'disk-log.ps1 -Summarize' {
  Context 'memory pressure (game already running, working set trimmed)' {
    $out = Summarize 'pressure'
    It 'reports memory pressure' { $out | Should Match 'MEMORY pressure' }
    It 'reports the commit charge' { $out | Should Match 'COMMIT charge reached 97' }
    # the last 5 samples are cut off on purpose (game closing), so the minimum is a bit above the fixture's 4500
    It 'reports the trimmed game memory' { $out | Should Match "trimmed the game's memory from 7000 to 4\d{3} MB" }
    It 'blames RAM/paging for the F9 mark' { $out | Should Match '10:00:20.*RAM/paging' }
    It 'splits available RAM into standby + free and says cleaners cannot help' { $out | Should Match 'standby cache 300 MB \+ free 150 MB.*cannot fix this' }
    It 'prints the pagefile usage line' { $out | Should Match 'pagefilePct\s+min\s+45\.0' }
    It 'adds no clock/ping/GPU lines (memory columns only)' { $out | Should Not Match 'cpuMHz|pingLoss|CPU clock fell|NETWORK:|GPU throttling' }
  }
  Context 'clean run (old log format without the memory-composition columns)' {
    $out = Summarize 'clean'
    It 'still summarizes and adds no standby line' { $out | Should Not Match 'standby' }
    It 'finds no trouble and points to PresentMon' { $out | Should Match 'no memory, disk, GPU, CPU or network trouble visible; .*next step: PresentMon' }
    It 'says the F9 mark is not a system bottleneck' { $out | Should Match 'network all normal: not a system bottleneck' }
    It 'adds no clock/ping/GPU lines' { $out | Should Not Match 'cpuMHz|pingLoss|CPU clock fell|NETWORK:|GPU throttling' }
    It 'adds no frame lines without frames.csv' { $out | Should Not Match 'frames\s+\d|FRAME hitches|frame max|frame hitch' }
  }
  Context 'frame times (PresentMon frames.csv, two swap chains, system healthy)' {
    $out = Summarize 'frames'
    It 'prints frame stats for the busiest swap chain over the used rows only' { $out | Should Match 'frames\s+\d+ frames, avg 20 fps, median 50\.0 ms, p99 50\.0 ms, max 400\.0 ms, 3 hitches over 150 ms' }
    It 'reports the hitches as game/driver side' { $out | Should Match 'FRAME hitches: 3 frames over 150 ms, worst 400 ms at 10:01:00, while RAM, disk, CPU, GPU and network looked normal: they come from the game or the driver' }
    It 'does not print the none line' { $out | Should Not Match 'no memory, disk, GPU, CPU or network trouble' }
    It 'blames a frame hitch for the 10:01:00 mark' { $out | Should Match '10:01:00 .*frame max 400 ms\s+->\s+frame hitch while RAM, disk, CPU, GPU and network were normal' }
    It 'does not count the 150 ms edge frame at the 10:02:00 mark' { $out | Should Match '10:02:00 .*frame max 150 ms\s+->\s+RAM, disk, CPU, GPU and network all normal: not a system bottleneck; no frame hitch either' }
  }
  Context 'throttling run (CPU clock drop, GPU power cap, lost pings)' {
    $out = Summarize 'throttle'
    It 'reports the CPU clock drop' { $out | Should Match 'CPU clock fell to 2000 MHz \(peak 4300 MHz\) under >50 % load in 16 samples' }
    It 'reports the network loss' { $out | Should Match 'NETWORK: 10\.3 % of pings lost' }
    It 'counts lost pings per host' { $out | Should Match 'gateway lost 3 of 29, internet lost 3 of 29' }
    It 'reports GPU throttling' { $out | Should Match 'GPU throttling .* in 38 % of measured samples, GPU temperature max 70 C' }
    It 'blames CPU clock and GPU throttle for mark 1' { $out | Should Match '10:01:30 .*->.*CPU clock.* \+ GPU throttle' }
    It 'blames NET for mark 2' { $out | Should Match '10:02:06 .*->.*NET' }
    It 'does not blame NET for mark 1' { $out | Should Not Match '10:01:30 .*NET' }
    It 'prints the clock stat line over every row' { $out | Should Match 'cpuMHz\s+min\s+2,?000\.0' }
    It 'prints the GPU clock stat line' { $out | Should Match 'gpuClockMHz\s+min\s+1,?800\.0' }
    It 'keeps lost pings (-1) out of the ping stat lines' { $out | Should Match 'pingGwMs\s+min\s+1\.0'; $out | Should Match 'pingNetMs\s+min\s+6\.0' }
  }
  Context 'gateway lag only (2 samples over 50 ms, no loss)' {
    $out = Summarize 'gwlag'
    It 'reports NETWORK with the gateway max and p95' { $out | Should Match 'NETWORK: 0\.0 % of pings lost, gateway RTT max 70 / p95 60 ms, internet RTT max 6 / p95 6 ms' }
    It 'does not print the none line' { $out | Should Not Match 'no memory, disk, GPU, CPU or network trouble' }
    It 'blames NET for the mark next to a 60 ms gateway ping' { $out | Should Match '10:01:02 .*->\s+NET' }
  }
  Context 'internet lag only (3 samples over 150 ms), no gateway, CPU clock near misses' {
    $out = Summarize 'netlag'
    It 'reports NETWORK with n/a for the missing gateway and the internet max and p95' { $out | Should Match 'gateway RTT n/a, internet RTT max 180 / p95 170 ms' }
    It 'does not print the none line' { $out | Should Not Match 'no memory, disk, GPU, CPU or network trouble' }
    It 'blames NET for the mark next to a 170 ms internet ping' { $out | Should Match '10:01:32 .*->\s+NET' }
    It 'does not fire the CPU clock rule on 2 low rows, a blank cell or 0.81 of peak' { $out | Should Not Match 'CPU clock' }
    It 'says the idle, blank-clock and 3500 MHz marks are normal' { foreach ($t in '10:00:04', '10:00:42', '10:02:36') { $out | Should Match "$t .*not a system bottleneck" } }
  }
  Context 'GPU throttle bits (8, 32, 64, 128 count; 1, 2, 256 do not)' {
    $out = Summarize 'gpubits'
    It 'counts exactly the 4 bad samples of 29 and shows the max temperature' { $out | Should Match 'GPU throttling \(thermal/HW slowdown\) in 14 % of measured samples, GPU temperature max 83 C' }
    It 'does not print the none line' { $out | Should Not Match 'no memory, disk, GPU, CPU or network trouble' }
    It 'prints the GPU temperature stat line' { $out | Should Match 'gpuTempC\s+min\s+60\.0.*max\s+83\.0' }
  }
  Context 'CPU clock only (exactly 3 low rows), GPU throttle under the 3 % edge' {
    $out = Summarize 'cpuclock'
    It 'reports the CPU clock drop at the 3-sample edge' { $out | Should Match 'CPU clock fell to 2000 MHz \(peak 4300 MHz\) under >50 % load in 3 samples' }
    It 'does not report 1 throttled sample of 39' { $out | Should Not Match 'GPU throttling' }
    It 'does not print the none line' { $out | Should Not Match 'no memory, disk, GPU, CPU or network trouble' }
  }
  Context 'steady run (idle down-clock and GPU idle bit are normal, smooth frames with the frame clock 2 h ahead)' {
    $out = Summarize 'steady'
    It 'finds no trouble and no frame hitches' { $out | Should Match 'no memory, disk, GPU, CPU or network trouble and no frame hitches visible \(frame time p99 50\.0 ms\)' }
    It 'does not report idle down-clocking' { $out | Should Not Match 'CPU clock fell to' }
    It 'does not report the idle GPU bit' { $out | Should Not Match 'GPU throttling' }
    It 'shows the always-on GPU power cap (bit 4) as info only: 20 of 30 measured samples' { $out | Should Match 'info: GPU power cap \(SW power limit\) was active in 6\d % of measured samples' }
    It 'does not blame the power cap in the F9 mark' { $out | Should Not Match 'GPU throttle' }
    It 'says the F9 mark is not a system bottleneck and had no frame hitch' { $out | Should Match '10:02:00 .*frame max 50 ms\s+->.*network all normal: not a system bottleneck; no frame hitch either' }
  }
  Context 'loading screens longer than 120 s, cut by the frame rate' {
    $out = Summarize 'loading'
    It 'uses only the playing span' { $out | Should Match '240 samples, 150 used \(game running, loading skipped by frame rate: 10:02:30-10:07:30 used\)' }
    It 'does not report the loading paging as memory pressure' { $out | Should Not Match 'MEMORY pressure' }
    It 'counts only the playing frames' { $out | Should Match 'frames\s+2997 frames, avg 10 fps, median 100\.0 ms, p99 100\.0 ms, max 400\.0 ms, 1 hitches over 300 ms' }
    It 'reports the one in-game hitch as game/driver side' { $out | Should Match 'FRAME hitches: 1 frames over 300 ms, worst 400 ms at 10:05:00, while RAM' }
    It 'blames a frame hitch for the 10:05:00 mark' { $out | Should Match '10:05:00 .*frame max 400 ms\s+->\s+frame hitch while' }
  }
  Context 'frames start 7.7 min after the first game row (clock 2 h ahead)' {
    $out = Summarize 'lateframes'
    It 'aligns them by whole half hours' { $out | Should Match 'frames\s+1297 frames, avg 10 fps, median 100\.0 ms, p99 100\.0 ms, max 400\.0 ms, 1 hitches over 300 ms' }
    It 'puts the hitch and the mark at 10:09:00' { $out | Should Match 'worst 400 ms at 10:09:00'; $out | Should Match '10:09:00 .*frame max 400 ms\s+->\s+frame hitch while' }
  }
  Context 'evening play: frame clock 2 h ahead passes midnight, odd-second rows, NA/blank frame times' {
    $out = Summarize 'midnight'
    It 'finds the span across the skewed midnight' { $out | Should Match '90 samples, 75 used \(game running, loading skipped by frame rate: 21:58:00-22:00:30 used\)' }
    It 'counts the frames without the 2 broken rows and without the exit frame past the span end' { $out | Should Match 'frames\s+2971 frames, avg 20 fps, median 50\.0 ms, p99 50\.0 ms, max 400\.0 ms, 1 hitches over 150 ms' }
    It 'puts the hitch at its real time' { $out | Should Match 'worst 400 ms at 22:00:00, while RAM' }
    It 'blames a frame hitch for the 22:00:01 mark' { $out | Should Match '22:00:01 .*frame max 400 ms\s+->\s+frame hitch while' }
  }
  Context 'game launch and exit (must not count as stutter)' {
    $out = Summarize 'launch'
    It 'skips start-up/exit' { $out | Should Match 'game start-up/exit skipped' }
    It 'does not report memory pressure' { $out | Should Not Match 'MEMORY pressure' }
    It 'does not report trimming' { $out | Should Not Match 'trimmed the game' }
  }
}
