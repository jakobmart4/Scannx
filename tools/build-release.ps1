# Builds dist\Scannx-<version>.zip (+ .sha256): the scripts, the launcher, the docs and Intel PresentMon with its MIT license.
# CI downloads PresentMon from Intel's GitHub release; locally pass any copy of the same file (the hash below must match).
param(
  [Parameter(Mandatory)][string]$Version,
  [Parameter(Mandatory)][string]$PresentMon,          # PresentMon-2.3.1-x64.exe
  [Parameter(Mandatory)][string]$PresentMonLicense,   # LICENSE.txt from GameTechDev/PresentMon at tag v2.3.1
  [string]$Out = ''   # default <repo>\dist, set below: $PSScriptRoot is empty inside param defaults under powershell -File
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $Out) { $Out = Join-Path $root 'dist' }
# the build disk-log.ps1 was tested with; a newer PresentMon may change CSV columns or its clock
$pmName = 'PresentMon-2.3.1-x64.exe'; $pmSha = '364e5d98d4d134bd54dd25c22ed2ca2f4883f8bc3ed6502bee0c151e3436d30c'
$sha = (Get-FileHash $PresentMon -Algorithm SHA256).Hash.ToLower()
if ($sha -ne $pmSha) { throw "PresentMon SHA256 is $sha, expected $pmSha ($pmName from github.com/GameTechDev/PresentMon/releases/tag/v2.3.1)" }
# the real LICENSE.txt has no "MIT License" title: it starts with "Copyright (C) 2017-2024 Intel Corporation" and the MIT permission text
$lic = Get-Content $PresentMonLicense -Raw
if ($lic -notmatch 'Intel Corporation' -or $lic -notmatch 'Permission is hereby granted, free of charge') { throw "$PresentMonLicense is not the PresentMon MIT license" }

$name = "Scannx-$Version"; $stage = Join-Path $Out $name
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item $stage -ItemType Directory -Force | Out-Null
foreach ($f in 'Scannx.cmd', 'scan-check.ps1', 'disk-log.ps1', 'README.md', 'LICENSE', 'CHANGELOG.md') { Copy-Item (Join-Path $root $f) $stage }
Copy-Item $PresentMon (Join-Path $stage $pmName)
Copy-Item $PresentMonLicense (Join-Path $stage 'PresentMon-LICENSE.txt')

$zip = Join-Path $Out "$name.zip"
if (Test-Path $zip) { Remove-Item $zip -Force }
Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::CreateFromDirectory($stage, $zip, 'Optimal', $true)   # $true: files sit in a Scannx-<version>\ folder
Remove-Item $stage -Recurse -Force
$zsha = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
"$zsha  $name.zip" | Set-Content "$zip.sha256" -Encoding ascii
Get-Item $zip, "$zip.sha256" | ForEach-Object { '{0}  {1:N0} B' -f $_.Name, $_.Length }
