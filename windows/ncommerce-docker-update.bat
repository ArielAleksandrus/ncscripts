@echo off
rem Atalho "Atualizar NCommerce": atualiza os scripts deste PC (ncscripts no GitHub),
rem baixa a versao publicada inteira e so entao troca, com volta para a anterior.
rem Quem faz tudo e o ncommerce-update.ps1. Sem ele (pacote antigo), o jeito antigo.
if exist "%~dp0ncommerce-update.ps1" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0ncommerce-update.ps1"
) else (
  if exist "%~dp0update-host.ps1" powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0update-host.ps1" "%~dp0."
  call "%~dp0ncommerce-docker-startup.bat" pull
)
set "RC=%ERRORLEVEL%"
rem A troca deste .bat fica numa linha so: o cmd ja leu a linha inteira antes do move.
if exist "%~dp0ncommerce-docker-update.bat.new" (move /y "%~dp0ncommerce-docker-update.bat.new" "%~f0" >nul & exit /b %RC%)
exit /b %RC%
