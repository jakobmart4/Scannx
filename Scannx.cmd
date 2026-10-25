@echo off
rem Scannx launcher. Double-click it: it asks for administrator rights (UAC), then shows a menu.
rem Admin shows the Defender exclusion list and lets the stutter log record frame times. Nothing here changes your system.
rem The path goes to PowerShell through %SELF%, not inside a quoted string: an apostrophe in a folder name would break that.
set "SELF=%~f0"
fltmc >nul 2>&1 || (powershell -NoProfile -Command "Start-Process -FilePath $env:SELF -Verb RunAs" & exit /b)
cd /d "%~dp0"
set "PS=powershell -NoProfile -ExecutionPolicy Bypass -File"

:menu
echo.
echo  Scannx
echo   1  Malware and health scan (full, a few minutes)
echo   2  Quick scan (skips the file walk, about 1 minute)
echo   3  Stutter log (start it BEFORE the game; F9 = mark a stutter)
echo      Ctrl+C stops early; then answer N to "Terminate batch job" to come back here
echo   4  Summarize an old stutter log again
echo   Q  Quit
set "c="
set /p "c=Choose: "
if defined c set "c=%c:"=%"
if /i "%c%"=="1" %PS% "%~dp0scan-check.ps1" & goto done
if /i "%c%"=="2" %PS% "%~dp0scan-check.ps1" -Fast & goto done
if /i "%c%"=="3" goto stutter
if /i "%c%"=="4" goto summarize
if /i "%c%"=="q" exit /b
goto menu

:stutter
set "g="
set /p "g=Game process name without .exe (Enter = Apex Legends): "
if defined g set "g=%g:"=%"
if defined g (%PS% "%~dp0disk-log.ps1" -Game "%g%") else (%PS% "%~dp0disk-log.ps1")
goto done

:summarize
set "d="
set /p "d=Drag a run-... folder from Desktop\disk-log here and press Enter: "
if not defined d goto menu
set "d=%d:"=%"
rem drag and drop or paste can leave a trailing space or backslash; PowerShell reads \" as a quote
:trim
if not defined d goto menu
if "%d:~-1%"==" " set "d=%d:~0,-1%" & goto trim
if "%d:~-1%"=="\" set "d=%d:~0,-1%"
%PS% "%~dp0disk-log.ps1" -Summarize "%d%"

:done
echo.
pause
goto menu
