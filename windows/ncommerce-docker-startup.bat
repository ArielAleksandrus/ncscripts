@echo off
setlocal EnableExtensions
rem Sobe o Docker Desktop, se precisar, e religa a stack. Sem pull.
rem A tarefa "NCommerce Docker Startup" chama este arquivo no logon.
rem A janela fica aberta enquanto o Docker sobe. O aviso sai antes dessa espera.

title NCommerce
echo.
powershell -NoProfile -Command "Write-Host ('INICIANDO O SISTEMA NCOMMERCE. N' + [char]0xC3 + 'O FECHE ESSA JANELA...') -ForegroundColor Yellow"
echo Ligando o Docker, o AnyDesk e os programas. Pode levar alguns minutos.
echo.

set "DOCKER=C:\Program Files\Docker\Docker\resources\bin\docker.exe"
set "DESKTOP=C:\Program Files\Docker\Docker\Docker Desktop.exe"
set "DIR=C:\NCommerce"

if not exist "%DOCKER%" (
  echo Docker Desktop nao encontrado.
  exit /b 1
)

"%DOCKER%" info >nul 2>&1
if not errorlevel 1 goto ready

if exist "%DESKTOP%" start "" "%DESKTOP%"
set /a N=0

echo Aguardando o Docker...
:wait
"%DOCKER%" info >nul 2>&1
if not errorlevel 1 goto ready
set /a N+=1
if %N% GEQ 60 goto notready
set /a MOD=N %% 6
if %MOD%==0 echo Ainda aguardando o Docker...
ping -n 6 127.0.0.1 >nul
goto wait

:notready
echo Docker nao ficou pronto.
exit /b 1

:ready
cd /d "%DIR%"
if exist "%DIR%\refresh-host-ips.ps1" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%DIR%\refresh-host-ips.ps1" "%DIR%"
)
if exist "%DIR%\anydesk-id.ps1" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%DIR%\anydesk-id.ps1" "%DIR%"
)
if not exist "%DIR%\control" mkdir "%DIR%\control"
rem Uma troca de versao (servico guard) deixa NCOMMERCE_TAG=keep-VERSAO no .env.
rem Atualizar volta para a versao publicada. So o pull: no logon a versao trocada fica.
if /I "%~1"=="pull" (
  powershell -NoProfile -Command "$f='%DIR%\.env'; $t=[IO.File]::ReadAllText($f) -replace '(?m)^NCOMMERCE_TAG=keep-[^\r\n]*','NCOMMERCE_TAG=latest'; [IO.File]::WriteAllText($f,$t)"
  rem Endereco novo do registry e do mestre: api e registry.ncommerce.app. So avisa se falhar.
  if exist "%DIR%\migrate-endpoints.ps1" powershell -NoProfile -ExecutionPolicy Bypass -File "%DIR%\migrate-endpoints.ps1" "%DIR%"
  "%DOCKER%" compose pull
  if errorlevel 1 exit /b 1
)
echo Ligando os programas do NCommerce...
"%DOCKER%" compose up -d
exit /b %ERRORLEVEL%
