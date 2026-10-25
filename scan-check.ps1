# Read-only malware / health check. Changes nothing.
# Report: Desktop\scan-report.txt (FLAGS first, then details). Works without admin; admin adds the Defender exclusion list + policy exclusions.
# -Fast skips the file walk (~1 min). -BudgetSec caps the walk (default 120 s) so it can never hang for 25 min.
param([string]$Out = (Join-Path ([Environment]::GetFolderPath('Desktop')) 'scan-report.txt'), [switch]$Fast, [int]$BudgetSec = 120)
$ErrorActionPreference = 'SilentlyContinue'
$od = Split-Path -Parent $Out; if ($od) { New-Item $od -ItemType Directory -Force | Out-Null }   # a missing folder would silently give no report
$part = "$Out.partial"; Set-Content $part '' -Encoding utf8       # sections are appended as they finish; survives a crash
$flags = New-Object Collections.Generic.List[string]
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
function Flag($t) { $flags.Add($t) }
function S($t) { Write-Host "[$((Get-Date).ToString('HH:mm:ss'))] $t"; Add-Content $part "`r`n=== $t ===" -Encoding utf8 }
function L($x) { if ($x) { Add-Content $part (($x | Out-String -Width 250).TrimEnd()) -Encoding utf8 } }
function ExeOf($v) { if ($v -match '^\s*"([^"]+)"') { $Matches[1] } elseif ($v -match '^\s*(.+?\.(exe|bat|cmd|vbs|ps1|lnk|scr))') { $Matches[1] } else { ($v -split ' ')[0] } }
$odd = 'ProgramData|\\Temp\\|\\Users\\Public'                      # places legit autostarts rarely live

S 'Info'; L "$(Get-Date) | boot: $((Get-CimInstance Win32_OperatingSystem).LastBootUpTime) | admin: $isAdmin | fast: $Fast | PS $($PSVersionTable.PSVersion)"
$o = Get-CimInstance Win32_OperatingSystem; L ('RAM: {0:N1} GB total, {1:N1} GB free' -f ($o.TotalVisibleMemorySize/1MB), ($o.FreePhysicalMemory/1MB))

S 'Defender'
$st = Get-MpComputerStatus
L ($st | Select RealTimeProtectionEnabled,AntivirusSignatureLastUpdated,QuickScanEndTime,FullScanEndTime | Format-List)
if (-not $st) { Flag 'Defender status unreadable (another AV may be primary)' } elseif (-not $st.RealTimeProtectionEnabled) { Flag 'Defender real-time protection is OFF' }
$p = Get-MpPreference
if ($st) {
  if (-not $st.FullScanEndTime -or $st.FullScanEndTime -lt (Get-Date).AddDays(-14)) { Flag "No Defender full scan in 14 d (last: $($st.FullScanEndTime))" }
  if ($st.AntivirusSignatureLastUpdated -lt (Get-Date).AddDays(-3)) { Flag "Defender signatures older than 3 d ($($st.AntivirusSignatureLastUpdated))" }
  if (-not $st.IsTamperProtected) { Flag 'Defender Tamper Protection is OFF' }
}
if ($isAdmin -and "$($p.ExclusionPath)" -notmatch 'N/A') {
  L "Exclusions  Paths: $($p.ExclusionPath -join '; ') | Procs: $($p.ExclusionProcess -join '; ') | Ext: $($p.ExclusionExtension -join '; ')"
  # malware likes to plant exclusions as POLICY (HKLM\SOFTWARE\Policies\...): Remove-MpPreference can't remove those, the registry keys must go
  $pol = 'Paths','Processes','Extensions','IpAddresses' | ForEach-Object { $k = "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Exclusions\$_"; if (Test-Path $k) { [pscustomobject]@{Kind=$_; Values=(Get-Item $k).ValueCount} } } | Where-Object Values
  if ($pol) { L ("Policy exclusions: " + (($pol | ForEach-Object { "$($_.Kind)=$($_.Values)" }) -join ', ')); Flag "Defender exclusions set by POLICY ($(($pol | ForEach-Object { "$($_.Kind)=$($_.Values)" }) -join ', ')): not normal on a home PC, malware trick (HKLM\SOFTWARE\Policies\Microsoft\Windows Defender\Exclusions)" }
  $badEx = 'Temp\\?$|^[A-Z]:\\?$|^C:\\Program Files( \(x86\))?\\?$|ProgramData\\Microsoft\\Windows\\?$|\\Windows\\Caches|\\[0-9A-F]{7,8}(\\|$)|RuntimeHost|proxies-peer|miner|Framework(64)?\\v4|AppData\\(Local|Roaming)\\?$'
  $sus = @(@($p.ExclusionPath) + @($p.ExclusionProcess) | Where-Object { $_ -match $badEx })
  if ($sus) { Flag "Suspicious Defender exclusions: $($sus.Count) (e.g. $(($sus | Select -First 3) -join ' | '))" }
  elseif ($p.ExclusionPath -or $p.ExclusionProcess -or $p.ExclusionExtension) { Flag "Defender has $(@($p.ExclusionPath).Count) path / $(@($p.ExclusionProcess).Count) process exclusions (look reasonable; check they are yours)" }
} else { L 'Exclusions: NOT VISIBLE - run as administrator to see them' }
# event 5007 is readable without admin: shows exclusions ADDED in the last 90 d (malware planted its list in bursts)
$add = Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-Windows Defender/Operational';Id=5007;StartTime=(Get-Date).AddDays(-90)} -MaxEvents 5000 | Where-Object { ($_.Message -replace '\s+',' ') -match 'Old value: New value: HKLM.*?Exclusions\\(Paths|Processes)' }
L '-- exclusions ADDED (event 5007, 90 d)'; L ($add | Group-Object { $_.TimeCreated.ToString('yyyy-MM-dd HH:mm') } | Sort Name | Select Name,Count | Format-Table -AutoSize)
if ($add) { Flag "Defender exclusions were added $(@($add).Count) time(s) in the last 90 d (first: $((@($add)[-1]).TimeCreated)); confirm each was you" }
$names = @{}; Get-MpThreat | ForEach-Object { $names[$_.ThreatID] = $_.ThreatName }
$det = Get-MpThreatDetection | Where-Object InitialDetectionTime -gt (Get-Date).AddDays(-180) | Sort InitialDetectionTime -Descending
L '-- detections (180 d)'; L ($det | Select -First 30 | ForEach-Object { "$($_.InitialDetectionTime) | $($names[$_.ThreatID]) | $((($_.Resources -join ' ') -replace '\|https?://\S+','') -replace '(.{0,200}).*','$1')" })
$rec = @($det | Where-Object InitialDetectionTime -gt (Get-Date).AddDays(-14) | ForEach-Object { $names[$_.ThreatID] } | Select -Unique)
if ($rec) { Flag "Defender detections in last 14 d: $($rec -join ', ')" }
L '-- scan history (event log)'; L (Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-Windows Defender/Operational';Id=1001,1002,1005} -MaxEvents 6 | ForEach-Object { "$($_.TimeCreated) | " + @{1001='scan finished';1002='scan stopped';1005='scan failed'}[[int]$_.Id] })

S 'Autostart (state = Task Manager Startup apps)'
$sa = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run','HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32','HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run','HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32'
function State($n) { foreach ($k in $sa) { $b = (Get-ItemProperty $k).$n; if ($b -is [byte[]] -and ($b[0] -band 1)) { return 'disabled' } }; 'ENABLED' }
foreach ($k in 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run','HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce','HKLM:\Software\Microsoft\Windows\CurrentVersion\Run','HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce','HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run') {
  L "-- $k"
  (Get-ItemProperty $k).PSObject.Properties | Where-Object Name -notmatch '^PS' | ForEach-Object {
    $s = State $_.Name; $exe = ExeOf $_.Value; $miss = -not (Test-Path -LiteralPath $exe)
    L ("[{0}]{1} {2} = {3}" -f $s, $(if ($miss) { ' [FILE MISSING]' } else { '' }), $_.Name, $_.Value)
    if ($s -eq 'ENABLED' -and $miss) { Flag "Autostart points to missing file: $($_.Name) -> $exe" }
    if ($s -eq 'ENABLED' -and $exe -match $odd) { Flag "Autostart in unusual place: $($_.Name) -> $exe" }
  }
}
S 'Startup folders'; L (Get-ChildItem "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup","$env:ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp" -Force | Where-Object Name -ne 'desktop.ini' | Select FullName,LastWriteTime | Format-Table -AutoSize)
S 'Scheduled tasks (non-Microsoft)'
L (Get-ScheduledTask | Where-Object { $_.TaskPath -notmatch '^\\Microsoft\\' } | ForEach-Object { $t = $_; $t.Actions | ForEach-Object {
  $e = [Environment]::ExpandEnvironmentVariables($_.Execute).Trim('"')
  if ($t.State -ne 'Disabled' -and ($e -match $odd -or $t.TaskName -match 'System Health|Windows System|RuntimeHost')) { Flag "Suspicious scheduled task: $($t.TaskPath)$($t.TaskName) -> $e" }
  "$($t.TaskPath)$($t.TaskName) [$($t.State)] -> $($_.Execute) $($_.Arguments)" } })
S 'Services (auto-start, outside Windows/Program Files)'
# anchored at the start: an unanchored 'Windows\' also hid C:\ProgramData\Microsoft\Windows\..., a miner hiding spot
$sysSvc = '^"?[A-Z]:\\Windows\\|^"?[A-Z]:\\Program Files( \(x86\))?\\|^"?[A-Z]:\\ProgramData\\Microsoft\\Windows Defender\\|^\\SystemRoot\\'
L (Get-CimInstance Win32_Service | Where-Object { $_.StartMode -eq 'Auto' -and $_.PathName -and $_.PathName -notmatch $sysSvc } | ForEach-Object { if ($_.PathName -match $odd -and $_.PathName -notmatch 'Windows Defender') { Flag "Service in unusual place: $($_.Name) -> $($_.PathName)" }; "$($_.Name) [$($_.State)] $($_.PathName)" })

S 'Persistence extras'
$w = Get-ItemProperty 'HKLM:\Software\Microsoft\Windows NT\CurrentVersion\Winlogon'; L "Winlogon Shell=$($w.Shell) Userinit=$($w.Userinit)"
if ($w.Shell -ne 'explorer.exe' -or $w.Userinit -notmatch '^C:\\Windows\\system32\\userinit\.exe,?$') { Flag 'Winlogon Shell/Userinit is not default' }
Get-ChildItem 'HKLM:\Software\Microsoft\Windows NT\CurrentVersion\Image File Execution Options' | Where-Object { (Get-ItemProperty $_.PSPath).Debugger } | ForEach-Object { Flag "IFEO debugger set for $($_.PSChildName)"; L "IFEO: $($_.PSChildName)" }
$wmi = Get-CimInstance -Namespace root\subscription -ClassName __EventConsumer | Where-Object Name -ne 'SCM Event Log Consumer'; if ($wmi) { Flag 'WMI event consumer present'; L ($wmi | Select Name,__CLASS | Format-Table) }
$h = Get-Content "$env:SystemRoot\System32\drivers\etc\hosts" | Where-Object { $_ -and $_ -notmatch '^\s*#' }; L '-- hosts'; L $h
if ($h) { Flag "hosts file has $(@($h).Count) custom entries" }
$px = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'); L "Proxy enable=$($px.ProxyEnable) server=$($px.ProxyServer) pac=$($px.AutoConfigURL)"; if ($px.ProxyEnable -eq 1 -or $px.AutoConfigURL) { Flag 'System proxy / PAC is set' }

S 'ProgramData\Microsoft\Windows\Caches (should hold only Windows .db files)'
$cc = Get-ChildItem "$env:ProgramData\Microsoft\Windows\Caches" -Force; L ($cc | Select Name,LastWriteTime | Format-Table -AutoSize)
if ($cc | Where-Object { $_.Name -notmatch '\.db$' }) { Flag 'Unknown items in ProgramData\Microsoft\Windows\Caches (miner hiding spot)' }
S 'Hex-named leftover folders (miner hiding spots; legit Windows has none here)'
$hx = foreach ($par in $env:ProgramData, "$env:ProgramData\Microsoft\Windows", "$env:ProgramData\Microsoft\Windows\Caches", "$env:LOCALAPPDATA\Microsoft\Windows", "$env:LOCALAPPDATA\Microsoft\Windows\Caches", "$env:APPDATA\Microsoft\Windows\Caches") {
  Get-ChildItem $par -Directory -Force | Where-Object Name -match '^[0-9A-F]{7,8}$' | ForEach-Object { [pscustomobject]@{Path=$_.FullName; KB=[int]((Get-ChildItem $_.FullName -Recurse -Force -File | Measure-Object Length -Sum).Sum/1KB); Changed=$_.LastWriteTime} } }
L ($hx | Format-Table -AutoSize); if ($hx) { Flag "Hex-named folders in ProgramData/Windows/Caches: $(@($hx).Count) (miner leftovers; $(@($hx | Where-Object KB).Count) non-empty)" }
S 'ProgramData top-level folders with exe'; L (Get-ChildItem $env:ProgramData -Directory -Force | Where-Object { Get-ChildItem $_.FullName -Filter *.exe -File -Force } | Select Name,LastWriteTime | Format-Table -AutoSize)
S 'Windows\SystemTemp (14 d, exe/dll/sys/tmp)'; L (Get-ChildItem "$env:SystemRoot\SystemTemp" -Recurse -Force -File | Where-Object { $_.LastWriteTime -gt (Get-Date).AddDays(-14) -and $_.Extension -match '\.(exe|dll|sys|tmp)$' } | Select -First 30 LastWriteTime,FullName,Length | Format-Table -AutoSize)

S 'Discord core index.js (clean = module.exports = require(./core.asar);)'
Get-ChildItem "$env:LOCALAPPDATA\Discord","$env:LOCALAPPDATA\DiscordPTB","$env:LOCALAPPDATA\DiscordCanary" -Recurse -Filter index.js | Where-Object FullName -match 'discord_desktop_core' | ForEach-Object {
  $c = (Get-Content $_.FullName -Raw).Trim(); L "$($_.FullName) | $($_.Length) B | $($c.Substring(0, [math]::Min(80, $c.Length)))"
  if ($c -ne "module.exports = require('./core.asar');") { Flag "Discord index.js is modified: $($_.FullName)" } }
L (Get-ChildItem "$env:APPDATA\Vencord","$env:APPDATA\BetterDiscord" -Directory | Select FullName,LastWriteTime | Format-Table -AutoSize)

S 'Network: listening on all interfaces (non-system) / outbound by process'
L (Get-NetTCPConnection -State Listen | Where-Object { $_.LocalAddress -in '0.0.0.0','::' -and $_.LocalPort -gt 1023 } | ForEach-Object { $n = (Get-Process -Id $_.OwningProcess).Name; if ($n -notmatch '^(System|svchost|lsass|wininit|services|spoolsv|steam|Discord)$') { "$n :$($_.LocalPort)" } } | Sort -Unique)
L (Get-NetTCPConnection -State Established | Where-Object { $_.RemoteAddress -notmatch '^(127\.|::1|10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.)' } | ForEach-Object { (Get-Process -Id $_.OwningProcess).Name } | Group-Object | Sort Count -Descending | Select Name,Count | Format-Table -AutoSize)
S 'Top memory (by process name)'; L (Get-Process | Group-Object Name | ForEach-Object { [pscustomobject]@{GB=[math]::Round(($_.Group | Measure WorkingSet64 -Sum).Sum/1GB,2);Count=$_.Count;Name=$_.Name} } | Sort GB -Descending | Select -First 8 | Format-Table -AutoSize)

S 'System log (14 d): disk / NTFS / hardware errors'
$ev = Get-WinEvent -FilterHashtable @{LogName='System';StartTime=(Get-Date).AddDays(-14);Level=1,2,3;ProviderName='disk','Ntfs','stornvme','storahci','Microsoft-Windows-WHEA-Logger','Microsoft-Windows-Kernel-Power'}
L ($ev | Group-Object ProviderName,Id | Sort Count -Descending | Select -First 10 Count,Name | Format-Table -AutoSize)
if ($ev | Where-Object { $_.ProviderName -match 'disk|Ntfs|stornvme|storahci|WHEA' }) { Flag 'Disk/NTFS/hardware errors in System log (14 d)' }

S 'Installed software worth a second look'
$risky = 'TeamViewer|AnyDesk|RDP ?Wrapper|Cheat Engine|KMS|Xeno|Solara|Internet Download Manager|\bBitTorrent|uTorrent|Crack'
$sw = Get-ItemProperty 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*','HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*' | Where-Object DisplayName -match $risky | Select DisplayName,DisplayVersion
L ($sw | Format-Table -AutoSize); if ($sw) { Flag "Remote-access / crack-type software installed: $(($sw.DisplayName | Select -Unique) -join ', ')" }
S 'Crack-named files/folders in Desktop and Downloads (depth 3)'
$cr = Get-ChildItem "$env:USERPROFILE\Desktop","$env:USERPROFILE\Downloads" -Recurse -Depth 3 -Force | Where-Object Name -match 'crack|keygen|kmspico|kmsauto|activator|repack|xeno|solara|executor' | Select -First 20 FullName
L ($cr | Format-Table -AutoSize); if ($cr) { Flag "Crack-named items in Desktop/Downloads ($(@($cr).Count))" }

if (-not $Fast) {
  S "File walk (budget $BudgetSec s): miner/proxyware markers + new exe/bat/ps1/vbs (30 d)"
  $mark = '^(pawns-sdk.*|lastgood_miner.*|last_miner_error.*|RuntimeHost\.exe.*|RuntimeTask\.exe.*|RunstimeHost.*|proxies-peer|.*srbminer.*|.*xmrig.*|winring0.*|acess token.*)$'
  $prune = '^(node_modules|\.git|Package Cache|Packages|WindowsApps|Cache|Code Cache|GPUCache|Cache_Data|Service Worker|CacheStorage|Crashpad|DawnCache|steamapps|Windows Defender|Windows Defender Advanced Threat Protection|Malwarebytes)$'
  $trusted = 'Package Cache|Microsoft\\(Edge|Teams|OneDrive)|Discord|Google|BraveSoftware|Roblox|Bloxstrap|NVIDIA|Steam|Epic|Riot|Battle\.net|\\Code\\|Programs\\|Razer|obs-studio|Malwarebytes|Spotify|Voicemod|Medal|Opera|JetBrains|Everything'
  $cut = (Get-Date).AddDays(-30); $sw2 = [Diagnostics.Stopwatch]::StartNew(); $stack = New-Object Collections.Stack
  foreach ($r in $env:ProgramData,$env:APPDATA,$env:LOCALAPPDATA,"$env:SystemRoot\SystemTemp","$env:SystemRoot\Temp",$env:PUBLIC,"$env:USERPROFILE\Downloads","$env:USERPROFILE\Desktop") { if (Test-Path $r) { $stack.Push($r) } }
  $hits = @(); $newx = @(); $dirs = 0
  while ($stack.Count -and $sw2.Elapsed.TotalSeconds -lt $BudgetSec) {
    $d = $stack.Pop(); $dirs++
    try {
      foreach ($f in [IO.Directory]::EnumerateFiles($d)) {
        $n = [IO.Path]::GetFileName($f)
        if ($n -match $mark) { $hits += $f }
        elseif ($n -match '\.(exe|bat|cmd|ps1|vbs|scr)$' -and [IO.File]::GetLastWriteTime($f) -gt $cut -and $f -notmatch $trusted) { $newx += "$([IO.File]::GetLastWriteTime($f).ToString('yyyy-MM-dd')) $f" }
      }
      foreach ($s in [IO.Directory]::EnumerateDirectories($d)) {
        $n = [IO.Path]::GetFileName($s)
        if ($n -match $mark) { $hits += $s }
        if ($n -match $prune -or ([IO.File]::GetAttributes($s) -band [IO.FileAttributes]::ReparsePoint)) { continue }
        $stack.Push($s)
      }
    } catch {}
  }
  L "walked $dirs folders in $([int]$sw2.Elapsed.TotalSeconds) s; left unvisited: $($stack.Count)"
  L '-- markers'; L $hits; if ($hits) { Flag "Known miner/proxyware/driver marker files: $(@($hits).Count) (see file walk)" }
  L '-- new executables/scripts'; L ($newx | Select -First 60)
  if ($stack.Count) { Flag "File walk hit the time budget ($BudgetSec s); $($stack.Count) folders not checked - rerun with -BudgetSec 600" }
}

$head = @("scan-check report $(Get-Date) | admin: $isAdmin | fast: $Fast", '', '=== FLAGS (what to look at first) ===')
$head += $(if ($flags.Count) { $flags | ForEach-Object { " ! $_" } } else { ' none - nothing automatic stood out' })
if (-not $isAdmin) { $head += ' (not admin: Defender exclusions are hidden; run as administrator for the full picture)' }
$head + (Get-Content $part) | Out-File $Out -Encoding utf8; Remove-Item $part
Write-Host "Done: $Out ($($flags.Count) flags). Read the report before you share it: it contains file paths and your user name."
