@echo off
:: Runs at Windows logon (via the scheduled task registered by
:: install-ncommerce-wsl.ps1). Makes WSL2 behave like a raw Ubuntu server:
::
::   1. Starts the distro if it isn't already running. Since /etc/wsl.conf
::      has systemd=true, this brings systemd up as PID 1, which in turn
::      starts cron (and anything else enabled via systemctl) exactly like
::      a normal Ubuntu boot - no extra scripting needed for cron itself.
::
::   2. Keeps the distro alive. WSL stops a distro shortly after the last
::      Windows-side wsl.exe process exits, even with nginx/mysql running
::      under systemd, so a hidden "wsl.exe ... sleep infinity" stays
::      attached. Only one is started, even if this runs again.
::
::   3. Makes sure LAN clients (tablets, terminals) can reach the app.
::      - If %UserProfile%\.wslconfig has networkingMode=mirrored (Windows 11
::        22H2+), WSL already shares the host's real network interfaces, so
::        a service bound to 0.0.0.0 inside WSL is already reachable at the
::        host's own LAN IP with no bridging - confirmed by hand on a real
::        machine: ncommerce_api (3000) and ncommerce (4200) were reachable
::        from a phone with zero portproxy rules. The only thing still
::        needed is a firewall allow rule, since Windows normally grants
::        that via an interactive first-run popup that nobody is there to
::        click on an unattended server.
::      - Otherwise (NAT mode / older Windows), fall back to the classic
::        netsh portproxy bridge: WSL2 hands the distro a new internal IP
::        every start, and by default that's only reachable from the
::        Windows host itself, not from other LAN devices.
::
:: Safe to re-run any time (e.g. manually, after `wsl --shutdown`).

setlocal enabledelayedexpansion

set DISTRO=Ubuntu-24.04
set WSL_PORTS=3000 4200

echo Starting %DISTRO%...
wsl.exe -d %DISTRO% -u root -- true

echo Starting the hidden keepalive for %DISTRO%...
powershell -NoProfile -ExecutionPolicy Bypass -Command "$running = Get-CimInstance Win32_Process | Where-Object { $_.Name -eq 'wsl.exe' -and $_.CommandLine -like '*%DISTRO%*sleep infinity*' }; if (-not $running) { Start-Process wsl.exe -ArgumentList '-d %DISTRO% -u root --exec /bin/sleep infinity' -WindowStyle Hidden }"

rem systemd needs a few seconds after first attach before nginx/cron exist
timeout /t 3 /nobreak >nul

set MIRRORED=0
if exist "%UserProfile%\.wslconfig" (
    findstr /i /r /c:"networkingMode[ \t]*=[ \t]*mirrored" "%UserProfile%\.wslconfig" >nul 2>&1
    if not errorlevel 1 set MIRRORED=1
)

if "%MIRRORED%"=="1" (
    echo Mirrored networking detected - no port bridging needed, just opening the firewall.
    for %%p in (%WSL_PORTS%) do (
        rem clean up a stale portproxy rule in case this machine switched from NAT to mirrored mode
        netsh interface portproxy delete v4tov4 listenport=%%p listenaddress=0.0.0.0 >nul 2>&1

        netsh advfirewall firewall delete rule name="NCommerce WSL port %%p" >nul 2>&1
        netsh advfirewall firewall add rule name="NCommerce WSL port %%p" dir=in action=allow protocol=TCP localport=%%p
    )
    echo Done. LAN clients can reach %DISTRO% via this PC's IP on: %WSL_PORTS%
    goto :eof
)

echo NAT networking - bridging via netsh portproxy. Waiting for the WSL IP...
set WSL_IP=
for /l %%n in (1,1,10) do (
    if "!WSL_IP!"=="" (
        for /f "usebackq tokens=1" %%i in (`wsl.exe -d %DISTRO% -- hostname -I`) do set WSL_IP=%%i
        if "!WSL_IP!"=="" timeout /t 1 >nul
    )
)

if "%WSL_IP%"=="" (
    echo Could not determine the IP of %DISTRO%. Is it installed and running?
    exit /b 1
)

echo %DISTRO% is at !WSL_IP! - updating port forwarding for: %WSL_PORTS%

for %%p in (%WSL_PORTS%) do (
    netsh interface portproxy delete v4tov4 listenport=%%p listenaddress=0.0.0.0 >nul 2>&1
    netsh interface portproxy add v4tov4 listenport=%%p listenaddress=0.0.0.0 connectport=%%p connectaddress=!WSL_IP!

    netsh advfirewall firewall delete rule name="NCommerce WSL port %%p" >nul 2>&1
    netsh advfirewall firewall add rule name="NCommerce WSL port %%p" dir=in action=allow protocol=TCP localport=%%p
)

echo Done. LAN clients can reach %DISTRO% via this PC's IP on: %WSL_PORTS%
