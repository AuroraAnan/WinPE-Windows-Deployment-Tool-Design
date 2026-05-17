@echo off
setlocal EnableExtensions EnableDelayedExpansion

set "SERVER_IP=192.168.1.143"
set "SERVER_SHARE=\\192.168.1.143\Deploy"
set "SERVER_DRIVE=Z:"
set "REMOTE_SCRIPT_DIR=Z:\AutoApply"
set "REMOTE_LOG_ROOT=Z:\LOG"
set "PING_MAX_RETRY=5"
set "NET_USE_MAX_RETRY=3"

set "STAMP=%DATE%_%TIME%"
set "STAMP=%STAMP:/=%"
set "STAMP=%STAMP:\=%"
set "STAMP=%STAMP::=%"
set "STAMP=%STAMP:.=%"
set "STAMP=%STAMP:,=%"
set "STAMP=%STAMP: =0%"
set "STAMP=%STAMP:-=%"
set "RUNID=%COMPUTERNAME%_%STAMP%_%RANDOM%"

set "WORKDIR=%TEMP%\AutoApply\WORK\%RUNID%"
set "LOGDIR=%TEMP%\AutoApply\LOG\%RUNID%"
set "DETAILDIR=%LOGDIR%\details"
set "STARTNET_DETAIL=%DETAILDIR%\00_startnet"
set "HTA_DETAIL=%DETAILDIR%\10_deploy_hta"
set "APPLY_DETAIL=%DETAILDIR%\20_applyimage"
set "SESSION_LOG=%LOGDIR%\DeploySession.log"
set "STARTNET_LOG=%STARTNET_DETAIL%\startnet.log"
set "RESULT_FILE=%LOGDIR%\DeploymentResult.txt"
set "README_FILE=%LOGDIR%\README_FIRST.txt"
set "ENV_FILE=%LOGDIR%\DeployEnv.cmd"
set "WORK_ENV_FILE=%WORKDIR%\DeployEnv.cmd"
set "HTA_RC_FILE=%HTA_DETAIL%\hta_exit_code.txt"

mkdir "%WORKDIR%" >nul 2>&1
mkdir "%STARTNET_DETAIL%" >nul 2>&1
mkdir "%HTA_DETAIL%" >nul 2>&1
mkdir "%APPLY_DETAIL%" >nul 2>&1
type nul > "%STARTNET_LOG%"
type nul > "%SESSION_LOG%"

call :WriteReadme
call :WriteResult 90 00 "PENDING" "Startnet is preparing deployment."
call :SetArchiveStatus "NOT_RUN"
call :WriteEnv
copy /y "%ENV_FILE%" "%WORK_ENV_FILE%" >> "%STARTNET_LOG%" 2>&1
if errorlevel 1 (
    call :Fail 30 00 "Failed to copy DeployEnv.cmd to WORKDIR."
    exit /b !ERRORLEVEL!
)

call :LogStep "Startnet started. RUNID=%RUNID%"
call :LogStep "Initializing WinPE network."
wpeutil InitializeNetwork >> "%STARTNET_LOG%" 2>&1
if errorlevel 1 (
    call :Fail 40 00 "wpeutil InitializeNetwork failed."
    exit /b !ERRORLEVEL!
)

call :PingServerWithRetry
if errorlevel 1 (
    call :Fail 40 00 "Ping to deployment server failed."
    exit /b !ERRORLEVEL!
)

call :LogStep "Removing existing drive mapping for %SERVER_DRIVE%."
net use "%SERVER_DRIVE%" /delete /y >> "%STARTNET_LOG%" 2>&1

call :MapServerDriveWithRetry
if errorlevel 1 (
    call :Fail 40 00 "Failed to map deployment share."
    exit /b !ERRORLEVEL!
)

call :LogStep "Copying deployment scripts from %REMOTE_SCRIPT_DIR% to %WORKDIR%."
copy /y "%REMOTE_SCRIPT_DIR%\Deploy.hta" "%WORKDIR%\Deploy.hta" >> "%STARTNET_LOG%" 2>&1
if errorlevel 1 (
    call :Fail 30 00 "Failed to copy Deploy.hta."
    exit /b !ERRORLEVEL!
)
copy /y "%REMOTE_SCRIPT_DIR%\ApplyImage.bat" "%WORKDIR%\ApplyImage.bat" >> "%STARTNET_LOG%" 2>&1
if errorlevel 1 (
    call :Fail 30 00 "Failed to copy ApplyImage.bat."
    exit /b !ERRORLEVEL!
)

if not exist "%WORKDIR%\Deploy.hta" (
    call :Fail 30 00 "Local Deploy.hta is missing after copy."
    exit /b !ERRORLEVEL!
)
if not exist "%WORKDIR%\ApplyImage.bat" (
    call :Fail 30 00 "Local ApplyImage.bat is missing after copy."
    exit /b !ERRORLEVEL!
)
if not exist X:\Windows\System32\mshta.exe (
    call :Fail 30 00 "mshta.exe not found. WinPE-HTA component may be missing."
    exit /b !ERRORLEVEL!
)

call :LogStep "Launching local Deploy.hta."
start /wait "" mshta.exe "%WORKDIR%\Deploy.hta"
set "MSHTA_RC=%ERRORLEVEL%"
call :LogStep "mshta.exe returned %MSHTA_RC%."

set "HTA_RC=90"
if exist "%HTA_RC_FILE%" (
    set /p "HTA_RC="<"%HTA_RC_FILE%"
)
if "%HTA_RC%"=="" set "HTA_RC=90"

if "%MSHTA_RC%"=="0" goto :AfterHta
if exist "%HTA_RC_FILE%" goto :AfterHta
call :Fail 30 00 "Failed to launch Deploy.hta."
exit /b %ERRORLEVEL%

:AfterHta
call :LogStep "Deploy.hta reported return code %HTA_RC%."
set "RESULT_STAGE=10"
if "%HTA_RC%"=="0" set "RESULT_STAGE=20"
if "%HTA_RC%"=="20" set "RESULT_STAGE=20"
if "%HTA_RC%"=="21" set "RESULT_STAGE=20"
if "%HTA_RC%"=="22" set "RESULT_STAGE=20"
if "%HTA_RC%"=="23" set "RESULT_STAGE=20"
if "%HTA_RC%"=="24" set "RESULT_STAGE=20"
if "%HTA_RC%"=="90" if exist "%HTA_RC_FILE%" set "RESULT_STAGE=20"
if "%HTA_RC%"=="0" (
    call :WriteResult 0 %RESULT_STAGE% "SUCCESS" "Deployment completed successfully."
) else if "%HTA_RC%"=="10" (
    call :WriteResult 10 10 "CANCELLED" "Deployment was cancelled by the user."
) else (
    call :WriteResult %HTA_RC% %RESULT_STAGE% "FAILED" "Deployment failed. Review details logs."
)

call :ArchiveLogs
exit /b %HTA_RC%

:WriteEnv
(
    echo @echo off
    echo set "RUNID=%RUNID%"
    echo set "WORKDIR=%WORKDIR%"
    echo set "LOGDIR=%LOGDIR%"
    echo set "DETAILDIR=%DETAILDIR%"
    echo set "SESSION_LOG=%SESSION_LOG%"
    echo set "SERVER_IP=%SERVER_IP%"
    echo set "SERVER_SHARE=%SERVER_SHARE%"
    echo set "SERVER_DRIVE=%SERVER_DRIVE%"
) > "%ENV_FILE%"
exit /b 0

:PingServerWithRetry
set "PING_ATTEMPT=1"
:PingServerRetryLoop
call :LogStep "Checking server connectivity: %SERVER_IP% (attempt %PING_ATTEMPT%/%PING_MAX_RETRY%)."
ping -n 2 "%SERVER_IP%" >> "%STARTNET_LOG%" 2>&1
if not errorlevel 1 (
    call :LogStep "Server connectivity check passed on attempt %PING_ATTEMPT%."
    exit /b 0
)
call :LogStep "Server connectivity check failed on attempt %PING_ATTEMPT%."
if %PING_ATTEMPT% GEQ %PING_MAX_RETRY% (
    exit /b 1
)
set /a PING_ATTEMPT+=1
ping -n 3 127.0.0.1 >nul 2>&1
goto :PingServerRetryLoop

:MapServerDriveWithRetry
set "NET_USE_ATTEMPT=1"
:MapServerDriveRetryLoop
call :LogStep "Mapping %SERVER_DRIVE% to %SERVER_SHARE% (attempt %NET_USE_ATTEMPT%/%NET_USE_MAX_RETRY%)."
net use "%SERVER_DRIVE%" "%SERVER_SHARE%" /persistent:no >> "%STARTNET_LOG%" 2>&1
if not errorlevel 1 (
    call :LogStep "Drive mapping completed on attempt %NET_USE_ATTEMPT%."
    exit /b 0
)
call :LogStep "Drive mapping failed on attempt %NET_USE_ATTEMPT%."
if %NET_USE_ATTEMPT% GEQ %NET_USE_MAX_RETRY% (
    exit /b 1
)
net use "%SERVER_DRIVE%" /delete /y >> "%STARTNET_LOG%" 2>&1
set /a NET_USE_ATTEMPT+=1
ping -n 3 127.0.0.1 >nul 2>&1
goto :MapServerDriveRetryLoop

:WriteReadme
(
    echo WinPE deployment log bundle
    echo.
    echo RunID: %RUNID%
    echo.
    echo Start here:
    echo 1. Read DeploymentResult.txt for the final status.
    echo 2. Read DeploySession.log for the stage timeline.
    echo 3. Open details\00_startnet, details\10_deploy_hta, and details\20_applyimage for raw logs.
    echo.
    echo Local log root: %LOGDIR%
    echo.
    echo Return codes:
    echo 0  = SUCCESS
    echo 10 = CANCELLED
    echo 20 = Parameter / environment error
    echo 21 = Preparation / script generation error
    echo 22 = DiskPart failed
    echo 23 = DISM Apply-Image failed
    echo 24 = BCDBoot failed
    echo 30 = HTA / script launch error
    echo 40 = Network / share mapping error
    echo 90 = Unknown / interrupted / running state
) > "%README_FILE%"
exit /b 0

:WriteResult
set "RESULT_CODE=%~1"
set "RESULT_STAGE=%~2"
set "RESULT_STATUS=%~3"
set "RESULT_MESSAGE=%~4"
(
    echo Status=%RESULT_STATUS%
    echo Code=%RESULT_CODE%
    echo Stage=%RESULT_STAGE%
    echo RunID=%RUNID%
    echo Message=%RESULT_MESSAGE%
    echo WorkDir=%WORKDIR%
    echo LogDir=%LOGDIR%
    echo ArchiveStatus=NOT_RUN
    echo Time=%DATE% %TIME%
) > "%RESULT_FILE%"
exit /b 0

:SetArchiveStatus
set "ARCHIVE_STATUS=%~1"
set "RESULT_TMP=%WORKDIR%\DeploymentResult.tmp"
if not exist "%RESULT_FILE%" exit /b 1
findstr /v /b /c:"ArchiveStatus=" "%RESULT_FILE%" > "%RESULT_TMP%" 2>nul
if errorlevel 2 exit /b 1
echo ArchiveStatus=%ARCHIVE_STATUS%>> "%RESULT_TMP%"
move /y "%RESULT_TMP%" "%RESULT_FILE%" >nul 2>&1
exit /b %ERRORLEVEL%

:LogStep
set "LOG_MESSAGE=%~1"
call :LogSession "%LOG_MESSAGE%"
echo [%DATE% %TIME%] %LOG_MESSAGE%>> "%STARTNET_LOG%"
exit /b 0

:LogSession
set "SESSION_MESSAGE=%~1"
echo [%DATE% %TIME%] [00_startnet] %SESSION_MESSAGE%>> "%SESSION_LOG%"
exit /b 0

:Fail
set "FAIL_CODE=%~1"
set "FAIL_STAGE=%~2"
set "FAIL_MESSAGE=%~3"
call :LogStep "FAILED: %FAIL_MESSAGE%"
call :WriteResult %FAIL_CODE% %FAIL_STAGE% "FAILED" "%FAIL_MESSAGE%"
call :ArchiveLogs
exit /b %FAIL_CODE%

:ArchiveLogs
set "ARCHIVE_DIR=%REMOTE_LOG_ROOT%\%RUNID%"
set "XCOPY_LOG=%WORKDIR%\archive_xcopy_output.txt"
set "ARCHIVE_COPY_LOG=%WORKDIR%\archive_refresh_output.txt"
call :LogStep "Archiving logs to %REMOTE_LOG_ROOT%\%RUNID%."
call :SetArchiveStatus "STARTED"
if not exist "%SERVER_DRIVE%\" (
    call :LogStep "Log archive failed. Server drive is not available: %SERVER_DRIVE%"
    call :SetArchiveStatus "FAILED: %SERVER_DRIVE% unavailable"
    exit /b 1
)
mkdir "%ARCHIVE_DIR%" >nul 2>&1
if errorlevel 1 (
    call :LogStep "Log archive failed. Could not create remote archive folder: %ARCHIVE_DIR%"
    call :SetArchiveStatus "FAILED: mkdir remote archive"
    exit /b 1
)
xcopy "%LOGDIR%\*" "%REMOTE_LOG_ROOT%\%RUNID%\" /e /i /h /y > "%XCOPY_LOG%" 2>&1
if errorlevel 1 (
    type "%XCOPY_LOG%" >> "%STARTNET_LOG%"
    call :LogStep "Log archive failed during xcopy."
    call :SetArchiveStatus "FAILED: xcopy log bundle"
    exit /b 1
)
type "%XCOPY_LOG%" >> "%STARTNET_LOG%"
call :LogStep "Log archive completed."
call :SetArchiveStatus "SUCCESS"
copy /y "%RESULT_FILE%" "%ARCHIVE_DIR%\DeploymentResult.txt" > "%ARCHIVE_COPY_LOG%" 2>&1
if errorlevel 1 (
    type "%ARCHIVE_COPY_LOG%" >> "%STARTNET_LOG%"
    call :LogStep "Log archive refresh failed for DeploymentResult.txt."
    call :SetArchiveStatus "FAILED: refresh result file"
    exit /b 1
)
copy /y "%STARTNET_LOG%" "%ARCHIVE_DIR%\details\00_startnet\startnet.log" > "%ARCHIVE_COPY_LOG%" 2>&1
if errorlevel 1 (
    type "%ARCHIVE_COPY_LOG%" >> "%STARTNET_LOG%"
    call :LogStep "Log archive refresh failed for startnet.log."
    call :SetArchiveStatus "FAILED: refresh startnet log"
    copy /y "%RESULT_FILE%" "%ARCHIVE_DIR%\DeploymentResult.txt" >nul 2>&1
    exit /b 1
)
copy /y "%SESSION_LOG%" "%ARCHIVE_DIR%\DeploySession.log" > "%ARCHIVE_COPY_LOG%" 2>&1
if errorlevel 1 (
    type "%ARCHIVE_COPY_LOG%" >> "%STARTNET_LOG%"
    call :LogStep "Log archive refresh failed for DeploySession.log."
    call :SetArchiveStatus "FAILED: refresh session log"
    copy /y "%RESULT_FILE%" "%ARCHIVE_DIR%\DeploymentResult.txt" >nul 2>&1
    copy /y "%STARTNET_LOG%" "%ARCHIVE_DIR%\details\00_startnet\startnet.log" >nul 2>&1
    exit /b 1
)
exit /b 0
