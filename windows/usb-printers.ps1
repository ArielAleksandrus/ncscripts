# Impressora USB no Windows. O Docker Desktop nao ve USB, entao o CUPS do container
# imprime por LPD na impressora compartilhada deste Windows.
# Instala o driver (opcional), liga o servico LPD, abre a 515 e compartilha as impressoras USB.
# Rode como admin. Impressora plugada depois: rode este script de novo.
# No CUPS do container: lpd://host.docker.internal/<compartilhamento>, com o PPD Elgin ou Bematech.
# O CUPS manda os dados prontos para a impressora; o Windows so repassa.

$ErrorActionPreference = "Stop"

$DriverDir = Join-Path $PSScriptRoot "drivers"

# Os dois sao Inno Setup. O da TH/ADV abre a tela da Bematech para escolher modelo e porta.
# O da HS e o mesmo driver da Elgin i9: o Windows cria a impressora quando ela e plugada.
function Install-PrinterDriver {
    if (-not (Test-Path $DriverDir)) { return }
    Write-Host ""
    Write-Host "Driver da impressora USB. Deixe a impressora ligada e plugada."
    Write-Host "  1 - Bematech MP-4200 TH ou ADV"
    Write-Host "  2 - Bematech MP-4200 HS ou Elgin i9"
    Write-Host "  Enter - pular (driver ja instalado ou outro modelo)"
    $choice = (Read-Host "Opcao").Trim()
    $setup = switch ($choice) {
        "1" { "bematech-mp4200-th-adv-spooler-x64-5.0.04.exe" }
        "2" { "elgin-i9-bematech-mp4200-hs-1.8.0.1.exe" }
        default { $null }
    }
    if (-not $setup) { return }
    if ($choice -eq "1") {
        Write-Host "Na tela da Bematech, escolha o modelo e a porta USB."
    }
    $proc = Start-Process -FilePath (Join-Path $DriverDir $setup) -ArgumentList "/SP- /SILENT /SUPPRESSMSGBOXES /NORESTART" -Wait -PassThru
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

try {
    Install-PrinterDriver
    if (-not (Enable-LpdService)) { exit 1 }
    $uris = Share-UsbPrinters
    if ($uris) {
        Write-Host "Impressoras USB para cadastrar no CUPS do container:"
        $uris | ForEach-Object { Write-Host $_ }
    }
} catch {
    Write-Host "Nao consegui preparar a impressora USB: $($_.Exception.Message)"
    exit 1
}
