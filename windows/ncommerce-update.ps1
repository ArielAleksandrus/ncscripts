<#
  Atualizacao do NCommerce no Windows. O atalho "Atualizar NCommerce"
  (ncommerce-docker-update.bat) chama este arquivo. Igual ao docker/update.sh
  do Linux:

  - Antes, atualiza os scripts de C:\NCommerce com o ncscripts publicado
    (update-host.ps1). Se este arquivo mudou, segue com o novo.
  - A loja so e tocada depois que a versao nova inteira esta baixada. Internet
    caindo, janela fechada ou Ctrl+C durante o download deixam a loja na versao
    em que estava.
  - Se a versao nova muda o banco, uma copia dele fica antes em
    C:\NCommerce\backups (as 3 ultimas).
  - Se a versao nova nao liga, volta para a anterior. Depois, a guarda (servico
    guard) confere a versao nova por 5 minutos e volta sozinha se ela falhar.
  - Uma atualizacao por vez (a mesma trava do instalador). Log de cada uma em
    C:\NCommerce\logs\atualizacao-*.log.

  -SemScripts   nao atualiza os scripts antes (quem chamou ja atualizou).
  -Recuperar    uso da tarefa de logon (ncommerce-docker-startup.bat): so
                desfaz o que uma atualizacao interrompida deixou pela metade,
                sem baixar nada. Sai com 2 se uma atualizacao esta rodando.
#>
param([string]$InstallDir = "", [switch]$SemScripts, [switch]$Recuperar)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
if (-not $InstallDir) { $InstallDir = $PSScriptRoot }
$InstallDir = $InstallDir.TrimEnd('\', '/')
if ($env:NCOMMERCE_DOCKER_EXE) {
    $DockerExe = $env:NCOMMERCE_DOCKER_EXE
} else {
    $DockerExe = Join-Path $env:ProgramFiles "Docker\Docker\resources\bin\docker.exe"
}
$DockerDesktop = ""
if ($env:ProgramFiles) { $DockerDesktop = Join-Path $env:ProgramFiles "Docker\Docker\Docker Desktop.exe" }
$WaitSeconds = 390
if ($env:NCOMMERCE_UPDATE_WAIT_S) { $WaitSeconds = [int]$env:NCOMMERCE_UPDATE_WAIT_S }
$RetryWait = 15
if ($env:NCOMMERCE_RETRY_WAIT_S) { $RetryWait = [int]$env:NCOMMERCE_RETRY_WAIT_S }
$MinFreeGb = 2
if ($env:NCOMMERCE_MIN_FREE_GB) { $MinFreeGb = [double]$env:NCOMMERCE_MIN_FREE_GB }
$LockName = "Global\NCommerceInstalador"
$DefaultRegistry = "registry.ncommerce.app:5050"

$lib = Join-Path $PSScriptRoot "instalador-lib.ps1"
if (-not (Test-Path -LiteralPath $lib)) {
    Write-Host "Falta $lib. A loja nao foi tocada." -ForegroundColor Red
    Write-Host "Chame o suporte NCommerce (o instalador poe esse arquivo no lugar)."
    exit 1
}
. $lib

$EnvFile = Join-Path $InstallDir ".env"
$script:Phase = "inicio"
$script:Finished = $false
$script:Registry = $DefaultRegistry
$script:PrevTag = "latest"
$script:OldApi = ""
$script:OldWeb = ""
$script:Lock = $null

function Show-Verdict([string]$Title, [string[]]$Lines = @(), [string]$Color = "White") {
    Say ""
    Say "==================================================================" $Color
    Say "  $Title" $Color
    Say "==================================================================" $Color
    foreach ($l in $Lines) { if ($l) { Say $l } }
    if ($script:NcLogFile) { Say "Log desta atualizacao: $($script:NcLogFile)" }
}

function Get-StoreEnv([string]$Key, [string]$Default) { return (Get-EnvValue $EnvFile $Key $Default) }

function Invoke-ChildScript([string]$Name, [string[]]$Extra = @()) {
    $file = Join-Path $InstallDir $Name
    if (-not (Test-Path -LiteralPath $file)) { return 0 }
    $ps = (Get-Process -Id $PID).Path
    $psArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $file) + $Extra
    return (Invoke-Native -Exe $ps -Arguments $psArgs)
}

function Wait-Docker([int]$Seconds) {
    for ($waited = 0; $waited -lt $Seconds; $waited += 5) {
        if (Test-DockerUp) { return $true }
        if ($waited -gt 0 -and ($waited % 60) -eq 0) { Say "  ainda esperando o Docker ($([int]($waited / 60)) min)..." }
        Start-Sleep -Seconds 5
    }
    return (Test-DockerUp)
}

# Uma loja numa versao guardada (keep-<versao>) que sumiu do computador nao
# liga: volta para a publicada.
function Repair-MissingKeepTag {
    $tag = Get-StoreEnv "NCOMMERCE_TAG" "latest"
    if ($tag -notlike "keep-*") { return }
    if (Get-ImageId "$($script:Registry)/ncommerce/api:$tag") { return }
    Say "A versao guardada $($tag.Substring(5)) nao esta mais neste computador. Voltando para a publicada."
    Set-EnvValues $EnvFile ([ordered]@{ NCOMMERCE_TAG = "latest" }) | Out-Null
}

# A primeira linha da ultima migration da imagem: se mudou, a versao nova mexe no banco.
function Get-LastMigration([string]$ImageId) {
    return (Get-DockerText @("run", "--rm", "--network", "none", "--entrypoint", "sh", $ImageId, "-c",
            "ls /app/ncommerce_api/db/migrate 2>/dev/null | sort | tail -n 1 | cut -c1-14"))
}

# Espera a guarda dizer se a versao nova funciona. 0 boa, 1 a guarda voltou
# para outra, 3 ainda em teste. $script:VerdictName fica com o nome da versao.
function Wait-GuardVerdict {
    $script:VerdictName = ""
    $running = @((Get-DockerText @("compose", "ps", "-q", "guard")) -split "`n" | Where-Object { $_ })
    if ($running.Count -eq 0) { return 3 }
    $tag = Get-StoreEnv "NCOMMERCE_TAG" "latest"
    $newImg = Get-ImageId "$($script:Registry)/ncommerce/api:$tag"
    $versions = Join-Path $InstallDir "control\versions.txt"
    Say ""
    Say "Conferindo a versao nova (ate $([int]($WaitSeconds / 60)) minutos). Pode fechar: a conferencia continua sozinha."
    $name = ""
    for ($i = 0; $i -lt $WaitSeconds; $i += 10) {
        $img = Get-ServiceImage "api"
        $line = ""
        if ($img -and [System.IO.File]::Exists($versions)) {
            $line = @([System.IO.File]::ReadAllLines($versions) | Where-Object { $_ -like "*|$img|*" })[0]
        }
        $state = ""
        if ($line) {
            $parts = $line -split '\|'
            $name = $parts[0]
            if ($parts.Count -ge 5) { $state = $parts[4] }
        }
        if ($newImg -and $img -and $img -ne $newImg) {
            $script:VerdictName = $name
            if (-not $script:VerdictName) { $script:VerdictName = "anterior" }
            return 1
        }
        if ($state -eq "good") {
            $script:VerdictName = $name
            return 0
        }
        Start-Sleep -Seconds 10
    }
    $script:VerdictName = $name
    if (-not $script:VerdictName) { $script:VerdictName = "nova" }
    return 3
}

# Sai do jeito certo para a fase em que a atualizacao parou. Tambem roda no
# Ctrl+C (o finally do PowerShell passa por aqui).
function Complete-Interrupted([bool]$Interrupted) {
    if ($script:Finished) { return }
    $script:Finished = $true
    switch ($script:Phase) {
        "baixando" {
            Restore-LatestTags $script:Registry $script:PrevTag $script:OldApi $script:OldWeb
            Clear-UpdateState
            $why = ""
            if ($Interrupted) { $why = "A atualizacao foi interrompida (janela fechada ou Ctrl+C)." }
            Show-Verdict "A ATUALIZACAO NAO FOI FEITA. A LOJA CONTINUA NA VERSAO EM QUE ESTAVA." @($why,
                "O que fazer: confira a internet e use o atalho Atualizar NCommerce de novo.") "Yellow"
        }
        "ligando" {
            Say "A atualizacao parou no meio da troca. Ligando o NCommerce de novo..."
            if ((Invoke-Compose -Arguments @("up", "-d") -Quiet) -eq 0) { Clear-UpdateState }
            Show-Verdict "A ATUALIZACAO FOI INTERROMPIDA NO MEIO DA TROCA." @(
                "O NCommerce esta sendo religado. Espere 2 minutos e confira se o sistema abre.",
                "Depois use o atalho Atualizar NCommerce de novo. Se o sistema nao abrir, chame o suporte.") "Yellow"
        }
        "conferindo" {
            # A versao nova ja esta no lugar; so a espera pelo veredito parou.
            Show-Verdict "ATUALIZACAO FEITA. A CONFERENCIA DA VERSAO NOVA CONTINUA SOZINHA." @(
                "Se ela falhar, o NCommerce volta sozinho para a anterior. Veja em alguns minutos se o sistema abre.") "Yellow"
        }
        default {
            Show-Verdict "A ATUALIZACAO NAO FOI FEITA. A LOJA CONTINUA COMO ESTAVA." @(
                "O que fazer: use o atalho Atualizar NCommerce de novo. Se repetir, mande o log para o suporte.") "Yellow"
        }
    }
}

function Stop-Update([string]$Why) {
    Say $Why
    Complete-Interrupted $false
    throw "parou"
}

# ----------------------------------------------------------------- recuperar

function Invoke-Recover {
    $script:Registry = Get-StoreEnv "NCOMMERCE_REGISTRY" $DefaultRegistry
    if (Repair-EnvFile $EnvFile) { Write-Host "O arquivo $EnvFile estava vazio. Voltei a copia anterior." }
    if (-not (Test-DockerUp)) { return 0 }
    $msg = Repair-InterruptedUpdate $script:Registry
    if ($msg) { Write-Host $msg }
    Repair-MissingKeepTag
    return 0
}

# --------------------------------------------------------------- atualizar

function Invoke-Update {
    Say "Atualizando o NCommerce. NAO FECHE ESTA JANELA ate aparecer o resultado."
    Say "A loja continua funcionando durante o download."
    if ($script:NcLogFile) { Say "Log desta atualizacao: $($script:NcLogFile)" }
    Write-NcLog ("ncommerce-update.ps1; pasta {0}; docker {1}; PowerShell {2}" -f $InstallDir, $DockerExe, $PSVersionTable.PSVersion)

    if (-not (Test-Path -LiteralPath (Join-Path $InstallDir "docker-compose.yml"))) {
        Stop-Update "Nao achei $InstallDir\docker-compose.yml. Rode o InstaladorWindows.bat antes."
    }

    if (-not (Test-DockerUp)) {
        Say "O Docker nao esta respondendo. Ligando o Docker Desktop..."
        if ($DockerDesktop -and (Test-Path -LiteralPath $DockerDesktop)) {
            try { Start-Process explorer.exe -ArgumentList "`"$DockerDesktop`"" } catch { Write-NcLog "Docker Desktop: $($_.Exception.Message)" }
        }
        if (-not (Wait-Docker 300)) {
            Stop-Update "O Docker deste computador nao ligou. Reinicie o computador e tente de novo; se repetir, chame o suporte."
        }
    }

    if (Repair-EnvFile $EnvFile) { Say "O arquivo $EnvFile estava vazio. Voltei a copia anterior." }
    $script:Registry = Get-StoreEnv "NCOMMERCE_REGISTRY" $DefaultRegistry
    # Uma atualizacao anterior que morreu (janela fechada, queda de energia).
    $msg = Repair-InterruptedUpdate $script:Registry
    if ($msg) {
        Say $msg
        if ((Read-UpdateState)) {
            if ((Invoke-Compose -Arguments @("up", "-d")) -eq 0) { Clear-UpdateState }
        }
    }
    Repair-MissingKeepTag

    New-Item -ItemType Directory -Force -Path (Join-Path $InstallDir "control") | Out-Null
    # Endereco novo do registry e do mestre (api e registry.ncommerce.app). So avisa se falhar.
    Invoke-ChildScript "migrate-endpoints.ps1" @($InstallDir) | Out-Null
    Invoke-ChildScript "refresh-host-ips.ps1" @($InstallDir) | Out-Null
    Invoke-ChildScript "anydesk-id.ps1" @($InstallDir) | Out-Null
    $script:Registry = Get-StoreEnv "NCOMMERCE_REGISTRY" $DefaultRegistry

    # A versao nova precisa de espaco para baixar ao lado da atual.
    try {
        $drive = New-Object System.IO.DriveInfo ([System.IO.Path]::GetPathRoot($InstallDir))
        $freeGb = [math]::Round($drive.AvailableFreeSpace / 1GB, 1)
        if ($freeGb -lt $MinFreeGb) {
            Stop-Update ("O disco deste computador esta quase cheio ({0} GB livres). A atualizacao precisa de pelo menos {1} GB. Chame o suporte NCommerce para liberar espaco." -f $freeGb, $MinFreeGb)
        }
    } catch {
        if ("$($_.Exception.Message)" -eq "parou") { throw }
        Write-NcLog "Espaco livre nao conferido: $($_.Exception.Message)"
    }

    $script:PrevTag = Get-StoreEnv "NCOMMERCE_TAG" "latest"
    $script:OldApi = Get-ServiceImage "api"
    $script:OldWeb = Get-ServiceImage "web"

    # ---- 1. Download. A loja segue no ar, na versao atual. O .env ainda nao
    # muda: a etiqueta "latest" vai so no ambiente deste processo.
    $script:Phase = "baixando"
    Write-UpdateState "pull" $script:OldApi $script:OldWeb $script:PrevTag
    Say ""
    Say "Baixando a versao publicada. Pode levar de 2 a 30 minutos, conforme a internet."
    $env:NCOMMERCE_TAG = "latest"
    $pulled = $false
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        if ((Invoke-Compose -Arguments @("pull")) -eq 0) { $pulled = $true; break }
        if ($attempt -lt 3) {
            Say "O download parou (tentativa $attempt de 3). Tentando de novo em $($attempt * $RetryWait) segundos..."
            Start-Sleep -Seconds ($attempt * $RetryWait)
        }
    }
    if (-not $pulled) {
        Stop-Update "Nao consegui baixar a versao nova: a internet caiu ou o servidor nao respondeu."
    }

    $newApi = Get-ImageId "$($script:Registry)/ncommerce/api:latest"
    if ($newApi -and $script:OldApi -and $newApi -ne $script:OldApi -and $env:NCOMMERCE_SKIP_DB_BACKUP -ne "1") {
        $oldMig = Get-LastMigration $script:OldApi
        $newMig = Get-LastMigration $newApi
        if (-not $oldMig -or $oldMig -ne $newMig) {
            Say "A versao nova muda o banco de dados. Guardando uma copia antes..."
            if (-not (Save-DatabaseDump "antes-de-atualizar")) {
                Stop-Update "Nao consegui guardar a copia do banco (disco cheio ou banco parado), entao nao atualizei. Chame o suporte NCommerce."
            }
        }
    }

    # ---- 2. Troca. Daqui em diante a versao nova inteira esta no computador.
    # Uma troca de versao (guarda) deixa NCOMMERCE_TAG=keep-<versao>. Atualizar volta para a publicada.
    $script:Phase = "ligando"
    Write-UpdateState "up" $script:OldApi $script:OldWeb $script:PrevTag
    if ($script:PrevTag -ne "latest") { Set-EnvValues $EnvFile ([ordered]@{ NCOMMERCE_TAG = "latest" }) | Out-Null }
    Say "Trocando para a versao nova. O sistema fica fora do ar por cerca de um minuto..."
    if ((Invoke-Compose -Arguments @("up", "-d")) -ne 0) {
        Say "O Docker nao conseguiu ligar a versao nova. Tentando mais uma vez..."
        Start-Sleep -Seconds 10
        if ((Invoke-Compose -Arguments @("up", "-d")) -ne 0) {
            Say "Nao ligou. Voltando para a versao anterior..."
            if ($script:PrevTag -ne "latest") {
                Set-EnvValues $EnvFile ([ordered]@{ NCOMMERCE_TAG = $script:PrevTag }) | Out-Null
                $env:NCOMMERCE_TAG = $script:PrevTag
            } else {
                Restore-LatestTags $script:Registry $script:PrevTag $script:OldApi $script:OldWeb
            }
            Invoke-Compose -Arguments @("up", "-d") | Out-Null
            Clear-UpdateState
            $script:Finished = $true
            Show-Verdict "A ATUALIZACAO FALHOU E A LOJA VOLTOU PARA A VERSAO ANTERIOR." @(
                "Confira se o sistema abre. Mande o log para o suporte NCommerce.") "Red"
            return 1
        }
    }
    Clear-UpdateState
    $script:Phase = "conferindo"

    $status = Wait-GuardVerdict
    Invoke-Compose -Arguments @("ps") | Out-Null
    $script:Finished = $true
    switch ($status) {
        0 {
            $v = ""
            if ($script:VerdictName) { $v = "VERSAO $($script:VerdictName) " }
            Show-Verdict "ATUALIZACAO CONCLUIDA. ${v}FUNCIONANDO." @("Pode fechar esta janela.") "Green"
            return 0
        }
        1 {
            Show-Verdict "A VERSAO NOVA NAO FUNCIONOU. O NCOMMERCE VOLTOU SOZINHO PARA A VERSAO $($script:VerdictName)." @(
                "A loja esta funcionando na versao anterior. Avise o suporte NCommerce.") "Yellow"
            return 1
        }
        default {
            Show-Verdict "ATUALIZACAO FEITA. A VERSAO $($script:VerdictName) AINDA ESTA EM TESTE." @(
                "Se ela falhar, o NCommerce volta sozinho para a anterior. Pode fechar esta janela.") "Green"
            return 0
        }
    }
}

# ------------------------------------------------------------------ roteiro

# Devolve o codigo de saida. Com Ctrl+C o PowerShell para no meio e passa so
# pelo finally: la a atualizacao se arruma conforme a fase.
function Invoke-Main {
    $interrupted = $true
    try {
        $script:Lock = Enter-NcLock $LockName
        if (-not $script:Lock) {
            $interrupted = $false
            $script:Finished = $true
            if (-not $Recuperar) {
                Write-Host "Uma atualizacao (ou o instalador) do NCommerce ja esta rodando em outra janela." -ForegroundColor Yellow
                Write-Host "Espere ela terminar. Esta janela pode ser fechada."
            }
            return 2
        }
        if ($Recuperar) {
            $r = @(Invoke-Recover)
            $script:Finished = $true
            $interrupted = $false
            return [int]$r[-1]
        }

        Start-NcLog (Join-Path $InstallDir "logs") "atualizacao"
        Initialize-NcConsole "NCommerce - atualizando - NAO FECHE ESTA JANELA"

        # Scripts novos primeiro. Se este arquivo mudou, segue com o novo.
        if (-not $SemScripts) {
            $self = Join-Path $InstallDir "ncommerce-update.ps1"
            $before = ""
            if (Test-Path -LiteralPath $self) { $before = (Get-FileHash -LiteralPath $self).Hash }
            Invoke-ChildScript "update-host.ps1" @($InstallDir) | Out-Null
            if ($before -and (Test-Path -LiteralPath $self) -and (Get-FileHash -LiteralPath $self).Hash -ne $before) {
                Say "O atualizador mudou. Seguindo com o novo..."
                $script:Finished = $true
                $interrupted = $false
                # A trava passa para o novo: solta aqui e ele pega logo em seguida.
                Exit-NcLock $script:Lock
                $script:Lock = $null
                Restore-NcConsole
                $ps = (Get-Process -Id $PID).Path
                $ErrorActionPreference = "Continue"
                & $ps -NoProfile -ExecutionPolicy Bypass -File $self -InstallDir $InstallDir -SemScripts
                return [int]$LASTEXITCODE
            }
        }

        $r = @(Invoke-Update)
        $interrupted = $false
        return [int]$r[-1]
    } catch {
        $interrupted = $false
        if ("$($_.Exception.Message)" -ne "parou") {
            Write-NcLog "ERRO inesperado: $($_.Exception.Message)"
            Write-NcLog "$($_.ScriptStackTrace)"
            Say "Erro inesperado: $($_.Exception.Message)"
        }
        return 1
    } finally {
        if (-not $script:Finished) { Complete-Interrupted $interrupted }
        Restore-NcConsole
        Exit-NcLock $script:Lock
        $script:Lock = $null
    }
}

$code = @(Invoke-Main)
exit ([int]$code[-1])
