# Scannx-Tools: plan

Status 2026-10-25: **v1.0.0**, the first public release. One launcher (`Scannx.cmd`), the malware/health scan (`scan-check.ps1`), the stutter logger (`disk-log.ps1`) with PresentMon frame times, 66 Pester tests, CI and a release workflow that bundles Intel PresentMon 2.3.1 (SHA256-pinned).
Each step stays small and checkable: change, test, update this file and `CHANGELOG.md`, commit.

## Done in v1.0.0

- Verdict logic of the stutter log covered by synthetic fixtures (`tests/fixtures`, made by `tests/make-fixtures.ps1`), mutation-checked.
- Frame times: PresentMon started before the game (anti-cheat blocks it later), its clock skew aligned, loading screens cut by frame rate.
- Scan smoke test on a real machine; release dry run (`workflow_dispatch`) builds the zip without publishing.

## Known limits

- The stutter log uses English performance-counter names; Windows with translated counter names may stop with "Cannot read performance counters".
- A log that runs across midnight is not handled.
- Loading screens in the middle of a session count as play; a short session where loading takes about half the time is not trimmed.
- The ping reaches the router and 1.1.1.1, not the game server.
- Ctrl+C inside the launcher ends with cmd's "Terminate batch job (Y/N)?"; answer N to get back to the menu.
- The anti-cheat hint only recognises EA AntiCheat.
- `scan-check.ps1` has a smoke test only; its regexes (exclusions, services, markers) have no unit tests.
- Scripts are not code-signed (SmartScreen warns on first run). GitHub Actions are pinned by tag, Pester comes from the PowerShell Gallery without a hash.

## Ideas (not planned yet)

- Measure the connection to the game server itself (lag that the PC and the router do not explain).
- Scan: compare against a saved baseline, check signatures of autostart programs, list firewall allow rules and known vulnerable drivers, `-Json` output.
- Unit tests for the scan's regexes.

## How to release

1. Add a `## vX.Y.Z - <date>` section at the top of `CHANGELOG.md`.
2. Optional: run the `release` workflow by hand; it builds the zip as an artifact only.
3. `git tag vX.Y.Z` and `git push origin vX.Y.Z`: CI tests, builds `Scannx-vX.Y.Z.zip` and publishes the GitHub release.
