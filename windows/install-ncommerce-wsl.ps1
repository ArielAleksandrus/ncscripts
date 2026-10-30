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
# Fixed location for the logon task, so it survives the download folder being deleted.
$InstallDir = "C:\NCommerce\wsl"
$WslPorts = @(3000, 4200)
# Hyper-V firewall VM creator id for WSL (from Microsoft's WSL networking docs).
$WslCreatorId = "{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}"

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

# Runs a bash script as root inside the distro. The script goes through stdin,
# not as an argument: Windows PowerShell 5.1 mangles double quotes in native
# arguments, and stdin arrives with CRLF, hence the tr.
function Invoke-WslRootScript([string]$Script) {
    $Script | & wsl.exe -d $Distro -u root -- sh -c "tr -d '\r' | bash -s"
    if ($LASTEXITCODE -ne 0) { Fail "Script inside $Distro failed (exit $LASTEXITCODE)." }
}

function Get-WslDefaultUser {
    # Windows PowerShell 5.1 turns redirected native stderr into a terminating
    # error under "Stop"; keep this function tolerant.
    $ErrorActionPreference = "Continue"
    $prev = [Console]::OutputEncoding
    try {
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
        $u = & wsl.exe -d $Distro -- id -un 2>$null
    } finally {
        [Console]::OutputEncoding = $prev
    }
    return (($u | Out-String) -replace "`0", "").Trim()
}

# With a missing/skipped first-run setup WSL logs in as root, and then
# instalador_unico.sh would install into /root instead of /home/<user>.
function Ensure-WslUser {
    $ErrorActionPreference = "Continue"
    $current = Get-WslDefaultUser
    if ($current -and $current -ne "root") {
        Write-Host "Linux default user: $current"
        return
    }

    Write-Host ""
    Write-Host "$Distro has no normal Linux user yet (it logs in as root)." -ForegroundColor Yellow
    do {
        $name = (Read-Host "Linux username to create (lowercase, no spaces, e.g. ncommerce)").Trim()
    } until ($name -cmatch '^[a-z_][a-z0-9_-]{0,31}$' -and $name -ne "root")

    & wsl.exe -d $Distro -u root -- getent passwd $name | Out-Null
    if ($LASTEXITCODE -ne 0) {
        & wsl.exe -d $Distro -u root -- useradd -m -s /bin/bash -G sudo $name
        if ($LASTEXITCODE -ne 0) { Fail "Could not create Linux user $name." }
    }
    Write-Host "Choose the Linux password for $name (asked twice; sudo uses it):"
    do {
        & wsl.exe -d $Distro -u root -- passwd $name
    } until ($LASTEXITCODE -eq 0)

    Invoke-WslRootScript (@'
set -e
CONF=/etc/wsl.conf
touch $CONF
if grep -q '^\[user\]' $CONF; then
  sed -i '/^\[user\]/,/^\[/{/^default=/d}' $CONF
  sed -i '/^\[user\]/a default=__USER__' $CONF
else
  printf '\n[user]\ndefault=__USER__\n' >> $CONF
fi
'@ -replace '__USER__', $name)
    Write-Host "Default Linux user set to $name."
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

function Enable-OpenSshServer {
    Write-Host "Opening SSH on port 22..."
    try {
        $cap = Get-WindowsCapability -Online -ErrorAction Stop |
            Where-Object { $_.Name -like "OpenSSH.Server*" } |
            Select-Object -First 1
        if (-not $cap) {
            Write-Host "This Windows build does not offer the OpenSSH Server feature."
            return
        }
        if ($cap.State -ne "Installed") {
            Add-WindowsCapability -Online -Name $cap.Name -ErrorAction Stop | Out-Null
        }
        Set-Service -Name sshd -StartupType Automatic -ErrorAction Stop
        Start-Service sshd -ErrorAction Stop
        $rule = Get-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -ErrorAction SilentlyContinue
        if (-not $rule) {
            New-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -DisplayName "OpenSSH SSH Server (sshd)" -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
        } else {
            Set-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -Enabled True -Action Allow
        }
        Write-Host "Windows SSH is listening on port 22."
    } catch {
        Write-Host "Could not start SSH: $($_.Exception.Message)"
    }
}
Enable-OpenSshServer

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

    # In mirrored mode inbound LAN traffic to WSL also goes through the Hyper-V
    # firewall, which can block tablets even with the netsh rules in place.
    if (Get-Command New-NetFirewallHyperVRule -ErrorAction SilentlyContinue) {
        try {
            foreach ($p in $WslPorts) {
                $ruleName = "NCommerce-WSL-$p"
                Remove-NetFirewallHyperVRule -Name $ruleName -ErrorAction SilentlyContinue
                New-NetFirewallHyperVRule -Name $ruleName -DisplayName "NCommerce WSL port $p" `
                    -Direction Inbound -VMCreatorId $WslCreatorId -Protocol TCP -LocalPorts $p -Action Allow | Out-Null
            }
            Write-Host "Hyper-V firewall: allowed inbound TCP $($WslPorts -join ', ') to WSL."
        } catch {
            Write-Host "Could not create Hyper-V firewall rules: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
} else {
    Write-Host "Windows build $build has no mirrored networking; LAN access will use netsh portproxy." -ForegroundColor Yellow
}

# 5. Set WSL2 as default, install Ubuntu 24.04 -------------------------------
# Mirrored networking needs WSL 2.0+; the inbox WSL of Windows 10 is older.
Write-Host "Updating WSL..."
try { wsl --update 2>$null | Out-Null } catch { }
wsl --set-default-version 2 | Out-Null

$installed = Get-WslDistroNames
if ($installed -notcontains $Distro) {
    Write-Host "Installing $Distro (this downloads ~500MB)..."
    Write-Host ""
    Write-Host "Ubuntu will start in THIS window and ask for a UNIX username and password" -ForegroundColor Yellow
    Write-Host "(Linux login, separate from Windows). When you see the Linux prompt (`$)," -ForegroundColor Yellow
    Write-Host "type  exit  and press Enter to continue here." -ForegroundColor Yellow
    Write-Host ""
    # No --no-launch: that skips the first-run setup, leaving the distro
    # unregistered (old store package) or logged in as root.
    wsl --install -d $Distro
    if ((Get-WslDistroNames) -notcontains $Distro) {
        Fail "$Distro did not install. If Windows asked for a restart, restart and run install-ncommerce-wsl.bat again."
    }
} else {
    Write-Host "$Distro is already installed."
}

wsl --set-default $Distro 2>$null
Ensure-WslUser

# 6. Enable systemd inside the distro (nginx, cron, mysql on "boot") --------
Write-Host "Enabling systemd inside $Distro..."
Invoke-WslRootScript @'
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
$sourceBat = Join-Path $scriptDir "ncommerce-wsl-startup.bat"
$startupBat = Join-Path $InstallDir "ncommerce-wsl-startup.bat"

if (Test-Path $sourceBat) {
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    Copy-Item $sourceBat $startupBat -Force
    $readme = Join-Path $scriptDir "README.txt"
    if (Test-Path $readme) { Copy-Item $readme $InstallDir -Force }

    Write-Host "Registering the logon task that starts $Distro and opens LAN ports..."
    # $InstallDir has no spaces, so /tr needs no extra quoting.
    schtasks /create /tn "NCommerce WSL Startup" /tr $startupBat /sc onlogon /rl highest /f | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail "Could not register the scheduled task." }
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
    # Built here instead of via wslpath: reading wslpath output through the
    # console code page mangles accented Windows user names (e.g. Joao with ~).
    $full = (Resolve-Path $ncscriptsRoot).Path
    $winPathForWsl = "/mnt/" + $full.Substring(0, 1).ToLower() + ($full.Substring(2) -replace '\\', '/')
    # sed strips CRLF in case the repo was cloned with Git for Windows autocrlf.
    wsl -d $Distro -- bash -lc "mkdir -p `$HOME/ncscripts && cp -a '$winPathForWsl'/. `$HOME/ncscripts/ && sed -i 's/\r`$//' `$HOME/ncscripts/*.sh && chmod +x `$HOME/ncscripts/*.sh"
    if ($LASTEXITCODE -ne 0) { Fail "Could not copy ncscripts into $Distro." }
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
