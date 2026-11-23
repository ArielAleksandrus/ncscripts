@echo off
setlocal EnableExtensions EnableDelayedExpansion
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
if not exist "%DIR%\control" mkdir "%DIR%\control"
rem R18: troca de tipo pela metade (o TrocarTipoWindows.bat deixa control\pausa enquanto
rem roda). Subir a loja inteira agora a ligaria sobre um banco incompleto: so o banco
rem (mysql e redis) sobe, para a troca poder continuar, e a janela diz o que fazer.
if exist "%DIR%\control\pausa" (
  echo.
  echo ATENCAO: ha uma troca do tipo da loja em andamento ^(ou interrompida^).
  echo A loja NAO foi ligada: so o banco de dados, para a troca poder continuar.
  echo Rode de novo o TrocarTipoWindows.bat para terminar a troca, ou chame o suporte.
  echo.
  "%DOCKER%" compose up -d mysql redis
  pause
  exit /b 0
)
if /I "%~1"=="pull" goto pull
rem Atualizacao que parou no meio (janela fechada, queda de energia): o
rem ncommerce-update.ps1 desfaz o download pela metade antes de ligar, para a
rem loja nao subir com api de uma versao e web de outra. Codigo 2: uma
rem atualizacao esta rodando agora, e ela mesma liga a loja.
if exist "%DIR%\ncommerce-update.ps1" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%DIR%\ncommerce-update.ps1" -Recuperar
  if errorlevel 2 (
    echo Uma atualizacao do NCommerce esta rodando em outra janela. Ela liga o sistema quando terminar.
    exit /b 0
  )
)
if exist "%DIR%\refresh-host-ips.ps1" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%DIR%\refresh-host-ips.ps1" "%DIR%"
)
if exist "%DIR%\anydesk-id.ps1" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%DIR%\anydesk-id.ps1" "%DIR%"
)
echo Ligando os programas do NCommerce...
"%DOCKER%" compose up -d
exit /b %ERRORLEVEL%

:pull
rem "pull" vem do atalho Atualizar NCommerce antigo. A atualizacao de verdade e o
rem ncommerce-update.ps1. Tudo num bloco so: o cmd le o bloco inteiro antes de
rem rodar, e o update-host.ps1 pode trocar este arquivo no meio.
(
  if not exist "%DIR%\ncommerce-update.ps1" if exist "%DIR%\update-host.ps1" powershell -NoProfile -ExecutionPolicy Bypass -File "%DIR%\update-host.ps1" "%DIR%"
  if exist "%DIR%\ncommerce-update.ps1" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%DIR%\ncommerce-update.ps1" -SemScripts
    exit /b !ERRORLEVEL!
  )
  rem Sem o ncommerce-update.ps1 (pacote antigo): o jeito antigo.
  powershell -NoProfile -Command "$f='%DIR%\.env'; $t=[IO.File]::ReadAllText($f) -replace '(?m)^NCOMMERCE_TAG=keep-[^\r\n]*','NCOMMERCE_TAG=latest'; [IO.File]::WriteAllText($f,$t)"
  if exist "%DIR%\migrate-endpoints.ps1" powershell -NoProfile -ExecutionPolicy Bypass -File "%DIR%\migrate-endpoints.ps1" "%DIR%"
  "%DOCKER%" compose pull
  if errorlevel 1 exit /b 1
  "%DOCKER%" compose up -d
  exit /b !ERRORLEVEL!
)
