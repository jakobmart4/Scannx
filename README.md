# Scannx

Read-only Windows checks for two questions: **is something hiding on this PC?** and **why does my game stutter?**
Plain Windows PowerShell 5.1 scripts: nothing to install, no data uploaded, no settings changed. They only write their reports to your Desktop, and the stutter log pings your router and 1.1.1.1 to measure lag.

*Eesti keeles: vaata lõppu.*

## Download and run

1. Download `Scannx-<version>.zip` from [Releases](https://github.com/jakobmart4/Scannx-Tools/releases). Optional: compare its SHA256 with the `.sha256` file next to it.
2. Right-click the zip, **Properties**, tick **Unblock**, OK. Then unzip it, for example to your Desktop.
3. Double-click **`Scannx.cmd`** and allow administrator rights (UAC). Windows may show "Windows protected your PC" because the scripts are not code-signed: **More info**, **Run anyway**. The scripts are short plain text; read them first if you like.
4. Pick from the menu:

| Choice | What it does | Time |
|---|---|---|
| 1 | Full malware and health scan | a few minutes |
| 2 | Quick scan (no file walk) | about 1 minute |
| 3 | Stutter log: start it **before** the game, play, press **F9** when it stutters (it asks for the game and the minutes) | as long as you choose |
| 4 | Summarize an old stutter log again (drag its folder into the window) | seconds |

Reports go to your Desktop: `scan-report.txt` and `disk-log\run-<date>_<time>\`. They contain file paths and your user name: **read them before you share them.**

## The scan (`scan-check.ps1`)

The report starts with **FLAGS**: things worth a look. A flag is a hint, not a verdict, and Scannx is not an antivirus. Run a Microsoft Defender full scan as well.

| Area | Flagged when |
|---|---|
| Defender | real-time protection is off, status cannot be read, no full scan in 14 days, signatures older than 3 days, Tamper Protection off |
| Exclusions (admin) | exclusions set by **policy** (`HKLM\SOFTWARE\Policies\Microsoft\Windows Defender\Exclusions`, a malware trick: `Remove-MpPreference` cannot remove them), suspicious exclusions (drive roots, Temp, AppData, Program Files, hex-named folders, miner names), or any exclusions at all ("check they are yours") |
| Exclusion history | Defender event 5007 shows exclusions added in the last 90 days (readable without admin) |
| Detections | Defender detections in the last 14 days |
| Autostart | an enabled Run entry points to a missing file or to `ProgramData`, `Temp` or `Users\Public` |
| Scheduled tasks, services | non-Microsoft tasks or auto-start services in those unusual places, or tasks named like known miners |
| Persistence | Winlogon Shell/Userinit not default, IFEO debugger set, WMI event consumer present |
| Network settings | custom `hosts` entries, system proxy or PAC script set |
| Miner hiding spots | unknown files in `ProgramData\Microsoft\Windows\Caches`, hex-named folders (7-8 hex digits) in ProgramData/Windows/Caches |
| Discord | `discord_desktop_core\index.js` is modified (token stealers do this) |
| Hardware | disk, NTFS, storage or WHEA errors in the System log (14 days) |
| Software | remote-access or crack-type software installed (TeamViewer, AnyDesk, Cheat Engine, KMS, torrent clients...), crack-named files in Desktop/Downloads |
| File walk | known miner / proxyware files (xmrig, SRBMiner, WinRing0, pawns-sdk, RuntimeHost...) in ProgramData, AppData, Temp, Public, Downloads, Desktop. Capped at 120 s |

It also lists, without flags: startup folders, folders in ProgramData that hold an exe, new files in `Windows\SystemTemp`, programs listening on all network interfaces, outbound connections by program and top memory users. The full scan adds up to 60 executables/scripts changed in the last 30 days; files under well-known apps (Steam, Discord, browsers, NVIDIA and similar) and cache folders are skipped there to keep the list short.
Without admin everything runs except the Defender exclusion list.

## The stutter log (`disk-log.ps1`)

**Start it before the game.** Anti-cheat software (for example EA Javelin in Apex Legends) blocks new frame-time recordings once it runs, even for administrators. If that happens, the log still records everything else; `events.txt` line 2 gives PresentMon's error (with a "start before the game" hint when it sees EA AntiCheat running).

While you play it records, about every 1-2 seconds: CPU load and real clock speed, RAM (free, standby, commit, pagefile, paging), GPU load and memory, every disk (latency, busy, queue, MB/s), network traffic and the game's memory. Every third sample also pings your router and 1.1.1.1 and reads GPU temperature, clock and throttle reasons (NVIDIA only, via `nvidia-smi`). Frame times come from Intel **PresentMon** (bundled in the zip).

- **F9** marks a stutter. Each mark gets its own diagnosis, and a snapshot of the top processes goes to `events.txt`.
- Spikes (CPU > 90 %, free RAM < 1 GB, heavy paging, GPU > 95 %, disk latency > 50 ms) are logged by themselves.
- **Ctrl+C** stops early and still writes the summary. Then answer **N** to "Terminate batch job?" to get back to the menu. Do not close the window with X: the summary is then missing (run choice 4 on the folder to make it).
- Another game: the menu asks for its process name (Task Manager, Details tab, without `.exe`).

`summary.txt` gives min/avg/max of every measure, then a verdict, then a diagnosis of each F9 mark. Loading screens at the start and the end are left out: by frame rate when frame times exist, otherwise the first 120 s after a game start seen in the log and the last few samples.

| Verdict | Meaning |
|---|---|
| MEMORY pressure | available RAM (free + standby) went below 1 GB or paging above 50 000 pages/s. It shows how much of it was standby cache: "RAM cleaner" tools can only free that part |
| COMMIT charge | RAM + pagefile at least 95 % full |
| Trimmed game memory | Windows took memory away from the game while RAM was short (hitches after alt-tab or AFK) |
| DISK | a disk answered slower than 50 ms |
| GPU / CPU | above 95 % / 90 % load in at least 3 % of the samples |
| CPU clock fell | the clock dropped below 60 % of its peak under load (thermal or power limit) |
| NETWORK | at least 1 % pings lost, or the router above 50 ms twice, or the internet above 150 ms three times |
| GPU throttling | thermal or hardware slowdown in at least 3 % of the readings (the normal power-limit bit is shown as info only) |
| FRAME hitches | frames longer than 3x the median and over 25 ms. If nothing else was wrong, the cause is the game or the driver (shader compilation, asset streaming), not your PC |

If nothing stands out and F9 marks show no frame hitch, the stutter is likely not on your PC (for example the game server). The ping only reaches your router and 1.1.1.1, not the game server.

## Requirements and limits

- Windows 10 or 11 with Windows PowerShell 5.1 (built in). Administrator rights for the Defender exclusion list and for frame times.
- The stutter log uses English performance-counter names. Live logging was tested on Windows 11 with English counter names. On a Windows with translated counter names (for example German or French) it may stop with "Cannot read performance counters".
- GPU temperature, clock and throttle need an NVIDIA GPU. Other GPUs leave those columns empty.
- Loading screens in the middle of a session count as play. When loading takes about half of a short session, nothing is trimmed (the cut compares with the median frame rate).

## Run the scripts directly

```powershell
powershell -ExecutionPolicy Bypass -File .\scan-check.ps1 -Fast -Out "$env:USERPROFILE\Desktop\scans\report.txt"   # -BudgetSec 600 = longer file walk
powershell -ExecutionPolicy Bypass -File .\disk-log.ps1 -Minutes 30 -Game r5apex_dx12     # -Dir <folder>, -PresentMon <exe>
powershell -ExecutionPolicy Bypass -File .\disk-log.ps1 -Summarize "$env:USERPROFILE\Desktop\disk-log\run-2026-10-25_16-37-00"
```

## Development

- Tests: `Invoke-Pester tests` (Pester 3.4, the one that ships with Windows). The stutter-log verdicts run on synthetic logs in `tests/fixtures` (made by `tests/make-fixtures.ps1`). The scan has a smoke test that runs it on the real machine (about 1 minute).
- CI on every push to `main` and every pull request: parse all scripts, PSScriptAnalyzer (errors), Pester, on `windows-latest` with Windows PowerShell 5.1.
- Plan, known limits and ideas: [docs/NEXT.md](docs/NEXT.md).
- Release: push a tag `vX.Y.Z` with a matching `## vX.Y.Z` section in `CHANGELOG.md`. CI builds `Scannx-vX.Y.Z.zip` with `tools/build-release.ps1` (which checks the PresentMon SHA256) and publishes it.

## License

MIT, see [LICENSE](LICENSE). The release zip includes Intel PresentMon 2.3.1 ([GameTechDev/PresentMon](https://github.com/GameTechDev/PresentMon)), MIT license, copyright Intel Corporation, in `PresentMon-LICENSE.txt`.

---

## Eesti keeles

Scannx on Windowsi kontrollid kahele küsimusele: **kas arvutis peidab end midagi** ja **miks mäng hakib**. Skriptid ainult loevad: midagi ei paigaldata, andmeid ei laeta üles ega seadeid muudeta. Raportid lähevad Desktopile ja hakkimise logi pingib ruuterit ja 1.1.1.1.

1. Lae [Releases](https://github.com/jakobmart4/Scannx-Tools/releases) alt `Scannx-<versioon>.zip`. Paremklõps, **Properties**, linnuke **Unblock** kasti, pakki lahti.
2. Topeltklõps **`Scannx.cmd`**, luba administraatori õigused. Kui Windows hoiatab ("Windows protected your PC"): **More info**, **Run anyway** (skriptid pole allkirjastatud).
3. Menüü: **1** täisskänn, **2** kiirskänn, **3** hakkimise logi (käivita **enne** mängu, hakkimisel vajuta **F9**; Ctrl+C lõpetab varem, siis vasta "Terminate batch job" küsimusele **N**), **4** vana logi kokkuvõte uuesti.

Raportid tulevad Desktopile (`scan-report.txt`, `disk-log\run-...\summary.txt`). Neis on failiteed ja kasutajanimi: vaata üle enne jagamist. FLAGS on vihjed, mitte otsus. Scannx ei asenda viirusetõrjet, tee ka Defenderi täisskänn.
