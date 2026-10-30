#Requires -RunAsAdministrator
<#
  Instalador Docker do NCommerce no Windows.

  Pede um codigo de 8 caracteres. O mestre troca esse codigo, uma vez,
  pelo token da empresa e pela chave privada de leitura (access key SSH).
  A chave e apagada depois do clone.
  Reexecutar nao apaga volume.
#>

$ErrorActionPreference = "Stop"
$InstallDir = "C:\NCommerce"
$TaskName = "NCommerce Docker Startup"
if ($env:NCOMMERCE_MASTER_URL) {
    $MasterUrl = $env:NCOMMERCE_MASTER_URL
} else {
    $MasterUrl = "https://ncommerce.app:3001"
}
$DockerExe = Join-Path $env:ProgramFiles "Docker\Docker\resources\bin\docker.exe"
$DockerDesktop = Join-Path $env:ProgramFiles "Docker\Docker\Docker Desktop.exe"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path

function Fail($msg) {
    Remove-Secrets
    Write-Host ""
    Write-Host "ERRO: $msg" -ForegroundColor Red
    Read-Host "Pressione Enter para sair"
    exit 1
}

function Read-InstallCode {
    while ($true) {
        $raw = Read-Host "Codigo de instalacao (8 caracteres)"
        $code = (($raw -replace "[\s\-]", "").ToUpper())
        if ($code -match "^[A-Z0-9]{8}$") { return $code }
        Write-Host "Use 8 letras ou numeros."
    }
}

function Get-MachineId {
    $dir = Join-Path $env:ProgramData "NCommerce"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $file = Join-Path $dir "machine-id"
    if (-not (Test-Path $file)) {
        [guid]::NewGuid().ToString() | Set-Content -Path $file -NoNewline -Encoding ascii
    }
    return (Get-Content -Raw -Path $file).Trim()
}

function Get-InstallGrant([string]$Code) {
    $machineId = Get-MachineId
    $payloadFile = New-TemporaryFile
    $bodyFile = New-TemporaryFile
    $payload = @{ code = $Code; machine_id = $machineId; hostname = $env:COMPUTERNAME } | ConvertTo-Json -Compress
    [System.IO.File]::WriteAllText($payloadFile.FullName, $payload)
    $ErrorActionPreference = "Continue"
    $http = & curl.exe -sS -o $bodyFile.FullName -w "%{http_code}" --max-time 30 `
        -X POST -H "Content-Type: application/json" --data-binary "@$($payloadFile.FullName)" `
        "$MasterUrl/install/redeem"
    $curlCode = $LASTEXITCODE
    $ErrorActionPreference = "Stop"
    Remove-Item $payloadFile.FullName -Force -ErrorAction SilentlyContinue
    $http = "$http".Trim()
    if ($curlCode -ne 0 -or $http -ne "200") {
        $detail = ""
        if (Test-Path $bodyFile.FullName) {
            $detail = Get-Content -Raw -Path $bodyFile.FullName -ErrorAction SilentlyContinue
            if ($detail -and $detail.Length -gt 500) { $detail = $detail.Substring(0, 500) }
        }
        Remove-Item $bodyFile.FullName -Force -ErrorAction SilentlyContinue
        Fail "Codigo recusado (HTTP $http). $detail"
    }
    try {
        $grant = Get-Content -Raw -Path $bodyFile.FullName | ConvertFrom-Json
    } catch {
        Remove-Item $bodyFile.FullName -Force -ErrorAction SilentlyContinue
        Fail "Resposta do mestre nao e o codigo de instalacao."
    }
    Remove-Item $bodyFile.FullName -Force
    if (-not $grant.token) { $grant | Add-Member -NotePropertyName token -NotePropertyValue $grant.ncommerce_token -Force }
    if (-not $grant.token -or -not $grant.git_private_key) {
        Fail "A resposta do mestre nao trouxe o token do ncommerce e a chave de leitura."
    }
    return $grant
}

function Save-CompanyBackup([string]$Code) {
    $machineId = Get-MachineId
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    $dest = Join-Path $InstallDir "ncommerce.zip"
    $ErrorActionPreference = "Continue"
    $http = & curl.exe -sS -o $dest -w "%{http_code}" --max-time 600 `
        "$MasterUrl/install/$Code/backup?machine_id=$machineId"
    $curlCode = $LASTEXITCODE
    $ErrorActionPreference = "Stop"
    if ($http -eq "204") {
        Remove-Item $dest -Force -ErrorAction SilentlyContinue
        Write-Host "Esta empresa nao tem backup no mestre. A instalacao segue vazia."
        return
    }
    if ($curlCode -ne 0 -or $http -ne "200") {
        Remove-Item $dest -Force -ErrorAction SilentlyContinue
        Fail "Nao consegui baixar o backup (HTTP $http)."
    }
    Write-Host "Backup baixado em $dest."
}

$script:SecretFiles = @()

function Remove-Secrets {
    foreach ($f in $script:SecretFiles) {
        if ($f -and (Test-Path $f)) {
            Remove-Item $f -Force -ErrorAction SilentlyContinue
        }
    }
    $script:SecretFiles = @()
    Remove-Item Env:GIT_SSH_COMMAND -ErrorAction SilentlyContinue
}

function Test-DockerReady {
    if (-not (Test-Path $DockerExe)) { return $false }
    $ErrorActionPreference = "Continue"
    & $DockerExe info *> $null
    return ($LASTEXITCODE -eq 0)
}

function Read-EnvValue([string]$Path, [string]$Key, [string]$Default) {
    if (-not (Test-Path $Path)) { return $Default }
    foreach ($line in Get-Content -Path $Path) {
        if ($line -like "$Key=*") { return $line.Substring($Key.Length + 1) }
    }
    return $Default
}

function Install-GitIfMissing {
    if (Get-Command git.exe -ErrorAction SilentlyContinue) { return }
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Fail "Git nao esta instalado e o winget nao existe."
    }
    Write-Host "Instalando Git..."
    & winget install --exact --id Git.Git --accept-package-agreements --accept-source-agreements --disable-interactivity
    $machine = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $user = [Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path = "$machine;$user"
    if (-not (Get-Command git.exe -ErrorAction SilentlyContinue)) {
        Fail "Git nao ficou no PATH. Feche a janela e rode o instalador de novo."
    }
}

function Find-Ssh {
    $candidates = @(
        (Join-Path $env:ProgramFiles "Git\usr\bin\ssh.exe"),
        (Join-Path $env:WINDIR "System32\OpenSSH\ssh.exe")
    )
    foreach ($candidate in $candidates) {
        if (Test-Path $candidate) { return $candidate }
    }
    $cmd = Get-Command ssh.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Clone-Repos([string]$GitKey) {
    Install-GitIfMissing
    $ssh = Find-Ssh
    if (-not $ssh) { Fail "Nao achei o ssh. Instale o Git for Windows e rode de novo." }
    $src = Join-Path $InstallDir "src"
    New-Item -ItemType Directory -Force -Path $src | Out-Null

    $keyText = $GitKey -replace "`r`n", "`n" -replace "`r", "`n"
    if (-not $keyText.EndsWith("`n")) { $keyText += "`n" }
    $keyFile = New-TemporaryFile
    $knownFile = New-TemporaryFile
    $script:SecretFiles += @($keyFile.FullName, $knownFile.FullName)
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($keyFile.FullName, $keyText, $utf8)
    & icacls.exe $keyFile.FullName /inheritance:r | Out-Null
    & icacls.exe $keyFile.FullName /grant:r "${env:USERNAME}:(R)" | Out-Null

    $keyscan = Join-Path (Split-Path $ssh) "ssh-keyscan.exe"
    if (-not (Test-Path $keyscan)) { $keyscan = "ssh-keyscan.exe" }
    $ErrorActionPreference = "Continue"
    $scan = & $keyscan -T 10 -t ed25519,rsa bitbucket.org 2>$null
    $ErrorActionPreference = "Stop"
    if (-not $scan) { Fail "Nao consegui obter a chave do servidor bitbucket.org." }
    [System.IO.File]::WriteAllText($knownFile.FullName, (($scan | Out-String).Trim() + "`n"), $utf8)

    $keyForSsh = ($keyFile.FullName -replace '\\', '/')
    $knownForSsh = ($knownFile.FullName -replace '\\', '/')
    $env:GIT_SSH_COMMAND = "`"$ssh`" -i `"$keyForSsh`" -o IdentitiesOnly=yes -o UserKnownHostsFile=`"$knownForSsh`" -o StrictHostKeyChecking=yes"
    $env:GIT_TERMINAL_PROMPT = "0"
    foreach ($repo in @("ncommerce_api", "ncommerce", "nfce")) {
        $dest = Join-Path $src $repo
        if (Test-Path (Join-Path $dest ".git")) {
            Write-Host "$repo ja esta em $dest"
            continue
        }
        if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
        Write-Host "Clonando $repo..."
        $ErrorActionPreference = "Continue"
        & git.exe clone --quiet "git@bitbucket.org:Aleksandrus/$repo.git" $dest
        $cloneCode = $LASTEXITCODE
        $ErrorActionPreference = "Stop"
        if ($cloneCode -ne 0) {
            if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
            Fail "Nao consegui clonar $repo. A chave de leitura do Bitbucket foi recusada."
        }
    }
    Remove-Secrets
}

# docker compose exec, com o console aberto, espera EOF no stdin e nao volta.
function Invoke-ComposeExec {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$ArgList)
    $parts = foreach ($a in $ArgList) {
        if ($a -match '[\s"]') { '"' + ($a.Replace('"', '\"')) + '"' } else { $a }
    }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $DockerExe
    $psi.Arguments = ((@("compose") + $parts) -join " ")
    $psi.WorkingDirectory = $InstallDir
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    $proc.StandardInput.Close()
    $out = $proc.StandardOutput.ReadToEnd()
    $proc.WaitForExit()
    $global:LASTEXITCODE = $proc.ExitCode
    return $out
}

function Test-TokenOnVolume {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    Push-Location $InstallDir
    try {
        for ($i = 0; $i -lt 15; $i++) {
            $raw = Invoke-ComposeExec exec -T api sh -c "if [ -f /env/.env.production ]; then grep -m1 '^NCOMMERCE_SERVER_TOKEN=' /env/.env.production || true; else echo __NOFILE__; fi"
            if ($LASTEXITCODE -ne 0) {
                Start-Sleep -Seconds 1
                continue
            }
            $text = "$(@($raw) | Select-Object -Last 1)".Trim()
            if (-not $text -or $text -eq "__NOFILE__") { return $false }
            if ($text -notlike "NCOMMERCE_SERVER_TOKEN=*") {
                Start-Sleep -Seconds 1
                continue
            }
            $value = $text.Substring("NCOMMERCE_SERVER_TOKEN=".Length).Trim().Trim("'").Trim('"')
            return [bool]$value
        }
        return $false
    } finally {
        Pop-Location
        $ErrorActionPreference = $prev
    }
}

function Get-DockerSetup([string]$OutFile) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $code = & curl.exe -sS -m 5 -H "Host: localhost" -o $OutFile -w "%{http_code}" "http://127.0.0.1:3000/api/v1/docker_setup"
    $curlCode = $LASTEXITCODE
    $ErrorActionPreference = $prev
    if ($curlCode -ne 0 -or -not $code) { return "000" }
    $text = "$code".Trim()
    if ($text -match '(\d{3})\s*$') { return $Matches[1] }
    return "000"
}

function Invoke-DockerLogin([string]$Registry, [string]$User, [string]$Token) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $DockerExe
    $psi.Arguments = "login `"$Registry`" --username `"$User`" --password-stdin"
    $psi.RedirectStandardInput = $true
    $psi.UseShellExecute = $false
    $proc = [System.Diagnostics.Process]::Start($psi)
    $proc.StandardInput.Write($Token)
    $proc.StandardInput.Close()
    $proc.WaitForExit()
    if ($proc.ExitCode -ne 0) { Fail "docker login falhou." }
}

function Restore-CompanyBackup([string]$Token) {
    $zip = Join-Path $InstallDir "ncommerce.zip"
    $marker = Join-Path $InstallDir ".backup-restored"
    if ((Test-Path $marker) -or -not (Test-Path $zip)) { return }
    if ($Token.Length -lt 6) { Fail "Token curto demais para abrir o backup." }
    $pass = $Token.Substring(0, 6)
    Write-Host "Restaurando o banco no container..."

    $restore = @'
set -e
cd /tmp/ncommerce-restore
if [ ! -f backup.sql ]; then
  echo "sem backup.sql"
  exit 1
fi
if [ -f docs.zip ]; then unzip -o docs.zip -d /tmp/ncommerce-restore >/dev/null; fi
if [ -f nfce.zip ]; then unzip -o nfce.zip -d /tmp/ncommerce-restore >/dev/null; fi
mysql -h mysql -uroot -pncommerce_root -e "CREATE DATABASE IF NOT EXISTS ncommerce_api_production CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
mysql -h mysql -uroot -pncommerce_root ncommerce_api_production < backup.sql
if [ -d business_docs ]; then cp -a business_docs /app/ncommerce_api/; fi
if [ -d essentials ]; then cp -a essentials /data/nfce/; fi
if [ -d notas_output ]; then cp -a notas_output /data/nfce/; fi
if [ -f printers.conf ]; then cp -a printers.conf /etc/cups/printers.conf; fi
rm -rf /tmp/ncommerce.zip /tmp/ncommerce-restore /tmp/ncommerce-restore.sh
'@
    $restore = $restore -replace "`r`n", "`n" -replace "`r", "`n"
    if (-not $restore.EndsWith("`n")) { $restore += "`n" }
    $scriptFile = New-TemporaryFile
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($scriptFile.FullName, $restore, $utf8)

    Push-Location $InstallDir
    $ErrorActionPreference = "Continue"
    & $DockerExe compose cp $zip "api:/tmp/ncommerce.zip"
    $copyCode = $LASTEXITCODE
    if ($copyCode -eq 0) {
        Invoke-ComposeExec exec -T api unzip -P $pass -o /tmp/ncommerce.zip -d /tmp/ncommerce-restore | Out-Null
        $copyCode = $LASTEXITCODE
    }
    if ($copyCode -eq 0) {
        & $DockerExe compose cp $scriptFile.FullName "api:/tmp/ncommerce-restore.sh"
        $copyCode = $LASTEXITCODE
    }
    if ($copyCode -eq 0) {
        Invoke-ComposeExec exec -T api sh /tmp/ncommerce-restore.sh | Out-Null
        $copyCode = $LASTEXITCODE
    }
    $ErrorActionPreference = "Stop"
    Pop-Location
    Remove-Item $scriptFile.FullName -Force -ErrorAction SilentlyContinue
    if ($copyCode -ne 0) {
        Fail "Nao abri o backup. A senha sao os 6 primeiros caracteres do token, e o zip ficou em $zip."
    }
    New-Item -ItemType File -Force -Path $marker | Out-Null
    Write-Host "Backup restaurado nos containers."
}

function Enable-OpenSshServer {
    Write-Host "Abrindo o SSH na porta 22..."
    try {
        $cap = Get-WindowsCapability -Online -ErrorAction Stop |
            Where-Object { $_.Name -like "OpenSSH.Server*" } |
            Select-Object -First 1
        if (-not $cap) {
            Write-Host "Este Windows nao oferece o servidor OpenSSH."
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
        Write-Host "SSH do Windows na porta 22. Use o usuario e a senha desta conta."
    } catch {
        Write-Host "Nao consegui ligar o SSH: $($_.Exception.Message)"
    }
}

Enable-OpenSshServer

# AnyDesk para o suporte entrar na tela do cliente. Falha aqui nao para a instalacao.
function Install-AnyDesk {
    $paths = @("${env:ProgramFiles(x86)}\AnyDesk\AnyDesk.exe", "$env:ProgramFiles\AnyDesk\AnyDesk.exe")
    if ($paths | Where-Object { Test-Path $_ }) {
        Write-Host "AnyDesk ja instalado."
        return
    }
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Host "Sem winget. Instale o AnyDesk depois em https://anydesk.com."
        return
    }
    Write-Host "Instalando o AnyDesk..."
    & winget install --exact --id AnyDeskSoftwareGmbH.AnyDesk --accept-package-agreements --accept-source-agreements --disable-interactivity
    if (-not ($paths | Where-Object { Test-Path $_ })) {
        Write-Host "Nao consegui instalar o AnyDesk. Instale depois em https://anydesk.com."
    }
}

Install-AnyDesk

function Get-AnyDeskExe {
    return @("${env:ProgramFiles(x86)}\AnyDesk\AnyDesk.exe", "$env:ProgramFiles\AnyDesk\AnyDesk.exe") |
        Where-Object { Test-Path $_ } | Select-Object -First 1
}

# Senha do acesso nao supervisionado. E a mesma em todos os clientes, por isso vem
# do mestre no resgate do codigo e nao fica escrita neste arquivo nem no disco.
function Set-AnyDeskPassword([string]$Password) {
    $exe = Get-AnyDeskExe
    if (-not $Password -or -not $exe) { return }
    $ErrorActionPreference = "Continue"
    $Password | & $exe --set-password | Out-Null
    $code = $LASTEXITCODE
    $ErrorActionPreference = "Stop"
    if ($code -eq 0) {
        Write-Host "Acesso nao supervisionado do AnyDesk configurado."
    } else {
        Write-Host "Nao consegui configurar a senha do AnyDesk."
    }
}

# O Windows nao deixa programa fixar icone na barra de tarefas. O atalho fica na Area de Trabalho,
# para o suporte dizer "abra o AnyDesk da Area de Trabalho".
function New-AnyDeskShortcut {
    $exe = Get-AnyDeskExe
    $desktop = [Environment]::GetFolderPath("Desktop")
    if (-not $exe -or -not $desktop) { return }
    $lnk = Join-Path $desktop "AnyDesk - Suporte NCommerce.lnk"
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($lnk)
    $shortcut.TargetPath = $exe
    $shortcut.WorkingDirectory = Split-Path -Parent $exe
    $shortcut.Description = "Acesso remoto do suporte NCommerce"
    $shortcut.Save()
    Write-Host "Atalho: $lnk"
}

New-AnyDeskShortcut

if (-not (Get-Command curl.exe -CommandType Application -ErrorAction SilentlyContinue)) {
    Fail "Este Windows nao tem curl.exe."
}

$installCode = Read-InstallCode
$grant = Get-InstallGrant $installCode
Set-AnyDeskPassword ([string]$grant.anydesk_password)
$grant.PSObject.Properties.Remove("anydesk_password")
$ncommerceToken = [string]$grant.token
$gitKey = [string]$grant.git_private_key
Clone-Repos $gitKey
$gitKey = $null

if (-not (Test-Path $DockerExe)) {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Fail "Docker Desktop nao esta instalado e o winget nao existe. Instale o Docker Desktop e rode este arquivo de novo."
    }
    Write-Host "Instalando Docker Desktop. Isso pode levar varios minutos."
    & winget install --exact --id Docker.DockerDesktop --accept-package-agreements --accept-source-agreements --disable-interactivity
    if (-not (Test-Path $DockerExe)) {
        Fail "Docker Desktop nao apareceu. Se o Windows pediu reinicio, reinicie e rode o instalador de novo."
    }
}

if (-not (Test-DockerReady)) {
    if (Test-Path $DockerDesktop) { Start-Process $DockerDesktop }
    Write-Host "Esperando o Docker Desktop ficar pronto..."
    $ready = $false
    for ($i = 0; $i -lt 60; $i++) {
        if (Test-DockerReady) { $ready = $true; break }
        Start-Sleep -Seconds 5
    }
    if (-not $ready) {
        Fail "O Docker nao ficou pronto. Abra o Docker Desktop, conclua o primeiro uso e rode este instalador de novo."
    }
}

$cupsPort = 631
$listen = Get-NetTCPConnection -LocalPort 631 -State Listen -ErrorAction SilentlyContinue
if ($listen) {
    $cupsPort = 6631
    Write-Host "A porta 631 ja esta em uso. O CUPS do container fica em http://127.0.0.1:6631."
}

$composeSrc = Join-Path $Root "docker\docker-compose.yml"
$startupSrc = Join-Path $Root "windows\ncommerce-docker-startup.bat"
$updateSrc = Join-Path $Root "windows\ncommerce-docker-update.bat"
if (-not (Test-Path $composeSrc)) { Fail "Nao achei $composeSrc." }
if (-not (Test-Path $startupSrc)) { Fail "Nao achei $startupSrc." }

New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
Copy-Item $composeSrc (Join-Path $InstallDir "docker-compose.yml") -Force
Copy-Item $startupSrc (Join-Path $InstallDir "ncommerce-docker-startup.bat") -Force
Copy-Item $updateSrc (Join-Path $InstallDir "ncommerce-docker-update.bat") -Force
Copy-Item (Join-Path $Root "windows\refresh-host-ips.ps1") (Join-Path $InstallDir "refresh-host-ips.ps1") -Force
Copy-Item (Join-Path $Root "windows\anydesk-id.ps1") (Join-Path $InstallDir "anydesk-id.ps1") -Force
Copy-Item (Join-Path $Root "windows\usb-printers.ps1") (Join-Path $InstallDir "usb-printers.ps1") -Force
Copy-Item (Join-Path $Root "windows\drivers") $InstallDir -Recurse -Force

$envFile = Join-Path $InstallDir ".env"
$registry = $env:NCOMMERCE_REGISTRY
if (-not $registry) { $registry = [string]$grant.registry }
if (-not $registry) { $registry = Read-EnvValue $envFile "NCOMMERCE_REGISTRY" "ncommerce.app:5050" }
$tag = $env:NCOMMERCE_TAG
if (-not $tag) { $tag = Read-EnvValue $envFile "NCOMMERCE_TAG" "latest" }
$envBody = "CUPS_PORT=$cupsPort`nNCOMMERCE_REGISTRY=$registry`nNCOMMERCE_TAG=$tag`n"
[System.IO.File]::WriteAllText($envFile, $envBody)
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $InstallDir "refresh-host-ips.ps1") $InstallDir
if ($LASTEXITCODE -ne 0) { Fail "Nao consegui gravar os IPs desta maquina." }
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $InstallDir "anydesk-id.ps1") $InstallDir

foreach ($port in @(3000, 4200)) {
    $name = "NCommerce TCP $port"
    $existing = Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue
    if (-not $existing) {
        New-NetFirewallRule -DisplayName $name -Direction Inbound -Protocol TCP -LocalPort $port -Action Allow | Out-Null
    }
}

$startup = Join-Path $InstallDir "ncommerce-docker-startup.bat"
Write-Host "Registrando a tarefa de logon $TaskName ..."
& schtasks.exe /create /tn $TaskName /tr $startup /sc onlogon /rl LIMITED /f | Out-Null
if ($LASTEXITCODE -ne 0) { Fail "Nao consegui criar a tarefa $TaskName." }

if (-not $grant.company) { Fail "O resgate nao trouxe o nome da empresa para entrar no registry." }
Write-Host "Entrando no registry $registry como $($grant.company)..."
Invoke-DockerLogin $registry ([string]$grant.company) $ncommerceToken

Write-Host "Baixando as imagens e subindo a stack..."
$ErrorActionPreference = "Continue"
Push-Location $InstallDir
& $DockerExe compose pull
if ($LASTEXITCODE -ne 0) {
    Pop-Location
    Fail "docker compose pull falhou."
}
& $DockerExe compose up -d
$upCode = $LASTEXITCODE
Pop-Location
$ErrorActionPreference = "Stop"
if ($upCode -ne 0) { Fail "docker compose up falhou." }

$skipTokenPost = $false
if (Test-TokenOnVolume) {
    Write-Host "O token desta maquina ja esta gravado."
    $skipTokenPost = $true
} else {
    Write-Host "Esperando a API para gravar o token..."
    $apiReady = $false
    $setupHttp = "000"
    $probe = New-TemporaryFile
    for ($i = 1; $i -le 90; $i++) {
        $setupHttp = Get-DockerSetup $probe.FullName
        if ($setupHttp -eq "200") { $apiReady = $true; break }
        if ($i % 5 -eq 0) {
            Write-Host "A API ainda nao aceitou o setup (HTTP $setupHttp)."
        }
        Start-Sleep -Seconds 4
    }
    Remove-Item $probe.FullName -Force -ErrorAction SilentlyContinue
    if (-not $apiReady) {
        if (Test-TokenOnVolume) {
            Write-Host "O token desta maquina ja esta gravado."
            $skipTokenPost = $true
        } else {
            $ErrorActionPreference = "Continue"
            Push-Location $InstallDir
            & $DockerExe compose ps
            & $DockerExe compose logs --tail 60 api
            Pop-Location
            $ErrorActionPreference = "Stop"
            Fail "A API nao aceitou o setup (ultimo HTTP $setupHttp) e nao ha token no volume."
        }
    }
}

Save-CompanyBackup $installCode
Restore-CompanyBackup $ncommerceToken

if (-not $skipTokenPost) {
    $setupFile = New-TemporaryFile
    $setupCode = Get-DockerSetup $setupFile.FullName
    $already = $false
    if ($setupCode -eq "200") {
        $setupRaw = Get-Content -Raw -Path $setupFile.FullName
        if ($setupRaw -match '"setup_required"\s*:\s*false') { $already = $true }
    }
    Remove-Item $setupFile.FullName -Force
    if ($already) {
        Write-Host "O token desta maquina ja esta gravado."
    } else {
        $payloadFile = New-TemporaryFile
        $answerFile = New-TemporaryFile
        [System.IO.File]::WriteAllText($payloadFile.FullName, (@{ token = $ncommerceToken } | ConvertTo-Json -Compress))
        $ErrorActionPreference = "Continue"
        $postHttp = & curl.exe -sS -m 40 -H "Host: localhost" -H "Content-Type: application/json" --data-binary "@$($payloadFile.FullName)" -o $answerFile.FullName -w "%{http_code}" "http://127.0.0.1:3000/api/v1/docker_setup"
        $postCode = $LASTEXITCODE
        $ErrorActionPreference = "Stop"
        $answer = ""
        if (Test-Path $answerFile.FullName) { $answer = Get-Content -Raw -Path $answerFile.FullName }
        Remove-Item $payloadFile.FullName -Force
        Remove-Item $answerFile.FullName -Force
        if ($postCode -ne 0 -or "$postHttp".Trim() -ne "200" -or $answer -notmatch '"ok"\s*:\s*true') {
            Fail "A API recusou o token (HTTP $postHttp). $answer"
        }
        if (-not (Test-TokenOnVolume)) { Fail "A API nao gravou /env/.env.production." }
        Write-Host "Token gravado."
    }
}
$ncommerceToken = $null

function New-UpdateShortcut {
    $desktop = [Environment]::GetFolderPath("Desktop")
    if (-not $desktop) {
        Write-Host "Nao achei a Area de Trabalho para o atalho."
        return
    }
    $lnk = Join-Path $desktop "Atualizar NCommerce.lnk"
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($lnk)
    $shortcut.TargetPath = "cmd.exe"
    $shortcut.Arguments = '/c "' + (Join-Path $InstallDir "ncommerce-docker-update.bat") + ' & pause"'
    $shortcut.WorkingDirectory = $InstallDir
    $shortcut.WindowStyle = 1
    $shortcut.Description = "Baixa a versao publicada e recria os containers"
    $shortcut.Save()
    Write-Host "Atalho: $lnk"
}

New-UpdateShortcut

# Impressora USB: o container imprime por LPD na impressora compartilhada do Windows.
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $InstallDir "usb-printers.ps1")

$siteHost = "localhost"
$ipsLine = Get-Content $envFile | Where-Object { $_ -like "NCOMMERCE_HOST_IPS=*" } | Select-Object -Last 1
if ($ipsLine) {
    $firstIp = ($ipsLine.Substring("NCOMMERCE_HOST_IPS=".Length) -split ",")[0]
    if ($firstIp) { $siteHost = $firstIp }
}

Write-Host ""
Write-Host "NCommerce no ar."
Write-Host "  Site:  http://${siteHost}:4200"
Write-Host "  API:   http://localhost:3000"
Write-Host "  CUPS:  http://127.0.0.1:$cupsPort"
Write-Host "  SSH:   porta 22, usuario e senha desta conta do Windows"
Write-Host "Codigo-fonte em C:\NCommerce\src (ncommerce_api, ncommerce, nfce)."
Write-Host "A tarefa '$TaskName' sobe a stack quando alguem entra no Windows."
Write-Host "Depois de uma queda de energia o PC precisa logar sozinho: netplwiz."
Write-Host "Atualizar: atalho Atualizar NCommerce na Area de Trabalho."
Write-Host "Impressora USB plugada depois: rode $InstallDir\usb-printers.ps1 como admin."
