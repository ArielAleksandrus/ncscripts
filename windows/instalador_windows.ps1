#Requires -RunAsAdministrator
<#
  Instalador Docker do NCommerce no Windows.

  Usa o codigo de 8 caracteres do codigo-instalacao.txt, que vem no zip
  de ncommerce.app/instalar, ou pede para digitar. O mestre troca esse codigo, uma vez,
  pelo token da empresa. O PC recebe so as imagens do registry, sem codigo-fonte.
  Reexecutar nao apaga volume.

  -IgnorarRequisitos instala num PC abaixo do minimo (suporte, por conta e risco).
  -Backup ARQUIVO.zip restaura este zip de backup em vez do backup do mestre.
                     Sem a opcao, o instalador pergunta: arraste o zip para a
                     janela ou tecle Enter para usar o do mestre.
  -Reinstalar        pede o codigo de novo mesmo com a loja ja instalada.
  -Retomada          uso interno: a tarefa de retomada chama assim no logon.

  Pode ser interrompido em qualquer ponto (janela fechada, Ctrl+C, queda de
  energia, reinicio) e aberto de novo: cada etapa confere o que ja existe antes
  de fazer. O progresso fica em C:\ProgramData\NCommerce\instalacao.estado e o
  log de cada execucao em C:\NCommerce\logs. Enquanto a instalacao nao termina,
  a tarefa "NCommerce Instalador Retomar" abre o instalador sozinha no proximo
  logon. Num PC com a loja ja instalada ele so confere e conserta, sem pedir
  codigo e sem tocar nos dados.
#>
param([switch]$IgnorarRequisitos, [string]$Backup = "", [switch]$Reinstalar, [switch]$Retomada)

$ErrorActionPreference = "Stop"
$InstallDir = "C:\NCommerce"
$DataDir = Join-Path $env:ProgramData "NCommerce"
$TaskName = "NCommerce Docker Startup"
$ResumeTaskName = "NCommerce Instalador Retomar"
$MaxAutoResumes = 3
$DefaultRegistry = "registry.ncommerce.app:5050"
$OldRegistry = "ncommerce.app:5050"
if ($env:NCOMMERCE_MASTER_URL) {
    $MasterUrl = $env:NCOMMERCE_MASTER_URL
} else {
    $MasterUrl = "https://api.ncommerce.app"
}
$DockerExe = Join-Path $env:ProgramFiles "Docker\Docker\resources\bin\docker.exe"
$DockerDesktop = Join-Path $env:ProgramFiles "Docker\Docker\Docker Desktop.exe"
# Este script fica em windows/; a raiz do ncscripts (docker/, windows/, codigo-instalacao.txt) e a pasta acima.
$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)

# O InstaladorWindows.bat confere este arquivo para saber se o PowerShell chegou
# a rodar o script (antivirus e politica de execucao barram antes disso).
try { [System.IO.File]::WriteAllText((Join-Path $env:TEMP "ncommerce-instalador-iniciou.flag"), "1") } catch { }

$lib = Join-Path $PSScriptRoot "instalador-lib.ps1"
if (-not (Test-Path -LiteralPath $lib) -or -not (Test-Path -LiteralPath (Join-Path $Root "docker\docker-compose.yml"))) {
    Write-Host ""
    Write-Host "Faltam arquivos do instalador nesta pasta: $Root" -ForegroundColor Red
    Write-Host "Extraia o zip do instalador inteiro (botao direito no zip > Extrair tudo) e abra o"
    Write-Host "InstaladorWindows.bat de dentro da pasta extraida."
    exit 1
}
. $lib

$script:NcStepTotal = 10
$script:Verdict = ""
$script:Mode = "instalacao"
$script:StoreAlreadyLive = $false
$script:Lock = $null

# ============================================================ fim e falha

function Show-Failure([string]$What, [string]$Hint) {
    Say ""
    Say "==================================================================" "Red"
    Say "  A INSTALACAO NAO TERMINOU." "Red"
    Say "==================================================================" "Red"
    if ($script:NcStepNow -gt 0) {
        Say ("Parou na etapa {0} de {1}: {2}." -f $script:NcStepNow, $script:NcStepTotal, $script:NcStepTitle)
    }
    Say "O que aconteceu: $What"
    if ($Hint) {
        Say "O que fazer: $Hint"
    } else {
        Say "O que fazer: abra o InstaladorWindows.bat de novo. Ele continua de onde parou e nao apaga nada."
    }
    if ($script:NcLogFile) {
        Say "Se parar de novo no mesmo ponto, mande este arquivo para o suporte NCommerce:"
        Say "  $($script:NcLogFile)"
    }
}

function Close-Installer {
    Restore-NcConsole
    Exit-NcLock $script:Lock
    $script:Lock = $null
}

# Para a instalacao com o motivo e o que fazer.
function Fail([string]$What, [string]$Hint = "") {
    Undo-LiveStoreChanges
    Show-Failure $What $Hint
    $script:Verdict = "falha"
    Close-Installer
    exit 1
}

# ---- Volta ao estado anterior. Numa loja que ja funcionava, esta execucao
# guarda antes (Save-LiveStoreSnapshot) o compose, o .env e as imagens em uso.
# Se ela falhar e a loja ficar sem responder, tudo volta e a loja e religada.
$script:SnapTaken = $false
$script:RollingBack = $false
function Get-SnapDir { return (Join-Path $InstallDir "control\antes-da-instalacao") }

# Uma copia de uma execucao anterior que nao terminou fica: ela e a da loja de
# antes. Copia com mais de 2 dias nao serve mais (a loja pode ter sido atualizada).
function Save-LiveStoreSnapshot {
    if (-not $script:StoreAlreadyLive) { return }
    $dir = Get-SnapDir
    $images = Join-Path $dir "imagens"
    if ([System.IO.File]::Exists($images) -and [System.IO.File]::GetLastWriteTime($images) -lt (Get-Date).AddDays(-2)) {
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ((Get-NcFileLength $images) -gt 0) {
        $script:SnapTaken = $true
        return
    }
    $tmp = "$dir.tmp"
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    foreach ($f in @("docker-compose.yml", ".env")) {
        $src = Join-Path $InstallDir $f
        if ([System.IO.File]::Exists($src)) { [System.IO.File]::Copy($src, (Join-Path $tmp $f), $true) }
    }
    $envFile = Join-Path $InstallDir ".env"
    $line = "{0}|{1}|{2}|{3}" -f (Get-ServiceImage "api"), (Get-ServiceImage "web"),
        (Get-EnvValue $envFile "NCOMMERCE_TAG" "latest"), (Get-EnvValue $envFile "NCOMMERCE_REGISTRY" $DefaultRegistry)
    Write-FileAtomic (Join-Path $tmp "imagens") "$line`n"
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    [System.IO.Directory]::Move($tmp, $dir)
    $script:SnapTaken = $true
    Write-NcLog "Copia da loja de antes guardada em $dir ($line)."
}

function Remove-LiveStoreSnapshot {
    if (-not $script:SnapTaken) { return }
    Remove-Item -LiteralPath (Get-SnapDir), "$(Get-SnapDir).tmp" -Recurse -Force -ErrorAction SilentlyContinue
    $script:SnapTaken = $false
}

function Get-SnapshotImages {
    $images = Join-Path (Get-SnapDir) "imagens"
    if ((Get-NcFileLength $images) -le 0) { return $null }
    $f = ([System.IO.File]::ReadAllText($images).Trim()) -split '\|'
    if ($f.Count -lt 4) { return $null }
    return @{ Api = $f[0]; Web = $f[1]; Tag = $f[2]; Registry = $f[3] }
}

# A etiqueta "latest" de api e web volta para as imagens de antes.
function Restore-SnapshotTags {
    if (-not $script:SnapTaken) { return }
    $img = Get-SnapshotImages
    if (-not $img) { return }
    Restore-LatestTags $img.Registry $img.Tag $img.Api $img.Web
}

function Undo-LiveStoreChanges {
    if (-not $script:SnapTaken -or $script:RollingBack) { return }
    $script:RollingBack = $true
    try {
        # Loja respondendo: nada a desfazer. A proxima execucao continua de onde parou.
        if (Wait-ApiUp 10) { return }
        $dir = Get-SnapDir
        Say ""
        Say "A loja nao esta respondendo. Voltando os arquivos e a versao de antes desta instalacao..." "Yellow"
        foreach ($f in @("docker-compose.yml", ".env")) {
            $src = Join-Path $dir $f
            if ([System.IO.File]::Exists($src)) { Copy-FileAtomic $src (Join-Path $InstallDir $f) | Out-Null }
        }
        Restore-SnapshotTags
        $wait = 180
        if ($env:NCOMMERCE_ROLLBACK_WAIT_S) { $wait = [int]$env:NCOMMERCE_ROLLBACK_WAIT_S }
        if ((Invoke-Compose -Arguments @("up", "-d") -Quiet) -eq 0 -and (Wait-ApiUp $wait)) {
            Remove-LiveStoreSnapshot
            Say "A LOJA VOLTOU PARA COMO ESTAVA ANTES DESTA INSTALACAO e esta respondendo." "Yellow"
        } else {
            Say "NAO consegui religar a loja como estava. Chame o suporte NCommerce agora." "Red"
            Say "A copia dos arquivos de antes esta em $dir."
        }
    } catch {
        Write-NcLog "Volta ao estado anterior: $($_.Exception.Message)"
    } finally {
        $script:RollingBack = $false
    }
}

# A versao nova baixada por cima de uma loja que funcionava (-Reinstalar,
# -Backup): se ela muda o banco, uma copia dele fica antes, como na atualizacao.
function Save-DumpIfDbChanges {
    if (-not $script:SnapTaken) { return }
    $img = Get-SnapshotImages
    if (-not $img -or -not $img.Api) { return }
    $newApi = Get-ImageId "$($script:Registry)/ncommerce/api:$($script:Tag)"
    if (-not $newApi -or $newApi -eq $img.Api) { return }
    $migration = "ls /app/ncommerce_api/db/migrate 2>/dev/null | sort | tail -n 1 | cut -c1-14"
    $oldMig = Get-DockerText @("run", "--rm", "--network", "none", "--entrypoint", "sh", $img.Api, "-c", $migration)
    $newMig = Get-DockerText @("run", "--rm", "--network", "none", "--entrypoint", "sh", $newApi, "-c", $migration)
    if ($oldMig -and $oldMig -eq $newMig) { return }
    Say "A versao baixada muda o banco de dados."
    if (-not (Save-DatabaseDump "antes-de-atualizar")) {
        Restore-SnapshotTags
        Fail "nao consegui guardar uma copia do banco antes de trocar de versao." `
            "nada foi trocado. Confira o espaco em disco e abra de novo, ou chame o suporte NCommerce."
    }
}

# ============================================================ ajudantes

function Get-UnixTime { return [int64][DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }

function Read-InstallCode {
    while ($true) {
        $raw = Read-Host "Codigo de instalacao (8 caracteres)"
        $code = (("$raw" -replace "[\s\-]", "").ToUpper())
        if ($code -match "^[A-Z0-9]{8}$") { return $code }
        Say "Use 8 letras ou numeros."
    }
}

# O zip baixado em ncommerce.app/instalar traz o codigo neste arquivo, para o cliente nao digitar.
function Read-CodeFile {
    $file = Join-Path $Root "codigo-instalacao.txt"
    if (-not (Test-Path -LiteralPath $file)) { return $null }
    $code = ("$(Get-Content -Raw -LiteralPath $file)" -replace "[\s\-]", "").ToUpper()
    if ($code -match "^[A-Z0-9]{8}$") { return $code }
    return $null
}

# ---- Aviso por WhatsApp depois de um reinicio (tarefa SYSTEM na inicializacao).
# Nome igual ao de windows/aviso-reinicio.ps1.
$RebootTaskName = "NCommerce Aviso Reinicio"

function Clear-RebootNotice {
    try {
        Unregister-ScheduledTask -TaskName $RebootTaskName -Confirm:$false -ErrorAction SilentlyContinue
        foreach ($name in @("aviso-reinicio.ps1", "aviso-reinicio.json", "aviso-reinicio-body.json", "aviso-reinicio-out.txt")) {
            Remove-Item -LiteralPath (Join-Path $DataDir $name) -Force -ErrorAction SilentlyContinue
        }
    } catch {
        Write-NcLog "Nao consegui remover o aviso de reinicio anterior: $($_.Exception.Message)"
    }
}

function Send-RebootNoticeNow([string]$Code) {
    $payloadFile = New-TemporaryFile
    $bodyFile = New-TemporaryFile
    try {
        $payload = @{ code = $Code; hostname = $env:COMPUTERNAME } | ConvertTo-Json -Compress
        [System.IO.File]::WriteAllText($payloadFile.FullName, $payload)
        $ErrorActionPreference = "Continue"
        $http = & curl.exe -sS -o $bodyFile.FullName -w "%{http_code}" --max-time 20 `
            -X POST -H "Content-Type: application/json" --data-binary "@$($payloadFile.FullName)" `
            "$MasterUrl/install/reboot_notice" 2>$null
        return ("$http".Trim() -eq "200")
    } catch {
        return $false
    } finally {
        Remove-Item $payloadFile.FullName, $bodyFile.FullName -Force -ErrorAction SilentlyContinue
    }
}

# Agenda o aviso para a proxima inicializacao. Sem a tarefa, avisa na hora.
# Sem codigo-instalacao.txt nao ha como saber de quem e o WhatsApp.
function Register-RebootNotice {
    $code = Read-CodeFile
    if (-not $code) { return $false }
    try {
        New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
        $scriptSrc = Join-Path $PSScriptRoot "aviso-reinicio.ps1"
        if (-not (Test-Path -LiteralPath $scriptSrc)) { throw "Nao achei $scriptSrc." }
        $scriptDst = Join-Path $DataDir "aviso-reinicio.ps1"
        Copy-FileAtomic $scriptSrc $scriptDst | Out-Null
        $config = @{ code = $code; master_url = $MasterUrl; task_name = $RebootTaskName } | ConvertTo-Json -Compress
        Write-FileAtomic (Join-Path $DataDir "aviso-reinicio.json") $config

        $ps = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
        $action = New-ScheduledTaskAction -Execute $ps -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptDst`""
        $boot = New-ScheduledTaskTrigger -AtStartup
        try { $boot.Delay = "PT45S" } catch { }
        $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
            -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 6)
        Register-ScheduledTask -TaskName $RebootTaskName -Action $action -Trigger $boot -Principal $principal `
            -Settings $settings -Description "Avisa o NCommerce para mandar WhatsApp pedindo o InstaladorWindows.bat." -Force | Out-Null
        Say "Quando o computador ligar, o WhatsApp do cadastro tambem recebe um aviso."
        return $true
    } catch {
        Write-NcLog "Nao consegui agendar o aviso de reinicio: $($_.Exception.Message)"
        return (Send-RebootNoticeNow $code)
    }
}

# ---- Retomada automatica. Enquanto a instalacao nao termina, esta tarefa abre
# o InstaladorWindows.bat no proximo logon deste usuario, ja como administrador
# (sem a pergunta do Windows). Cobre o reinicio que o WSL2 pede e tambem queda
# de energia. Sai quando a instalacao termina ou depois de $MaxAutoResumes vezes.
function Register-ResumeTask {
    try {
        $bat = Join-Path $Root "InstaladorWindows.bat"
        if (-not (Test-Path -LiteralPath $bat)) { return $false }
        $extra = "-Retomada"
        if ($IgnorarRequisitos) { $extra += " -IgnorarRequisitos" }
        # Se a pasta do instalador for apagada, a tarefa se remove sozinha.
        $argument = "/c if exist `"$bat`" (`"$bat`" $extra) else (schtasks /delete /tn `"$ResumeTaskName`" /f)"
        $action = New-ScheduledTaskAction -Execute (Join-Path $env:SystemRoot "System32\cmd.exe") -Argument $argument
        $user = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
        try { $trigger.Delay = "PT20S" } catch { }
        $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
            -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 3)
        Register-ScheduledTask -TaskName $ResumeTaskName -Action $action -Trigger $trigger -Principal $principal `
            -Settings $settings -Description "Continua a instalacao do NCommerce que nao terminou." -Force | Out-Null
        return $true
    } catch {
        Write-NcLog "Nao consegui agendar a retomada: $($_.Exception.Message)"
        return $false
    }
}

function Clear-ResumeTask {
    try {
        Unregister-ScheduledTask -TaskName $ResumeTaskName -Confirm:$false -ErrorAction SilentlyContinue
    } catch { }
}

function Get-MachineId {
    New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
    $file = Join-Path $DataDir "machine-id"
    $value = ""
    if (Test-Path -LiteralPath $file) { $value = "$(Get-Content -Raw -LiteralPath $file)".Trim() }
    # Arquivo vazio ou estragado (queda de energia na criacao) nao pode travar o instalador.
    if ($value -notmatch '^[0-9A-Za-z\-]{16,64}$') {
        $value = [guid]::NewGuid().ToString()
        Write-FileAtomic $file $value
    }
    return $value
}

# Troca o codigo pelo token. Devolve o objeto do mestre; $null quando o codigo
# foi recusado; a palavra "sem-resposta" quando o mestre nao respondeu.
# O mestre aceita o mesmo codigo de novo neste computador (machine_id).
function Get-InstallGrant([string]$Code) {
    $machineId = Get-MachineId
    $payloadFile = New-TemporaryFile
    $bodyFile = New-TemporaryFile
    try {
        $payload = @{ code = $Code; machine_id = $machineId; hostname = $env:COMPUTERNAME } | ConvertTo-Json -Compress
        [System.IO.File]::WriteAllText($payloadFile.FullName, $payload)
        $http = "000"
        for ($i = 1; $i -le 3; $i++) {
            $ErrorActionPreference = "Continue"
            $http = & curl.exe -sS -o $bodyFile.FullName -w "%{http_code}" --connect-timeout 15 --max-time 30 `
                -X POST -H "Content-Type: application/json" --data-binary "@$($payloadFile.FullName)" `
                "$MasterUrl/install/redeem" 2>$null
            $ErrorActionPreference = "Stop"
            $http = "$http".Trim()
            if ($http -match '^[1-4]\d\d$') { break }
            if ($i -lt 3) { Start-Sleep -Seconds (5 * $i) }
        }
        if ($http -notmatch '^[1-4]\d\d$') {
            Say "O servidor do NCommerce nao respondeu (HTTP $http)."
            return "sem-resposta"
        }
        if ($http -ne "200") {
            $detail = ""
            try { $detail = "$(Get-Content -Raw -LiteralPath $bodyFile.FullName -ErrorAction SilentlyContinue)" } catch { }
            if ($detail.Length -gt 300) { $detail = $detail.Substring(0, 300) }
            Say "Codigo $Code recusado (HTTP $http). $detail"
            return $null
        }
        try {
            $grant = Get-Content -Raw -LiteralPath $bodyFile.FullName | ConvertFrom-Json
        } catch {
            Say "A resposta do servidor nao veio no formato esperado."
            return "sem-resposta"
        }
        if (-not $grant.token) { $grant | Add-Member -NotePropertyName token -NotePropertyValue $grant.ncommerce_token -Force }
        if (-not $grant.token -or -not $grant.company) {
            Say "A resposta do servidor veio incompleta (sem o token ou sem o nome da empresa)."
            return "sem-resposta"
        }
        return $grant
    } finally {
        Remove-Item $payloadFile.FullName, $bodyFile.FullName -Force -ErrorAction SilentlyContinue
    }
}

function Test-DockerReady {
    if (-not (Test-Path -LiteralPath $DockerExe)) { return $false }
    $ErrorActionPreference = "Continue"
    & $DockerExe info *> $null
    return ($LASTEXITCODE -eq 0)
}

# Num Windows 10 recem-instalado o App Installer (winget) existe mas ainda nao foi registrado
# para o usuario. Registra antes de desistir.
function Initialize-Winget {
    if (Get-Command winget -ErrorAction SilentlyContinue) { return $true }
    try {
        Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe -ErrorAction Stop | Out-Null
    } catch {
        return $false
    }
    return [bool](Get-Command winget -ErrorAction SilentlyContinue)
}

# Baixa um instalador direto do fabricante quando o winget nao serve. O download
# continua de onde parou e o arquivo so e usado se a assinatura digital do
# fabricante conferir: arquivo cortado ou trocado no caminho nao roda.
function Get-SignedInstaller([string]$Url, [string]$Name, [string]$SignerPattern) {
    $dir = Join-Path $DataDir "downloads"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $part = Join-Path $dir "$Name.part"
    $final = Join-Path $dir $Name
    for ($round = 1; $round -le 2; $round++) {
        $http = Get-FileResumable $Url $part 5
        if ($http -ne "200" -and $http -ne "206" -and $http -ne "416") {
            Write-NcLog "Download de $Name falhou (HTTP $http)."
            return $null
        }
        Remove-Item -LiteralPath $final -Force -ErrorAction SilentlyContinue
        [System.IO.File]::Move($part, $final)
        $sig = Get-AuthenticodeSignature -LiteralPath $final
        if ($sig.Status -eq "Valid" -and "$($sig.SignerCertificate.Subject)" -match $SignerPattern) { return $final }
        # Pedaco velho ou arquivo danificado: recomeca do zero uma vez.
        Write-NcLog "Assinatura de $Name nao conferiu ($($sig.Status)). Baixando de novo."
        Remove-Item -LiteralPath $final -Force -ErrorAction SilentlyContinue
    }
    return $null
}

# O token fica em /env/.env.production, no volume da API. Da para ler isso
# enquanto o Rails ainda roda db:prepare e a porta 3000 nao responde.
function Test-TokenOnVolume([int]$Tries = 15) {
    $ErrorActionPreference = "Continue"
    for ($i = 0; $i -lt $Tries; $i++) {
        $raw = Invoke-ComposeExec exec -T api sh -c "if [ -f /env/.env.production ]; then grep -m1 '^NCOMMERCE_SERVER_TOKEN=' /env/.env.production || true; else echo __NOFILE__; fi"
        if ($LASTEXITCODE -ne 0) {
            if ($i -lt $Tries - 1) { Start-Sleep -Seconds 1 }
            continue
        }
        $text = "$(@($raw -split "`n") | Where-Object { $_.Trim() } | Select-Object -Last 1)".Trim()
        if (-not $text -or $text -eq "__NOFILE__") { return $false }
        if ($text -notlike "NCOMMERCE_SERVER_TOKEN=*") {
            if ($i -lt $Tries - 1) { Start-Sleep -Seconds 1 }
            continue
        }
        $value = $text.Substring("NCOMMERCE_SERVER_TOKEN=".Length).Trim().Trim("'").Trim('"')
        return [bool]$value
    }
    return $false
}

# O mesmo, com a API parada: le o volume api_env direto, com uma imagem que ja
# esta no computador.
function Test-TokenOnStoppedVolume {
    $ErrorActionPreference = "Continue"
    $project = (Split-Path -Leaf $InstallDir).ToLower()
    $volume = & $DockerExe volume ls -q --filter "label=com.docker.compose.project=$project" --filter "label=com.docker.compose.volume=api_env" 2>$null |
        Select-Object -First 1
    if (-not $volume) { return $false }
    foreach ($image in @("redis:7-alpine", "docker:27.5.1-cli", "mysql:8.0")) {
        & $DockerExe image inspect $image *> $null
        if ($LASTEXITCODE -ne 0) { continue }
        & $DockerExe run --rm --network none --entrypoint sh -v "${volume}:/env:ro" $image -c "grep -q '^NCOMMERCE_SERVER_TOKEN=..*' /env/.env.production" *> $null
        return ($LASTEXITCODE -eq 0)
    }
    return $false
}

# A loja ja foi instalada e configurada neste computador?
function Test-StoreInstalled {
    if (-not (Test-DockerReady)) { return $false }
    if (-not (Test-Path -LiteralPath (Join-Path $InstallDir "docker-compose.yml"))) { return $false }
    if (-not (Test-Path -LiteralPath (Join-Path $InstallDir ".env"))) { return $false }
    if (Test-TokenOnVolume 1) { return $true }
    return (Test-TokenOnStoppedVolume)
}

# A imagem publicada responde 403 para Host 127.0.0.1. localhost esta permitido.
function Get-DockerSetup([string]$OutFile) {
    $ErrorActionPreference = "Continue"
    $code = & curl.exe -sS -m 5 -H "Host: localhost" -o $OutFile -w "%{http_code}" "http://127.0.0.1:3000/api/v1/docker_setup" 2>$null
    $curlCode = $LASTEXITCODE
    if ($curlCode -ne 0 -or -not $code) { return "000" }
    $text = "$code".Trim()
    if ($text -match '(\d{3})\s*$') { return $Matches[1] }
    return "000"
}

# Espera a API responder ao docker_setup. Devolve $true quando respondeu 200.
function Wait-ApiUp([int]$Seconds) {
    $probe = New-TemporaryFile
    try {
        for ($waited = 0; $waited -lt $Seconds; $waited += 5) {
            if ((Get-DockerSetup $probe.FullName) -eq "200") { return $true }
            if ($waited -gt 0 -and ($waited % 30) -eq 0) {
                Say "  ainda esperando o sistema responder ($waited s de ate $Seconds s)..."
            }
            Start-Sleep -Seconds 5
        }
        return $false
    } finally {
        Remove-Item $probe.FullName -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-DockerLogin([string]$Registry, [string]$User, [string]$Token) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $DockerExe
    $psi.Arguments = "login `"$Registry`" --username `"$User`" --password-stdin"
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    $errTask = $proc.StandardError.ReadToEndAsync()
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $proc.StandardInput.Write($Token)
    $proc.StandardInput.Close()
    $proc.WaitForExit()
    Write-NcLog ("docker login: " + "$($outTask.Result) $($errTask.Result)".Trim())
    return ($proc.ExitCode -eq 0)
}

# Fuso do Windows no nome IANA que o container usa (TZ). O jar da NFC-e monta o
# dhEmi com `date`; em UTC a SEFAZ rejeita a nota (703, emissao no futuro).
function Get-IanaTimeZone {
    $map = @{
        "E. South America Standard Time" = "America/Sao_Paulo"
        "SA Eastern Standard Time" = "America/Fortaleza"
        "Bahia Standard Time" = "America/Bahia"
        "Tocantins Standard Time" = "America/Araguaina"
        "Central Brazilian Standard Time" = "America/Cuiaba"
        "SA Western Standard Time" = "America/Manaus"
        "SA Pacific Standard Time" = "America/Rio_Branco"
        "UTC-02" = "America/Noronha"
    }
    $id = [System.TimeZoneInfo]::Local.Id
    if ($map.ContainsKey($id)) { return $map[$id] }
    return "America/Sao_Paulo"
}

# Documentos do usuario (MyDocuments segue o OneDrive quando ele move a pasta).
# O compose monta Documentos\ncommerce\plugins em app/lib/plugins.
function Initialize-PluginsDir {
    # Loja ja instalada: a pasta que ela usa nao muda de lugar.
    $saved = Get-EnvValue (Join-Path $InstallDir ".env") "NCOMMERCE_PLUGINS_DIR"
    if ($saved -and (Test-Path -LiteralPath $saved -PathType Container)) { return $saved.Replace('/', '\') }
    $docs = [Environment]::GetFolderPath("MyDocuments")
    $dir = Join-Path $docs "ncommerce\plugins"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $readme = "Plugins do NCommerce`r`n`r`nCopie o arquivo do plugin (.rb) para a pasta plugins, ao lado deste arquivo.`r`nDepois entre como admin e use o botao Reiniciar NCommerce em`r`nConfiguracoes > Empresa. O plugin entra no backup da loja.`r`n"
    try { [System.IO.File]::WriteAllText((Join-Path $docs "ncommerce\LEIA-ME.txt"), $readme) } catch { }
    return $dir
}

# ============================================================ etapa 1

# MySQL, API, CUPS e o WSL do Docker Desktop juntos nao cabem em 4 GB: o PC passa a
# usar o arquivo de paginacao e o caixa fica lento. 6 GB bastam. Clock nao e exigido:
# um processador com 4 threads dificilmente e lento demais. Barra antes de qualquer instalacao.
function Assert-Computer {
    if ($ExecutionContext.SessionState.LanguageMode -ne "FullLanguage") {
        Fail "o Windows deste computador limita o PowerShell (modo $($ExecutionContext.SessionState.LanguageMode)), por politica da empresa ou do antivirus." `
            "chame o suporte NCommerce: o instalador precisa do PowerShell sem essa restricao."
    }
    if (-not (Get-Command curl.exe -CommandType Application -ErrorAction SilentlyContinue)) {
        Fail "este Windows nao tem o curl.exe (Windows 10 antigo demais)." "atualize o Windows pelo Windows Update e abra o instalador de novo."
    }

    $problems = @()
    $os = Get-CimInstance Win32_OperatingSystem
    $build = [int]$os.BuildNumber
    # 19045 e o Windows 10 22H2, o mais antigo que o Docker Desktop aceita.
    if ($build -lt 19045) { $problems += "Windows 10 22H2 ou Windows 11 (este e o build $build)" }
    if (-not [Environment]::Is64BitOperatingSystem -or $env:PROCESSOR_ARCHITECTURE -ne "AMD64") {
        $problems += "Windows de 64 bits em processador Intel ou AMD (este e $($env:PROCESSOR_ARCHITECTURE))"
    }
    $threads = (Get-CimInstance Win32_Processor | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
    if ($threads -lt 4) { $problems += "processador com 4 threads (este tem $threads)" }
    # Um PC de 6 GB informa menos: o firmware e o video integrado reservam ate ~1 GB. 5 GB
    # aceita esse PC e barra o de 4 GB, que informa no maximo 4.
    $ramGb = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1)
    if ($ramGb -lt 5.0) { $problems += "6 GB de RAM (este tem $ramGb GB)" }
    # Docker Desktop, o disco do WSL e as imagens ficam no C:. Loja ja instalada
    # so precisa de folga para atualizar.
    $needGb = 25
    if (Test-Path -LiteralPath (Join-Path $InstallDir ".env")) { $needGb = 5 }
    try {
        $freeGb = [math]::Round((Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'").FreeSpace / 1GB, 1)
        if ($freeGb -lt $needGb) { $problems += "$needGb GB livres no disco C: (este tem $freeGb GB livres)" }
    } catch { }

    if ($problems.Count -gt 0) {
        Say ""
        Say "Este computador nao atende o minimo do NCommerce. Falta:" "Red"
        $problems | ForEach-Object { Say "  - $_" "Red" }
        if ($IgnorarRequisitos) {
            Say "Seguindo mesmo assim (-IgnorarRequisitos)." "Yellow"
        } else {
            Fail "este computador esta abaixo do minimo: $($problems[0])." `
                "use um computador com Windows 10 22H2 ou Windows 11, 4 threads, 6 GB de RAM e 25 GB livres no disco C:. Abrir de novo neste nao resolve."
        }
    } else {
        Say "Sistema, processador, memoria e disco: ok."
    }

    # Antivirus de terceiros costuma barrar o Docker e o WSL. So anota: ajuda o suporte.
    try {
        $av = @(Get-CimInstance -Namespace root/SecurityCenter2 -ClassName AntiVirusProduct -ErrorAction Stop |
            ForEach-Object { $_.displayName } | Where-Object { $_ -and $_ -notmatch "Windows Defender|Microsoft Defender" } | Select-Object -Unique)
        if ($av.Count -gt 0) {
            Say "Antivirus neste computador: $($av -join ', '). Se a instalacao parar no Docker, ele pode estar bloqueando: avise o suporte."
        }
    } catch { }

    # O Wi-Fi pode ainda estar conectando logo depois de ligar.
    $masterHost = ([System.Uri]$MasterUrl).Host
    $online = $false
    for ($i = 1; $i -le 4; $i++) {
        try {
            [System.Net.Dns]::GetHostAddresses($masterHost) | Out-Null
            $online = $true
            break
        } catch {
            if ($i -lt 4) { Say "Sem internet ainda. Esperando..."; Start-Sleep -Seconds 5 }
        }
    }
    if (-not $online) {
        Fail "este computador esta sem internet (nao achei $masterHost)." `
            "confira o cabo de rede ou o Wi-Fi, abra um site qualquer no navegador para testar e abra o instalador de novo."
    }

    # Com o relogio errado o HTTPS falha com erro de certificado e a SEFAZ rejeita a nota.
    $skew = Get-ClockSkewSeconds "$MasterUrl/"
    if ($null -ne $skew -and $skew -gt 300) {
        Say "O relogio deste computador esta errado em $([int]($skew / 60)) minutos. Acertando pela internet..."
        try {
            Set-Service -Name w32time -StartupType Automatic -ErrorAction SilentlyContinue
            Start-Service w32time -ErrorAction SilentlyContinue
            Invoke-Native -Exe "w32tm.exe" -Arguments @("/resync", "/force") -Quiet | Out-Null
        } catch { }
        Start-Sleep -Seconds 5
        $skew = Get-ClockSkewSeconds "$MasterUrl/"
        if ($null -ne $skew -and $skew -gt 300) {
            Fail "a data e a hora deste computador estao erradas (diferenca de $([int]($skew / 60)) minutos)." `
                "clique com o botao direito no relogio do Windows > Ajustar data e hora > ligue 'Definir horario automaticamente' e clique em 'Sincronizar agora'. Depois abra o instalador de novo."
        }
        Say "Relogio acertado."
    }
    $ErrorActionPreference = "Continue"
    $http = & curl.exe -sS -o NUL -w "%{http_code}" --connect-timeout 15 --max-time 30 "$MasterUrl/" 2>&1
    $ErrorActionPreference = "Stop"
    $httpText = "$(@($http) | Select-Object -Last 1)".Trim()
    if ($httpText -notmatch '^[1-5]\d\d$') {
        Write-NcLog "curl: $(@($http) -join ' ')"
        Fail "nao consegui falar com o servidor do NCommerce ($MasterUrl)." `
            "confira a internet. Se outros sites abrem, um antivirus, firewall ou filtro da rede pode estar bloqueando: chame o suporte. Depois abra o instalador de novo."
    }
    Say "Internet, servidor do NCommerce e relogio: ok."
}

# ============================================================ etapa 2

# O Docker Desktop roda em cima do WSL2. Num Windows recem-formatado o WSL nao esta ligado,
# o Docker pede reinicio e o codigo de instalacao, que so vale uma vez, ja teria sido gasto.
# Por isso o WSL e preparado aqui, antes de pedir o codigo.
function Initialize-Wsl {
    if (Test-DockerReady) {
        Say "O Docker ja esta funcionando neste computador."
        return
    }

    # Com o hypervisor ja rodando, o Windows informa VirtualizationFirmwareEnabled = False.
    $hypervisor = (Get-CimInstance Win32_ComputerSystem).HypervisorPresent
    $firmware = (Get-CimInstance Win32_Processor | Select-Object -First 1).VirtualizationFirmwareEnabled
    if (-not $hypervisor -and -not $firmware) {
        Fail "a virtualizacao esta desligada na BIOS deste computador." `
            "chame o suporte NCommerce ou um tecnico: e preciso entrar na BIOS e ligar Intel VT-x (ou AMD-V / SVM). Depois abra o instalador de novo."
    }

    $rebootNeeded = $false
    foreach ($f in @("Microsoft-Windows-Subsystem-Linux", "VirtualMachinePlatform")) {
        $state = $null
        try { $state = (Get-WindowsOptionalFeature -Online -FeatureName $f -ErrorAction Stop).State } catch { }
        if ("$state" -ne "Enabled") {
            Say "Ligando o recurso $f do Windows..."
            try {
                $result = Enable-WindowsOptionalFeature -Online -FeatureName $f -All -NoRestart -ErrorAction Stop
                if ($result.RestartNeeded) { $rebootNeeded = $true }
            } catch {
                Write-NcLog "Enable-WindowsOptionalFeature ${f}: $($_.Exception.Message)"
                Register-RebootNotice | Out-Null
                Fail "o Windows nao deixou ligar o recurso $f (costuma ser uma atualizacao do Windows esperando reinicio)." `
                    "reinicie o computador. O instalador abre sozinho depois de voce entrar no Windows; se nao abrir, abra o InstaladorWindows.bat de novo."
            }
        }
    }
    if ($rebootNeeded) {
        Say ""
        Say "O Windows precisa reiniciar para terminar de ligar o WSL2." "Yellow"
        Register-RebootNotice | Out-Null
        Set-NcState "reinicio_pedido" ([string](Get-UnixTime))
        Say "Depois do reinicio, entre no Windows com este mesmo usuario: o instalador abre sozinho e continua." "Yellow"
        Say "Se ele nao abrir em 1 minuto, abra o InstaladorWindows.bat de novo. O codigo de instalacao ainda nao foi usado." "Yellow"
        $script:Verdict = "reinicio"
        Close-Installer
        Read-Host "Pressione Enter para reiniciar agora (ou feche a janela para reiniciar depois)" | Out-Null
        Restart-Computer -Force
        exit 0
    }

    # O WSL que vem no Windows e antigo para o Docker Desktop. Falha aqui nao para a instalacao:
    # o proprio Docker Desktop pede a atualizacao no primeiro uso.
    Say "Atualizando o WSL..."
    $updateCode = Invoke-Native -Exe "wsl.exe" -Arguments @("--update") -Quiet
    Invoke-Native -Exe "wsl.exe" -Arguments @("--set-default-version", "2") -Quiet | Out-Null
    if ($updateCode -ne 0) { Say "Nao consegui atualizar o WSL (codigo $updateCode). O Docker Desktop atualiza no primeiro uso." }
}

# ============================================================ etapa 3

# Windows recem-instalado marca a rede como Publica, e a regra do OpenSSH so vale em rede Privada.
# A rede em que o PC esta agora e a da loja, entao ela vira Privada. Redes de dominio ficam como estao.
function Set-StoreNetworkPrivate {
    try {
        $public = @(Get-NetConnectionProfile -ErrorAction Stop | Where-Object { $_.NetworkCategory -eq "Public" })
        foreach ($p in $public) {
            Set-NetConnectionProfile -InterfaceIndex $p.InterfaceIndex -NetworkCategory Private -ErrorAction Stop
            Say "Rede '$($p.Name)' marcada como Privada."
        }
    } catch {
        Say "Nao consegui marcar a rede como Privada: $($_.Exception.Message)"
    }
}

# Sessao pelo tunel fica em silencio num comando longo. Sem probe o NAT
# derruba o TCP. Probe a cada 30s: a sessao viva nao expira; 3 falhas
# seguidas (~90s sem resposta) desconectam.
function Set-SshClientAlive {
    $config = Join-Path $env:ProgramData "ssh\sshd_config"
    if (-not (Test-Path -LiteralPath $config)) {
        Say "Nao achei $config. Sem keepalive no SSH."
        return
    }
    $raw = [System.IO.File]::ReadAllText($config)
    if ($raw -match '(?m)^ClientAliveInterval\s+30\s*$' -and $raw -match '(?m)^ClientAliveCountMax\s+3\s*$') {
        Say "SSH ja sonda o cliente a cada 30s."
        return
    }
    $updated = $raw
    $updated = [regex]::Replace($updated, '(?m)^[ \t]*#?[ \t]*ClientAliveInterval[ \t]+\S+.*$', 'ClientAliveInterval 30')
    $updated = [regex]::Replace($updated, '(?m)^[ \t]*#?[ \t]*ClientAliveCountMax[ \t]+\S+.*$', 'ClientAliveCountMax 3')
    $nl = "`n"
    if ($updated.Contains("`r`n")) { $nl = "`r`n" }
    if ($updated -notmatch '(?m)^ClientAliveInterval\s+') {
        $updated = $updated.TrimEnd() + $nl + "ClientAliveInterval 30" + $nl + "ClientAliveCountMax 3" + $nl
    } elseif ($updated -notmatch '(?m)^ClientAliveCountMax\s+') {
        $updated = $updated.TrimEnd() + $nl + "ClientAliveCountMax 3" + $nl
    }
    # O anterior fica em sshd_config.bak; a troca e de uma vez.
    Write-FileAtomic $config $updated -Backup
    $sshd = Join-Path $env:Windir "System32\OpenSSH\sshd.exe"
    $ErrorActionPreference = "Continue"
    & $sshd -t *> $null
    $testCode = $LASTEXITCODE
    $ErrorActionPreference = "Stop"
    if ($testCode -ne 0) {
        Write-FileAtomic $config $raw
        Say "sshd rejeitou o keepalive. Configuracao anterior restaurada."
        return
    }
    try {
        Restart-Service sshd -ErrorAction Stop
    } catch {
        Say "Keepalive gravado, mas o sshd nao reiniciou: $($_.Exception.Message)"
        return
    }
    Say "SSH sonda o cliente a cada 30s. Sessao viva nao cai por silencio."
}

# Nada aqui para a instalacao: o SSH e do suporte, e a loja funciona sem ele.
function Enable-OpenSshServer {
    Say "Abrindo o SSH na porta 22..."
    try {
        $cap = Get-WindowsCapability -Online -ErrorAction Stop |
            Where-Object { $_.Name -like "OpenSSH.Server*" } |
            Select-Object -First 1
        if (-not $cap) {
            Warn "este Windows nao oferece o servidor OpenSSH. O suporte fica sem acesso por SSH."
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
        Set-SshClientAlive
        Say "SSH do Windows na porta 22. Use o usuario e a senha desta conta."
    } catch {
        Warn "nao consegui ligar o SSH do Windows ($($_.Exception.Message)). O suporte fica sem acesso por SSH."
    }
}

function Get-AnyDeskExe {
    return @("${env:ProgramFiles(x86)}\AnyDesk\AnyDesk.exe", "$env:ProgramFiles\AnyDesk\AnyDesk.exe") |
        Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
}

# AnyDesk para o suporte entrar na tela do cliente. Falha aqui nao para a instalacao.
function Install-AnyDesk {
    if (Get-AnyDeskExe) {
        Say "AnyDesk ja instalado."
        return
    }
    Say "Instalando o AnyDesk..."
    if (Initialize-Winget) {
        Invoke-Native -Exe "winget" -Arguments @("install", "--source", "winget", "--exact", "--id", "AnyDesk.AnyDesk",
            "--accept-package-agreements", "--accept-source-agreements", "--disable-interactivity") -Quiet | Out-Null
    }
    if (-not (Get-AnyDeskExe)) {
        # Sem winget, ou winget antigo: direto do fabricante, com a assinatura conferida.
        $setup = Get-SignedInstaller "https://download.anydesk.com/AnyDesk.exe" "AnyDesk.exe" "AnyDesk Software|philandro Software"
        if ($setup) {
            $target = Join-Path ${env:ProgramFiles(x86)} "AnyDesk"
            try {
                Start-Process -FilePath $setup -ArgumentList "--install `"$target`" --start-with-win --create-desktop-icon --silent" -Wait
            } catch {
                Write-NcLog "AnyDesk --install: $($_.Exception.Message)"
            }
        }
    }
    if (-not (Get-AnyDeskExe)) {
        Warn "nao consegui instalar o AnyDesk. O suporte instala depois (https://anydesk.com)."
    }
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
        Say "Acesso nao supervisionado do AnyDesk configurado."
    } else {
        Warn "nao consegui configurar a senha do AnyDesk (codigo $code)."
    }
}

# O Windows nao deixa programa fixar icone na barra de tarefas. O atalho fica na Area de Trabalho,
# para o suporte dizer "abra o AnyDesk da Area de Trabalho".
function New-AnyDeskShortcut {
    try {
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
        Say "Atalho: $lnk"
    } catch {
        Write-NcLog "Atalho do AnyDesk: $($_.Exception.Message)"
    }
}

# ============================================================ etapa 4

function Install-DockerDesktop {
    if (Test-Path -LiteralPath $DockerExe) { return }
    Say "Instalando o Docker Desktop. Isso pode levar de 5 a 20 minutos."
    # --accept-license pula a tela de termos no primeiro uso. --always-run-service deixa o servico
    # do Docker subir sem admin, para a tarefa de logon funcionar com o usuario comum.
    $installArgs = "install --quiet --accept-license --backend=wsl-2 --always-run-service"
    if (Initialize-Winget) {
        Invoke-Retry 2 20 {
            Invoke-Native -Exe "winget" -Arguments @("install", "--source", "winget", "--exact", "--id", "Docker.DockerDesktop",
                "--accept-package-agreements", "--accept-source-agreements", "--disable-interactivity",
                "--override", $installArgs) -Quiet | Out-Null
            return (Test-Path -LiteralPath $DockerExe)
        } | Out-Null
    }
    if (-not (Test-Path -LiteralPath $DockerExe)) {
        # Sem winget, ou o winget falhou: direto da Docker. O download continua de onde
        # parou e so roda com a assinatura digital da Docker conferida.
        Say "Baixando o Docker Desktop direto do site da Docker (cerca de 600 MB)..."
        $setup = Get-SignedInstaller "https://desktop.docker.com/win/main/amd64/Docker%20Desktop%20Installer.exe" "DockerDesktopInstaller.exe" "Docker Inc"
        if ($setup) {
            Say "Instalando o Docker Desktop..."
            try {
                $proc = Start-Process -FilePath $setup -ArgumentList $installArgs -Wait -PassThru
                Write-NcLog "Docker Desktop Installer saiu com codigo $($proc.ExitCode)."
            } catch {
                Write-NcLog "Docker Desktop Installer: $($_.Exception.Message)"
            }
            if (Test-Path -LiteralPath $DockerExe) { Remove-Item -LiteralPath $setup -Force -ErrorAction SilentlyContinue }
        }
    }
    if (-not (Test-Path -LiteralPath $DockerExe)) {
        Register-RebootNotice | Out-Null
        Fail "o Docker Desktop nao ficou instalado." `
            "reinicie o computador. O instalador abre sozinho depois de voce entrar no Windows; se nao abrir, abra o InstaladorWindows.bat de novo. O codigo de instalacao ainda nao foi usado."
    }
}

function Wait-DockerReady([int]$Seconds) {
    for ($waited = 0; $waited -lt $Seconds; $waited += 5) {
        if (Test-DockerReady) { return $true }
        if ($waited -gt 0 -and ($waited % 60) -eq 0) { Say "  ainda esperando o Docker ($([int]($waited / 60)) min)..." }
        Start-Sleep -Seconds 5
    }
    return (Test-DockerReady)
}

function Start-DockerDesktop {
    # Quem usa o PC precisa estar no grupo docker-users para a tarefa de logon falar com o Docker.
    $me = "$env:USERDOMAIN\$env:USERNAME"
    try {
        $members = @(Get-LocalGroupMember -Group "docker-users" -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
        if ($members -notcontains $me) { Add-LocalGroupMember -Group "docker-users" -Member $me -ErrorAction Stop }
    } catch {
        Write-NcLog "Nao consegui colocar $me no grupo docker-users: $($_.Exception.Message)"
    }

    if (Test-DockerReady) {
        Say "Docker funcionando."
        return
    }
    # Pelo explorer o Docker Desktop abre como o usuario comum, e nao como admin, igual ao logon.
    if (Test-Path -LiteralPath $DockerDesktop) { Start-Process explorer.exe -ArgumentList "`"$DockerDesktop`"" }
    Say "Esperando o Docker Desktop ficar pronto. Na primeira vez pode levar uns 10 minutos."
    Say "Se abrir uma janela do Docker pedindo para aceitar ou entrar numa conta, pode fechar essa janela."
    if (Wait-DockerReady 600) {
        Say "Docker funcionando."
        return
    }
    # Docker Desktop travado na abertura: fecha, desliga o WSL e abre de novo, uma vez.
    Say "O Docker ainda nao respondeu. Reiniciando o Docker Desktop..."
    try {
        Get-Process -Name "Docker Desktop", "com.docker.backend", "com.docker.build" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Invoke-Native -Exe "wsl.exe" -Arguments @("--shutdown") -Quiet | Out-Null
        Start-Sleep -Seconds 5
        if (Test-Path -LiteralPath $DockerDesktop) { Start-Process explorer.exe -ArgumentList "`"$DockerDesktop`"" }
    } catch {
        Write-NcLog "Reinicio do Docker Desktop: $($_.Exception.Message)"
    }
    if (Wait-DockerReady 420) {
        Say "Docker funcionando."
        return
    }
    Register-RebootNotice | Out-Null
    Fail "o Docker Desktop esta instalado mas nao ficou pronto." `
        "reinicie o computador. O instalador abre sozinho depois de voce entrar no Windows; se nao abrir, abra o InstaladorWindows.bat de novo. O codigo de instalacao ainda nao foi usado."
}

# ============================================================ etapa 5

# Backup que a instalacao restaura: o zip de -Backup, um zip arrastado para a
# janela ou, sem nenhum, o do mestre (devolve vazio). A escolha fica no arquivo
# de estado: uma retomada nao pergunta de novo.
function Select-BackupZip([string]$Token) {
    if ($Backup) {
        $path = ConvertFrom-DroppedPath $Backup
        $problem = Get-BackupZipProblem $path $Token
        if ($problem) { Fail $problem "confira o arquivo de backup e abra de novo com -Backup C:\caminho\do\arquivo.zip." }
        $full = (Resolve-Path -LiteralPath $path).Path
        Say "Backup avulso valido: $full."
        Set-NcState "backup_escolha" $full
        return $full
    }
    $saved = Get-NcState "backup_escolha"
    if ($saved -eq "servidor") {
        Say "Backup: o guardado no servidor (escolhido antes)."
        return ""
    }
    if ($saved -and -not (Get-BackupZipProblem $saved $Token)) {
        Say "Backup avulso (escolhido antes): $saved."
        return $saved
    }
    Say ""
    Say "Backup: para restaurar um zip de backup avulso, arraste o arquivo para esta janela e tecle Enter."
    Say "Para usar o backup guardado no servidor, so tecle Enter."
    while ($true) {
        $path = ConvertFrom-DroppedPath (Read-Host "Zip de backup (Enter = servidor)")
        if (-not $path) {
            Say "Usando o backup do servidor."
            Set-NcState "backup_escolha" "servidor"
            return ""
        }
        $problem = Get-BackupZipProblem $path $Token
        if (-not $problem) {
            $full = (Resolve-Path -LiteralPath $path).Path
            Say "Backup avulso valido: $full."
            Set-NcState "backup_escolha" $full
            return $full
        }
        Say $problem
        Say "Arraste outro zip, ou tecle Enter para usar o backup do servidor."
    }
}

function Get-StoreGrant {
    if (Test-StoreInstalled) { $script:StoreAlreadyLive = $true }
    if ($script:StoreAlreadyLive -and -not $Reinstalar -and -not $Backup) {
        $script:Mode = "reparo"
        Say "O NCommerce ja esta instalado neste computador."
        Say "Vou so conferir e consertar o que precisar. Nao preciso do codigo e os dados da loja nao sao tocados."
        return $null
    }

    $grant = $null
    $code = ""
    # Codigo do arquivo do zip, depois o digitado numa execucao anterior, depois o teclado.
    foreach ($candidate in @((Read-CodeFile), (Get-NcState "codigo"))) {
        if (-not $candidate -or $grant) { continue }
        Say "Usando o codigo de instalacao $candidate."
        $answer = Get-InstallGrant $candidate
        if ($answer -is [string]) {
            Fail "o servidor do NCommerce nao respondeu ao codigo de instalacao." `
                "espere alguns minutos e abra o instalador de novo. O codigo continua valendo neste computador."
        }
        if ($answer) { $grant = $answer; $code = $candidate }
    }
    while (-not $grant) {
        Say "Peca o codigo de instalacao ao suporte NCommerce e digite abaixo."
        $code = Read-InstallCode
        $answer = Get-InstallGrant $code
        if ($answer -is [string]) {
            Fail "o servidor do NCommerce nao respondeu ao codigo de instalacao." `
                "espere alguns minutos e abra o instalador de novo."
        }
        if ($answer) { $grant = $answer }
    }
    Set-NcState "codigo" $code
    $grant | Add-Member -NotePropertyName install_code -NotePropertyValue $code -Force
    Say "Codigo aceito. Empresa: $($grant.company)."
    return $grant
}

# ============================================================ etapa 6

function Install-StoreFiles([string]$RegistryFromMaster) {
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $InstallDir "control") | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $InstallDir "host") | Out-Null

    # Instaladores antigos clonavam o codigo-fonte em src\. Nada usa essa pasta.
    $oldSrc = Join-Path $InstallDir "src"
    if (Test-Path -LiteralPath $oldSrc) { Remove-Item -LiteralPath $oldSrc -Recurse -Force -ErrorAction SilentlyContinue }

    $files = @(
        @{ From = "docker\docker-compose.yml"; To = "docker-compose.yml"; Backup = $true },
        @{ From = "docker\guard.sh"; To = "guard.sh" },
        @{ From = "windows\ncommerce-docker-startup.bat"; To = "ncommerce-docker-startup.bat" },
        @{ From = "windows\ncommerce-docker-update.bat"; To = "ncommerce-docker-update.bat" },
        @{ From = "windows\ncommerce-update.ps1"; To = "ncommerce-update.ps1" },
        @{ From = "windows\instalador-lib.ps1"; To = "instalador-lib.ps1" },
        @{ From = "windows\refresh-host-ips.ps1"; To = "refresh-host-ips.ps1" },
        @{ From = "windows\anydesk-id.ps1"; To = "anydesk-id.ps1" },
        @{ From = "windows\usb-printers.ps1"; To = "usb-printers.ps1" },
        @{ From = "windows\net-check.ps1"; To = "net-check.ps1" },
        @{ From = "windows\migrate-endpoints.ps1"; To = "migrate-endpoints.ps1" },
        @{ From = "windows\update-host.ps1"; To = "update-host.ps1" },
        @{ From = "windows\rollback.bat"; To = "rollback.bat" }
    )
    # Arquivo cortado na extracao do zip nao pode chegar em C:\NCommerce.
    foreach ($f in $files) {
        $src = Join-Path $Root $f.From
        if ((Get-NcFileLength $src) -le 0) {
            Fail "o arquivo $($f.From) do instalador esta faltando ou vazio." `
                "baixe o instalador de novo em ncommerce.app/instalar, extraia o zip inteiro e abra de novo."
        }
        if ($src -like "*.ps1") {
            $tokens = $null; $errors = $null
            [System.Management.Automation.Language.Parser]::ParseFile($src, [ref]$tokens, [ref]$errors) | Out-Null
            if ($errors -and $errors.Count -gt 0) {
                Fail "o arquivo $($f.From) do instalador esta danificado." `
                    "baixe o instalador de novo em ncommerce.app/instalar, extraia o zip inteiro e abra de novo."
            }
        }
    }
    # O compose novo tem que ser lido pelo Docker deste computador antes de entrar no lugar do atual.
    $ErrorActionPreference = "Continue"
    $composeErr = & $DockerExe compose -f (Join-Path $Root "docker\docker-compose.yml") config -q 2>&1
    $composeCode = $LASTEXITCODE
    $ErrorActionPreference = "Stop"
    if ($composeCode -ne 0) {
        Write-NcLog "docker compose config: $(@($composeErr) -join ' ')"
        Fail "o arquivo docker\docker-compose.yml do instalador esta danificado (ou o Docker deste computador e antigo demais para ele)." `
            "baixe o instalador de novo em ncommerce.app/instalar, extraia o zip inteiro e abra de novo. Se repetir, chame o suporte NCommerce."
    }
    foreach ($f in $files) {
        Copy-FileAtomic (Join-Path $Root $f.From) (Join-Path $InstallDir $f.To) -Backup:([bool]$f.Backup) | Out-Null
    }
    $driversSrc = Join-Path $Root "windows\drivers"
    if (Test-Path -LiteralPath $driversSrc) {
        $driversDst = Join-Path $InstallDir "drivers"
        New-Item -ItemType Directory -Force -Path $driversDst | Out-Null
        foreach ($d in (Get-ChildItem -LiteralPath $driversSrc -File)) {
            Copy-FileAtomic $d.FullName (Join-Path $driversDst $d.Name) | Out-Null
        }
    }

    $envFile = Join-Path $InstallDir ".env"
    if (Repair-EnvFile $envFile) { Say "O arquivo $envFile estava vazio. Voltei a copia anterior." }
    $script:PluginsDir = Initialize-PluginsDir

    $fileRegistry = Get-EnvValue $envFile "NCOMMERCE_REGISTRY"
    # O registry antigo sai de cena quando ha um login novo para fazer.
    if ($script:Mode -eq "instalacao" -and $fileRegistry -eq $OldRegistry) { $fileRegistry = "" }
    $registry = $env:NCOMMERCE_REGISTRY
    if (-not $registry) { $registry = $fileRegistry }
    if (-not $registry) { $registry = $RegistryFromMaster }
    if (-not $registry) { $registry = $DefaultRegistry }
    $tag = $env:NCOMMERCE_TAG
    if (-not $tag) { $tag = Get-EnvValue $envFile "NCOMMERCE_TAG" "latest" }

    # A porta do CUPS e escolhida uma vez. Numa segunda execucao a 631 esta
    # ocupada pelo proprio container, e escolher de novo trocaria a porta da loja.
    $cupsPort = Get-EnvValue $envFile "CUPS_PORT"
    if ($cupsPort -ne "631" -and $cupsPort -ne "6631") {
        $cupsPort = "631"
        if (Get-NetTCPConnection -LocalPort 631 -State Listen -ErrorAction SilentlyContinue) {
            $cupsPort = "6631"
            Say "A porta 631 ja esta em uso. O CUPS do container fica em http://127.0.0.1:6631."
        }
    }

    $values = [ordered]@{
        CUPS_PORT = $cupsPort
        NCOMMERCE_REGISTRY = $registry
        NCOMMERCE_TAG = $tag
        NCOMMERCE_PLUGINS_DIR = $script:PluginsDir.Replace('\', '/')
        TZ = (Get-IanaTimeZone)
    }
    Set-EnvValues $envFile $values | Out-Null
    $script:Registry = $registry
    $script:Tag = $tag
    $script:CupsPort = $cupsPort

    $code = Invoke-Native -Exe "powershell.exe" -Arguments @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $InstallDir "refresh-host-ips.ps1"), $InstallDir)
    if ($code -ne 0) { Warn "nao consegui gravar os IPs deste computador. A tela de enderecos do NCommerce pode ficar vazia." }
    Invoke-Native -Exe "powershell.exe" -Arguments @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $InstallDir "anydesk-id.ps1"), $InstallDir) -Quiet | Out-Null

    foreach ($port in @(3000, 4200)) {
        $name = "NCommerce TCP $port"
        try {
            if (-not (Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue)) {
                New-NetFirewallRule -DisplayName $name -Direction Inbound -Protocol TCP -LocalPort $port -Action Allow | Out-Null
            }
        } catch {
            Warn "nao consegui abrir a porta $port no firewall do Windows. Tablets e celulares podem nao conectar."
        }
    }

    $startup = Join-Path $InstallDir "ncommerce-docker-startup.bat"
    Say "Registrando a tarefa de logon '$TaskName'..."
    $taskCode = Invoke-Native -Exe "schtasks.exe" -Arguments @("/create", "/tn", $TaskName, "/tr", $startup, "/sc", "onlogon", "/rl", "LIMITED", "/f") -Quiet
    if ($taskCode -ne 0) {
        Fail "nao consegui criar a tarefa '$TaskName', que liga o NCommerce quando o Windows inicia."
    }
    Say "Arquivos do NCommerce em $InstallDir."
}

# ============================================================ etapa 7

function Get-StoreImages {
    Push-Location $InstallDir
    try {
        $ErrorActionPreference = "Continue"
        $out = & $DockerExe compose config --images 2>$null
        if ($LASTEXITCODE -ne 0) { return @() }
        return @($out | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
    } finally {
        Pop-Location
    }
}

function Test-ImageHere([string]$Image) {
    $ErrorActionPreference = "Continue"
    & $DockerExe image inspect $Image *> $null
    return ($LASTEXITCODE -eq 0)
}

# Quantas imagens da loja faltam neste computador; -1 quando nao deu para saber.
function Get-StoreImagesMissingCount {
    $images = Get-StoreImages
    if ($images.Count -eq 0) { return -1 }
    $count = 0
    foreach ($image in $images) {
        if (-not (Test-ImageHere $image)) { $count++ }
    }
    return $count
}

function Save-StoreImages($Grant) {
    $ErrorActionPreference = "Continue"
    $http = & curl.exe -sS -o NUL -w "%{http_code}" --connect-timeout 15 --max-time 30 "https://$($script:Registry)/v2/" 2>&1
    $ErrorActionPreference = "Stop"
    $httpText = "$(@($http) | Select-Object -Last 1)".Trim()
    if ($httpText -ne "200" -and $httpText -ne "401") {
        Write-NcLog "curl registry: $(@($http) -join ' ')"
        Fail "nao consegui chegar no servidor de onde o NCommerce e baixado ($($script:Registry))." `
            "confira a internet. Se outros sites abrem, a rede ou o antivirus pode estar bloqueando a porta $(($script:Registry -split ':')[-1]): chame o suporte. Depois abra o instalador de novo."
    }

    if ($script:Mode -eq "instalacao") {
        Say "Entrando no registry $($script:Registry) como $($Grant.company)..."
        if (-not (Invoke-DockerLogin $script:Registry ([string]$Grant.company) ([string]$Grant.token))) {
            Fail "o servidor nao aceitou a entrada desta empresa ($($Grant.company)) para baixar o sistema." `
                "abra o instalador de novo. Se repetir, mande o log para o suporte NCommerce."
        }
    }

    # Uma loja que voltou de versao fica com NCOMMERCE_TAG=keep-<versao>, que so
    # existe neste computador: nao ha o que baixar para api e web.
    $services = @()
    if ($script:Tag -like "keep-*") {
        if (Test-ImageHere "$($script:Registry)/ncommerce/api:$($script:Tag)") {
            Say "A loja esta numa versao guardada ($($script:Tag.Substring(5))). Ela fica; para a publicada, use o atalho Atualizar NCommerce."
            $services = @("mysql", "redis", "guard")
        } else {
            Say "A versao guardada $($script:Tag.Substring(5)) nao esta mais neste computador. Usando a publicada."
            $script:Tag = "latest"
            Set-EnvValues (Join-Path $InstallDir ".env") ([ordered]@{ NCOMMERCE_TAG = "latest" }) | Out-Null
        }
    }

    # Reparo: so baixa o que falta. A versao da loja muda no Atualizar NCommerce.
    if ($script:Mode -eq "reparo") {
        if ((Get-StoreImagesMissingCount) -eq 0) {
            Say "As imagens do NCommerce ja estao neste computador."
            return
        }
    }

    Say "Baixando o NCommerce. E a parte mais demorada: de 5 a 30 minutos, conforme a internet."
    Say "Se a internet cair, o que ja foi baixado fica guardado."
    $pulled = Invoke-Retry 4 15 {
        return ((Invoke-Compose -Arguments (@("pull") + $services)) -eq 0)
    }
    if (-not $pulled) {
        # Loja que ja funcionava: a etiqueta "latest" volta para a versao em uso.
        Restore-SnapshotTags
        Fail "o download do NCommerce nao terminou (internet caiu ou esta muito lenta)." `
            "confira a internet e abra o instalador de novo. Ele continua do ponto em que o download parou."
    }
    Say "Download concluido."
    Save-DumpIfDbChanges
}

# ============================================================ etapa 8

function Assert-PortsFree {
    # Com os containers da loja ja criados, quem ocupa as portas somos nos.
    Push-Location $InstallDir
    $ErrorActionPreference = "Continue"
    $existing = & $DockerExe compose ps -aq 2>$null
    $ErrorActionPreference = "Stop"
    Pop-Location
    if ($existing) { return }
    foreach ($port in @(3000, 4200)) {
        $listen = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $listen) { continue }
        $owner = ""
        try { $owner = (Get-Process -Id $listen.OwningProcess -ErrorAction Stop).ProcessName } catch { }
        if ($owner -match "docker|wslrelay|vpnkit") { continue }
        Fail "a porta $port, que o NCommerce usa, esta ocupada por outro programa ($owner)." `
            "feche ou desinstale esse programa e abra o instalador de novo. Se nao souber qual e, chame o suporte NCommerce."
    }
}

function Start-Store {
    Assert-PortsFree
    Say "Ligando o NCommerce..."
    $up = Invoke-Retry 2 10 { return ((Invoke-Compose -Arguments @("up", "-d")) -eq 0) }
    # Troca de uma atualizacao interrompida que este up terminou.
    if ($up -and (Read-UpdateState)) { Clear-UpdateState }
    if (-not $up) {
        Invoke-Compose -Arguments @("ps") -Quiet | Out-Null
        Fail "o Docker nao conseguiu ligar o NCommerce." `
            "reinicie o computador e abra o instalador de novo. Se repetir, mande o log para o suporte NCommerce."
    }
    if ($script:Mode -eq "instalacao" -and (Test-TokenOnVolume)) { $script:StoreAlreadyLive = $true }
    Say "Esperando o sistema responder. Na primeira vez ele prepara o banco de dados: ate 8 minutos."
    if (-not (Wait-ApiUp 480)) {
        if (-not (Test-TokenOnVolume 3)) {
            Invoke-Compose -Arguments @("ps") -Quiet | Out-Null
            Invoke-Compose -Arguments @("logs", "--tail", "60", "api") -Quiet | Out-Null
            Fail "o NCommerce foi ligado mas nao respondeu em 8 minutos." `
                "abra o instalador de novo. Se repetir, mande o log para o suporte NCommerce."
        }
        Say "A API ainda nao respondeu, mas o token desta maquina ja esta gravado. Sigo."
    }
    Say "Sistema respondendo."
}

# ============================================================ etapa 9

# 200 grava o zip. 204 significa empresa sem backup. Outro HTTP aborta.
# O download continua de onde parou e o zip so vale depois de conferido.
function Save-CompanyBackup([string]$Code, [string]$Token) {
    $machineId = Get-MachineId
    $dest = Join-Path $InstallDir "ncommerce.zip"
    $part = Join-Path $DataDir "ncommerce.zip.part"
    for ($round = 1; $round -le 2; $round++) {
        Say "Baixando o backup da loja guardado no servidor..."
        $http = Get-FileResumable "$MasterUrl/install/$Code/backup?machine_id=$machineId" $part 4
        if ($http -eq "204") {
            Remove-Item -LiteralPath $part, $dest -Force -ErrorAction SilentlyContinue
            Say "Esta empresa nao tem backup no servidor. A instalacao segue com a loja vazia."
            return
        }
        if ($http -ne "200" -and $http -ne "206" -and $http -ne "416") {
            Fail "nao consegui baixar o backup da loja (HTTP $http)." `
                "confira a internet e abra o instalador de novo. O download continua de onde parou."
        }
        if ((Test-Path -LiteralPath $part) -and -not (Get-BackupZipProblem $part $Token)) {
            Copy-FileAtomic $part $dest | Out-Null
            Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
            Say "Backup baixado e conferido."
            return
        }
        # Pedaco de um backup antigo ou arquivo danificado: comeca do zero uma vez.
        Say "O backup baixado nao passou na conferencia. Baixando de novo do inicio..."
        Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
    }
    Fail "o backup baixado do servidor esta danificado." "abra o instalador de novo. Se repetir, chame o suporte NCommerce."
}

# Um zip avulso entra no lugar do backup do mestre. Escolhido de proposito,
# ele e restaurado mesmo num PC que ja restaurou um backup antes.
function Use-BackupZip([string]$Zip) {
    $dest = Join-Path $InstallDir "ncommerce.zip"
    if ([System.IO.Path]::GetFullPath($Zip) -ne [System.IO.Path]::GetFullPath($dest)) {
        Copy-FileAtomic $Zip $dest | Out-Null
    }
    # Uma retomada depois de restaurar este mesmo zip nao restaura de novo.
    if ((Get-NcState "backup_restaurado") -ne $Zip) {
        Remove-Item -LiteralPath (Join-Path $InstallDir ".backup-restored") -Force -ErrorAction SilentlyContinue
    }
    Say "Backup avulso copiado para $dest."
}

# O restore deixou os plugins do backup em /tmp/ncommerce-plugins no container.
# Eles vao para Documentos\ncommerce\plugins e a API reinicia para carregar.
function Restore-BackupPlugins {
    $ErrorActionPreference = "Continue"
    $list = Invoke-ComposeExec exec -T api find /tmp/ncommerce-plugins -type f
    if ($LASTEXITCODE -eq 0 -and "$list".Trim()) {
        Invoke-Compose -Arguments @("cp", "api:/tmp/ncommerce-plugins/.", $script:PluginsDir) -Quiet | Out-Null
        Say "Plugins restaurados em $($script:PluginsDir)."
        Invoke-Compose -Arguments @("restart", "api") -Quiet | Out-Null
        if (-not (Wait-ApiUp 240)) { Warn "a API demorou para voltar depois de carregar os plugins." }
    }
    Invoke-ComposeExec exec -T api rm -rf /tmp/ncommerce-plugins | Out-Null
}

function Restore-CompanyBackup([string]$Token, [string]$ChosenZip) {
    $zip = Join-Path $InstallDir "ncommerce.zip"
    $marker = Join-Path $InstallDir ".backup-restored"
    if (Test-Path -LiteralPath $marker) {
        Say "O backup ja foi restaurado numa execucao anterior."
        return
    }
    if (-not (Test-Path -LiteralPath $zip)) { return }
    if ($Token.Length -lt 6) { Fail "o token desta empresa e curto demais para abrir o backup." "chame o suporte NCommerce." }
    $pass = $Token.Substring(0, 6)
    if ($script:StoreAlreadyLive) {
        if (-not (Save-DatabaseDump "antes-de-restaurar")) {
            Fail "nao consegui guardar uma copia do banco atual antes de restaurar o backup por cima." `
                "nada foi alterado. Confira o espaco em disco e abra de novo, ou chame o suporte NCommerce."
        }
    }
    Say "Restaurando o banco de dados da loja. Pode levar alguns minutos..."

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
# backup/ guarda os XML dos meses anteriores, que o relatorio de impostos le.
for part in essentials notas_output backup notas_compra notas_input notas_log; do
  if [ -d "$part" ]; then cp -a "$part" /data/nfce/; fi
done
# Segundo CNPJ: a pasta inteira, com o .last_id que numera as notas dele.
if [ -f nfce_ext.zip ]; then
  mkdir -p nfce_ext /data/nfce/externo
  unzip -o nfce_ext.zip -d nfce_ext >/dev/null
  cp -a nfce_ext/. /data/nfce/externo/
fi
# Plugins: o instalador copia daqui para Documentos\ncommerce\plugins (montado so leitura).
rm -rf /tmp/ncommerce-plugins
mkdir -p /tmp/ncommerce-plugins
if [ -f plugins.zip ]; then unzip -o plugins.zip -d /tmp/ncommerce-plugins >/dev/null; fi
# Impressoras, drivers (.ppd) e filtros. Imagem antiga sem o restaurador: so o printers.conf.
if command -v ncommerce-restore-cups >/dev/null 2>&1; then
  ncommerce-restore-cups /tmp/ncommerce-restore || echo "Nao restaurei todas as impressoras. Configure as que faltarem na web do CUPS."
elif [ -f printers.conf ]; then
  cp -a printers.conf /etc/cups/printers.conf
fi
rm -rf /tmp/ncommerce.zip /tmp/ncommerce-restore /tmp/ncommerce-restore.sh
'@
    $restore = $restore -replace "`r`n", "`n" -replace "`r", "`n"
    if (-not $restore.EndsWith("`n")) { $restore += "`n" }
    $scriptFile = New-TemporaryFile
    [System.IO.File]::WriteAllText($scriptFile.FullName, $restore, (New-Object System.Text.UTF8Encoding $false))

    $ErrorActionPreference = "Continue"
    $stage = "copiar o backup para o container"
    # Sobra de uma restauracao interrompida sai antes: o zip e aberto de novo inteiro.
    Invoke-ComposeExec exec -T api rm -rf /tmp/ncommerce-restore /tmp/ncommerce.zip | Out-Null
    $code = Invoke-Compose -Arguments @("cp", $zip, "api:/tmp/ncommerce.zip") -Quiet
    if ($code -eq 0) {
        $stage = "abrir o backup (a senha sao os 6 primeiros caracteres do token)"
        Invoke-ComposeExec exec -T api unzip -P $pass -o /tmp/ncommerce.zip -d /tmp/ncommerce-restore | Out-Null
        $code = $LASTEXITCODE
    }
    if ($code -eq 0) {
        $stage = "copiar o roteiro de restauracao"
        $code = Invoke-Compose -Arguments @("cp", $scriptFile.FullName, "api:/tmp/ncommerce-restore.sh") -Quiet
    }
    if ($code -eq 0) {
        $stage = "restaurar o banco e os arquivos"
        $out = Invoke-ComposeExec exec -T api sh /tmp/ncommerce-restore.sh
        $code = $LASTEXITCODE
        Write-NcLog "restore: $out"
    }
    $ErrorActionPreference = "Stop"
    Remove-Item $scriptFile.FullName -Force -ErrorAction SilentlyContinue
    if ($code -ne 0) {
        Fail "a restauracao do backup parou em: $stage. O zip ficou em $zip." `
            "abra o instalador de novo: ele restaura o backup desde o inicio. Se repetir, chame o suporte NCommerce."
    }
    Restore-BackupPlugins
    New-Item -ItemType File -Force -Path $marker | Out-Null
    $restored = "servidor"
    if ($ChosenZip) { $restored = $ChosenZip }
    Set-NcState "backup_restaurado" $restored
    Say "Backup restaurado."
}

function Send-StoreToken([string]$Token) {
    if (Test-TokenOnVolume 3) {
        Say "O token desta maquina ja esta gravado."
        return
    }
    $setupFile = New-TemporaryFile
    $setupCode = Get-DockerSetup $setupFile.FullName
    $already = $false
    if ($setupCode -eq "200") {
        $setupRaw = "$(Get-Content -Raw -LiteralPath $setupFile.FullName)"
        if ($setupRaw -match '"setup_required"\s*:\s*false') { $already = $true }
    }
    Remove-Item $setupFile.FullName -Force -ErrorAction SilentlyContinue
    if ($already) {
        Say "O token desta maquina ja esta gravado."
        return
    }
    $payloadFile = New-TemporaryFile
    $answerFile = New-TemporaryFile
    $postHttp = "000"
    $answer = ""
    try {
        [System.IO.File]::WriteAllText($payloadFile.FullName, (@{ token = $Token } | ConvertTo-Json -Compress))
        # 502: a API nao conseguiu conferir o token com o mestre. Tenta de novo.
        for ($i = 1; $i -le 4; $i++) {
            $ErrorActionPreference = "Continue"
            $postHttp = & curl.exe -sS -m 40 -H "Host: localhost" -H "Content-Type: application/json" --data-binary "@$($payloadFile.FullName)" -o $answerFile.FullName -w "%{http_code}" "http://127.0.0.1:3000/api/v1/docker_setup" 2>$null
            $ErrorActionPreference = "Stop"
            $postHttp = "$postHttp".Trim()
            if ($postHttp -match '^\d{3}$' -and $postHttp -ne "000" -and $postHttp -ne "502" -and $postHttp -ne "503") { break }
            if ($i -lt 4) { Start-Sleep -Seconds (10 * $i) }
        }
        if (Test-Path -LiteralPath $answerFile.FullName) { $answer = "$(Get-Content -Raw -LiteralPath $answerFile.FullName)" }
    } finally {
        Remove-Item $payloadFile.FullName, $answerFile.FullName -Force -ErrorAction SilentlyContinue
    }
    if ($postHttp -ne "200" -or $answer -notmatch '"ok"\s*:\s*true') {
        if ($answer.Length -gt 300) { $answer = $answer.Substring(0, 300) }
        Write-NcLog "docker_setup POST: HTTP $postHttp $answer"
        Fail "o NCommerce nao aceitou a identificacao desta empresa (HTTP $postHttp)." `
            "abra o instalador de novo. Se repetir, mande o log para o suporte NCommerce."
    }
    if (-not (Test-TokenOnVolume)) {
        Fail "o NCommerce respondeu que gravou o token, mas ele nao esta no disco." `
            "abra o instalador de novo. Se repetir, mande o log para o suporte NCommerce."
    }
    Say "Token gravado."
}

function Import-StoreData($Grant, [string]$BackupZip) {
    if ($script:Mode -eq "reparo") {
        Say "Loja ja instalada: os dados ficam como estao."
        return
    }
    $token = [string]$Grant.token
    $marker = Join-Path $InstallDir ".backup-restored"
    if ($BackupZip) {
        Use-BackupZip $BackupZip
        Restore-CompanyBackup $token $BackupZip
    } elseif ($script:StoreAlreadyLive) {
        # O backup do servidor e mais velho que o banco de uma loja que ja funciona:
        # restaurar por cima apagaria as vendas feitas depois dele.
        Say "Esta loja ja estava funcionando neste computador: o backup do servidor NAO e restaurado por cima."
        Say "(Para restaurar um backup de proposito, abra com -Backup C:\caminho\arquivo.zip.)"
        New-Item -ItemType File -Force -Path $marker | Out-Null
    } elseif (Test-Path -LiteralPath $marker) {
        Say "O backup ja foi restaurado numa execucao anterior."
    } else {
        Save-CompanyBackup ([string]$Grant.install_code) $token
        Restore-CompanyBackup $token ""
    }
    Send-StoreToken $token
}

# ============================================================ etapa 10

function New-UpdateShortcut {
    try {
        $desktop = [Environment]::GetFolderPath("Desktop")
        if (-not $desktop) {
            Warn "nao achei a Area de Trabalho para criar o atalho Atualizar NCommerce."
            return
        }
        $lnk = Join-Path $desktop "Atualizar NCommerce.lnk"
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($lnk)
        $shortcut.TargetPath = "cmd.exe"
        $shortcut.Arguments = '/c "' + (Join-Path $InstallDir "ncommerce-docker-update.bat") + ' & pause"'
        $shortcut.WorkingDirectory = $InstallDir
        $shortcut.WindowStyle = 1
        $shortcut.Description = "Atualiza os scripts deste PC, baixa a versao publicada e recria os containers"
        $shortcut.Save()
        Say "Atalho: $lnk"
    } catch {
        Warn "nao consegui criar o atalho Atualizar NCommerce na Area de Trabalho ($($_.Exception.Message))."
    }
}

function Get-RunningServices {
    Push-Location $InstallDir
    try {
        $ErrorActionPreference = "Continue"
        $out = & $DockerExe compose ps --status running --services 2>$null
        return @($out | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
    } finally {
        Pop-Location
    }
}

# So declara sucesso depois de ver a loja funcionando de verdade e o inicio
# automatico configurado.
function Assert-StoreWorking {
    $wanted = @("mysql", "redis", "api", "web", "guard")
    $running = Get-RunningServices
    $down = @($wanted | Where-Object { $running -notcontains $_ })
    if ($down.Count -gt 0) {
        # Um container pode estar reiniciando logo depois do restore: mais uma chance.
        Start-Sleep -Seconds 15
        Invoke-Compose -Arguments @("up", "-d") -Quiet | Out-Null
        Start-Sleep -Seconds 10
        $running = Get-RunningServices
        $down = @($wanted | Where-Object { $running -notcontains $_ })
    }
    if ($down.Count -gt 0) {
        Invoke-Compose -Arguments @("ps") -Quiet | Out-Null
        Fail "estas partes do NCommerce nao ficaram ligadas: $($down -join ', ')." `
            "reinicie o computador e abra o instalador de novo. Se repetir, mande o log para o suporte NCommerce."
    }
    Say "Containers ligados: mysql, redis, api, web e guard."

    $probe = New-TemporaryFile
    $identified = $false
    $http = "000"
    for ($i = 1; $i -le 36; $i++) {
        $http = Get-DockerSetup $probe.FullName
        if ($http -eq "200" -and "$(Get-Content -Raw -LiteralPath $probe.FullName)" -match '"setup_required"\s*:\s*false') { $identified = $true; break }
        Start-Sleep -Seconds 5
    }
    Remove-Item $probe.FullName -Force -ErrorAction SilentlyContinue
    if (-not $identified) {
        if ($http -eq "200") {
            Fail "o NCommerce esta no ar mas ainda sem a identificacao da empresa (token)." `
                "abra o instalador de novo. Se repetir, mande o log para o suporte NCommerce."
        }
        Invoke-Compose -Arguments @("logs", "--tail", "40", "api") -Quiet | Out-Null
        Fail "a API do NCommerce nao respondeu na conferencia final (HTTP $http)." `
            "espere 5 minutos e abra o instalador de novo. Se repetir, mande o log para o suporte NCommerce."
    }
    Say "API respondendo e identificada."

    $webOk = $false
    $webHttp = "000"
    for ($i = 1; $i -le 24; $i++) {
        $ErrorActionPreference = "Continue"
        $webHttp = "$(& curl.exe -sS -o NUL -w "%{http_code}" -m 5 "http://127.0.0.1:4200/" 2>$null)".Trim()
        $ErrorActionPreference = "Stop"
        if ($webHttp -match '^[23]\d\d$') { $webOk = $true; break }
        Start-Sleep -Seconds 5
    }
    if (-not $webOk) {
        Invoke-Compose -Arguments @("logs", "--tail", "40", "web") -Quiet | Out-Null
        Fail "a tela do NCommerce (porta 4200) nao abriu na conferencia final (HTTP $webHttp)." `
            "abra o instalador de novo. Se repetir, mande o log para o suporte NCommerce."
    }
    Say "Tela do sistema abrindo na porta 4200."

    # Inicio automatico: a tarefa de logon liga o Docker Desktop e a stack.
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $task) {
        Fail "a tarefa '$TaskName', que liga o NCommerce quando o Windows inicia, nao ficou registrada." `
            "abra o instalador de novo. Se repetir, mande o log para o suporte NCommerce."
    }
    if ("$($task.State)" -eq "Disabled") {
        try { Enable-ScheduledTask -TaskName $TaskName | Out-Null } catch { }
        Warn "a tarefa '$TaskName' estava desativada. Reativei; se alguem desativar de novo, a loja nao liga sozinha."
    }
    if (-not (Test-Path -LiteralPath (Join-Path $InstallDir "ncommerce-docker-startup.bat"))) {
        Fail "o arquivo que liga o NCommerce no logon sumiu de $InstallDir." "abra o instalador de novo."
    }
    Say "Inicio automatico no logon do Windows: conferido."
}

# Depois de uma queda de energia alguem precisa entrar no Windows para o Docker
# Desktop abrir. Com logon automatico a loja volta sozinha.
function Test-AutoLogon {
    try {
        $key = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -ErrorAction Stop
        return ("$($key.AutoAdminLogon)" -eq "1")
    } catch {
        return $false
    }
}

function Show-Success([string]$CupsPort) {
    $siteHost = "localhost"
    $firstIp = ((Get-EnvValue (Join-Path $InstallDir ".env") "NCOMMERCE_HOST_IPS") -split ",")[0]
    if ($firstIp) { $siteHost = $firstIp }
    Say ""
    Say "==================================================================" "Green"
    if ($script:NcWarnings.Count -eq 0) {
        Say "  INSTALACAO CONCLUIDA COM SUCESSO. O NCOMMERCE ESTA NO AR." "Green"
    } else {
        Say "  INSTALACAO CONCLUIDA. O NCOMMERCE ESTA NO AR, COM AVISOS." "Green"
    }
    Say "==================================================================" "Green"
    Say "  Site:  http://${siteHost}:4200"
    Say "  API:   http://localhost:3000"
    Say "  CUPS:  http://127.0.0.1:$CupsPort"
    Say "  SSH:   porta 22, usuario e senha desta conta do Windows"
    Say "O NCommerce liga sozinho quando alguem entra no Windows (tarefa '$TaskName')."
    if (-not (Test-AutoLogon)) {
        Say "IMPORTANTE: depois de uma queda de energia o PC precisa entrar no Windows sozinho para a loja voltar."
        Say "O suporte configura isso com o comando netplwiz (entrar sem pedir senha)."
    }
    Say "Atualizar: atalho Atualizar NCommerce na Area de Trabalho."
    Say "Impressora USB plugada depois: o Windows compartilha sozinho e ela aparece no CUPS em ate 5 minutos."
    if ($script:NcWarnings.Count -gt 0) {
        Say ""
        Say "Avisos (a loja funciona; avise o suporte NCommerce destes pontos):" "Yellow"
        foreach ($w in $script:NcWarnings) { Say "  - $w" "Yellow" }
    }
    if ($script:NcLogFile) { Say "Log desta instalacao: $($script:NcLogFile)" }
    Say "Pode fechar esta janela."
}

# ============================================================ roteiro

$exitCode = 1
try {
    $script:Lock = Enter-NcLock "Global\NCommerceInstalador"
    # No logon a tarefa de inicio (ncommerce-update.ps1 -Recuperar) segura a
    # trava por alguns segundos: espera um pouco antes de desistir.
    for ($i = 0; -not $script:Lock -and $i -lt 15; $i++) {
        if ($i -eq 0) { Write-Host "Esperando outra janela do NCommerce terminar..." }
        Start-Sleep -Seconds 2
        $script:Lock = Enter-NcLock "Global\NCommerceInstalador"
    }
    if (-not $script:Lock) {
        Write-Host ""
        Write-Host "O instalador do NCommerce ja esta aberto em outra janela (ou uma atualizacao esta rodando)." -ForegroundColor Yellow
        Write-Host "Espere ela terminar. Esta janela pode ser fechada."
        $script:Verdict = "ocupado"
        exit 2
    }

    New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
    Start-NcLog (Join-Path $InstallDir "logs") "instalacao"
    Initialize-NcState (Join-Path $DataDir "instalacao.estado")
    Initialize-NcConsole "NCommerce - instalando - NAO FECHE ESTA JANELA"

    Say "=================================================================="
    Say "  INSTALADOR DO NCOMMERCE"
    Say "=================================================================="
    Say "Sao $($script:NcStepTotal) etapas e leva de 20 a 60 minutos, conforme a internet."
    Say "NAO FECHE ESTA JANELA e nao desligue o computador ate aparecer o resultado." "Yellow"
    Say "Se a instalacao parar por qualquer motivo, e so abrir o InstaladorWindows.bat de novo: ela continua."
    if ($script:NcLogFile) { Say "Log desta instalacao: $($script:NcLogFile)" }
    Write-NcLog ("instalador v2; pasta {0}; PowerShell {1}; {2}" -f $Root, $PSVersionTable.PSVersion, [Environment]::OSVersion.VersionString)

    Set-NcState "versao_instalador" "2"
    Set-NcState "ultima_execucao" ([string](Get-UnixTime))
    $attempts = 0
    [int]::TryParse((Get-NcState "tentativas"), [ref]$attempts) | Out-Null
    Set-NcState "tentativas" ([string]($attempts + 1))

    # Arquivos baixados da internet vem marcados; o Windows pergunta antes de abrir cada um.
    try { Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue } catch { }

    # A retomada automatica nao insiste para sempre.
    $resumes = 0
    [int]::TryParse((Get-NcState "retomadas"), [ref]$resumes) | Out-Null
    if ($Retomada) {
        $resumes++
        Set-NcState "retomadas" ([string]$resumes)
        Say "Continuando a instalacao que nao terminou da ultima vez."
    }
    # Uma tentativa anterior pode ter agendado o aviso por WhatsApp e o usuario abriu
    # o instalador antes da tarefa rodar. Quem chegou aqui nao precisa do aviso.
    Clear-RebootNotice

    Step 1 "Conferindo o computador"
    Assert-Computer
    Set-NcStepDone "conferir"

    Step 2 "Preparando o Windows (WSL2)"
    if ($resumes -lt $MaxAutoResumes) { Register-ResumeTask | Out-Null } else { Clear-ResumeTask }
    Initialize-Wsl
    Set-NcStepDone "wsl"

    Step 3 "Acesso do suporte (rede, SSH e AnyDesk)"
    Set-StoreNetworkPrivate
    Enable-OpenSshServer
    Install-AnyDesk
    New-AnyDeskShortcut
    Set-NcStepDone "suporte"

    Step 4 "Docker Desktop"
    # O Docker fica pronto antes de pedir o codigo: se ele travar, o codigo nao e gasto.
    Install-DockerDesktop
    Start-DockerDesktop
    Set-NcStepDone "docker"

    Step 5 "Codigo de instalacao"
    $grant = Get-StoreGrant
    $backupZip = ""
    $registryFromMaster = ""
    if ($grant) {
        Set-AnyDeskPassword ([string]$grant.anydesk_password)
        $grant.PSObject.Properties.Remove("anydesk_password")
        $grant.PSObject.Properties.Remove("git_private_key")
        $registryFromMaster = [string]$grant.registry
        $backupZip = Select-BackupZip ([string]$grant.token)
    }
    Say ""
    Say "Agora e so esperar. Nao precisa digitar mais nada ate o fim."
    Set-NcStepDone "codigo"

    Step 6 "Arquivos e servicos do NCommerce"
    # Atualizacao que morreu no download: a etiqueta "latest" volta antes de qualquer compose up.
    $interruptedMsg = Repair-InterruptedUpdate (Get-EnvValue (Join-Path $InstallDir ".env") "NCOMMERCE_REGISTRY" $DefaultRegistry)
    if ($interruptedMsg) { Say $interruptedMsg }
    Save-LiveStoreSnapshot
    Install-StoreFiles $registryFromMaster
    Set-NcStepDone "arquivos"

    Step 7 "Baixando o NCommerce"
    Save-StoreImages $grant
    Set-NcStepDone "download"

    Step 8 "Ligando o NCommerce"
    Start-Store
    Set-NcStepDone "ligar"

    Step 9 "Dados da loja"
    Import-StoreData $grant $backupZip
    $grant = $null
    Set-NcStepDone "dados"

    Step 10 "Conferencia final"
    New-UpdateShortcut
    # Impressora USB: o container imprime por LPD na impressora compartilhada do Windows.
    # Falha aqui nao desfaz a instalacao: a tarefa de impressoras tenta de novo sozinha.
    $printerArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $InstallDir "usb-printers.ps1"))
    if ($script:Mode -eq "reparo" -or $Retomada) { $printerArgs += "-SemDriver" }
    $ErrorActionPreference = "Continue"
    & powershell.exe @printerArgs
    $printerCode = $LASTEXITCODE
    $ErrorActionPreference = "Stop"
    if ($printerCode -ne 0) { Warn "a impressora USB nao foi preparada agora. Avise o suporte se a loja usa impressora USB." }
    Assert-StoreWorking
    Set-NcStepDone "conferencia_final"
    Set-NcState "concluida" ([string](Get-UnixTime))
    Remove-NcState "codigo"
    Remove-NcState "backup_escolha"
    Remove-NcState "retomadas"
    Clear-ResumeTask
    Clear-RebootNotice
    Remove-LiveStoreSnapshot

    Show-Success $script:CupsPort
    $script:Verdict = "ok"
    $exitCode = 0
} catch {
    # Erro que nenhuma etapa previu. O detalhe vai para o log; a tela diz o que fazer.
    if ($script:Verdict -eq "") {
        $detail = "$($_.Exception.Message)"
        Write-NcLog "ERRO inesperado: $detail"
        Write-NcLog "$($_.ScriptStackTrace)"
        Undo-LiveStoreChanges
        Show-Failure "um passo falhou de um jeito que o instalador nao esperava ($detail)." ""
        $script:Verdict = "falha"
    }
} finally {
    # Tambem passa aqui com Ctrl+C: o estado em disco ja esta consistente, so falta avisar.
    if ($script:Verdict -eq "") {
        Write-NcLog "Instalacao interrompida (Ctrl+C ou janela fechada) na etapa $($script:NcStepNow)."
        Undo-LiveStoreChanges
        Write-Host ""
        Write-Host "A INSTALACAO FOI INTERROMPIDA. Abra o InstaladorWindows.bat de novo: ela continua de onde parou." -ForegroundColor Yellow
    }
    Close-Installer
}
exit $exitCode
