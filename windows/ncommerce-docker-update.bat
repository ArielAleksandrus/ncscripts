@echo off
rem Baixa a versao publicada no registry e recria o que mudou.
call "%~dp0ncommerce-docker-startup.bat" pull
exit /b %ERRORLEVEL%
