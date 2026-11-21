# Atualiza os scripts deste PC (C:\NCommerce) com o ncscripts publicado no GitHub,
# o mesmo zip do instalador. O ncommerce-update.ps1 (atalho "Atualizar
# NCommerce") chama este script antes do download das imagens.
# Sem internet ou com o GitHub fora, so avisa: a atualizacao das imagens segue.
#
# Nada e trocado se algum arquivo do pacote vier danificado: o zip e baixado
# inteiro antes de abrir, cada .ps1 passa pela conferencia de sintaxe e o
# docker-compose.yml pelo docker compose config. Cada arquivo e trocado de uma
# vez (copia ao lado e troca), entao uma queda de energia deixa o antigo ou o novo.
# O proprio .bat em execucao nao e trocado aqui (o cmd le o .bat aos poucos): ele
# fica em ncommerce-docker-update.bat.new e o .bat se troca na ultima linha.
# Este arquivo nao usa o instalador-lib.ps1: numa loja antiga ele ainda nao existe.
param([string]$InstallDir = "C:\NCommerce")

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$InstallDir = $InstallDir.TrimEnd('\', '/', '.')
if (-not $InstallDir) { $InstallDir = "C:\NCommerce" }
$ZipUrl = "https://github.com/ArielAleksandrus/ncscripts/archive/refs/heads/master.zip"
if ($env:NCOMMERCE_SCRIPTS_ZIP_URL) { $ZipUrl = $env:NCOMMERCE_SCRIPTS_ZIP_URL }
if ($env:NCOMMERCE_DOCKER_EXE) {
    $DockerExe = $env:NCOMMERCE_DOCKER_EXE
} else {
    $DockerExe = Join-Path "$env:ProgramFiles" "Docker\Docker\resources\bin\docker.exe"
}

$files = @(
    @{ From = "docker\docker-compose.yml"; To = "docker-compose.yml"; Backup = $true },
    @{ From = "windows\instalador-lib.ps1"; To = "instalador-lib.ps1" },
    @{ From = "windows\ncommerce-update.ps1"; To = "ncommerce-update.ps1" },
    @{ From = "windows\ncommerce-docker-startup.bat"; To = "ncommerce-docker-startup.bat" },
    @{ From = "windows\refresh-host-ips.ps1"; To = "refresh-host-ips.ps1" },
    @{ From = "windows\anydesk-id.ps1"; To = "anydesk-id.ps1" },
    @{ From = "windows\usb-printers.ps1"; To = "usb-printers.ps1" },
    @{ From = "windows\net-check.ps1"; To = "net-check.ps1" },
    @{ From = "windows\migrate-endpoints.ps1"; To = "migrate-endpoints.ps1" },
    @{ From = "windows\update-host.ps1"; To = "update-host.ps1" },
    @{ From = "docker\guard.sh"; To = "guard.sh" },
    @{ From = "windows\rollback.bat"; To = "rollback.bat" },
    @{ From = "windows\ncommerce-docker-update.bat"; To = "ncommerce-docker-update.bat"; Staged = $true }
)

function Stop-HostUpdate([string]$Why) {
    Write-Host "$Why Sigo com a atualizacao do sistema."
    throw "parou"
}

function Get-Length([string]$Path) {
    if (-not [System.IO.File]::Exists($Path)) { return -1 }
    return (New-Object System.IO.FileInfo $Path).Length
}

function Test-SameFile([string]$A, [string]$B) {
    if (-not [System.IO.File]::Exists($A) -or -not [System.IO.File]::Exists($B)) { return $false }
    return ((Get-FileHash -LiteralPath $A).Hash -eq (Get-FileHash -LiteralPath $B).Hash)
}

# Copia ao lado (<destino>.novo), confere o tamanho e troca de uma vez.
function Copy-Atomic([string]$Source, [string]$Destination, [bool]$Backup) {
    $tmp = "$Destination.novo"
    [System.IO.File]::Copy($Source, $tmp, $true)
    if ((Get-Length $tmp) -ne (Get-Length $Source)) {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        throw "copia incompleta de $Source"
    }
    if ([System.IO.File]::Exists($Destination)) {
        $bak = [NullString]::Value
        if ($Backup) { $bak = "$Destination.bak" }
        [System.IO.File]::Replace($tmp, $Destination, $bak)
    } else {
        [System.IO.File]::Move($tmp, $Destination)
    }
}

# Instaladores antigos clonavam o codigo-fonte em C:\NCommerce\src. A stack roda
# das imagens e nada usa essa pasta: sai daqui, com o historico do git.
$oldSrc = Join-Path $InstallDir "src"
if (Test-Path -LiteralPath $oldSrc) {
    Remove-Item -LiteralPath $oldSrc -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $oldSrc) {
        Write-Host "Nao consegui apagar $oldSrc por inteiro."
    } else {
        Write-Host "Codigo-fonte antigo apagado de $oldSrc."
    }
}

$work = Join-Path ([System.IO.Path]::GetTempPath()) ("ncscripts-" + [guid]::NewGuid().ToString("N"))
try {
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    $zip = Join-Path $work "ncscripts.zip"
    # O pacote vem inteiro para um arquivo e so depois e aberto.
    $downloaded = $false
    if (Get-Command curl.exe -CommandType Application -ErrorAction SilentlyContinue) {
        $ErrorActionPreference = "Continue"
        & curl.exe -fsSL --retry 2 --connect-timeout 15 --max-time 180 -o $zip $ZipUrl 2>$null
        $downloaded = ($LASTEXITCODE -eq 0)
        $ErrorActionPreference = "Stop"
    } else {
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri $ZipUrl -OutFile $zip -UseBasicParsing -TimeoutSec 180
            $downloaded = $true
        } catch {
            $downloaded = $false
        }
    }
    if (-not $downloaded -or (Get-Length $zip) -le 0) { Stop-HostUpdate "Nao consegui baixar os scripts do NCommerce." }
    $out = Join-Path $work "x"
    try {
        Expand-Archive -LiteralPath $zip -DestinationPath $out -Force
    } catch {
        Stop-HostUpdate "O pacote de scripts do NCommerce veio danificado. Nao troquei nenhum script."
    }
    $root = Get-ChildItem -LiteralPath $out -Directory | Where-Object {
        Test-Path -LiteralPath (Join-Path $_.FullName "docker\docker-compose.yml")
    } | Select-Object -First 1
    if (-not $root -or -not (Test-Path -LiteralPath (Join-Path $root.FullName "windows"))) {
        Stop-HostUpdate "O pacote do GitHub veio sem as pastas docker e windows."
    }
    $root = $root.FullName

    # Conferencia de tudo antes de trocar qualquer coisa.
    foreach ($f in $files) {
        $src = Join-Path $root $f.From
        if (-not [System.IO.File]::Exists($src)) { continue }
        if ((Get-Length $src) -le 0) { Stop-HostUpdate "O pacote do GitHub trouxe $($f.From) vazio. Nao troquei nenhum script." }
        if ($src -like "*.ps1") {
            $tokens = $null; $errors = $null
            [System.Management.Automation.Language.Parser]::ParseFile($src, [ref]$tokens, [ref]$errors) | Out-Null
            if ($errors -and $errors.Count -gt 0) {
                Stop-HostUpdate "O pacote do GitHub trouxe $($f.From) com erro. Nao troquei nenhum script."
            }
        }
    }
    $compose = Join-Path $root "docker\docker-compose.yml"
    if (Test-Path -LiteralPath $DockerExe) {
        $ErrorActionPreference = "Continue"
        & $DockerExe info *> $null
        if ($LASTEXITCODE -eq 0) {
            & $DockerExe compose -f $compose config -q *> $null
            if ($LASTEXITCODE -ne 0) {
                $ErrorActionPreference = "Stop"
                Stop-HostUpdate "O docker-compose.yml do pacote do GitHub nao passou na conferencia. Nao troquei nenhum script."
            }
        }
        $ErrorActionPreference = "Stop"
    }

    $changed = @()
    foreach ($f in $files) {
        $src = Join-Path $root $f.From
        if (-not [System.IO.File]::Exists($src)) { continue }
        $dst = Join-Path $InstallDir $f.To
        if (Test-SameFile $src $dst) {
            if ($f.Staged) { Remove-Item -LiteralPath "$dst.new" -Force -ErrorAction SilentlyContinue }
            continue
        }
        if ($f.Staged) { $dst = "$dst.new" }
        Copy-Atomic $src $dst ([bool]$f.Backup)
        $changed += $f.To
    }
    $drivers = Join-Path $root "windows\drivers"
    if (Test-Path -LiteralPath $drivers) {
        $driversDst = Join-Path $InstallDir "drivers"
        New-Item -ItemType Directory -Force -Path $driversDst | Out-Null
        foreach ($d in (Get-ChildItem -LiteralPath $drivers -File)) {
            $target = Join-Path $driversDst $d.Name
            if (-not (Test-SameFile $d.FullName $target)) { Copy-Atomic $d.FullName $target $false }
        }
    }

    if ($changed.Count -gt 0) {
        Write-Host ("Scripts do NCommerce atualizados: " + ($changed -join ", "))
    } else {
        Write-Host "Scripts do NCommerce ja estao na versao publicada."
    }
} catch {
    if ("$($_.Exception.Message)" -ne "parou") {
        Write-Host "Nao consegui atualizar os scripts do NCommerce ($($_.Exception.Message)). Sigo com a atualizacao do sistema."
    }
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
exit 0
