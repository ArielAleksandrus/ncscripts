# Testes do windows/desinstalador_windows.ps1 no PowerShell 7 do Linux. O
# desinstalador roda inteiro, num processo proprio, contra um "computador" de
# mentira em /tmp/uninst: docker de tests/windows/fake/docker (por cima do
# tests/fake/bin/docker), tarefas agendadas e firewall de mentira
# (tests/windows/fake/modules, arquivos em /fake/win). Nada toca o Docker de
# verdade. Rode por tests/run-windows.sh.

BeforeAll {
    $script:Repo = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path
    $script:Uninstaller = Join-Path $Repo "windows/desinstalador_windows.ps1"
    $script:U = "/tmp/uninst"
    $script:Loja = "$U/NCommerce"
    $script:PD = "$U/ProgramData"
    $script:Home2 = "$U/home"
    $script:BK = "$U/bk"
    $script:StateFile = "$PD/NCommerce-desinstalacao/desinstalacao.estado"
    $script:Reg = "reg.test:5050"

    $script:SavedEnv = @{}
    foreach ($k in @("NCOMMERCE_DOCKER_EXE", "NCOMMERCE_INSTALL_DIR", "NCOMMERCE_DOCKER_WAIT_S", "NCOMMERCE_MYSQL_WAIT_S", "ProgramData", "HOME", "TEMP", "PATH", "PSModulePath")) {
        $SavedEnv[$k] = [Environment]::GetEnvironmentVariable($k)
    }
    $script:Bin = "/tmp/uninst-bin"
    New-Item -ItemType Directory -Force -Path $Bin | Out-Null
    & ln -sf (Join-Path $Repo "tests/fake/bin/mysqldump") (Join-Path $Bin "mysqldump")
    $env:NCOMMERCE_DOCKER_EXE = Join-Path $Repo "tests/windows/fake/docker"
    $env:NCOMMERCE_INSTALL_DIR = $Loja
    $env:NCOMMERCE_DOCKER_WAIT_S = "0"
    $env:NCOMMERCE_MYSQL_WAIT_S = "3"
    $env:ProgramData = $PD
    $env:HOME = $Home2
    $env:TEMP = "$U/temp"
    $env:PATH = "$(Join-Path $Repo 'tests/windows/fake'):${Bin}:$($SavedEnv['PATH'])"
    $env:PSModulePath = "$(Join-Path $Repo 'tests/windows/fake/modules'):$($SavedEnv['PSModulePath'])"

    $script:StoreTasks = @("NCommerce Docker Startup", "NCommerce Instalador Retomar", "NCommerce Aviso Reinicio", "NCommerce Impressoras USB")
    $script:StoreRules = @("NCommerce TCP 3000", "NCommerce TCP 4200", "NCommerce LPD 515")
    $script:StoreVolumes = @("mysql_data", "nfce_data", "cups_data", "api_uploads", "api_print", "api_docs", "api_log", "api_backups", "api_env", "web_promos") |
        ForEach-Object { "ncommerce_$_" }

    function Set-Knob([string]$Name, [string]$Value = "1") { [IO.File]::WriteAllText("/fake/knobs/$Name", "$Value`n") }
    function Remove-Knob([string]$Name) { Remove-Item "/fake/knobs/$Name" -Force -ErrorAction SilentlyContinue }
    function Get-Calls { if (Test-Path /fake/calls.log) { return "$(Get-Content -Raw /fake/calls.log)" } return "" }
    function Write-File([string]$Path, [string]$Text) {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
        [IO.File]::WriteAllText($Path, $Text)
    }

    # Um computador com a loja instalada e rodando, e coisas que NAO sao do instalador.
    function Reset-Machine {
        & pkill -9 -f "desinstalador_windows.ps1" 2>$null
        Start-Sleep -Milliseconds 300
        foreach ($d in @("/fake", $U)) { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
        New-Item -ItemType Directory -Force -Path "/fake/state/images", "/fake/state/containers", "/fake/state/volumes", "/fake/state/networks",
            "/fake/knobs", "/fake/win/tasks", "/fake/win/fw", "$Home2/Desktop", "$U/temp", $BK | Out-Null
        [IO.File]::WriteAllText("/fake/calls.log", "")
        Set-Knob "api_never_starts"

        # C:\NCommerce
        New-Item -ItemType Directory -Force -Path $Loja | Out-Null
        Copy-Item (Join-Path $Repo "docker/docker-compose.yml") "$Loja/docker-compose.yml"
        Write-File "$Loja/.env" "NCOMMERCE_REGISTRY=$Reg`nNCOMMERCE_TAG=latest`nCUPS_PORT=631`nNCOMMERCE_PLUGINS_DIR=$Home2/Documents/ncommerce/plugins`n"
        Write-File "$Loja/.env.bak" "NCOMMERCE_REGISTRY=$Reg`n"
        Write-File "$Loja/ncommerce-docker-startup.bat" "@echo off`r`n"
        Write-File "$Loja/control/versions.txt" "v1|sha256:api1|sha256:web1|1|good|1`n"
        Write-File "$Loja/host/anydesk_id" "123456789`n"
        Write-File "$Loja/logs/instalacao-20260101-000000.log" "ok`n"
        Write-File "$Loja/backups/antes-de-atualizar-20260101-000000.sql.gz" "copia antiga"
        Write-File "$Loja/drivers/bematech.exe" "driver"
        Write-File "$Loja/wsl/instalacao-nativa.txt" "nao e do instalador Docker"
        # C:\ProgramData\NCommerce e outras pastas
        Write-File "$PD/NCommerce/machine-id" "0f0e0d0c-0b0a-0908-0706-050403020100"
        Write-File "$PD/NCommerce/instalacao.estado" "concluida=1`n"
        Write-File "$PD/NCommerce/downloads/AnyDesk.exe" "instalador"
        Write-File "$PD/Outro/fica.txt" "de outro programa"
        Write-File "$Home2/Documents/ncommerce/plugins/meu_plugin.rb" "# plugin`n"
        Write-File "$Home2/Documents/ncommerce/LEIA-ME.txt" "Plugins do NCommerce`n"
        Write-File "$Home2/Documents/outra-coisa.txt" "do usuario"
        Write-File "$Home2/Desktop/Atualizar NCommerce.lnk" "lnk"
        Write-File "$Home2/Desktop/AnyDesk - Suporte NCommerce.lnk" "lnk"
        Write-File "$Home2/Desktop/Outro.lnk" "lnk"
        Write-File "$U/temp/ncommerce-instalador-iniciou.flag" "1"
        # Tarefas e firewall
        foreach ($t in $StoreTasks + @("Outra Tarefa")) { Write-File "/fake/win/tasks/$t" "" }
        foreach ($r in $StoreRules + @("OpenSSH-Server-In-TCP", "Outra regra")) { Write-File "/fake/win/fw/$r" "" }
        # Docker: a loja (projeto ncommerce) e um projeto de outro programa
        foreach ($s in @("mysql", "redis", "api", "web", "guard")) {
            Write-File "/fake/state/containers/$s" "sha256:$s`n"
            Write-File "/fake/state/containers/$s.status" "running`n"
        }
        Write-File "/fake/state/containers/outro" "sha256:nginx`n"
        Write-File "/fake/state/containers/outro.status" "running`n"
        Write-File "/fake/state/containers/outro.project" "outro"
        foreach ($v in $StoreVolumes) { Write-File "/fake/state/volumes/$v" "ncommerce" }
        Write-File "/fake/state/volumes/outro_dados" "outro"
        Write-File "/fake/state/networks/ncommerce_default" "ncommerce"
        Write-File "/fake/state/networks/outro_default" "outro"
        Write-File "/fake/state/images/reg.test_5050_ncommerce_api_latest" "sha256:api1`n"
        Write-File "/fake/state/images/reg.test_5050_ncommerce_web_latest" "sha256:web1`n"
        Write-File "/fake/state/imagelist" (@(
                "$Reg/ncommerce/api|latest|sha256:api1", "$Reg/ncommerce/web|latest|sha256:web1",
                "$Reg/ncommerce/api|keep-v0|sha256:api0", "registry.ncommerce.app:5050/ncommerce/web|<none>|sha256:webold",
                "mysql|8.0|sha256:mysql", "redis|7-alpine|sha256:redis", "docker|27.5.1-cli|sha256:guard",
                "nginx|latest|sha256:nginx", "outra.reg/ncommerce/api|latest|sha256:outra") -join "`n")
        # O que fica nos volumes (visto pelo docker cp)
        Write-File "/fake/ctr/env/.env.production" "NCOMMERCE_SERVER_TOKEN=tok123456789`n"
        Write-File "/fake/ctr/data/nfce/nota1.xml" "<nfe/>"
        Write-File "/fake/ctr/app/ncommerce_api/business_docs/contrato.txt" "doc"
        Write-File "/fake/ctr/app/ncommerce_api/public/uploads/logo.png" "png"
        Write-File "/fake/ctr/etc/cups/printers.conf" "<Printer x>"
        Write-File "/fake/ctr/var/ncommerce/backups/api.zip" "zip"
        Write-File "/fake/ctr/usr/share/nginx/html/assets/promo-tablet/promo.png" "png"
    }

    # Tudo o que o desinstalador poderia mudar, para comparar antes e depois.
    function Get-Snapshot {
        $lines = foreach ($root in @($U, "/fake/state", "/fake/win")) {
            if (-not (Test-Path $root)) { continue }
            # pwsh itself creates ~/.cache, ~/.local and ~/.config.
            Get-ChildItem $root -Recurse -Force | Where-Object { $_.FullName -notmatch "^$([regex]::Escape($Home2))/\." } |
                Sort-Object FullName | ForEach-Object {
                if ($_.PSIsContainer) { "D $($_.FullName)" } else { "F $($_.FullName) $((Get-FileHash -LiteralPath $_.FullName).Hash)" }
            }
        }
        return ($lines -join "`n")
    }

    function Invoke-Uninstall([string[]]$Arguments = @(), [string]$Answer = "") {
        $all = @("-PastaBackup", $BK) + $Arguments
        $script:Out = ($Answer | & pwsh -NoProfile -File $Uninstaller @all 2>&1 | Out-String)
        $script:Rc = $LASTEXITCODE
    }

    function Get-BackupDirs { return @(Get-ChildItem $BK -Directory -ErrorAction SilentlyContinue) }
    function Test-NothingChangedCalls {
        $calls = Get-Calls
        foreach ($bad in @("docker rm ", "compose down", "compose stop", "compose up", "volume rm", "network rm", "image rm", "logout",
                "Unregister-ScheduledTask", "Remove-NetFirewallRule", "mysqldump", "docker cp")) {
            $calls | Should -Not -Match ([regex]::Escape($bad))
        }
    }
    function Wait-Call([string]$Text) {
        for ($i = 0; $i -lt 300; $i++) {
            if ((Get-Calls).Contains($Text)) { return $true }
            Start-Sleep -Milliseconds 100
        }
        return $false
    }
}

AfterAll {
    & pkill -9 -f "desinstalador_windows.ps1" 2>$null
    foreach ($k in $SavedEnv.Keys) { [Environment]::SetEnvironmentVariable($k, $SavedEnv[$k]) }
}

Describe "simular e confirmar" {
    BeforeEach { Reset-Machine }

    It "-Simular nao muda nada, nao pede confirmacao e lista cada passo" {
        $before = Get-Snapshot
        Invoke-Uninstall @("-Simular")
        $Rc | Should -Be 0
        $Out | Should -Match "SIMULACAO: nada foi alterado"
        $Out | Should -Not -Match "digite DESINSTALAR"
        $Out | Should -Match ([regex]::Escape("$BK/NCommerce-backup-desinstalacao-"))
        $Out | Should -Match "mysqldump"
        $Out | Should -Match "docker compose stop guard api web"
        $Out | Should -Match ([regex]::Escape("docker cp <container api>:/data/nfce"))
        foreach ($t in $StoreTasks) { $Out | Should -Match ([regex]::Escape("Unregister-ScheduledTask -TaskName '$t'")) }
        foreach ($r in $StoreRules) { $Out | Should -Match ([regex]::Escape("Remove-NetFirewallRule -DisplayName '$r'")) }
        foreach ($v in $StoreVolumes) { $Out | Should -Match ([regex]::Escape("docker volume rm $v")) }
        $Out | Should -Match ([regex]::Escape("docker compose down --remove-orphans"))
        $Out | Should -Match ([regex]::Escape("docker network rm ncommerce_default"))
        $Out | Should -Match ([regex]::Escape("docker image rm $Reg/ncommerce/api:latest"))
        $Out | Should -Match ([regex]::Escape("docker image rm $Reg/ncommerce/api:keep-v0"))
        $Out | Should -Match ([regex]::Escape("docker image rm sha256:webold"))
        $Out | Should -Match ([regex]::Escape("docker logout $Reg"))
        $Out | Should -Match "Atualizar NCommerce.lnk"
        $Out | Should -Match ([regex]::Escape("Remove-Item -Recurse '$Loja'"))
        $Out | Should -Match ([regex]::Escape("Remove-Item -Recurse '$PD/NCommerce'"))
        $Out | Should -Match "Remova a mao se quiser"
        $Out | Should -Match "AnyDesk"
        foreach ($other in @("Outra Tarefa", "Outra regra", "DisplayName 'OpenSSH", "outro_dados", "outro_default", "image rm mysql", "image rm nginx", "outra.reg", "Outro.lnk")) {
            $Out | Should -Not -Match ([regex]::Escape($other))
        }
        Get-Snapshot | Should -Be $before
        Test-NothingChangedCalls
        Test-Path "$PD/NCommerce-desinstalacao" | Should -BeFalse
    }

    It "-Simular -SemBackup avisa que os dados se perdem e nao lista a copia" {
        Invoke-Uninstall @("-Simular", "-SemBackup")
        $Rc | Should -Be 0
        $Out | Should -Match "SEM COPIA DE SEGURANCA"
        $Out | Should -Not -Match "mysqldump"
        Test-NothingChangedCalls
    }

    It "confirmacao errada cancela sem mudar nada" {
        $before = Get-Snapshot
        foreach ($answer in @("desinstalar", "sim", "")) {
            Invoke-Uninstall @() $answer
            $Rc | Should -Be 3
            $Out | Should -Match "Cancelado. Nada foi alterado."
        }
        Get-Snapshot | Should -Be $before
        Test-NothingChangedCalls
        Test-Path "$PD/NCommerce-desinstalacao" | Should -BeFalse
    }
}

Describe "desinstalar" {
    BeforeEach { Reset-Machine }

    It "copia primeiro, remove so o que o instalador criou e diz onde esta a copia" {
        Invoke-Uninstall @() "DESINSTALAR"
        $Rc | Should -Be 0
        $Out | Should -Match "DESINSTALACAO CONCLUIDA"
        $Out | Should -Match "Remova a mao se quiser"

        # Copia de seguranca, fora da instalacao e conferida
        $dirs = Get-BackupDirs
        $dirs.Count | Should -Be 1
        $bkDir = $dirs[0].FullName
        $bkDir | Should -Match "NCommerce-backup-desinstalacao-\d{8}-\d{6}$"
        $Out | Should -Match ([regex]::Escape("Copia de seguranca da loja: $bkDir"))
        $dump = @(Get-ChildItem "$bkDir/banco" -Filter "antes-de-desinstalar-*.sql.gz")
        $dump.Count | Should -Be 1
        (& gzip -dc $dump[0].FullName | Out-String) | Should -Match "Dump completed"
        Get-Content -Raw "$bkDir/C_NCommerce/.env" | Should -Match "NCOMMERCE_REGISTRY=$Reg"
        Test-Path "$bkDir/C_NCommerce/.env.bak" | Should -BeTrue
        Test-Path "$bkDir/C_NCommerce/control/versions.txt" | Should -BeTrue
        Test-Path "$bkDir/C_NCommerce/backups/antes-de-atualizar-20260101-000000.sql.gz" | Should -BeTrue
        Test-Path "$bkDir/C_NCommerce/drivers" | Should -BeFalse
        Test-Path "$bkDir/C_NCommerce/wsl" | Should -BeFalse
        Get-Content -Raw "$bkDir/volumes/api_env/.env.production" | Should -Match "NCOMMERCE_SERVER_TOKEN=tok"
        Test-Path "$bkDir/volumes/nfce_data/nota1.xml" | Should -BeTrue
        Test-Path "$bkDir/volumes/cups_data/printers.conf" | Should -BeTrue
        Test-Path "$bkDir/volumes/web_promos/promo.png" | Should -BeTrue
        Test-Path "$bkDir/plugins/meu_plugin.rb" | Should -BeTrue
        Test-Path "$bkDir/ProgramData_NCommerce/machine-id" | Should -BeTrue
        Test-Path "$bkDir/ProgramData_NCommerce/downloads" | Should -BeFalse
        Test-Path "$bkDir/LEIA-ME.txt" | Should -BeTrue
        @(Get-ChildItem $bkDir -Filter "desinstalacao-*.log").Count | Should -Be 1

        # A copia vem antes de qualquer remocao, com a loja parada
        $calls = Get-Calls
        $calls.IndexOf("compose stop guard api web") | Should -BeLessThan $calls.IndexOf("mysqldump")
        $calls.IndexOf("mysqldump") | Should -BeLessThan $calls.IndexOf("Unregister-ScheduledTask")
        $calls.IndexOf("Unregister-ScheduledTask") | Should -BeLessThan $calls.IndexOf("compose down")
        $calls.IndexOf("compose down") | Should -BeLessThan $calls.IndexOf("volume rm")
        $calls | Should -Match ([regex]::Escape("docker logout $Reg"))

        # Removido
        foreach ($t in $StoreTasks) { Test-Path "/fake/win/tasks/$t" | Should -BeFalse }
        foreach ($r in $StoreRules) { Test-Path "/fake/win/fw/$r" | Should -BeFalse }
        foreach ($s in @("mysql", "redis", "api", "web", "guard")) { Test-Path "/fake/state/containers/$s" | Should -BeFalse }
        foreach ($v in $StoreVolumes) { Test-Path "/fake/state/volumes/$v" | Should -BeFalse }
        Test-Path "/fake/state/networks/ncommerce_default" | Should -BeFalse
        $images = Get-Content -Raw /fake/state/imagelist
        $images | Should -Not -Match "reg\.test:5050/ncommerce"
        $images | Should -Not -Match "registry\.ncommerce\.app"
        Test-Path "$Home2/Desktop/Atualizar NCommerce.lnk" | Should -BeFalse
        Test-Path "$Home2/Desktop/AnyDesk - Suporte NCommerce.lnk" | Should -BeFalse
        Test-Path "$PD/NCommerce" | Should -BeFalse
        Test-Path "$Home2/Documents/ncommerce" | Should -BeFalse
        Test-Path "$U/temp/ncommerce-instalador-iniciou.flag" | Should -BeFalse
        @(Get-ChildItem $Loja -Force | ForEach-Object Name) | Should -Be @("wsl")

        # Nao era do instalador: fica
        Test-Path "/fake/win/tasks/Outra Tarefa" | Should -BeTrue
        Test-Path "/fake/win/fw/Outra regra" | Should -BeTrue
        Test-Path "/fake/win/fw/OpenSSH-Server-In-TCP" | Should -BeTrue
        Test-Path "/fake/state/containers/outro" | Should -BeTrue
        Test-Path "/fake/state/volumes/outro_dados" | Should -BeTrue
        Test-Path "/fake/state/networks/outro_default" | Should -BeTrue
        foreach ($i in @("mysql|8.0", "redis|7-alpine", "docker|27.5.1-cli", "nginx|latest", "outra.reg/ncommerce/api|latest")) {
            $images | Should -Match ([regex]::Escape($i))
        }
        Test-Path "$Home2/Desktop/Outro.lnk" | Should -BeTrue
        Test-Path "$PD/Outro/fica.txt" | Should -BeTrue
        Test-Path "$Home2/Documents/outra-coisa.txt" | Should -BeTrue
        Test-Path "$Loja/wsl/instalacao-nativa.txt" | Should -BeTrue

        # Progresso apagado, log guardado fora do que foi removido
        Test-Path $StateFile | Should -BeFalse
        @(Get-ChildItem "$PD/NCommerce-desinstalacao" -Filter "desinstalacao-*.log").Count | Should -Be 1

        # Rodar de novo: nada a remover
        Invoke-Uninstall @() "DESINSTALAR"
        $Rc | Should -Be 0
        $Out | Should -Match "Nao achei nada do NCommerce"
    }

    It "copia do banco falha: para antes de remover qualquer coisa e religa a loja" {
        Set-Knob "dump_fail"
        $tasksBefore = @(Get-ChildItem /fake/win/tasks).Count
        Invoke-Uninstall @() "DESINSTALAR"
        $Rc | Should -Be 1
        $Out | Should -Match "NADA FOI REMOVIDO"
        $Out | Should -Match "A DESINSTALACAO NAO TERMINOU"
        $Out | Should -Match "-SemBackup"
        @(Get-ChildItem /fake/win/tasks).Count | Should -Be $tasksBefore
        foreach ($v in $StoreVolumes) { Test-Path "/fake/state/volumes/$v" | Should -BeTrue }
        Test-Path "/fake/state/containers/api" | Should -BeTrue
        (Get-Content -Raw /fake/state/containers/api.status).Trim() | Should -Be "running"
        Test-Path "$Loja/.env" | Should -BeTrue
        Test-Path "$Home2/Desktop/Atualizar NCommerce.lnk" | Should -BeTrue
        @(Get-ChildItem $BK -Force).Count | Should -Be 0
        $calls = Get-Calls
        foreach ($bad in @("Unregister-ScheduledTask", "Remove-NetFirewallRule", "compose down", "volume rm", "image rm", "docker rm ")) {
            $calls | Should -Not -Match ([regex]::Escape($bad))
        }

        # Arrumado o problema, a proxima execucao termina.
        Remove-Knob "dump_fail"
        Invoke-Uninstall @() "DESINSTALAR"
        $Rc | Should -Be 0
        $Out | Should -Match "DESINSTALACAO CONCLUIDA"
        (Get-BackupDirs).Count | Should -Be 1
    }

    It "copia das notas fiscais falha: tambem nao remove nada" {
        Set-Knob "cp_vol_fail"
        Invoke-Uninstall @() "DESINSTALAR"
        $Rc | Should -Be 1
        $Out | Should -Match "NADA FOI REMOVIDO"
        foreach ($v in $StoreVolumes) { Test-Path "/fake/state/volumes/$v" | Should -BeTrue }
        @(Get-ChildItem $BK -Force).Count | Should -Be 0
        (Get-Calls) | Should -Not -Match "Unregister-ScheduledTask"
    }

    It "-SemBackup apaga sem copia e diz isso alto" {
        Invoke-Uninstall @("-SemBackup") "DESINSTALAR"
        $Rc | Should -Be 0
        $Out | Should -Match "SEM COPIA DE SEGURANCA"
        $Out | Should -Match "Nenhuma copia de seguranca foi feita"
        $Out | Should -Match "DESINSTALACAO CONCLUIDA"
        (Get-Calls) | Should -Not -Match "mysqldump"
        (Get-Calls) | Should -Not -Match "docker cp"
        @(Get-ChildItem $BK -Force).Count | Should -Be 0
        foreach ($v in $StoreVolumes) { Test-Path "/fake/state/volumes/$v" | Should -BeFalse }
        Test-Path "/fake/state/volumes/outro_dados" | Should -BeTrue
    }

    It "Docker parado: nada e removido" {
        Set-Knob "daemon_down"
        Invoke-Uninstall @() "DESINSTALAR"
        $Rc | Should -Be 1
        $Out | Should -Match "Docker Desktop nao respondeu"
        (Get-Calls) | Should -Not -Match "Unregister-ScheduledTask"
        foreach ($t in $StoreTasks) { Test-Path "/fake/win/tasks/$t" | Should -BeTrue }
        Test-Path "$Loja/.env" | Should -BeTrue
        $Out | Should -Not -Match "DESINSTALACAO CONCLUIDA"
    }

    It "interrompido no meio (janela fechada): a proxima execucao continua de onde parou" {
        Set-Knob "volume_rm_hang"
        $p = Start-Process pwsh -PassThru -RedirectStandardOutput /tmp/uninst-bg.out -RedirectStandardError /tmp/uninst-bg.err `
            -ArgumentList @("-NoProfile", "-File", $Uninstaller, "-PastaBackup", $BK, "-Confirmacao", "DESINSTALAR")
        Wait-Call "docker volume rm" | Should -BeTrue
        $p.Kill($true); $p.WaitForExit()
        Remove-Knob "volume_rm_hang"
        $state = Get-Content -Raw $StateFile
        $state | Should -Match "etapa_backup="
        $state | Should -Match "etapa_tarefas="
        $state | Should -Match "etapa_containers="
        $state | Should -Not -Match "etapa_volumes="
        (Get-BackupDirs).Count | Should -Be 1

        Invoke-Uninstall @() "DESINSTALAR"
        $Rc | Should -Be 0
        $Out | Should -Match "parou no meio"
        $Out | Should -Match "Copia de seguranca \(banco, arquivos e configuracao\): ja feita"
        $Out | Should -Match "DESINSTALACAO CONCLUIDA"
        $Out | Should -Match ([regex]::Escape("Copia de seguranca da loja: $((Get-BackupDirs)[0].FullName)"))
        @((Get-Calls) -split "`n" | Where-Object { $_ -like "mysqldump *" }).Count | Should -Be 1
        (Get-BackupDirs).Count | Should -Be 1
        foreach ($v in $StoreVolumes) { Test-Path "/fake/state/volumes/$v" | Should -BeFalse }
        Test-Path "$PD/NCommerce" | Should -BeFalse
        Test-Path $StateFile | Should -BeFalse
    }
}
