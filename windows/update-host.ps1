# Atualiza os scripts deste PC (C:\NCommerce) com o ncscripts publicado no GitHub,
# o mesmo zip do instalador. O ncommerce-docker-update.bat (atalho "Atualizar
# NCommerce") chama este script antes do pull das imagens.
# Sem internet ou com o GitHub fora, so avisa: a atualizacao das imagens segue.
# O proprio .bat em execucao nao e trocado aqui (o cmd le o .bat aos poucos): ele
# fica em ncommerce-docker-update.bat.new e o .bat se troca na ultima linha.
param([string]$InstallDir = "C:\NCommerce")

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$ZipUrl = "https://github.com/ArielAleksandrus/ncscripts/archive/refs/heads/master.zip"

# Instaladores antigos clonavam o codigo-fonte em C:\NCommerce\src. A stack roda
# das imagens e nada usa essa pasta: sai daqui, com o historico do git.
$oldSrc = Join-Path $InstallDir "src"
if (Test-Path $oldSrc) {
    Remove-Item $oldSrc -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path $oldSrc) {
        Write-Host "Nao consegui apagar $oldSrc por inteiro."
    } else {
        Write-Host "Codigo-fonte antigo apagado de $oldSrc."
    }
}

$work = Join-Path $env:TEMP ("ncscripts-" + [guid]::NewGuid().ToString("N"))
try {
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    $zip = Join-Path $work "ncscripts.zip"
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $ZipUrl -OutFile $zip -UseBasicParsing -TimeoutSec 60
    Expand-Archive -Path $zip -DestinationPath $work -Force
    $root = Join-Path $work "ncscripts-master"
    if (-not (Test-Path (Join-Path $root "windows"))) { throw "zip sem a pasta windows" }

    $files = @(
        @{ From = "docker\docker-compose.yml";          To = "docker-compose.yml" },
        @{ From = "windows\ncommerce-docker-startup.bat"; To = "ncommerce-docker-startup.bat" },
        @{ From = "windows\refresh-host-ips.ps1";       To = "refresh-host-ips.ps1" },
        @{ From = "windows\anydesk-id.ps1";             To = "anydesk-id.ps1" },
        @{ From = "windows\usb-printers.ps1";           To = "usb-printers.ps1" },
        @{ From = "windows\net-check.ps1";             To = "net-check.ps1" },
        @{ From = "windows\update-host.ps1";            To = "update-host.ps1" },
        @{ From = "docker\guard.sh";                    To = "guard.sh" },
        @{ From = "windows\rollback.bat";               To = "rollback.bat" },
        @{ From = "windows\ncommerce-docker-update.bat"; To = "ncommerce-docker-update.bat.new" }
    )
    $changed = @()
    foreach ($f in $files) {
        $src = Join-Path $root $f.From
        if (-not (Test-Path $src)) { continue }
        $dst = Join-Path $InstallDir $f.To
        $current = $dst -replace '\.new$', ''
        if ((Test-Path $current) -and ((Get-FileHash $src).Hash -eq (Get-FileHash $current).Hash)) { continue }
        Copy-Item $src $dst -Force
        $changed += ($f.To -replace '\.new$', '')
    }
    $drivers = Join-Path $root "windows\drivers"
    if (Test-Path $drivers) { Copy-Item $drivers $InstallDir -Recurse -Force }

    if ($changed.Count -gt 0) {
        Write-Host ("Scripts do NCommerce atualizados: " + ($changed -join ", "))
    } else {
        Write-Host "Scripts do NCommerce ja estao na versao publicada."
    }
} catch {
    Write-Host "Nao consegui atualizar os scripts do NCommerce ($($_.Exception.Message)). Sigo com a atualizacao do sistema."
} finally {
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}
exit 0
