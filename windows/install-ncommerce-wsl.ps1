#Requires -RunAsAdministrator
<#
  NCommerce WSL2 bootstrap.

  Prepares a Windows machine to host NCommerce (API + front + NFC-e) inside
  WSL2 Ubuntu 24.04, then copies ncscripts into the distro and opens a shell
  so you can run instalador_unico.sh the same way as on a real Ubuntu PC.

  Re-run safe: skips steps that are already done.
#>

$ErrorActionPreference = "Stop"
$Distro = "Ubuntu-24.04"

function Fail($msg) {
    Write-Host ""
    Write-Host "ERROR: $msg" -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit 1
}

function Get-WslDistroNames {
    # `wsl -l` writes UTF-16 LE. PowerShell often sees extra NULs, so
    # `-notcontains Ubuntu-24.04` is a false negative and the script
    # tries to install the distro again.
    $prev = [Console]::OutputEncoding
    try {
        [Console]::OutputEncoding = [System.Text.Encoding]::Unicode
        $raw = & wsl.exe -l -q 2>$null
    } finally {
        [Console]::OutputEncoding = $prev
    }
    if (-not $raw) { return @() }
    $text = ($raw | Out-String) -replace "`0", ""
    return @(
        $text -split "`r?`n" |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ }
    )
}

function Test-WslWorks {
    try {
        & wsl.exe -l -q 2>$null | Out-Null
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    }
}

# Ensures exactly one networkingMode=mirrored under [wsl2]. Replaces nat (or
# any other value) instead of inserting a second key, which WSL's INI parser
# would treat as undefined.
function Set-WslMirroredNetworking([string]$Path) {
    $modeLine = "networkingMode=mirrored"
    $fresh = @"
[wsl2]
networkingMode=mirrored
firewall=true
localhostForwarding=true
"@

    $raw = $null
    if (Test-Path $Path) {
        $raw = Get-Content $Path -Raw -ErrorAction SilentlyContinue
    }
    if ([string]::IsNullOrWhiteSpace($raw)) {
        Set-Content -Path $Path -Value $fresh -Encoding ASCII
        Write-Host "Created $Path with mirrored networking."
        return
    }

    $lines = New-Object System.Collections.Generic.List[string]
    $inWsl2 = $false
    $sawWsl2 = $false
    $wroteMode = $false
    $changed = $false

    foreach ($line in (Get-Content $Path)) {
        if ($line -match '^\s*\[') {
            if ($inWsl2 -and -not $wroteMode) {
                $lines.Add($modeLine)
                $wroteMode = $true
                $changed = $true
            }
            $inWsl2 = ($line -match '^\s*\[wsl2\]\s*$')
            if ($inWsl2) { $sawWsl2 = $true }
        }

        if ($inWsl2 -and $line -match '^\s*networkingMode\s*=') {
            if ($wroteMode) {
                $changed = $true
                continue
            }
            if ($line -notmatch '^\s*networkingMode\s*=\s*mirrored\s*$') {
                $changed = $true
            }
            $line = $modeLine
            $wroteMode = $true
        }

        $lines.Add($line)
    }

    if ($inWsl2 -and -not $wroteMode) {
        $lines.Add($modeLine)
        $changed = $true
    } elseif (-not $sawWsl2) {
        if ($lines.Count -gt 0 -and $lines[$lines.Count - 1] -ne "") {
            $lines.Add("")
        }
        $lines.Add("[wsl2]")
        $lines.Add($modeLine)
        $changed = $true
    }

    if ($changed) {
        ($lines -join "`r`n").TrimEnd() + "`r`n" | Set-Content -Path $Path -Encoding ASCII -NoNewline
        Write-Host "Updated $Path : $modeLine"
    } else {
        Write-Host "$Path already has mirrored networking."
    }
}

Write-Host "=== NCommerce WSL2 bootstrap ===" -ForegroundColor Cyan

# 1. Windows version check --------------------------------------------------
$build = [System.Environment]::OSVersion.Version.Build
if ($build -lt 19041) {
    Fail "Windows build $build is too old for WSL2 (need build 19041+, i.e. Windows 10 2004 or newer). Update Windows first."
}

# 2. Virtualization firmware check ------------------------------------------
# Get-ComputerInfo returns $null on some PCs even when WSL already runs.
# Only abort when we are sure firmware virt is off AND WSL does not work yet.
Write-Host "Checking virtualization support in firmware..."
$virtEnabled = $null
try {
    $info = Get-ComputerInfo -Property "HyperVRequirementVirtualizationFirmwareEnabled"
    $virtEnabled = $info.HyperVRequirementVirtualizationFirmwareEnabled
} catch {
    $virtEnabled = $null
}

if ($virtEnabled -eq $false -and -not (Test-WslWorks)) {
    Fail @"
Virtualization (VT-x / AMD-V) is disabled or unavailable in this PC's BIOS/UEFI.
WSL2 cannot run without it. Turn it on in firmware (CPU / Advanced / Virtualization),
or use a different PC as the server.
"@
}
if ($null -eq $virtEnabled) {
    Write-Host "Could not read firmware virtualization flag; continuing (WSL will fail later if it is really off)." -ForegroundColor Yellow
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

# 4. Mirrored networking on Windows 11 22H2+ (build 22621+) -----------------
# This is what makes nginx :3000 / :4200 reachable on the LAN at the PC's
# own IP, without netsh portproxy. Confirmed on a real restaurant-style setup.
$wslConfigPath = Join-Path $env:USERPROFILE ".wslconfig"
$mirroredSupported = ($build -ge 22621)
if ($mirroredSupported) {
    Write-Host "Enabling mirrored networking in $wslConfigPath ..."
    Set-WslMirroredNetworking $wslConfigPath
} else {
    Write-Host "Windows build $build has no mirrored networking; LAN access will use netsh portproxy." -ForegroundColor Yellow
}

# 5. Set WSL2 as default, install Ubuntu 24.04 -------------------------------
wsl --set-default-version 2 | Out-Null

$installed = Get-WslDistroNames
if ($installed -notcontains $Distro) {
    Write-Host "Installing $Distro (this downloads ~500MB)..."
    wsl --install -d $Distro --no-launch
    if ($LASTEXITCODE -ne 0 -and (Get-WslDistroNames) -notcontains $Distro) {
        wsl --install -d $Distro
    }
    Write-Host ""
    Write-Host "If a console opened, create a UNIX username and password (Linux login," -ForegroundColor Yellow
    Write-Host "separate from Windows), then come back here." -ForegroundColor Yellow
    Read-Host "Press Enter once Ubuntu finished first-run setup (user created)"
} else {
    Write-Host "$Distro is already installed."
}

wsl --set-default $Distro 2>$null

# 6. Enable systemd inside the distro (nginx, cron, mysql on "boot") --------
Write-Host "Enabling systemd inside $Distro..."
wsl -d $Distro -u root -- bash -lc @'
set -e
CONF=/etc/wsl.conf
touch "$CONF"
if grep -q '^\[boot\]' "$CONF"; then
  if grep -q '^systemd=' "$CONF"; then
    sed -i 's/^systemd=.*/systemd=true/' "$CONF"
  else
    sed -i '/^\[boot\]/a systemd=true' "$CONF"
  fi
else
  printf '\n[boot]\nsystemd=true\n' >> "$CONF"
fi
'@
wsl --shutdown
Start-Sleep -Seconds 5

# 7. Register the startup task that keeps WSL alive + LAN reachable ---------
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$startupBat = Join-Path $scriptDir "ncommerce-wsl-startup.bat"

if (Test-Path $startupBat) {
    Write-Host "Registering the logon task that starts $Distro and opens LAN ports..."
    schtasks /create /tn "NCommerce WSL Startup" /tr "`"$startupBat`"" /sc onlogon /rl highest /f | Out-Null
    Write-Host ""
    Write-Host "NOTE: this task fires when a user logs into Windows. For a restaurant PC" -ForegroundColor Yellow
    Write-Host "that should come up after a power cut, enable auto-logon:" -ForegroundColor Yellow
    Write-Host "  netplwiz  -> uncheck 'Users must enter a user name and password'" -ForegroundColor Yellow
    Write-Host "Do not run the task as SYSTEM: WSL distros are per-user." -ForegroundColor Yellow
} else {
    Write-Host "ncommerce-wsl-startup.bat not found next to this script - skipping task registration." -ForegroundColor Yellow
}

if (Test-Path $startupBat) {
    & $startupBat
}

# 8. Copy ncscripts into Ubuntu and open a shell on them ---------------------
$ncscriptsRoot = Split-Path -Parent $scriptDir
$installer = Join-Path $ncscriptsRoot "instalador_unico.sh"
if (Test-Path $installer) {
    Write-Host "Copying ncscripts into $Distro ~/ncscripts ..."
    $winPathForWsl = (wsl -d $Distro -- wslpath -a "$ncscriptsRoot").Trim() -replace "`0", ""
    wsl -d $Distro -- bash -lc "mkdir -p `$HOME/ncscripts && cp -a '$winPathForWsl'/. `$HOME/ncscripts/ && chmod +x `$HOME/ncscripts/*.sh"
} else {
    Write-Host "instalador_unico.sh not next to windows/. You will need to download ncscripts inside Ubuntu." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "=== WSL2 / Ubuntu 24.04 is ready. ===" -ForegroundColor Cyan
Write-Host "Inside the Ubuntu shell, run:"
Write-Host "  cd ~/ncscripts"
Write-Host "  ./instalador_unico.sh"
Write-Host ""
Write-Host "That script still asks for the NCommerce token, Linux user, Bitbucket SSH key"
Write-Host "and Dropbox login - same as a real Ubuntu install. It will NOT reboot Windows."
Write-Host ""
wsl -d $Distro -- bash -lc "cd ~/ncscripts 2>/dev/null; exec bash"
