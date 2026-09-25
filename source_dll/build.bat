@echo off
rem Builds zitrostats_dll.dll for the 32-bit Soldat server on Windows.
rem Compiler output stays in build\win32; only the finished library is copied to the
rem script folder (one level up), which is where main.pas loads it from.
setlocal
cd /d "%~dp0"

set "FPC=fpc"
if exist "C:\FPC\3.2.2\bin\i386-win32\fpc.exe" set "FPC=C:\FPC\3.2.2\bin\i386-win32\fpc.exe"

rem The MySQL mirror is always part of the library and needs nothing else on the server.
rem "build.bat debug" builds with range, overflow and object checks plus line numbers in the crash log;
rem the library is slower and larger, so use it only while hunting a bug.
set "OPTS=-O2 -Xs -XX -CX"
if /i "%~1"=="debug" set "OPTS=-O1 -gl -gw -Cr -Co -Ci -CX"

if not exist build\win32 mkdir build\win32
"%FPC%" -B -Pi386 -Twin32 -Mobjfpc -Sh %OPTS% -FUbuild\win32 -FEbuild\win32 -ozitrostats_dll.dll zs_main.pas
if errorlevel 1 (
  echo Build failed.
  exit /b 1
)

copy /Y build\win32\zitrostats_dll.dll ..\zitrostats_dll.dll >nul
if errorlevel 1 (
  echo Could not replace ..\zitrostats_dll.dll - stop the server if it is running.
  exit /b 1
)
echo Built ..\zitrostats_dll.dll
