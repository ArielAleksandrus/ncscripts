# PowerShell 7 no Linux para testar a logica dos scripts do Windows com
# comandos de mentira (docker, curl.exe). O que depende do Windows de verdade
# (WSL, Docker Desktop, tarefas agendadas, registro) nao roda aqui.
FROM mcr.microsoft.com/powershell:7.4-ubuntu-22.04
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends zip unzip python3 curl ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && ln -s /usr/bin/curl /usr/local/bin/curl.exe
RUN pwsh -NoProfile -Command "Set-PSRepository PSGallery -InstallationPolicy Trusted; \
      Install-Module Pester -RequiredVersion 5.6.1 -Scope AllUsers -Force; \
      Install-Module PSScriptAnalyzer -RequiredVersion 1.23.0 -Scope AllUsers -Force"
ENV LANG=C.UTF-8
