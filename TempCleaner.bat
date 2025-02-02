@echo off

:: Check for admin privileges
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo Requesting administrative privileges...
    powershell -Command "Start-Process -Verb runAs -FilePath '%~f0'"
    exit /b
)

:: Function to delete files in a folder and log the action
call :DeleteFiles "%temp%" "User Temp Files"
call :DeleteFiles "C:\Windows\Temp" "System Temp Files"
call :DeleteFiles "C:\Windows\SoftwareDistribution\Download" "Windows Update Cache"
call :DeleteFiles "C:\Users\%username%\AppData\Local\Microsoft\Windows\Explorer" "Thumbnail Cache"
call :DeleteFiles "C:\Windows\Minidump" "Memory Dumps"
call :DeleteFiles "C:\Users\%username%\AppData\Local\Microsoft\Windows\INetCache" "Edge/IE Cache"

:: Exit
echo Cleanup completed.
pause
exit /b

:: Function to delete files in a folder and log the action
:DeleteFiles
set folder=%1
set description=%2

echo Cleaning %description%...
if exist "%folder%" (
    forfiles /p "%folder%" /s /c "cmd /c del /q @path" >nul 2>&1
    if %errorLevel% equ 0 (
        echo %description% deleted successfully.
    ) else (
        echo Failed to delete files in %description%.
        echo Possible reasons:
        echo - The file is currently in use by another process.
        echo - The file is locked by the system or has restricted permissions.
        echo - Insufficient privileges to delete the file.
        echo - The file may be corrupted or protected.
    )
) else (
    echo %description% folder does not exist.
)
exit /b