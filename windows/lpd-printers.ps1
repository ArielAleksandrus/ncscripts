# Impressora USB no Windows. O Docker Desktop nao ve USB, entao o CUPS do container
# imprime por LPD na impressora compartilhada deste Windows.
# Liga o servico LPD, abre a 515 e compartilha as impressoras USB.
# Rode como admin. Impressora plugada depois: rode este script de novo.
# No CUPS do container: lpd://host.docker.internal/<compartilhamento>, com o PPD Elgin ou Bematech.
# O CUPS manda os dados prontos para a impressora; o Windows so repassa.

$ErrorActionPreference = "Stop"

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
