<#
  Desinstalador do NCommerce (versao Docker) no Windows.

  Remove o que o InstaladorWindows.bat criou: containers, volumes e imagens do
  NCommerce no Docker, as tarefas agendadas, as regras do firewall, os atalhos
  e as pastas C:\NCommerce e C:\ProgramData\NCommerce. Docker Desktop, WSL,
  AnyDesk, OpenSSH, driver e compartilhamento da impressora ficam: o instalador
  nao anota se eles ja existiam antes, e outros programas podem usar. No fim
  aparece a lista do que pode ser removido a mao.

  Antes de apagar qualquer coisa ele faz uma copia de seguranca FORA da
  instalacao, em C:\NCommerce-backup-desinstalacao-<data>: o banco de dados
  (conferido ate o fim), as notas fiscais e os outros arquivos da loja que
  ficam no Docker, a configuracao (.env, docker-compose.yml, token) e os
  plugins. Se a copia falhar, nada e removido. A copia fica no C: e nao em
  Documentos porque Documentos costuma ser sincronizado com o OneDrive, e a
  copia tem o token e as senhas da loja.

  -Simular      so mostra o que seria feito. Nao muda nada e nao precisa de
                administrador nem da confirmacao.
  -SemBackup    apaga SEM fazer a copia de seguranca (os dados da loja se perdem).
  -PastaBackup  pasta onde criar a copia, por exemplo um pen drive (E:\).
                Padrao: C:\.
  -Confirmacao  uso do suporte (por SSH, sem teclado): o texto DESINSTALAR.

  Pode ser interrompido (janela fechada, queda de energia) e aberto de novo:
  continua de onde parou. O progresso fica em
  C:\ProgramData\NCommerce-desinstalacao\desinstalacao.estado e o log de cada
  execucao na mesma pasta, que sobrevive a remocao. No fim o log tambem e
  copiado para a pasta da copia de seguranca.
#>
param([switch]$Simular, [switch]$SemBackup, [string]$PastaBackup = "", [string]$Confirmacao = "")

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$ConfirmWord = "DESINSTALAR"
# The tests point these at temporary folders and at the fake docker.
$InstallDir = "C:\NCommerce"
if ($env:NCOMMERCE_INSTALL_DIR) { $InstallDir = $env:NCOMMERCE_INSTALL_DIR }
$InstallDir = $InstallDir.TrimEnd('\', '/')
$DataDir = Join-Path $env:ProgramData "NCommerce"
$UninstallDir = Join-Path $env:ProgramData "NCommerce-desinstalacao"
if ($env:NCOMMERCE_DOCKER_EXE) {
    $DockerExe = $env:NCOMMERCE_DOCKER_EXE
} elseif ($env:ProgramFiles) {
    $DockerExe = Join-Path $env:ProgramFiles "Docker\Docker\resources\bin\docker.exe"
} else {
    $DockerExe = ""
}
$DockerDesktop = ""
if ($env:ProgramFiles) { $DockerDesktop = Join-Path $env:ProgramFiles "Docker\Docker\Docker Desktop.exe" }
$DockerWait = 300
if ($env:NCOMMERCE_DOCKER_WAIT_S) { $DockerWait = [int]$env:NCOMMERCE_DOCKER_WAIT_S }
$MysqlWait = 180
if ($env:NCOMMERCE_MYSQL_WAIT_S) { $MysqlWait = [int]$env:NCOMMERCE_MYSQL_WAIT_S }

# Everything below is what windows/instalador_windows.ps1 and the scripts it
# copies (usb-printers.ps1, aviso-reinicio.ps1) create, by these exact names.
$TaskNames = @("NCommerce Docker Startup", "NCommerce Instalador Retomar", "NCommerce Aviso Reinicio", "NCommerce Impressoras USB")
$FirewallRules = @("NCommerce TCP 3000", "NCommerce TCP 4200", "NCommerce LPD 515")
$ShortcutNames = @("Atualizar NCommerce.lnk", "AnyDesk - Suporte NCommerce.lnk")
$KnownRegistries = @("registry.ncommerce.app:5050", "ncommerce.app:5050")
$VolumeNames = @("mysql_data", "nfce_data", "cups_data", "api_uploads", "api_print", "api_docs", "api_log", "api_backups", "api_env", "web_promos")
# Store files that live only inside Docker. Need = the backup fails without them.
$VolumeCopies = @(
    @{ Volume = "api_env"; Service = "api"; Path = "/env"; Need = $true; What = "token e endereco do mestre" },
    @{ Volume = "nfce_data"; Service = "api"; Path = "/data/nfce"; Need = $true; What = "notas fiscais (XML)" },
    @{ Volume = "api_docs"; Service = "api"; Path = "/app/ncommerce_api/business_docs"; Need = $true; What = "documentos da empresa" },
    @{ Volume = "api_uploads"; Service = "api"; Path = "/app/ncommerce_api/public/uploads"; Need = $true; What = "imagens enviadas" },
    @{ Volume = "cups_data"; Service = "api"; Path = "/etc/cups"; Need = $false; What = "impressoras do CUPS" },
    @{ Volume = "api_backups"; Service = "api"; Path = "/var/ncommerce/backups"; Need = $false; What = "backups da API" },
    @{ Volume = "web_promos"; Service = "web"; Path = "/usr/share/nginx/html/assets/promo-tablet"; Need = $false; What = "promocoes do tablet" }
)
# C:\NCommerce\wsl is the native install in WSL (advanced/windows-wsl), not this one.
$SkipInInstallDir = @("drivers", "src", "wsl")
$Project = (Split-Path -Leaf $InstallDir).ToLower()
$Steps = @(
    @{ Name = "backup"; Title = "Copia de seguranca (banco, arquivos e configuracao)" },
    @{ Name = "tarefas"; Title = "Tarefas agendadas" },
    @{ Name = "containers"; Title = "Containers e rede do NCommerce" },
    @{ Name = "volumes"; Title = "Dados do NCommerce no Docker (volumes)" },
    @{ Name = "imagens"; Title = "Imagens do NCommerce e login do registry" },
    @{ Name = "firewall"; Title = "Regras do firewall" },
    @{ Name = "atalhos"; Title = "Atalhos" },
    @{ Name = "pastas"; Title = "Pastas do NCommerce" }
)

$lib = Join-Path $PSScriptRoot "instalador-lib.ps1"
if (-not (Test-Path -LiteralPath $lib)) {
    Write-Host ""
    Write-Host "Falta o arquivo $lib." -ForegroundColor Red
    Write-Host "Extraia o zip do instalador inteiro e abra o DesinstaladorWindows.bat de dentro da pasta extraida."
    exit 1
}
. $lib

$script:NcStepTotal = $Steps.Count
$script:Verdict = ""
$script:Lock = $null
$script:DockerState = ""
$script:StoppedStore = $false
$script:Plan = New-Object System.Collections.Generic.List[object]
$script:ManualExtra = New-Object System.Collections.Generic.List[string]

# ============================================================ fim e falha

function Close-Uninstaller {
    Restore-NcConsole
    Exit-NcLock $script:Lock
    $script:Lock = $null
}

function Fail([string]$What, [string]$Hint = "") {
    Say ""
    Say "==================================================================" "Red"
    Say "  A DESINSTALACAO NAO TERMINOU." "Red"
    Say "==================================================================" "Red"
    if ($script:NcStepNow -gt 0) {
        Say ("Parou na etapa {0} de {1}: {2}." -f $script:NcStepNow, $script:NcStepTotal, $script:NcStepTitle)
    }
    Say "O que aconteceu: $What"
    if ($Hint) {
        Say "O que fazer: $Hint"
    } else {
        Say "O que fazer: abra o DesinstaladorWindows.bat de novo. Ele continua de onde parou."
    }
    $bk = Get-NcState "backup_pasta"
    if ((Test-NcStepDone "backup") -and $bk) { Say "A copia de seguranca da loja esta em $bk." }
    if ($script:NcLogFile) { Say "Log: $($script:NcLogFile)" }
    $script:Verdict = "falha"
    Close-Uninstaller
    exit 1
}

# ============================================================ ajudantes

# PowerShell on Linux (the tests) has no UAC: treated as administrator.
function Test-IsAdmin {
    if ($PSVersionTable.PSEdition -eq "Core" -and -not $IsWindows) { return $true }
    try {
        $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        return (New-Object System.Security.Principal.WindowsPrincipal $id).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

function Test-UnderPath([string]$Path, [string]$Parent) {
    if (-not $Path -or -not $Parent) { return $false }
    $p = [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    $q = [System.IO.Path]::GetFullPath($Parent).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    return $p.StartsWith($q, [System.StringComparison]::OrdinalIgnoreCase)
}

# Docker output without the console and without changing folder (C:\NCommerce
# may be gone already). One trimmed line per item.
function Get-DockerLines([string[]]$Arguments) {
    if (-not $DockerExe) { return @() }
    $ErrorActionPreference = "Continue"
    try {
        $out = & $DockerExe @Arguments 2>$null
        if ($LASTEXITCODE -ne 0) { return @() }
        return @($out | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
    } catch {
        return @()
    }
}

# docker compose output, run in the store folder (compose file and .env).
function Get-ComposeLines([string[]]$Arguments) {
    if (-not (Test-ComposeFile)) { return @() }
    return @((Get-DockerText (@("compose") + $Arguments)) -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Test-DockerCommand([string[]]$Arguments) {
    $ErrorActionPreference = "Continue"
    try {
        & $DockerExe @Arguments *> $null
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    }
}

function Test-ComposeFile { return (Test-Path -LiteralPath (Join-Path $InstallDir "docker-compose.yml")) }

# "ok", "parado" (instalado sem responder) ou "ausente" (sem Docker).
function Get-DockerState {
    if (-not $DockerExe -or -not (Test-Path -LiteralPath $DockerExe)) { return "ausente" }
    if (Test-DockerUp) { return "ok" }
    return "parado"
}

function Start-DockerIfNeeded {
    $state = Get-DockerState
    if ($state -ne "parado") { return $state }
    Say "O Docker nao esta respondendo. Ligando o Docker Desktop..."
    if ($DockerDesktop -and (Test-Path -LiteralPath $DockerDesktop)) {
        try { Start-Process explorer.exe -ArgumentList "`"$DockerDesktop`"" } catch { Write-NcLog "Docker Desktop: $($_.Exception.Message)" }
    }
    for ($waited = 0; $waited -lt $DockerWait; $waited += 5) {
        if (Test-DockerUp) { return "ok" }
        if ($waited -gt 0 -and ($waited % 60) -eq 0) { Say "  ainda esperando o Docker ($([int]($waited / 60)) min)..." }
        Start-Sleep -Seconds 5
    }
    return (Get-DockerState)
}

function Get-StoreContainers {
    return @(Get-DockerLines @("ps", "-aq", "--filter", "label=com.docker.compose.project=$Project"))
}

function Get-StoreNetworks {
    $found = @(Get-DockerLines @("network", "ls", "-q", "--filter", "label=com.docker.compose.project=$Project"))
    if (Test-DockerCommand @("network", "inspect", "${Project}_default")) { $found += "${Project}_default" }
    return @($found | Select-Object -Unique)
}

# Volumes of the compose project: by label, and by the names the compose file declares.
function Get-StoreVolumes {
    $found = @(Get-DockerLines @("volume", "ls", "-q", "--filter", "label=com.docker.compose.project=$Project"))
    foreach ($v in $VolumeNames) {
        $name = "${Project}_$v"
        if ($found -notcontains $name -and (Test-DockerCommand @("volume", "inspect", $name))) { $found += $name }
    }
    return @($found | Select-Object -Unique)
}

function Get-StoreRegistries {
    $saved = Get-NcState "registros"
    if ($saved) { return @($saved -split ",") }
    $list = @($KnownRegistries)
    $fromEnv = Get-EnvValue (Join-Path $InstallDir ".env") "NCOMMERCE_REGISTRY"
    if ($fromEnv -and $list -notcontains $fromEnv) { $list += $fromEnv }
    return $list
}

# Only <registry>/ncommerce/api and /web, every tag (latest, keep-*, untagged).
# mysql, redis and docker:cli are public images that may serve other programs.
function Get-StoreImages {
    $repos = @(Get-StoreRegistries | ForEach-Object { [regex]::Escape($_) }) -join "|"
    $pattern = "^($repos)/ncommerce/(api|web)$"
    $refs = @()
    foreach ($line in (Get-DockerLines @("image", "ls", "--format", "{{.Repository}}|{{.Tag}}|{{.ID}}"))) {
        $f = $line -split '\|'
        if ($f.Count -lt 3 -or $f[0] -notmatch $pattern) { continue }
        if ($f[1] -and $f[1] -ne "<none>") { $refs += "$($f[0]):$($f[1])" } else { $refs += $f[2] }
    }
    return @($refs | Select-Object -Unique)
}

function Get-PresentTasks {
    $found = @()
    foreach ($t in $TaskNames) {
        try {
            if (Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue) { $found += $t }
        } catch { }
    }
    return $found
}

function Get-PresentFirewallRules {
    $found = @()
    foreach ($r in $FirewallRules) {
        try {
            if (Get-NetFirewallRule -DisplayName $r -ErrorAction SilentlyContinue) { $found += $r }
        } catch { }
    }
    return $found
}

function Get-PresentShortcuts {
    $desktop = [Environment]::GetFolderPath("Desktop")
    if (-not $desktop) { return @() }
    return @($ShortcutNames | ForEach-Object { Join-Path $desktop $_ } | Where-Object { Test-Path -LiteralPath $_ })
}

# Documentos\ncommerce\plugins, the folder the installer creates. A folder the
# support moved somewhere else stays (it may hold other things).
function Get-PluginsDir {
    $saved = Get-NcState "pasta_plugins"
    if ($saved) { return $saved }
    return (Get-EnvValue (Join-Path $InstallDir ".env") "NCOMMERCE_PLUGINS_DIR")
}

function Test-InstallerPluginsDir([string]$Dir) {
    return ($Dir -and ($Dir.Replace('\', '/').TrimEnd('/') -match '/ncommerce/plugins$'))
}

# C:\NCommerce is removed only when it looks like the store folder: never a
# drive root or a system folder, whatever NCOMMERCE_INSTALL_DIR says.
function Test-InstallDirSafe {
    if ((Get-NcState "pasta_loja_ok") -eq "1") { return $true }
    if (-not (Test-Path -LiteralPath $InstallDir -PathType Container)) { return $false }
    $full = [System.IO.Path]::GetFullPath($InstallDir).TrimEnd('\', '/')
    if (-not (Split-Path -Parent $full)) { return $false }
    foreach ($sys in @($env:SystemRoot, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData, $env:USERPROFILE, $env:HOME)) {
        if ($sys -and $full -eq [System.IO.Path]::GetFullPath($sys).TrimEnd('\', '/')) { return $false }
    }
    foreach ($marker in @("docker-compose.yml", "ncommerce-docker-startup.bat", "instalador-lib.ps1", ".env", "control")) {
        if (Test-Path -LiteralPath (Join-Path $InstallDir $marker)) { return $true }
    }
    return $false
}

function Get-TempFlag {
    if (-not $env:TEMP) { return "" }
    return (Join-Path $env:TEMP "ncommerce-instalador-iniciou.flag")
}

function Get-BackupTarget {
    $saved = Get-NcState "backup_pasta"
    if ($saved) { return $saved }
    $root = $PastaBackup
    if (-not $root -and $env:SystemDrive) { $root = "$($env:SystemDrive)\" }
    if (-not $root) { $root = Split-Path -Parent $InstallDir }
    return (Join-Path $root ("NCommerce-backup-desinstalacao-{0}" -f (Get-Date -Format "yyyyMMdd-HHmmss")))
}

# ============================================================ o plano

function Add-PlanItem([string]$Step, [string]$Text, [string]$Command = "") {
    $script:Plan.Add([pscustomobject]@{ Step = $Step; Text = $Text; Command = $Command })
}

# What this run would do, read from the computer as it is now. The same list
# is shown before the confirmation and by -Simular.
function Build-Plan([bool]$WithBackup) {
    $script:Plan.Clear()
    $dockerOk = ($script:DockerState -eq "ok")
    $composeHere = Test-ComposeFile
    $volumes = @()
    if ($dockerOk) { $volumes = Get-StoreVolumes }
    $dockerNote = "o Docker nao esta respondendo agora; na desinstalacao ele e ligado antes"

    if ($WithBackup -and -not (Test-NcStepDone "backup")) {
        $bk = Get-BackupTarget
        Add-PlanItem "backup" "Pasta da copia: $bk (montada em $bk.parcial e renomeada quando termina)"
        if ($script:DockerState -eq "parado") {
            Add-PlanItem "backup" "Banco de dados e arquivos da loja no Docker ($dockerNote)"
        } elseif ($volumes -contains "${Project}_mysql_data") {
            Add-PlanItem "backup" "Parar guard, api e web para nao entrar venda depois da copia" "docker compose stop guard api web   (em $InstallDir)"
            Add-PlanItem "backup" "Banco de dados, conferido ate o fim (Dump completed e gzip inteiro)" `
                "docker compose exec -T mysql mysqldump ... ncommerce_api_production  ->  $bk\banco\antes-de-desinstalar-<data>.sql.gz"
            foreach ($c in $VolumeCopies) {
                if ($volumes -notcontains "${Project}_$($c.Volume)") { continue }
                $kind = "obrigatorio"
                if (-not $c.Need) { $kind = "se der" }
                Add-PlanItem "backup" "Volume ${Project}_$($c.Volume): $($c.What) ($kind)" "docker cp <container $($c.Service)>:$($c.Path) $bk\volumes\$($c.Volume)"
            }
        } else {
            Add-PlanItem "backup" "Banco de dados: nao ha banco do NCommerce no Docker deste computador"
        }
        if (Test-Path -LiteralPath $InstallDir) {
            Add-PlanItem "backup" "Arquivos de $InstallDir (.env, docker-compose.yml, control, host, logs, copias antigas do banco)" `
                "copiar $InstallDir -> $bk\C_NCommerce (sem drivers, src e wsl)"
        }
        if (Test-Path -LiteralPath $DataDir) {
            Add-PlanItem "backup" "Arquivos de $DataDir (machine-id, progresso da instalacao)" "copiar $DataDir -> $bk\ProgramData_NCommerce (sem downloads)"
        }
        $plugins = Get-PluginsDir
        if ($plugins -and (Test-Path -LiteralPath $plugins)) {
            Add-PlanItem "backup" "Plugins da loja ($plugins)" "copiar $plugins -> $bk\plugins"
        }
    }

    if (-not (Test-NcStepDone "tarefas")) {
        foreach ($t in (Get-PresentTasks)) { Add-PlanItem "tarefas" "Tarefa agendada '$t'" "Unregister-ScheduledTask -TaskName '$t'" }
    }

    if ($script:DockerState -eq "parado") {
        foreach ($s in @("containers", "volumes", "imagens")) {
            if (-not (Test-NcStepDone $s)) {
                Add-PlanItem $s "Containers, volumes ${Project}_* e imagens <registry>/ncommerce/api e web do projeto '$Project' ($dockerNote)"
                break
            }
        }
    } elseif ($dockerOk) {
        if (-not (Test-NcStepDone "containers")) {
            $containers = Get-StoreContainers
            if ($containers.Count -gt 0 -and $composeHere) {
                Add-PlanItem "containers" "Containers do NCommerce ($($containers.Count)) e a rede" "docker compose down --remove-orphans   (em $InstallDir)"
            }
            foreach ($c in $containers) { Add-PlanItem "containers" "Container $c do projeto '$Project'" "docker rm -f $c" }
            foreach ($n in (Get-StoreNetworks)) { Add-PlanItem "containers" "Rede $n" "docker network rm $n" }
        }
        if (-not (Test-NcStepDone "volumes")) {
            foreach ($v in $volumes) { Add-PlanItem "volumes" "Volume $v" "docker volume rm $v" }
        }
        if (-not (Test-NcStepDone "imagens")) {
            $images = Get-StoreImages
            foreach ($i in $images) { Add-PlanItem "imagens" "Imagem $i" "docker image rm $i" }
            # The login cannot be seen from here: it goes with the rest of the store.
            if ($images.Count -gt 0 -or @($script:Plan | Where-Object { $_.Step -eq "containers" -or $_.Step -eq "volumes" }).Count -gt 0) {
                foreach ($r in (Get-StoreRegistries)) { Add-PlanItem "imagens" "Login guardado do registry $r" "docker logout $r" }
            }
        }
    }

    if (-not (Test-NcStepDone "firewall")) {
        foreach ($r in (Get-PresentFirewallRules)) { Add-PlanItem "firewall" "Regra do firewall '$r'" "Remove-NetFirewallRule -DisplayName '$r'" }
    }
    if (-not (Test-NcStepDone "atalhos")) {
        foreach ($l in (Get-PresentShortcuts)) { Add-PlanItem "atalhos" "Atalho $l" "Remove-Item '$l'" }
    }
    if (-not (Test-NcStepDone "pastas")) {
        if (Test-Path -LiteralPath $InstallDir) {
            if (Test-InstallDirSafe) {
                $keep = ""
                $wsl = Join-Path $InstallDir "wsl"
                if (Test-Path -LiteralPath $wsl) { $keep = " (menos $wsl, da instalacao nativa no WSL)" }
                Add-PlanItem "pastas" "Pasta $InstallDir$keep" "Remove-Item -Recurse '$InstallDir'"
            }
        }
        if (Test-Path -LiteralPath $DataDir) { Add-PlanItem "pastas" "Pasta $DataDir" "Remove-Item -Recurse '$DataDir'" }
        $plugins = Get-PluginsDir
        if ((Test-InstallerPluginsDir $plugins) -and (Test-Path -LiteralPath $plugins)) {
            Add-PlanItem "pastas" "Pasta de plugins $plugins e o LEIA-ME.txt ao lado (a pasta de cima sai se ficar vazia)" "Remove-Item -Recurse '$plugins'"
        }
        $flag = Get-TempFlag
        if ($flag -and (Test-Path -LiteralPath $flag)) { Add-PlanItem "pastas" "Arquivo $flag" "Remove-Item '$flag'" }
    }
}

function Show-Plan([bool]$WithCommands) {
    foreach ($s in $Steps) {
        $items = @($script:Plan | Where-Object { $_.Step -eq $s.Name })
        if (Test-NcStepDone $s.Name) {
            Say "  [$($s.Title)] ja feito numa execucao anterior."
            continue
        }
        if ($items.Count -eq 0) {
            Say "  [$($s.Title)] nada a fazer."
            continue
        }
        Say "  [$($s.Title)]"
        foreach ($i in $items) {
            Say "    - $($i.Text)"
            if ($WithCommands -and $i.Command) { Say "        comando: $($i.Command)" }
        }
    }
}

function Test-PlanHasRemovals {
    return (@($script:Plan | Where-Object { $_.Step -ne "backup" }).Count -gt 0)
}

function Show-ManualList {
    Say ""
    Say "Remova a mao se quiser (o desinstalador NAO mexe: o instalador nao anota se ja existiam, e outros programas podem usar):" "Yellow"
    Say "  - Docker Desktop e o WSL (Configuracoes > Aplicativos; recursos 'Subsistema do Windows para Linux' e 'Plataforma de Maquina Virtual')."
    Say "    Se o Docker ficar: as imagens publicas mysql:8.0, redis:7-alpine e docker:27.5.1-cli podem sair com 'docker image rm <imagem>'."
    Say "  - AnyDesk. A senha de acesso nao supervisionado do suporte NCommerce continua configurada nele:"
    Say "    desinstale o AnyDesk ou troque essa senha nas configuracoes de seguranca dele."
    Say "  - Servidor OpenSSH do Windows (porta 22): servico sshd, regra do firewall 'OpenSSH-Server-In-TCP' e"
    Say "    as linhas ClientAlive em C:\ProgramData\ssh\sshd_config (o anterior esta em sshd_config.bak)."
    Say "  - Servico LPD do Windows (recurso 'Servico LPD'), o driver da impressora (Bematech) e o compartilhamento"
    Say "    das impressoras USB (Impressoras > Propriedades da impressora > Compartilhamento)."
    Say "  - A rede da loja marcada como Privada, este usuario no grupo docker-users e o log PrintService/Operational ligado."
    Say "  - A pasta do instalador (onde esta este DesinstaladorWindows.bat)."
    foreach ($m in $script:ManualExtra) { Say "  - $m" }
}

# ============================================================ etapa 1

# Guard first (it restarts stopped containers), then the store: no sale after the copy.
function Stop-StoreForBackup {
    $running = @(Get-ComposeLines @("ps", "--status", "running", "--services"))
    if ($running -notcontains "api" -and $running -notcontains "web") { return }
    Say "Parando o NCommerce para a copia (nenhuma venda entra depois dela)..."
    $script:StoppedStore = $true
    Invoke-Compose -Arguments @("stop", "guard", "api", "web") -Quiet | Out-Null
}

function Restore-StoreAfterFailure {
    if (-not $script:StoppedStore) { return }
    $script:StoppedStore = $false
    Say "Religando o NCommerce como estava..."
    if ((Invoke-Compose -Arguments @("up", "-d") -Quiet) -ne 0) {
        Say "Nao consegui religar o NCommerce. Reinicie o computador: ele liga sozinho." "Yellow"
    }
}

function Wait-MysqlReady {
    $running = @(Get-ComposeLines @("ps", "--status", "running", "--services"))
    if ($running -notcontains "mysql") {
        Say "Ligando o banco de dados para a copia..."
        if ((Invoke-Compose -Arguments @("up", "-d", "mysql") -Quiet) -ne 0) { return $false }
    }
    for ($waited = 0; $waited -le $MysqlWait; $waited += 3) {
        Invoke-ComposeExec exec -T mysql sh -c 'mysqladmin ping -h 127.0.0.1 -uroot -p"$MYSQL_ROOT_PASSWORD" --silent' | Out-Null
        if ($LASTEXITCODE -eq 0) { return $true }
        if ($waited -lt $MysqlWait) { Start-Sleep -Seconds 3 }
    }
    return $false
}

# Reads the whole .gz: a cut file fails, and the dump must end with mysqldump's
# "Dump completed" line.
function Test-DumpComplete([string]$Path) {
    if ((Get-NcFileLength $Path) -lt 20) { return $false }
    $fs = $null
    try {
        $fs = [System.IO.File]::OpenRead($Path)
        $gz = New-Object System.IO.Compression.GZipStream($fs, [System.IO.Compression.CompressionMode]::Decompress)
        $buf = New-Object byte[] 65536
        $tail = ""
        $total = 0
        while (($n = $gz.Read($buf, 0, $buf.Length)) -gt 0) {
            $total += $n
            $tail = $tail + [System.Text.Encoding]::ASCII.GetString($buf, 0, $n)
            if ($tail.Length -gt 400) { $tail = $tail.Substring($tail.Length - 400) }
        }
        return ($total -gt 0 -and $tail.Contains("Dump completed"))
    } catch {
        return $false
    } finally {
        if ($fs) { $fs.Dispose() }
    }
}

# Copies a folder, file by file, checking each size. Skips junctions.
function Copy-Tree([string]$Source, [string]$Dest, [string[]]$Skip = @()) {
    if (-not [System.IO.Directory]::Exists($Source)) { return 0 }
    [System.IO.Directory]::CreateDirectory($Dest) | Out-Null
    $count = 0
    foreach ($f in [System.IO.Directory]::GetFiles($Source)) {
        $to = Join-Path $Dest ([System.IO.Path]::GetFileName($f))
        [System.IO.File]::Copy($f, $to, $true)
        if ((Get-NcFileLength $to) -ne (Get-NcFileLength $f)) { throw "A copia de $f ficou incompleta." }
        $count++
    }
    foreach ($d in [System.IO.Directory]::GetDirectories($Source)) {
        $name = [System.IO.Path]::GetFileName($d)
        if ($Skip -contains $name) { continue }
        if (([System.IO.File]::GetAttributes($d) -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
        $count += Copy-Tree $d (Join-Path $Dest $name)
    }
    return $count
}

function Write-BackupReadme([string]$Dir, [string]$DumpName) {
    $lines = @(
        "Copia de seguranca feita pelo desinstalador do NCommerce em $(Get-Date -Format 'dd/MM/yyyy HH:mm'), no computador $env:COMPUTERNAME.",
        "",
        "ATENCAO: esta pasta tem o token da loja e senhas. Guarde num lugar seguro (pen drive, HD externo).",
        "Nao coloque numa pasta sincronizada (OneDrive, Google Drive) e nao mande por WhatsApp ou e-mail.",
        "As notas fiscais (XML, em volumes\nfce_data) precisam ser guardadas por 5 anos.",
        "",
        "Conteudo:"
    )
    if ($DumpName) { $lines += "  banco\$DumpName   banco de dados da loja (mysqldump, conferido ate o fim)" }
    $lines += "  volumes\               arquivos da loja que ficavam no Docker (notas, documentos, imagens, impressoras, token)"
    $lines += "  C_NCommerce\           configuracao (.env, docker-compose.yml, control, host), logs e copias antigas do banco"
    $lines += "  ProgramData_NCommerce\ identificacao deste computador (machine-id)"
    $lines += "  plugins\               plugins da loja"
    $lines += "  desinstalacao-*.log    o que o desinstalador fez"
    $lines += ""
    $lines += "Para voltar a loja neste ou em outro computador, chame o suporte NCommerce com esta pasta."
    Write-FileAtomic (Join-Path $Dir "LEIA-ME.txt") (($lines -join "`r`n") + "`r`n")
}

function Stop-Backup([string]$Partial, [string]$What) {
    Remove-Item -LiteralPath $Partial -Recurse -Force -ErrorAction SilentlyContinue
    Restore-StoreAfterFailure
    Say ""
    Say "NADA FOI REMOVIDO: sem a copia de seguranca o desinstalador nao apaga nada." "Red"
    Fail "a copia de seguranca nao ficou completa: $What" `
        "confira o espaco livre no disco (e se o Docker Desktop esta aberto) e abra o DesinstaladorWindows.bat de novo. Se repetir, chame o suporte NCommerce. So para apagar sem copia (os dados se perdem): DesinstaladorWindows.bat -SemBackup."
}

function Save-UninstallBackup {
    $final = Get-NcState "backup_pasta"
    $partial = "$final.parcial"
    Say "Copia de seguranca em $final"
    # A copy cut by an earlier run starts over.
    Remove-Item -LiteralPath $partial -Recurse -Force -ErrorAction SilentlyContinue
    try {
        New-Item -ItemType Directory -Force -Path $partial | Out-Null
    } catch {
        Stop-Backup $partial "nao consegui criar a pasta $partial ($($_.Exception.Message))."
    }
    Protect-NcBackupDir $partial | Out-Null

    $dumpName = ""
    $volumes = @()
    if ($script:DockerState -eq "ok") { $volumes = Get-StoreVolumes }
    if ($volumes -contains "${Project}_mysql_data") {
        if (-not (Test-ComposeFile)) {
            Stop-Backup $partial "o banco do NCommerce esta no Docker, mas falta $InstallDir\docker-compose.yml para ligar o banco e copiar."
        }
        Stop-StoreForBackup
        if (-not (Wait-MysqlReady)) { Stop-Backup $partial "o banco de dados nao ligou para a copia." }
        if (-not (Save-DatabaseDump "antes-de-desinstalar")) { Stop-Backup $partial "a copia do banco de dados (mysqldump) falhou." }
        $dump = Get-ChildItem -LiteralPath (Join-Path $InstallDir "backups") -Filter "antes-de-desinstalar-*.sql.gz" |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if (-not $dump) { Stop-Backup $partial "a copia do banco de dados sumiu depois de feita." }
        New-Item -ItemType Directory -Force -Path (Join-Path $partial "banco") | Out-Null
        $dumpDest = Join-Path $partial "banco\$($dump.Name)"
        [System.IO.File]::Move($dump.FullName, $dumpDest)
        if (-not (Test-DumpComplete $dumpDest)) { Stop-Backup $partial "a copia do banco de dados ficou incompleta." }
        $dumpName = $dump.Name
        Say "Banco de dados copiado e conferido ($([math]::Ceiling((Get-NcFileLength $dumpDest) / 1KB)) KB comprimido)."

        foreach ($c in $VolumeCopies) {
            if ($volumes -notcontains "${Project}_$($c.Volume)") { continue }
            $cid = @(Get-ComposeLines @("ps", "-aq", $c.Service))[0]
            if (-not $cid) {
                Invoke-Compose -Arguments @("up", "--no-start", $c.Service) -Quiet | Out-Null
                $cid = @(Get-ComposeLines @("ps", "-aq", $c.Service))[0]
            }
            $dest = Join-Path $partial "volumes\$($c.Volume)"
            New-Item -ItemType Directory -Force -Path (Join-Path $partial "volumes") | Out-Null
            $code = 1
            if ($cid) { $code = Invoke-Native -Exe $DockerExe -Arguments @("cp", "${cid}:$($c.Path)", $dest) -Quiet }
            if ($code -eq 0 -and (Test-Path -LiteralPath $dest)) {
                Say "Copiado: $($c.What) ($($c.Volume))."
            } elseif ($c.Need) {
                Stop-Backup $partial "nao consegui copiar $($c.What) (volume $($c.Volume))."
            } else {
                Warn "nao consegui copiar $($c.What) (volume $($c.Volume)). O resto da copia esta completo."
            }
        }
    } elseif ($script:DockerState -eq "ok") {
        Say "Nao ha banco do NCommerce no Docker deste computador."
    } else {
        Say "O Docker nao esta neste computador: nao ha banco do NCommerce para copiar."
    }

    try {
        $n = Copy-Tree $InstallDir (Join-Path $partial "C_NCommerce") $SkipInInstallDir
        $n += Copy-Tree $DataDir (Join-Path $partial "ProgramData_NCommerce") @("downloads")
        $plugins = Get-PluginsDir
        if ($plugins -and (Test-Path -LiteralPath $plugins)) { $n += Copy-Tree $plugins (Join-Path $partial "plugins") }
        Say "Configuracao, plugins e arquivos da loja copiados ($n arquivos)."
        Write-BackupReadme $partial $dumpName
    } catch {
        Stop-Backup $partial "nao consegui copiar os arquivos da loja ($($_.Exception.Message))."
    }
    try {
        [System.IO.Directory]::Move($partial, $final)
    } catch {
        Stop-Backup $partial "nao consegui renomear $partial para $final ($($_.Exception.Message))."
    }
    if ($dumpName) { Set-NcState "backup_banco" "1" }
    # Copia pronta: daqui em diante a loja e removida, nao religada. Religar numa
    # falha das etapas seguintes faria vendas que nao estao na copia.
    $script:StoppedStore = $false
    Say "COPIA DE SEGURANCA PRONTA: $final" "Green"
}

# ============================================================ etapas 2 a 8

function Remove-StoreTasks {
    foreach ($t in (Get-PresentTasks)) {
        try {
            Unregister-ScheduledTask -TaskName $t -Confirm:$false -ErrorAction Stop
        } catch {
            Fail "nao consegui remover a tarefa agendada '$t' ($($_.Exception.Message))."
        }
        Say "Tarefa removida: $t"
    }
}

function Assert-DockerReady {
    if ($script:DockerState -eq "parado") {
        Fail "o Docker Desktop nao respondeu, e sem ele nao da para remover os containers e os dados do NCommerce." `
            "reinicie o computador, espere o Docker Desktop abrir e abra o DesinstaladorWindows.bat de novo. Ele continua de onde parou."
    }
    return ($script:DockerState -eq "ok")
}

function Remove-StoreContainers {
    if (-not (Assert-DockerReady)) { Say "O Docker nao esta neste computador: nada a remover."; return }
    if ((Get-StoreContainers).Count -gt 0 -and (Test-ComposeFile)) {
        Invoke-Compose -Arguments @("down", "--remove-orphans") | Out-Null
    }
    $left = Get-StoreContainers
    if ($left.Count -gt 0) { Invoke-Native -Exe $DockerExe -Arguments (@("rm", "-f") + $left) -Quiet | Out-Null }
    foreach ($n in (Get-StoreNetworks)) { Invoke-Native -Exe $DockerExe -Arguments @("network", "rm", $n) -Quiet | Out-Null }
    $left = Get-StoreContainers
    if ($left.Count -gt 0) {
        Fail "o Docker nao removeu estes containers do NCommerce: $($left -join ', ')." `
            "reinicie o computador e abra o DesinstaladorWindows.bat de novo."
    }
    Say "Containers e rede do NCommerce removidos."
}

function Remove-StoreVolumes {
    if (-not (Test-NcStepDone "backup") -and (Get-NcState "sem_backup") -ne "1") {
        Fail "os dados do NCommerce so saem depois da copia de seguranca, e ela nao foi feita." "abra o DesinstaladorWindows.bat de novo."
    }
    if (-not (Assert-DockerReady)) { Say "O Docker nao esta neste computador: nada a remover."; return }
    $volumes = @(Get-StoreVolumes)
    # O banco so sai se a copia levou o banco (o Docker pode nao ter listado o
    # volume na hora da copia).
    if ($volumes -contains "${Project}_mysql_data" -and (Get-NcState "backup_banco") -ne "1" -and (Get-NcState "sem_backup") -ne "1") {
        Fail "o banco de dados do NCommerce ainda esta no Docker, mas a copia de seguranca foi feita sem ele." `
            "chame o suporte NCommerce. Nada do banco foi apagado."
    }
    foreach ($v in $volumes) {
        if ((Invoke-Native -Exe $DockerExe -Arguments @("volume", "rm", $v) -Quiet) -eq 0) { Say "Volume removido: $v" }
    }
    $left = Get-StoreVolumes
    if ($left.Count -gt 0) {
        Fail "o Docker nao removeu estes volumes do NCommerce: $($left -join ', ')." `
            "reinicie o computador e abra o DesinstaladorWindows.bat de novo."
    }
}

# An image still used by some other container is not forced out: it goes to the manual list.
function Remove-StoreImages {
    if (-not (Assert-DockerReady)) { Say "O Docker nao esta neste computador: nada a remover."; return }
    foreach ($i in (Get-StoreImages)) {
        if ((Invoke-Native -Exe $DockerExe -Arguments @("image", "rm", $i) -Quiet) -eq 0) {
            Say "Imagem removida: $i"
        } else {
            Warn "o Docker nao removeu a imagem $i (outro container usa?)."
            $script:ManualExtra.Add("Imagem $i (docker image rm $i).")
        }
    }
    foreach ($r in (Get-StoreRegistries)) { Invoke-Native -Exe $DockerExe -Arguments @("logout", $r) -Quiet | Out-Null }
    Say "Login guardado do registry do NCommerce removido."
}

function Remove-StoreFirewallRules {
    foreach ($r in (Get-PresentFirewallRules)) {
        try {
            Remove-NetFirewallRule -DisplayName $r -ErrorAction Stop
        } catch {
            Fail "nao consegui remover a regra do firewall '$r' ($($_.Exception.Message))."
        }
        Say "Regra do firewall removida: $r"
    }
}

function Remove-StoreShortcuts {
    foreach ($l in (Get-PresentShortcuts)) {
        Remove-Item -LiteralPath $l -Force
        Say "Atalho removido: $l"
    }
}

function Remove-StoreFolders {
    if (Test-Path -LiteralPath $InstallDir) {
        if (Test-InstallDirSafe) {
            foreach ($item in @(Get-ChildItem -LiteralPath $InstallDir -Force)) {
                if ($item.Name -eq "wsl") { continue }
                Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction SilentlyContinue
            }
            if (@(Get-ChildItem -LiteralPath $InstallDir -Force | Where-Object { $_.Name -ne "wsl" }).Count -gt 0) {
                Fail "alguns arquivos de $InstallDir estao em uso e nao sairam." `
                    "feche as janelas do NCommerce (ou reinicie o computador) e abra o DesinstaladorWindows.bat de novo."
            }
            if (Test-Path -LiteralPath (Join-Path $InstallDir "wsl")) {
                $script:ManualExtra.Add("A pasta $(Join-Path $InstallDir 'wsl'), da instalacao nativa no WSL (advanced\windows-wsl), nao e desta instalacao.")
            } else {
                Remove-Item -LiteralPath $InstallDir -Recurse -Force
            }
            Say "Pasta removida: $InstallDir"
        } else {
            $script:ManualExtra.Add("A pasta $InstallDir nao parece a do NCommerce e ficou.")
        }
    }
    if (Test-Path -LiteralPath $DataDir) {
        Remove-Item -LiteralPath $DataDir -Recurse -Force
        Say "Pasta removida: $DataDir"
    }
    $plugins = Get-PluginsDir
    if (Test-InstallerPluginsDir $plugins) {
        if (Test-Path -LiteralPath $plugins) {
            Remove-Item -LiteralPath $plugins -Recurse -Force
            Say "Pasta removida: $plugins"
        }
        $parent = Split-Path -Parent $plugins
        Remove-Item -LiteralPath (Join-Path $parent "LEIA-ME.txt") -Force -ErrorAction SilentlyContinue
        if ((Test-Path -LiteralPath $parent) -and @(Get-ChildItem -LiteralPath $parent -Force).Count -eq 0) {
            Remove-Item -LiteralPath $parent -Force
        }
    } elseif ($plugins -and (Test-Path -LiteralPath $plugins)) {
        $script:ManualExtra.Add("A pasta de plugins $plugins (fora do lugar padrao, pode ter outras coisas).")
    }
    $flag = Get-TempFlag
    if ($flag) { Remove-Item -LiteralPath $flag -Force -ErrorAction SilentlyContinue }
}

function Invoke-UninstallStep([int]$Index, [scriptblock]$Action) {
    $s = $Steps[$Index]
    if (Test-NcStepDone $s.Name) {
        Say ("=== Etapa {0} de {1}: {2}: ja feita ===" -f ($Index + 1), $script:NcStepTotal, $s.Title) "Cyan"
        return
    }
    Step ($Index + 1) $s.Title
    & $Action
    Set-NcStepDone $s.Name
}

# ============================================================ roteiro

$exitCode = 1
try {
    $here = $PSScriptRoot
    if (Test-UnderPath $here $InstallDir) {
        Write-Host "Este desinstalador esta dentro de $InstallDir, que ele apaga." -ForegroundColor Red
        Write-Host "Copie a pasta do instalador para outro lugar (por exemplo a Area de Trabalho) e abra de la."
        $script:Verdict = "pasta"
        exit 1
    }
    if (-not $Simular -and -not (Test-IsAdmin)) {
        Write-Host "O desinstalador precisa de administrador. Abra pelo DesinstaladorWindows.bat (ele pede)." -ForegroundColor Red
        Write-Host "Para so ver o que seria feito, sem administrador: DesinstaladorWindows.bat -Simular"
        $script:Verdict = "admin"
        exit 1
    }
    if ($PastaBackup -and ((Test-UnderPath $PastaBackup $InstallDir) -or (Test-UnderPath $PastaBackup $DataDir))) {
        Write-Host "A pasta da copia ($PastaBackup) nao pode ficar dentro de $InstallDir ou ${DataDir}: elas sao apagadas." -ForegroundColor Red
        $script:Verdict = "pasta"
        exit 1
    }

    if (-not $Simular) {
        $script:Lock = Enter-NcLock "Global\NCommerceInstalador"
        for ($i = 0; -not $script:Lock -and $i -lt 15; $i++) {
            if ($i -eq 0) { Write-Host "Esperando outra janela do NCommerce terminar..." }
            Start-Sleep -Seconds 2
            $script:Lock = Enter-NcLock "Global\NCommerceInstalador"
        }
        if (-not $script:Lock) {
            Write-Host ""
            Write-Host "O instalador, uma atualizacao ou outro desinstalador do NCommerce esta aberto em outra janela." -ForegroundColor Yellow
            Write-Host "Espere terminar e abra de novo. Nada foi alterado."
            $script:Verdict = "ocupado"
            exit 2
        }
    }

    # Progress of an earlier run, read without creating anything.
    $stateFile = Join-Path $UninstallDir "desinstalacao.estado"
    if ([System.IO.File]::Exists($stateFile)) { $script:NcStateFile = $stateFile }
    $resuming = (@(Get-NcStateLines | Where-Object { $_ -like "etapa_*" }).Count -gt 0)
    $withBackup = -not $SemBackup
    # Once removal started without the copy there is nothing left to copy.
    if ((Get-NcState "sem_backup") -eq "1" -and (Test-NcStepDone "tarefas")) { $withBackup = $false }
    # And a copy already made stays the copy of this uninstall, -SemBackup or not.
    if ((Get-NcState "sem_backup") -ne "1" -and (Test-NcStepDone "backup")) { $withBackup = $true }

    $script:DockerState = Get-DockerState
    Build-Plan $withBackup

    Say "=================================================================="
    if ($Simular) {
        Say "  DESINSTALADOR DO NCOMMERCE - SIMULACAO (nada sera alterado)"
    } else {
        Say "  DESINSTALADOR DO NCOMMERCE"
    }
    Say "=================================================================="
    if ($resuming) { Say "Uma desinstalacao anterior parou no meio. Esta continua de onde ela parou." "Yellow" }
    if (-not (Test-PlanHasRemovals) -and -not $resuming) {
        Say "Nao achei nada do NCommerce (versao Docker) para remover neste computador."
        Show-ManualList
        $script:Verdict = "nada"
        $exitCode = 0
        exit 0
    }
    if ($Simular -and -not (Test-IsAdmin)) {
        Say "(Sem administrador o Windows pode esconder algumas tarefas agendadas desta lista.)"
    }
    Say "Projeto do Docker: '$Project'. Docker: $($script:DockerState)."
    Say ""
    Say "O que sera feito, nesta ordem:"
    Show-Plan $Simular
    if ($withBackup) {
        Say ""
        Say "Antes de remover qualquer coisa, a copia de seguranca. Se ela falhar, nada e removido."
    } else {
        Say ""
        Say "!!! SEM COPIA DE SEGURANCA (-SemBackup): o banco de dados, as notas fiscais e a configuracao da loja" "Red"
        Say "!!! serao APAGADOS e NAO PODEM SER RECUPERADOS." "Red"
    }
    Show-ManualList

    if ($Simular) {
        Say ""
        Say "SIMULACAO: nada foi alterado. Para desinstalar de verdade, abra o DesinstaladorWindows.bat sem -Simular."
        $script:Verdict = "simulacao"
        $exitCode = 0
        exit 0
    }

    Say ""
    $answer = $Confirmacao
    if (-not $answer) { $answer = Read-Host "Para desinstalar, digite $ConfirmWord e tecle Enter (qualquer outra coisa cancela)" }
    if ("$answer".Trim() -cne $ConfirmWord) {
        Say "Cancelado. Nada foi alterado."
        $script:Verdict = "cancelado"
        $exitCode = 3
        exit 3
    }

    # From here on the computer changes: log and progress go to a folder that is not removed.
    Start-NcLog $UninstallDir "desinstalacao"
    Initialize-NcState $stateFile
    Initialize-NcConsole "NCommerce - desinstalando - NAO FECHE ESTA JANELA"
    Write-NcLog ("desinstalador v2; pasta {0}; projeto {1}; PowerShell {2}" -f $InstallDir, $Project, $PSVersionTable.PSVersion)
    if (-not (Get-NcState "inicio")) {
        Set-NcState "inicio" ([string][DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
        Set-NcState "pasta_plugins" (Get-PluginsDir)
        Set-NcState "registros" ((Get-StoreRegistries) -join ",")
        if (Test-InstallDirSafe) { Set-NcState "pasta_loja_ok" "1" }
    }
    if ($withBackup) {
        if (-not (Get-NcState "backup_pasta")) { Set-NcState "backup_pasta" (Get-BackupTarget) }
        Remove-NcState "sem_backup"
    } else {
        Set-NcState "sem_backup" "1"
    }
    if ($script:NcLogFile) { Say "Log desta desinstalacao: $($script:NcLogFile)" }
    Say "NAO FECHE ESTA JANELA. Se parar, abra o DesinstaladorWindows.bat de novo: continua de onde parou." "Yellow"

    # Docker is needed for the copy and for removing containers, volumes and images.
    $dockerSteps = @("containers", "volumes", "imagens") | Where-Object { -not (Test-NcStepDone $_) }
    if ($dockerSteps -or ($withBackup -and -not (Test-NcStepDone "backup"))) {
        $script:DockerState = Start-DockerIfNeeded
        if ($script:DockerState -eq "parado") {
            Fail "o Docker Desktop nao respondeu. Nada foi removido nesta execucao." `
                "reinicie o computador, espere o Docker Desktop abrir e abra o DesinstaladorWindows.bat de novo."
        }
    }

    Invoke-UninstallStep 0 {
        if ($withBackup) {
            Save-UninstallBackup
        } else {
            Say "SEM COPIA DE SEGURANCA (-SemBackup): os dados da loja vao ser apagados." "Red"
        }
    }
    Invoke-UninstallStep 1 { Remove-StoreTasks }
    Invoke-UninstallStep 2 { Remove-StoreContainers }
    Invoke-UninstallStep 3 { Remove-StoreVolumes }
    Invoke-UninstallStep 4 { Remove-StoreImages }
    Invoke-UninstallStep 5 { Remove-StoreFirewallRules }
    Invoke-UninstallStep 6 { Remove-StoreShortcuts }
    Invoke-UninstallStep 7 { Remove-StoreFolders }

    $backupDir = ""
    if ((Get-NcState "sem_backup") -ne "1") { $backupDir = Get-NcState "backup_pasta" }
    Say ""
    Say "==================================================================" "Green"
    Say "  DESINSTALACAO CONCLUIDA." "Green"
    Say "==================================================================" "Green"
    if ($backupDir) {
        Say "Copia de seguranca da loja: $backupDir" "Green"
        Say "Ela tem o token e as senhas da loja: guarde num lugar seguro, fora do OneDrive."
    } else {
        Say "Nenhuma copia de seguranca foi feita (-SemBackup)." "Yellow"
    }
    if ($script:NcWarnings.Count -gt 0) {
        Say ""
        Say "Avisos:" "Yellow"
        foreach ($w in $script:NcWarnings) { Say "  - $w" "Yellow" }
    }
    Show-ManualList
    if ($script:NcLogFile) {
        Say "Log desta desinstalacao: $($script:NcLogFile)"
        if ($backupDir -and (Test-Path -LiteralPath $backupDir)) {
            try { [System.IO.File]::Copy($script:NcLogFile, (Join-Path $backupDir ([System.IO.Path]::GetFileName($script:NcLogFile))), $true) } catch { }
        }
    }
    # Done: a later install and uninstall starts from zero. The logs stay.
    Remove-Item -LiteralPath $stateFile, "$stateFile.novo" -Force -ErrorAction SilentlyContinue
    $script:Verdict = "ok"
    $exitCode = 0
} catch {
    if ($script:Verdict -eq "") {
        $detail = "$($_.Exception.Message)"
        Write-NcLog "ERRO inesperado: $detail"
        Write-NcLog "$($_.ScriptStackTrace)"
        Restore-StoreAfterFailure
        Say ""
        Say "A DESINSTALACAO NAO TERMINOU: um passo falhou de um jeito inesperado ($detail)." "Red"
        Say "Abra o DesinstaladorWindows.bat de novo: ele continua de onde parou."
        if ($script:NcLogFile) { Say "Se repetir, mande este arquivo para o suporte NCommerce: $($script:NcLogFile)" }
        $script:Verdict = "falha"
    }
} finally {
    if ($script:Verdict -eq "") {
        Write-NcLog "Desinstalacao interrompida (Ctrl+C ou janela fechada) na etapa $($script:NcStepNow)."
        Restore-StoreAfterFailure
        Write-Host ""
        Write-Host "A DESINSTALACAO FOI INTERROMPIDA. Abra o DesinstaladorWindows.bat de novo: ela continua de onde parou." -ForegroundColor Yellow
    }
    Close-Uninstaller
}
exit $exitCode
