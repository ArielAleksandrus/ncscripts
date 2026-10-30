@echo off
setlocal EnableExtensions
rem Sobe o Docker Desktop, se precisar, e religa a stack. Sem pull.
rem A tarefa "NCommerce Docker Startup" chama este arquivo no logon.

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

:wait
"%DOCKER%" info >nul 2>&1
if not errorlevel 1 goto ready
set /a N+=1
if %N% GEQ 60 goto notready
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
if /I "%~1"=="pull" (
  "%DOCKER%" compose pull
  if errorlevel 1 exit /b 1
)
"%DOCKER%" compose up -d
exit /b %ERRORLEVEL%
