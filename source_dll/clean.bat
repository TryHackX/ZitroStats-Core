@echo off
rem Removes compiler output and test builds (build\). The library in the script folder stays.
cd /d "%~dp0"
if exist build rmdir /s /q build
echo Removed build\
