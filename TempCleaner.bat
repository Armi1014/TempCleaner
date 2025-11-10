@echo off
setlocal EnableExtensions EnableDelayedExpansion

rem =========================================================
rem TempCleaner.bat - Windows temp/cache cleaner
rem =========================================================

rem ---------------------------------------------------------
rem Detect admin
rem ---------------------------------------------------------
>nul 2>&1 net session
if %errorlevel%==0 (
    set "IsAdmin=1"
) else (
    set "IsAdmin=0"
)

rem =========================================================
rem Setup logging
rem =========================================================
set "logFile=%~dp0cleanup_log.txt"

(
    echo Cleanup started at %date% %time%
    echo Running as user: %USERNAME%
    echo Running as admin: %IsAdmin%
    echo ----------------------------------------
) >"%logFile%"

echo Cleanup started at %date% %time%
echo Running as admin: %IsAdmin%
echo(

rem =========================================================
rem Cleanup targets
rem =========================================================

rem -- User-level temp
call :DeleteFolder "%TEMP%" "User Temp Files"

rem -- System-level stuff: only if admin
if "%IsAdmin%"=="1" (
    call :DeleteFolder "%SystemRoot%\Temp" "System Temp Files"
    call :DeleteFolder "%SystemRoot%\SoftwareDistribution\Download" "Windows Update Cache"
    call :DeleteFolder "%SystemRoot%\Minidump" "Memory Dumps"
) else (
    echo Skipping system-level cleanup (run as Administrator to enable).
    echo [INFO] Skipped system-level cleanup (not running as admin).>>"%logFile%"
)

rem -- Browser cache
call :DeleteFolder "%LOCALAPPDATA%\Microsoft\Windows\INetCache" "Edge/IE Cache"

echo(
choice /C YN /M "Do you want to clear the Explorer thumbnail cache? (This may restart Explorer)"
if errorlevel 2 goto SkipThumbs

echo(
echo Stopping Explorer...
echo [Thumbs] User chose to clear thumbnail cache.>>"%logFile%"
taskkill /f /im explorer.exe >nul 2>&1

call :DeleteFolder "%LOCALAPPDATA%\Microsoft\Windows\Explorer" "Thumbnail Cache"

echo Restarting Explorer...
start explorer.exe

:SkipThumbs
echo Cleanup completed at %date% %time%>>"%logFile%"
echo(
echo Cleanup completed. See cleanup_log.txt for details.
pause
endlocal
exit /b


rem =========================================================
rem Subroutine: DeleteFolder <folder> <description>
rem =========================================================
:DeleteFolder
set "folder=%~1"
set "desc=%~2"

rem Empty path check
if "%folder%"=="" goto DF_Empty

rem Normalize some critical vars for safety checks
set "winroot=%SystemRoot%"

rem Block dangerous roots and critical folders
if /I "%folder%"=="\" goto DF_Danger
if /I "%folder%"=="C:\" goto DF_Danger
if /I "%folder%"=="C:" goto DF_Danger
if /I "%folder%"=="%winroot%" goto DF_Danger
if /I "%folder%"=="%winroot%\System32" goto DF_Danger

echo(
echo Cleaning %desc%:
echo   %folder%

if not exist "%folder%" goto DF_NotExist

echo [%desc%] Files in "%folder%":>>"%logFile%"
dir /s /b "%folder%\*" >>"%logFile%" 2>nul

rem Delete files
del /s /f /q "%folder%\*" >nul 2>&1

rem Delete subfolders (but not the root folder itself)
for /d %%D in ("%folder%\*") do rd /s /q "%%D" >nul 2>&1

set "err=%errorlevel%"

if "%err%"=="0" goto DF_Ok

echo [%desc%] Failed to delete some files or folders (error %err%).>>"%logFile%"
echo Failed to delete some files or folders.
goto DF_End

:DF_Ok
echo [%desc%] Files and subfolders deleted successfully.>>"%logFile%"
echo Done.
goto DF_End

:DF_NotExist
echo [%desc%] Folder "%folder%" does not exist.>>"%logFile%"
echo Folder does not exist, skipping.
goto DF_End

:DF_Empty
echo Skipping %desc% (empty path).
echo [%desc%] Skipped: empty path.>>"%logFile%"
goto DF_End

:DF_Danger
echo Skipping %desc% (dangerous path: %folder%).
echo [%desc%] Skipped: dangerous path "%folder%".>>"%logFile%"
goto DF_End

:DF_End
goto :EOF
