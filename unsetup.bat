@echo off
title APIKOmicReader setup
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\setup.ps1" %*
echo.
pause
