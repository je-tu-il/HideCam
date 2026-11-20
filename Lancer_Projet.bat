@echo off
chcp 65001 >nul
cd /d "%~dp0"

set "APP_TITLE=HideCam (StealthRecorder)"
title %APP_TITLE%

echo ========================================================
echo   %APP_TITLE%
echo ========================================================
echo.
echo [*] Projet pret.
exit /b 0
