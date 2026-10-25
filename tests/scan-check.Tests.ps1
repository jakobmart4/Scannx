# Smoke test: runs the real scan-check.ps1 -Fast on this machine (read-only, about 1 min) and checks the report's shape, not its findings.
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$script = Join-Path (Split-Path -Parent $here) 'scan-check.ps1'

Describe 'scan-check.ps1 -Fast (smoke test)' {
  # -Out points into a folder that does not exist yet: the script must create it (it used to print "Done" and write nothing)
  $dir = Join-Path $env:TEMP ('scannx-scan-' + [guid]::NewGuid().ToString('N'))
  $out = Join-Path $dir 'sub\report.txt'
  & powershell -NoProfile -ExecutionPolicy Bypass -File $script -Fast -Out $out | Out-Null
  $txt = if (Test-Path $out) { Get-Content $out -Raw } else { '' }
  It 'writes the report header and the FLAGS block first' { $txt | Should Match '^\W*scan-check report .*\| fast: True\s+=== FLAGS \(what to look at first\) ===' }
  It 'lists at least one flag or says none' { $txt | Should Match '=== FLAGS[^\n]*\n( ! | none - nothing automatic stood out)' }
  It 'runs every section' {
    foreach ($s in 'Info', 'Defender', 'Autostart', 'Startup folders', 'Scheduled tasks', 'Services', 'Persistence extras', 'Discord core index.js', 'Network', 'Top memory', 'System log', 'Installed software', 'Crack-named') {
      $txt | Should Match "=== $([regex]::Escape($s))" }
  }
  It 'skips the file walk with -Fast' { $txt | Should Not Match '=== File walk' }
  It 'removes the .partial file' { Test-Path "$out.partial" | Should Be $false }
  Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue   # the report holds this machine's paths and user name
}
