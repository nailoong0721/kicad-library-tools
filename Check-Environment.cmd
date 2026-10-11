@echo off
setlocal
set "PSModulePath="
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Check-Environment.ps1" %*
set "checkExit=%ERRORLEVEL%"
echo.
pause
exit /b %checkExit%
