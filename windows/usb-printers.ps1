# Impressora USB no Windows. O Docker Desktop nao ve USB, entao o CUPS do container
# imprime por LPD na impressora compartilhada deste Windows.
# Instala o driver (opcional), liga o servico LPD, abre a 515 e compartilha as impressoras USB.
# Rode como admin. Impressora plugada depois: a tarefa "NCommerce Impressoras USB" roda
# este script com -Sincronizar (compartilha e atualiza a lista) quando o Windows cria uma
# impressora, ao ligar o PC e a cada 5 minutos.
# No CUPS do container: lpd://host.docker.internal/<compartilhamento>, com o PPD Elgin ou Bematech.
# O CUPS manda os dados prontos para a impressora; o Windows so repassa.

param([switch]$Sincronizar)

$ErrorActionPreference = "Stop"

$TaskName = "NCommerce Impressoras USB"
$DriverDir = Join-Path $PSScriptRoot "drivers"

# Inno Setup da Bematech. O mesmo driver serve para MP-4200 TH/ADV, Elgin i9 e Epson T20,
# e abre a tela da Bematech para escolher modelo e porta.
function Install-PrinterDriver {
    $setup = Join-Path $DriverDir "bematech-mp4200-th-adv-spooler-x64-5.0.04.exe"
    if (-not (Test-Path $setup)) { return }
    Write-Host ""
    Write-Host "Driver da impressora USB (Bematech MP-4200, Elgin i9 ou Epson T20)."
    Write-Host "Deixe a impressora ligada e plugada."
    $answer = (Read-Host "Instalar o driver? [S/n] (n se ele ja esta instalado)").Trim()
    if ($answer -match "^[nN]") { return }
    Write-Host "Na tela da Bematech, escolha o modelo e a porta USB."
    $proc = Start-Process -FilePath $setup -ArgumentList "/SP- /SILENT /SUPPRESSMSGBOXES /NORESTART" -Wait -PassThru
    if ($proc.ExitCode -ne 0) {
        Write-Host "O instalador do driver terminou com codigo $($proc.ExitCode)."
    }
    # O Windows leva alguns segundos para criar a impressora depois do driver.
    Start-Sleep -Seconds 10
}

function Enable-LpdService {
    $feature = Get-WindowsOptionalFeature -Online -FeatureName "Printing-Foundation-LPDPrintService"
    if (-not $feature) {
        Write-Host "Este Windows nao oferece o Servico LPD."
        return $false
    }
    if ($feature.State -ne "Enabled") {
        Write-Host "Ligando o Servico LPD do Windows..."
        Enable-WindowsOptionalFeature -Online -FeatureName "Printing-Foundation-LPDPrintService" -All -NoRestart | Out-Null
    }
    Set-Service -Name LPDSVC -StartupType Automatic
    Start-Service LPDSVC

    # LocalSubnet cobre a rede da loja e a rede virtual do WSL, de onde vem o container.
    $name = "NCommerce LPD 515"
    if (-not (Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName $name -Direction Inbound -Protocol TCP -LocalPort 515 -RemoteAddress LocalSubnet -Action Allow | Out-Null
    }
    return $true
}

function Get-FreeShareName([string]$PrinterName) {
    $base = ($PrinterName -replace "[^A-Za-z0-9]", "")
    if (-not $base) { $base = "impressora" }
    if ($base.Length -gt 40) { $base = $base.Substring(0, 40) }
    $taken = @(Get-Printer | Where-Object { $_.Shared } | ForEach-Object { $_.ShareName })
    $name = $base
    $i = 2
    while ($taken -contains $name) {
        $name = "$base$i"
        $i++
    }
    return $name
}

function Share-UsbPrinters {
    $printers = @(Get-Printer | Where-Object { $_.PortName -like "USB*" })
    if (-not $printers) {
        Write-Host "Nenhuma impressora USB instalada no Windows."
        Write-Host "Instale o driver do fabricante, plugue a impressora e rode este script de novo."
        return @()
    }
    $uris = @()
    foreach ($p in $printers) {
        if (-not $p.Shared) {
            Set-Printer -Name $p.Name -Shared $true -ShareName (Get-FreeShareName $p.Name)
            $p = Get-Printer -Name $p.Name
        }
        $uris += "  $($p.Name): lpd://host.docker.internal/$([uri]::EscapeDataString($p.ShareName))"
    }
    return $uris
}

# O CUPS do container le esta lista (backend winusb) e mostra cada impressora em
# "Impressoras locais", com o driver ja escolhido. Uma linha por impressora:
# compartilhamento<TAB>nome<TAB>driver.
function Write-PrinterList {
    $hostDir = Join-Path $PSScriptRoot "host"
    New-Item -ItemType Directory -Force -Path $hostDir | Out-Null
    $lines = @(Get-Printer | Where-Object { $_.PortName -like "USB*" -and $_.Shared } |
        ForEach-Object { "$($_.ShareName)`t$($_.Name)`t$($_.DriverName)" })
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText((Join-Path $hostDir "usb_printers"), (($lines | ForEach-Object { "$_`n" }) -join ""), $utf8)
}

# Roda como SYSTEM, que pode compartilhar impressora sem ninguem logado como admin.
# O evento 300 do PrintService (impressora criada) so e gravado com o log ligado.
function Register-SyncTask {
    & wevtutil.exe set-log Microsoft-Windows-PrintService/Operational /enabled:true | Out-Null
    $script = Join-Path $PSScriptRoot "usb-printers.ps1"
    $action = New-ScheduledTaskAction -Execute "powershell.exe" `
        -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`" -Sincronizar"
    $added = Get-CimClass -ClassName MSFT_TaskEventTrigger -Namespace Root/Microsoft/Windows/TaskScheduler |
        New-CimInstance -ClientOnly
    $added.Enabled = $true
    $added.Subscription = '<QueryList><Query Id="0" Path="Microsoft-Windows-PrintService/Operational"><Select Path="Microsoft-Windows-PrintService/Operational">*[System[EventID=300]]</Select></Query></QueryList>'
    $every5 = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 5)
    $boot = New-ScheduledTaskTrigger -AtStartup
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 2)
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger @($added, $every5, $boot) `
        -Settings $settings -Principal $principal -Force | Out-Null
}

if ($Sincronizar) {
    try {
        Share-UsbPrinters | Out-Null
        Write-PrinterList
    } catch {
        exit 1
    }
    exit 0
}

try {
    Install-PrinterDriver
    if (-not (Enable-LpdService)) { exit 1 }
    $uris = Share-UsbPrinters
    Write-PrinterList
    Register-SyncTask
    if ($uris) {
        Write-Host "Impressoras USB que aparecem no CUPS em Impressoras locais:"
        $uris | ForEach-Object { Write-Host $_ }
    }
} catch {
    Write-Host "Nao consegui preparar a impressora USB: $($_.Exception.Message)"
    exit 1
}
