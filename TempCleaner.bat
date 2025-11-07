@echo off
setlocal EnableExtensions

rem =========================================================
rem Setup logging
rem =========================================================
set "logFile=%~dp0cleanup_log.txt"

echo Cleanup started at %date% %time% >"%logFile%"
echo Running as user: %USERNAME%>>"%logFile%"
echo ---------------------------------------->>"%logFile%"

echo Cleanup started at %date% %time%
echo(

rem =========================================================
rem Cleanup targets
rem =========================================================
call :DeleteFolder "%TEMP%" "User Temp Files"
call :DeleteFolder "C:\Windows\Temp" "System Temp Files"
call :DeleteFolder "C:\Windows\SoftwareDistribution\Download" "Windows Update Cache"
call :DeleteFolder "C:\Windows\Minidump" "Memory Dumps"
call :DeleteFolder "%LOCALAPPDATA%\Microsoft\Windows\INetCache" "Edge/IE Cache"

echo(
choice /C YN /M "Do you want to clear the Explorer thumbnail cache? (This may restart Explorer)"
if errorlevel 2 goto SkipThumbs

echo(
echo Stopping Explorer...
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

rem Block dangerous roots
if /I "%folder%"=="\" goto DF_Danger
if /I "%folder%"=="C:\" goto DF_Danger
if /I "%folder%"=="C:" goto DF_Danger

echo(
echo Cleaning %desc%:
echo   %folder%

if not exist "%folder%" goto DF_NotExist

echo [%desc%] Files in "%folder%":>>"%logFile%"
dir /s /b "%folder%\*" >>"%logFile%" 2>nul

del /s /f /q "%folder%\*" >nul 2>&1
set "err=%errorlevel%"

if "%err%"=="0" goto DF_Ok

echo [%desc%] Failed to delete some files (error %err%).>>"%logFile%"
echo Failed to delete some files.
goto DF_End

:DF_Ok
echo [%desc%] Files deleted successfully.>>"%logFile%"
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
