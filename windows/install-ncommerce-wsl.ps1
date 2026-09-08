#Requires -RunAsAdministrator
<#
  NCommerce WSL2 bootstrap.

  Prepares a Windows machine to host the NCommerce API inside WSL2/Ubuntu.
  Does NOT reimplement your Linux setup: once Ubuntu is ready, it hands off
  to a normal WSL shell where you run instalador_unico.sh exactly as you
  would on real hardware. This script only handles the Windows-specific
  parts: virtualization prerequisites, installing the distro, enabling
  systemd (for cron), and registering the startup task that keeps the
  server reachable after a reboot.

  Re-run safe: skips steps that are already done, same spirit as the
  resumable instalador_unico.sh.
#>

$ErrorActionPreference = "Stop"
$Distro = "Ubuntu-24.04"

function Fail($msg) {
    Write-Host ""
    Write-Host "ERROR: $msg" -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit 1
}

Write-Host "=== NCommerce WSL2 bootstrap ===" -ForegroundColor Cyan

# 1. Windows version check --------------------------------------------------
$build = [System.Environment]::OSVersion.Version.Build
if ($build -lt 19041) {
    Fail "Windows build $build is too old for WSL2 (need build 19041+, i.e. Windows 10 version 2004 or newer). Update Windows first."
}

# 2. Virtualization firmware check ------------------------------------------
Write-Host "Checking virtualization support in firmware..."
$info = Get-ComputerInfo -Property "HyperV*"
if (-not $info.HyperVRequirementVirtualizationFirmwareEnabled) {
    Fail @"
Virtualization (VT-x / AMD-V) is disabled or unavailable in this PC's BIOS/UEFI.
WSL2 cannot run without it, and there is no software workaround - it has to be
turned on in the firmware setup screen (often under CPU / Advanced / Virtualization),
or this specific machine cannot host the NCommerce server. If it's not available
after checking the BIOS, use a different PC (or a dedicated Ubuntu box) as the server.
"@
}

# 3. Enable required Windows features ----------------------------------------
Write-Host "Enabling WSL and Virtual Machine Platform..."
$features = @("Microsoft-Windows-Subsystem-Linux", "VirtualMachinePlatform")
$rebootNeeded = $false
foreach ($f in $features) {
    $state = (Get-WindowsOptionalFeature -Online -FeatureName $f).State
    if ($state -ne "Enabled") {
        $result = Enable-WindowsOptionalFeature -Online -FeatureName $f -All -NoRestart
        if ($result.RestartNeeded) { $rebootNeeded = $true }
    }
}

if ($rebootNeeded) {
    Write-Host ""
    Write-Host "Windows needs to restart to finish enabling WSL2." -ForegroundColor Yellow
    Write-Host "After the restart, double-click install-ncommerce-wsl.bat again to continue." -ForegroundColor Yellow
    Read-Host "Press Enter to restart now (or close this window to restart later)"
    Restart-Computer
    exit
}

# 4. Set WSL2 as default, install Ubuntu -------------------------------------
wsl --set-default-version 2 | Out-Null

$installedRaw = (wsl -l -q) 2>$null
$installed = $installedRaw | ForEach-Object { $_ -replace "`0", "" } | Where-Object { $_ -ne "" }

if ($installed -notcontains $Distro) {
    Write-Host "Installing $Distro (this downloads ~500MB)..."
    wsl --install -d $Distro
    Write-Host ""
    Write-Host "A console window will open to finish installing $Distro." -ForegroundColor Yellow
    Write-Host "It will ask you to create a UNIX username and password - this is your" -ForegroundColor Yellow
    Write-Host "Linux login, separate from Windows. Same as setting up a fresh Ubuntu box." -ForegroundColor Yellow
    Read-Host "Press Enter once you've created the Ubuntu user and see a shell prompt"
} else {
    Write-Host "$Distro is already installed."
}

# 5. Enable systemd inside the distro (needed for cron, services, etc.) -----
Write-Host "Enabling systemd inside $Distro..."
wsl -d $Distro -u root -- bash -c "printf '[boot]\nsystemd=true\n' > /etc/wsl.conf"
wsl --shutdown
Start-Sleep -Seconds 3

# 6. Register the startup task that keeps WSL alive + LAN reachable ---------
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$startupBat = Join-Path $scriptDir "ncommerce-wsl-startup.bat"

if (Test-Path $startupBat) {
    Write-Host "Registering the logon task that starts $Distro and forwards LAN ports..."
    schtasks /create /tn "NCommerce WSL Startup" /tr "`"$startupBat`"" /sc onlogon /rl highest /f | Out-Null
    Write-Host ""
    Write-Host "NOTE: this task fires when a user logs into Windows. For a server that" -ForegroundColor Yellow
    Write-Host "should come up unattended after a power loss/reboot, enable Windows" -ForegroundColor Yellow
    Write-Host "auto-logon for this machine's account (netplwiz -> uncheck 'require" -ForegroundColor Yellow
    Write-Host "password'). Scheduling it as SYSTEM instead is deliberately avoided here:" -ForegroundColor Yellow
    Write-Host "WSL distro registrations are per-user, and SYSTEM does not see them." -ForegroundColor Yellow
} else {
    Write-Host "ncommerce-wsl-startup.bat not found next to this script - skipping task registration." -ForegroundColor Yellow
}

# Run it once now too, so the machine is in its final state immediately.
& $startupBat

# 7. Hand off to the real installer, inside Ubuntu, unmodified --------------
Write-Host ""
Write-Host "=== WSL2/Ubuntu is ready. Opening a shell to run the NCommerce installer. ===" -ForegroundColor Cyan
Write-Host "Inside the shell that opens, run the same steps as on real hardware, e.g.:"
Write-Host "  curl -LO https://github.com/ArielAleksandrus/ncscripts/archive/refs/heads/master.zip"
Write-Host "  unzip master.zip && cd ncscripts-master"
Write-Host "  ./instalador_unico.sh"
Write-Host ""
wsl -d $Distro
