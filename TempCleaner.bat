<<<<<<< HEAD
@echo off

:: Check for admin privileges
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo Requesting administrative privileges...
    powershell -Command "Start-Process -Verb runAs -FilePath '%~f0'"
    exit /b
)

:: Get the directory of the batch file
set "logFile=%~dp0cleanup_log.txt"

:: Start Logging
echo Cleanup started... > "%logFile%"

:: Function to delete files in a folder and log the action
call :DeleteFiles "%temp%" "User Temp Files"
call :DeleteFiles "C:\Windows\Temp" "System Temp Files"
call :DeleteFiles "C:\Windows\SoftwareDistribution\Download" "Windows Update Cache"
call :DeleteFiles "C:\Windows\Minidump" "Memory Dumps"
call :DeleteFiles "C:\Users\%username%\AppData\Local\Microsoft\Windows\INetCache" "Edge/IE Cache"

:: Ask before deleting Explorer cache
echo Do you want to clear the Explorer thumbnail cache? (This may restart Explorer) [Y/N]
set /p choice=
if /i "%choice%"=="Y" (
    taskkill /f /im explorer.exe >nul 2>&1
    call :DeleteFiles "C:\Users\%username%\AppData\Local\Microsoft\Windows\Explorer" "Thumbnail Cache"
    start explorer.exe
)

:: Exit
echo Cleanup completed. >> "%logFile%"
echo Cleanup completed. See cleanup_log.txt for details.
pause
exit /b

:: Function to delete files in a folder and log the action
:DeleteFiles
set "folder=%1"
set "description=%2"

echo Cleaning %description%...
if exist "%folder%" (
    echo %description% - Files in "%folder%": >> "%logFile%"
    dir /s /b "%folder%\*" >> "%logFile%" 2>nul
    del /s /f /q "%folder%\*" >nul 2>&1
    if %errorLevel% equ 0 (
        echo %description% deleted successfully. >> "%logFile%"
    ) else (
        echo Failed to delete files in %description%. >> "%logFile%"
    )
) else (
    echo %description% folder does not exist. >> "%logFile%"
)
exit /b
=======
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
>>>>>>> 2bb01693755ef860fe27dacb936c1a7f6297d184
