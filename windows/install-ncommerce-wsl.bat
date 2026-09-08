@echo off
:: Double-click entry point. Elevates and runs the PowerShell bootstrap
:: that installs WSL2 + Ubuntu for the NCommerce API.

net session >nul 2>&1
if %errorLevel% neq 0 (
    echo Requesting administrator privileges...
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-ncommerce-wsl.ps1"
pause
