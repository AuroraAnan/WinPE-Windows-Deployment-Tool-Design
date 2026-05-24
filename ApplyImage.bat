@echo off
setlocal EnableExtensions EnableDelayedExpansion

set "ENV_FILE=%~dp0DeployEnv.cmd"
if not exist "%ENV_FILE%" (
    echo ERROR: DeployEnv.cmd not found at "%ENV_FILE%".
    exit /b 20
)

call "%~dp0DeployEnv.cmd"
if errorlevel 1 (
    echo ERROR: Failed to load DeployEnv.cmd.
    exit /b 20
)

set "APPLY_DETAIL=%LOGDIR%\details\20_applyimage"
set "APPLY_LOG=%APPLY_DETAIL%\applyimage.log"
set "DISKPART_SCRIPT=%APPLY_DETAIL%\diskpart.script.txt"
set "DISKPART_PRECHECK_SCRIPT=%APPLY_DETAIL%\diskpart.precheck.script.txt"
set "DISKPART_LOG=%APPLY_DETAIL%\diskpart.log"
set "BAD_PIPE=^|"

if "%~1"=="" (
    set "PARAM_FILE=%LOGDIR%\details\10_deploy_hta\selected_params.ini"
) else (
    set "PARAM_FILE=%~1"
)

if not exist "%APPLY_DETAIL%" mkdir "%APPLY_DETAIL%" >nul 2>&1
if not exist "%APPLY_DETAIL%" (
    if defined SESSION_LOG >> "%SESSION_LOG%" echo [%DATE% %TIME%] [20_applyimage] ERROR 21: Failed to create apply detail directory "%APPLY_DETAIL%".
    exit /b 21
)

break > "%APPLY_LOG%" 2>nul
if errorlevel 1 (
    if defined SESSION_LOG >> "%SESSION_LOG%" echo [%DATE% %TIME%] [20_applyimage] ERROR 21: Failed to initialize apply log "%APPLY_LOG%".
    exit /b 21
)

call :Log "ApplyImage stage started."
call :Log "Parameter file: %PARAM_FILE%"

call :LoadParams
if errorlevel 1 (
    call :Fail 20 "Failed to load deployment parameters."
    exit /b 20
)

call :ValidateParams
if errorlevel 1 (
    call :Fail 20 "Deployment parameter validation failed."
    exit /b 20
)

call :ValidateTargetDisk
if errorlevel 1 (
    call :Fail 20 "Target disk validation failed. Disk will not be cleaned."
    exit /b 20
)

call :ValidateWimImageIndex
if errorlevel 1 (
    call :Fail 20 "WIM image index validation failed. Disk will not be cleaned."
    exit /b 20
)

call :ValidateDriveLetters
if errorlevel 1 (
    call :Fail 20 "Required drive letters are already in use. Disk will not be cleaned."
    exit /b 20
)

call :GenerateDiskPartScript
if errorlevel 1 (
    call :Fail 21 "Failed to generate DiskPart script."
    exit /b 21
)

call :Log "Running DiskPart against disk %TARGET_DISK%."
>> "%DISKPART_LOG%" echo.
>> "%DISKPART_LOG%" echo ===== DiskPart clean and partition stage =====
diskpart /s "%DISKPART_SCRIPT%" >> "%DISKPART_LOG%" 2>&1
if errorlevel 1 (
    call :Fail 22 "DiskPart failed. See %DISKPART_LOG%."
    exit /b 22
)
call :ScanDiskPartLog
if errorlevel 1 (
    call :Fail 22 "DiskPart log contains error keywords. See %DISKPART_LOG%."
    exit /b 22
)
call :Log "DiskPart completed successfully."

call :Log "Applying image index %IMAGE_INDEX% from %WIM_PATH% to W:\."
>> "%APPLY_LOG%" echo.
>> "%APPLY_LOG%" echo Running DISM apply image.
dism /Apply-Image /ImageFile:"%WIM_PATH%" /Index:%IMAGE_INDEX% /ApplyDir:W:\ >> "%APPLY_LOG%" 2>&1
if errorlevel 1 (
    call :Fail 23 "DISM apply image failed."
    exit /b 23
)
call :VerifyDismResult
if errorlevel 1 (
    call :Fail 23 "DISM returned success but applied Windows files are incomplete."
    exit /b 23
)
call :Log "DISM apply image completed successfully."

call :Log "Creating UEFI boot files."
>> "%APPLY_LOG%" echo.
>> "%APPLY_LOG%" echo Running BCDBoot.
bcdboot W:\Windows /s S: /f UEFI >> "%APPLY_LOG%" 2>&1
if errorlevel 1 (
    call :Fail 24 "BCDBoot failed."
    exit /b 24
)
call :VerifyBcdBootResult
if errorlevel 1 (
    call :Fail 24 "BCDBoot returned success but UEFI boot files are incomplete."
    exit /b 24
)
call :Log "BCDBoot completed successfully."

call :Log "ApplyImage stage completed successfully."
exit /b 0

:LoadParams
if not exist "%PARAM_FILE%" (
    call :Log "ERROR: Parameter file does not exist: %PARAM_FILE%"
    exit /b 1
)

find "!" "%PARAM_FILE%" >nul 2>&1
if not errorlevel 1 (
    call :Log "ERROR: Parameter file contains invalid exclamation mark."
    exit /b 1
)

find "^^" "%PARAM_FILE%" >nul 2>&1
if not errorlevel 1 (
    call :Log "ERROR: Parameter file contains invalid caret."
    exit /b 1
)

set "WIM_PATH="
set "TARGET_DISK="
set "RECOVERY_SIZE_MB="
set "IMAGE_INDEX="

for /f "usebackq tokens=1* delims==" %%A in ("%PARAM_FILE%") do (
    set "INI_KEY=%%~A"
    set "INI_VALUE=%%~B"
    call :NormalizeIniKey
    call :NormalizeIniValue
    if /i "!INI_KEY!"=="WIM_PATH" set "WIM_PATH=!INI_VALUE!"
    if /i "!INI_KEY!"=="TARGET_DISK" set "TARGET_DISK=!INI_VALUE!"
    if /i "!INI_KEY!"=="RECOVERY_SIZE_MB" set "RECOVERY_SIZE_MB=!INI_VALUE!"
    if /i "!INI_KEY!"=="IMAGE_INDEX" set "IMAGE_INDEX=!INI_VALUE!"
)

if not defined IMAGE_INDEX set "IMAGE_INDEX=1"
exit /b 0

:ValidateParams
set "VALIDATION_FAILED=0"

if not defined WIM_PATH (
    call :Log "ERROR: WIM_PATH is missing."
    set "VALIDATION_FAILED=1"
) else (
    set "CHECK_VALUE=!WIM_PATH!"
    call :ContainsBadChars
    if errorlevel 1 (
        call :Log "ERROR: WIM_PATH contains invalid characters."
        set "VALIDATION_FAILED=1"
    ) else if not exist "!WIM_PATH!" (
        call :Log "ERROR: WIM_PATH does not exist: !WIM_PATH!"
        set "VALIDATION_FAILED=1"
    )
)

if not defined TARGET_DISK (
    call :Log "ERROR: TARGET_DISK is missing."
    set "VALIDATION_FAILED=1"
) else (
    set "CHECK_VALUE=!TARGET_DISK!"
    call :ContainsBadChars
    if errorlevel 1 (
        call :Log "ERROR: TARGET_DISK contains invalid characters."
        set "VALIDATION_FAILED=1"
    ) else (
        set "NUMBER_VALUE=!TARGET_DISK!"
        call :IsNumberValue
        if errorlevel 1 (
            call :Log "ERROR: TARGET_DISK must be numeric."
            set "VALIDATION_FAILED=1"
        )
    )
)

if not defined RECOVERY_SIZE_MB (
    call :Log "ERROR: RECOVERY_SIZE_MB is missing."
    set "VALIDATION_FAILED=1"
) else (
    set "CHECK_VALUE=!RECOVERY_SIZE_MB!"
    call :ContainsBadChars
    if errorlevel 1 (
        call :Log "ERROR: RECOVERY_SIZE_MB contains invalid characters."
        set "VALIDATION_FAILED=1"
    ) else (
        set "NUMBER_VALUE=!RECOVERY_SIZE_MB!"
        call :IsNumberValue
        if errorlevel 1 (
            call :Log "ERROR: RECOVERY_SIZE_MB must be numeric."
            set "VALIDATION_FAILED=1"
        ) else if !RECOVERY_SIZE_MB! LSS 1536 (
            call :Log "ERROR: RECOVERY_SIZE_MB must be at least 1536."
            set "VALIDATION_FAILED=1"
        )
    )
)

if not defined IMAGE_INDEX (
    set "IMAGE_INDEX=1"
) else (
    set "CHECK_VALUE=!IMAGE_INDEX!"
    call :ContainsBadChars
    if errorlevel 1 (
        call :Log "ERROR: IMAGE_INDEX contains invalid characters."
        set "VALIDATION_FAILED=1"
    ) else (
        set "NUMBER_VALUE=!IMAGE_INDEX!"
        call :IsNumberValue
        if errorlevel 1 (
            call :Log "ERROR: IMAGE_INDEX must be numeric."
            set "VALIDATION_FAILED=1"
        )
    )
)

if "%VALIDATION_FAILED%"=="1" exit /b 1
call :Log "Validated parameters: WIM_PATH=!WIM_PATH!, TARGET_DISK=!TARGET_DISK!, RECOVERY_SIZE_MB=!RECOVERY_SIZE_MB!, IMAGE_INDEX=!IMAGE_INDEX!"
exit /b 0

:ValidateTargetDisk
call :Log "Validating target disk %TARGET_DISK% before clean."
(
    echo ===== DiskPart target disk precheck =====
    echo Selected disk: %TARGET_DISK%
) > "%DISKPART_LOG%"

(
    echo list disk
    echo select disk %TARGET_DISK%
    echo detail disk
) > "%DISKPART_PRECHECK_SCRIPT%"

if errorlevel 1 (
    call :Log "ERROR: Failed to generate DiskPart precheck script."
    exit /b 1
)

diskpart /s "%DISKPART_PRECHECK_SCRIPT%" >> "%DISKPART_LOG%" 2>&1
if errorlevel 1 (
    call :Log "ERROR: DiskPart could not select target disk %TARGET_DISK%."
    exit /b 1
)
call :ScanDiskPartLog
if errorlevel 1 (
    call :Log "ERROR: DiskPart precheck log contains error keywords. Disk will not be cleaned."
    exit /b 1
)
call :Log "DiskPart precheck log keyword scan passed."

where wmic >nul 2>&1
if errorlevel 1 (
    call :Log "WMIC is not available; target disk existence was validated with DiskPart only."
    call :Log "Target disk precheck passed."
    exit /b 0
)

set "TARGET_DISK_WMI_FOUND=0"
set "TARGET_DISK_WMI_EXCLUDED=0"
set "TARGET_DISK_WMI_EXCLUDE_REASON="
for /f "tokens=1* delims==" %%A in ('wmic diskdrive where "Index=%TARGET_DISK%" get InterfaceType^,MediaType^,Model^,PNPDeviceID^,Size /value 2^>nul') do (
    set "WMI_KEY=%%~A"
    set "WMI_VALUE=%%~B"
    if defined WMI_KEY (
        set "TARGET_DISK_WMI_FOUND=1"
        >> "%DISKPART_LOG%" echo WMI !WMI_KEY!=!WMI_VALUE!
        if /i "!WMI_KEY!"=="InterfaceType" (
            set "CHECK_VALUE=!WMI_VALUE!"
            call :IsExcludedInterfaceType
            if errorlevel 1 (
                set "TARGET_DISK_WMI_EXCLUDED=1"
                set "TARGET_DISK_WMI_EXCLUDE_REASON=InterfaceType=!WMI_VALUE!"
            )
        )
        if /i "!WMI_KEY!"=="MediaType" (
            set "MEDIA_CHECK=!WMI_VALUE!"
            if /i not "!MEDIA_CHECK:Removable=!"=="!MEDIA_CHECK!" (
                set "TARGET_DISK_WMI_EXCLUDED=1"
                set "TARGET_DISK_WMI_EXCLUDE_REASON=MediaType=!WMI_VALUE!"
            )
        )
        if /i "!WMI_KEY!"=="PNPDeviceID" (
            set "PNP_CHECK=!WMI_VALUE!"
            if not "!PNP_CHECK:USBSTOR=!"=="!PNP_CHECK!" (
                set "TARGET_DISK_WMI_EXCLUDED=1"
                set "TARGET_DISK_WMI_EXCLUDE_REASON=PNPDeviceID contains USBSTOR"
            )
            if not "!PNP_CHECK:USB\=!"=="!PNP_CHECK!" (
                set "TARGET_DISK_WMI_EXCLUDED=1"
                set "TARGET_DISK_WMI_EXCLUDE_REASON=PNPDeviceID contains USB\"
            )
        )
        if /i "!WMI_KEY!"=="Model" (
            set "MODEL_CHECK=!WMI_VALUE!"
            if /i not "!MODEL_CHECK:USB =!"=="!MODEL_CHECK!" (
                set "TARGET_DISK_WMI_EXCLUDED=1"
                set "TARGET_DISK_WMI_EXCLUDE_REASON=Model indicates USB/removable media: !WMI_VALUE!"
            )
            if /i not "!MODEL_CHECK:CARD READER=!"=="!MODEL_CHECK!" (
                set "TARGET_DISK_WMI_EXCLUDED=1"
                set "TARGET_DISK_WMI_EXCLUDE_REASON=Model indicates card reader: !WMI_VALUE!"
            )
        )
    )
)

if not "%TARGET_DISK_WMI_FOUND%"=="1" (
    call :Log "ERROR: WMIC could not find disk index %TARGET_DISK%."
    exit /b 1
)

if "%TARGET_DISK_WMI_EXCLUDED%"=="1" (
    call :Log "ERROR: Target disk %TARGET_DISK% is excluded by WMIC precheck: %TARGET_DISK_WMI_EXCLUDE_REASON%."
    exit /b 1
)

call :Log "Target disk precheck passed."
exit /b 0

:ValidateWimImageIndex
call :Log "Validating WIM image index %IMAGE_INDEX% before clean."
>> "%APPLY_LOG%" echo.
>> "%APPLY_LOG%" echo Running DISM WIM index validation.
dism /Get-WimInfo /WimFile:"%WIM_PATH%" /Index:%IMAGE_INDEX% >> "%APPLY_LOG%" 2>&1
if errorlevel 1 (
    call :Log "ERROR: WIM image index %IMAGE_INDEX% is not valid for %WIM_PATH%."
    exit /b 1
)
call :Log "WIM image index precheck passed."
exit /b 0

:ValidateDriveLetters
call :Log "Checking S:, W:, and R: drive letter availability before clean."
set "DRIVE_LETTER_FAILED=0"
if exist S:\NUL (
    call :Log "ERROR: S: is already in use."
    set "DRIVE_LETTER_FAILED=1"
)
if exist W:\NUL (
    call :Log "ERROR: W: is already in use."
    set "DRIVE_LETTER_FAILED=1"
)
if exist R:\NUL (
    call :Log "ERROR: R: is already in use."
    set "DRIVE_LETTER_FAILED=1"
)
if "%DRIVE_LETTER_FAILED%"=="1" exit /b 1
call :Log "Drive letter precheck passed."
exit /b 0

:NormalizeIniKey
:NormalizeIniKeyLeft
if "!INI_KEY:~0,1!"==" " (
    set "INI_KEY=!INI_KEY:~1!"
    goto :NormalizeIniKeyLeft
)
:NormalizeIniKeyRight
if "!INI_KEY:~-1!"==" " (
    set "INI_KEY=!INI_KEY:~0,-1!"
    goto :NormalizeIniKeyRight
)
exit /b 0

:NormalizeIniValue
:NormalizeIniValueLeft
if "!INI_VALUE:~0,1!"==" " (
    set "INI_VALUE=!INI_VALUE:~1!"
    goto :NormalizeIniValueLeft
)
:NormalizeIniValueRight
if "!INI_VALUE:~-1!"==" " (
    set "INI_VALUE=!INI_VALUE:~0,-1!"
    goto :NormalizeIniValueRight
)
exit /b 0

:ContainsQuote
set "CHECK_REMAINDER=!CHECK_VALUE:"=!"
if not "!CHECK_REMAINDER!"=="!CHECK_VALUE!" exit /b 1
exit /b 0

:ContainsBadChars
set "CHECK_REMAINDER=!CHECK_VALUE:"=!"
if not "!CHECK_REMAINDER!"=="!CHECK_VALUE!" exit /b 1
set "CHECK_REMAINDER=!CHECK_VALUE:&=!"
if not "!CHECK_REMAINDER!"=="!CHECK_VALUE!" exit /b 1
set "CHECK_REMAINDER=!CHECK_VALUE:%BAD_PIPE%=!"
if not "!CHECK_REMAINDER!"=="!CHECK_VALUE!" exit /b 1
set "CHECK_REMAINDER=!CHECK_VALUE:<=!"
if not "!CHECK_REMAINDER!"=="!CHECK_VALUE!" exit /b 1
set "CHECK_REMAINDER=!CHECK_VALUE:>=!"
if not "!CHECK_REMAINDER!"=="!CHECK_VALUE!" exit /b 1
set "CHECK_REMAINDER=!CHECK_VALUE:(=!"
if not "!CHECK_REMAINDER!"=="!CHECK_VALUE!" exit /b 1
set "CHECK_REMAINDER=!CHECK_VALUE:)=!"
if not "!CHECK_REMAINDER!"=="!CHECK_VALUE!" exit /b 1
set "CHECK_REMAINDER=!CHECK_VALUE:^^=!"
if not "!CHECK_REMAINDER!"=="!CHECK_VALUE!" exit /b 1
exit /b 0

:IsNumberValue
if not defined NUMBER_VALUE exit /b 1
set "NUMBER_REMAINDER=!NUMBER_VALUE!"
set "NUMBER_REMAINDER=!NUMBER_REMAINDER:0=!"
set "NUMBER_REMAINDER=!NUMBER_REMAINDER:1=!"
set "NUMBER_REMAINDER=!NUMBER_REMAINDER:2=!"
set "NUMBER_REMAINDER=!NUMBER_REMAINDER:3=!"
set "NUMBER_REMAINDER=!NUMBER_REMAINDER:4=!"
set "NUMBER_REMAINDER=!NUMBER_REMAINDER:5=!"
set "NUMBER_REMAINDER=!NUMBER_REMAINDER:6=!"
set "NUMBER_REMAINDER=!NUMBER_REMAINDER:7=!"
set "NUMBER_REMAINDER=!NUMBER_REMAINDER:8=!"
set "NUMBER_REMAINDER=!NUMBER_REMAINDER:9=!"
if defined NUMBER_REMAINDER exit /b 1
exit /b 0

:IsExcludedInterfaceType
if not defined CHECK_VALUE exit /b 0
if /i "!CHECK_VALUE!"=="USB" exit /b 1
if /i "!CHECK_VALUE!"=="SD" exit /b 1
if /i "!CHECK_VALUE!"=="MMC" exit /b 1
if /i "!CHECK_VALUE!"=="IEEE1394" exit /b 1
if /i "!CHECK_VALUE!"=="1394" exit /b 1
exit /b 0

:ScanDiskPartLog
if not exist "%DISKPART_LOG%" (
    call :Log "ERROR: DiskPart log does not exist: %DISKPART_LOG%"
    exit /b 1
)

findstr /i /c:"error" /c:"failed" /c:"failure" /c:"cannot" /c:"unable" /c:"not selected" /c:"no disk" /c:"错误" /c:"失败" "%DISKPART_LOG%" >nul 2>&1
if not errorlevel 1 (
    call :Log "ERROR: DiskPart log contains an error keyword."
    >> "%APPLY_LOG%" echo.
    >> "%APPLY_LOG%" echo DiskPart error keyword matches:
    findstr /i /c:"error" /c:"failed" /c:"failure" /c:"cannot" /c:"unable" /c:"not selected" /c:"no disk" /c:"错误" /c:"失败" "%DISKPART_LOG%" >> "%APPLY_LOG%" 2>&1
    exit /b 1
)

call :Log "DiskPart log keyword scan passed."
exit /b 0

:VerifyDismResult
call :Log "Verifying applied Windows image files."
if not exist W:\Windows\System32\Config\SYSTEM (
    call :Log "ERROR: Missing W:\Windows\System32\Config\SYSTEM after DISM."
    exit /b 1
)
if not exist W:\Windows\System32\winload.efi (
    call :Log "ERROR: Missing W:\Windows\System32\winload.efi after DISM."
    exit /b 1
)
if not exist W:\Windows\explorer.exe (
    call :Log "ERROR: Missing W:\Windows\explorer.exe after DISM."
    exit /b 1
)
call :Log "DISM result existence check passed."
exit /b 0

:VerifyBcdBootResult
call :Log "Verifying UEFI boot files on S:."
if not exist S:\EFI\Microsoft\Boot\BCD (
    call :Log "ERROR: Missing S:\EFI\Microsoft\Boot\BCD after BCDBoot."
    exit /b 1
)
if not exist S:\EFI\Microsoft\Boot\bootmgfw.efi (
    call :Log "ERROR: Missing S:\EFI\Microsoft\Boot\bootmgfw.efi after BCDBoot."
    exit /b 1
)
call :Log "BCDBoot result existence check passed."
exit /b 0

:GenerateDiskPartScript
(
    echo select disk %TARGET_DISK%
    echo clean
    echo convert gpt
    echo create partition efi size=300
    echo format quick fs=fat32 label="System"
    echo assign letter=S
    echo create partition msr size=16
    echo create partition primary
    echo shrink desired=%RECOVERY_SIZE_MB%
    echo format quick fs=ntfs label="Windows"
    echo assign letter=W
    echo create partition primary
    echo format quick fs=ntfs label="Recovery"
    echo assign letter=R
    echo set id="de94bba4-06d1-4d40-a16a-bfd50179d6ac"
    echo gpt attributes=0x8000000000000001
    echo list volume
) > "%DISKPART_SCRIPT%"

if errorlevel 1 exit /b 1
if not exist "%DISKPART_SCRIPT%" exit /b 1

call :Log "Generated DiskPart script: %DISKPART_SCRIPT%"
exit /b 0

:Fail
set "FAIL_CODE=%~1"
set "FAIL_MESSAGE=%~2"
if not defined FAIL_MESSAGE set "FAIL_MESSAGE=ApplyImage failed."
call :Log "ERROR %FAIL_CODE%: %FAIL_MESSAGE%"
exit /b %FAIL_CODE%

:Log
set "LOG_MESSAGE=%~1"
if defined APPLY_LOG >> "%APPLY_LOG%" echo [%DATE% %TIME%] %LOG_MESSAGE%
if defined SESSION_LOG >> "%SESSION_LOG%" echo [%DATE% %TIME%] [20_applyimage] %LOG_MESSAGE%
exit /b 0
