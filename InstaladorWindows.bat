@echo off
:: Duplo clique. Pede admin e roda o instalador Docker.

net session >nul 2>&1
if %errorLevel% neq 0 (
    echo Pedindo privilegio de administrador...
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0instalador_docker.ps1"
pause
