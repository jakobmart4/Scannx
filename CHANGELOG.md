# Changelog

## v1.0.0 - 2026-10-25

First public release.

- **Scannx.cmd**: one double-click launcher with a menu (full scan, quick scan, stutter log, summarize an old log). Asks for administrator rights itself.
- **scan-check.ps1**: read-only malware and health check. Defender state, exclusions (including exclusions planted as policy) and their history, detections, autostart, scheduled tasks, services, persistence spots, hosts and proxy, miner hiding spots, Discord `index.js`, disk errors, remote-access and crack-type software, and a time-boxed file walk for miner/proxyware markers. FLAGS on top of the report.
- **disk-log.ps1**: stutter logger with a summary and a verdict: memory pressure, commit charge, game memory trimming, disk latency, CPU/GPU load, CPU clock drops, network loss and lag, GPU thermal throttling, and frame-time hitches from PresentMon. Press F9 to mark a stutter; each mark gets its own diagnosis.
- Frame times: the zip bundles Intel PresentMon 2.3.1 (MIT, SHA256-checked at build time). Loading screens at the start and the end are cut out by frame rate.
