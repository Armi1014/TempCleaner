@echo off
set "PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"
if exist "%PWSH%" (
  "%PWSH%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0TempCleaner.ps1"
) else (
  powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0TempCleaner.ps1"
)
