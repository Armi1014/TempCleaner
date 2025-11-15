@echo off
"%ProgramFiles%\PowerShell\7\pwsh.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0TempCleaner.ps1" %*
