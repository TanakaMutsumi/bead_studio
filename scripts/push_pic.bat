@echo off
rem ============================================================
rem  push_pic.bat - 把电脑图片导入安卓模拟器（注册进媒体库）
rem  用法1：把图片文件直接拖到本脚本图标上
rem  用法2：命令行  push_pic.bat C:\path\to\image.jpg
rem ============================================================
setlocal EnableDelayedExpansion
set ADB=D:\Android\Sdk\platform-tools\adb.exe

if "%~1"=="" (
  echo [Usage] Drag an image file onto this script, or:
  echo         push_pic.bat C:\path\to\image.jpg
  pause
  exit /b 1
)

set "SRC=%~f1"
set "NAME=%~nx1"
set "EXT=%~x1"
set "MIME=image/jpeg"
if /I "%EXT%"==".png" set "MIME=image/png"
if /I "%EXT%"==".webp" set "MIME=image/webp"
if /I "%EXT%"==".bmp" set "MIME=image/bmp"
if /I "%EXT%"==".gif" set "MIME=image/gif"

echo [1/3] Checking emulator ...
%ADB% get-state >nul 2>&1
if errorlevel 1 (
  echo   Emulator not running. Start it first ^(emulator -avd bead_test^).
  pause
  exit /b 1
)

echo [2/3] Pushing %NAME% ...
%ADB% push "%SRC%" "/sdcard/Pictures/%NAME%"
if errorlevel 1 (
  echo   Push failed.
  pause
  exit /b 1
)

echo [3/3] Registering in media library ...
FOR /F %%n IN ('%ADB% shell content query --uri content://media/external/images/media --projection _display_name ^| find /C "Row:"') DO SET BEFORE=%%n
%ADB% shell content insert --uri content://media/external/images/media --bind "_data:s:/sdcard/Pictures/%NAME%" --bind "mime_type:s:%MIME%" --bind "_display_name:s:%NAME%" >nul 2>&1
FOR /F %%n IN ('%ADB% shell content query --uri content://media/external/images/media --projection _display_name ^| find /C "Row:"') DO SET AFTER=%%n

if "%AFTER%"=="%BEFORE%" (
  echo   OK - already in media library, no duplicate. Total images: %AFTER%
) else (
  echo   OK - added to media library. Total images: %AFTER%
)
echo Done. Open the app and pick it from gallery.
pause
exit /b 0
