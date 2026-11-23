@echo off
:: Duplo clique. Pede administrador e roda a troca do tipo da loja (windows\trocar_tipo_windows.ps1).
:: APAGA TODO O BANCO DA LOJA (depois de uma copia de seguranca conferida) e recria a loja
:: como restaurante, comercio em geral ou industria. Opcoes vao para o script, ex.:
::   TrocarTipoWindows.bat -Simular            so mostra o que seria feito (nao muda nada)
::   TrocarTipoWindows.bat -Tipo comercio      nao pergunta o tipo
::   TrocarTipoWindows.bat -PastaBackup E:\    copia num pen drive

net session >/dev/null 2>&1
if %errorLevel% neq 0 (
    echo Pedindo privilegio de administrador...
    if "%~1"=="" (
        powershell -Command "Start-Process '%~f0' -Verb RunAs"
    ) else (
        powershell -Command "Start-Process '%~f0' -ArgumentList '%*' -Verb RunAs"
    )
    exit /b
)

cd /d "%~dp0.."
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\windows\trocar_tipo_windows.ps1" %*
pause
