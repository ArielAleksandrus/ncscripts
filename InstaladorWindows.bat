@echo off
:: Duplo clique. Pede admin e roda o instalador Docker.
:: Opcoes vao para o instalador, ex.: InstaladorWindows.bat -IgnorarRequisitos

net session >nul 2>&1
if %errorLevel% neq 0 (
    echo Pedindo privilegio de administrador...
    if "%~1"=="" (
        powershell -Command "Start-Process '%~f0' -Verb RunAs"
    ) else (
        powershell -Command "Start-Process '%~f0' -ArgumentList '%*' -Verb RunAs"
    )
    exit /b
)

cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0windows\instalador_windows.ps1" %*
pause
