@echo off
:: Duplo clique. Pede admin e roda o desinstalador Docker (windows\desinstalador_windows.ps1).
:: Opcoes vao para o desinstalador, ex.: DesinstaladorWindows.bat -Simular
::   -Simular     so mostra o que seria feito (nao muda nada, nao pede admin)
::   -SemBackup   apaga sem fazer a copia de seguranca da loja

echo %* | findstr /i /c:"-Simular" >nul
if %errorLevel% equ 0 goto run

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

:run
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0windows\desinstalador_windows.ps1" %*
pause
