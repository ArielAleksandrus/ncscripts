@echo off
setlocal
rem Troca a versao do NCommerce pelo terminal. Quem troca e o servico guard.
rem   rollback.bat            volta para a versao boa anterior
rem   rollback.bat lista      mostra as versoes guardadas
rem   rollback.bat ^<versao^>   troca para essa versao
rem A tela tambem troca: Configuracoes ^> Empresa ^> Versoes.
set "DOCKER=C:\Program Files\Docker\Docker\resources\bin\docker.exe"
cd /d "%~dp0"
"%DOCKER%" compose exec -T guard sh /ncommerce/guard.sh lista
if errorlevel 1 (
  echo O servico guard nao esta rodando. Abra o Docker Desktop e tente de novo.
  goto end
)
if /I "%~1"=="lista" goto end
echo.
if "%~1"=="" (set "ALVO=a versao boa anterior") else (set "ALVO=%~1")
set "OK="
set /p "OK=Trocar para %ALVO%? O sistema fica fora do ar por cerca de um minuto. [s/N] "
if /I not "%OK%"=="s" (
  echo Nada mudou.
  goto end
)
"%DOCKER%" compose exec -T guard sh /ncommerce/guard.sh trocar "%~1" terminal
:end
pause
