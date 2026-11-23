# Testes do windows/ncommerce-update.ps1 e do windows/update-host.ps1 no
# PowerShell 7 do Linux, com o docker de mentira de tests/fake/bin/docker (o
# mesmo dos testes do Linux: imagens e containers sao arquivos em /fake/state).
# Rode por tests/run-windows.sh.

BeforeAll {
    $script:Repo = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path
    $script:Loja = "/tmp/loja"
    $script:Reg = "reg.test:5050"
    $env:NCOMMERCE_DOCKER_EXE = Join-Path $Repo "tests/fake/bin/docker"
    $env:NCOMMERCE_UPDATE_WAIT_S = "20"
    $env:NCOMMERCE_RETRY_WAIT_S = "0"
    # So o mysqldump e o mysqladmin de mentira entram no PATH (o docker de mentira roda o exec aqui).
    $script:Bin = "/tmp/fakebin"
    New-Item -ItemType Directory -Force -Path $Bin | Out-Null
    & ln -sf (Join-Path $Repo "tests/fake/bin/mysqldump") (Join-Path $Bin "mysqldump")
    & ln -sf (Join-Path $Repo "tests/windows/fake/mysqladmin") (Join-Path $Bin "mysqladmin")
    $env:PATH = "${Bin}:$env:PATH"

    function Set-Knob([string]$Name, [string]$Value = "1") { [IO.File]::WriteAllText("/fake/knobs/$Name", "$Value`n") }
    function Remove-Knob([string]$Name) { Remove-Item "/fake/knobs/$Name" -Force -ErrorAction SilentlyContinue }
    function Get-Ref([string]$Ref) {
        $f = "/fake/state/images/" + ($Ref -replace '[/:]', '_')
        if (Test-Path $f) { return (Get-Content -Raw $f).Trim() }
        return ""
    }
    function Get-Running([string]$Svc) { return (Get-Content -Raw "/fake/state/containers/$Svc").Trim() }
    function Get-Calls { if (Test-Path /fake/calls.log) { return "$(Get-Content -Raw /fake/calls.log)" } return "" }
    function Get-EnvLine([string]$Key) {
        return @((Get-Content (Join-Path $Loja ".env")) | Where-Object { $_ -like "$Key=*" })[-1]
    }
    function Get-UpdateStateText {
        $f = Join-Path $Loja "control/update.state"
        if (Test-Path $f) { return (Get-Content -Raw $f).Trim() }
        return ""
    }

    # Loja instalada, rodando api1/web1, marcada boa pela guarda.
    function Reset-Store {
        # Atualizacao de um teste anterior ainda rodando seguraria a trava.
        & pkill -9 -f "ncommerce-update.ps1" 2>$null
        Start-Sleep -Milliseconds 300
        foreach ($d in @("/fake", $Loja, "/tmp/pkg")) { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
        New-Item -ItemType Directory -Force -Path "/fake/state/images", "/fake/state/containers", "/fake/knobs", "$Loja/control" | Out-Null
        [IO.File]::WriteAllText("/fake/calls.log", "")
        Set-Knob "api_never_starts"
        foreach ($f in @("ncommerce-update.ps1", "instalador-lib.ps1", "update-host.ps1", "ncommerce-docker-startup.bat", "rollback.bat", "ncommerce-docker-update.bat")) {
            Copy-Item (Join-Path $Repo "windows/$f") (Join-Path $Loja $f)
        }
        Copy-Item (Join-Path $Repo "docker/docker-compose.yml") (Join-Path $Loja "docker-compose.yml")
        Copy-Item (Join-Path $Repo "docker/guard.sh") (Join-Path $Loja "guard.sh")
        [IO.File]::WriteAllText((Join-Path $Loja ".env"), "NCOMMERCE_REGISTRY=$Reg`nNCOMMERCE_TAG=latest`nCUPS_PORT=631`n")
        [IO.File]::WriteAllText("/fake/state/images/reg.test_5050_ncommerce_api_latest", "sha256:api1`n")
        [IO.File]::WriteAllText("/fake/state/images/reg.test_5050_ncommerce_web_latest", "sha256:web1`n")
        foreach ($s in @("mysql", "redis", "api", "web", "guard")) {
            [IO.File]::WriteAllText("/fake/state/containers/$s", "sha256:$s`n")
            [IO.File]::WriteAllText("/fake/state/containers/$s.status", "running`n")
        }
        [IO.File]::WriteAllText("/fake/state/containers/api", "sha256:api1`n")
        [IO.File]::WriteAllText("/fake/state/containers/web", "sha256:web1`n")
        [IO.File]::WriteAllText("$Loja/control/versions.txt", "v1|sha256:api1|sha256:web1|1|good|20260101`nv2|sha256:api2|sha256:web2|2|good|20260101`n")
        Set-Knob "migration_sha256_api1" "20260101000000"
        Set-Knob "migration_sha256_api2" "20260101000000"
    }

    # Roda a atualizacao num processo proprio, como o atalho. Saida em $script:Out.
    function Invoke-StoreUpdate([string[]]$Extra = @("-SemScripts")) {
        $script:Out = (& pwsh -NoProfile -File (Join-Path $Loja "ncommerce-update.ps1") -InstallDir $Loja @Extra 2>&1 | Out-String)
        $script:Rc = $LASTEXITCODE
    }
    function Start-StoreUpdate([string[]]$Extra = @("-SemScripts")) {
        $psArgs = @("-NoProfile", "-File", (Join-Path $Loja "ncommerce-update.ps1"), "-InstallDir", $Loja) + $Extra
        return (Start-Process pwsh -ArgumentList $psArgs -PassThru -RedirectStandardOutput /tmp/upd-bg.out -RedirectStandardError /tmp/upd-bg.err)
    }
    function Wait-Call([string]$Text) {
        for ($i = 0; $i -lt 200; $i++) {
            if ((Get-Calls).Contains($Text)) { return $true }
            Start-Sleep -Milliseconds 100
        }
        return $false
    }

    # Pacote publicado (zip do GitHub) = os scripts deste repositorio.
    function New-Package([scriptblock]$Change = {}) {
        $root = "/tmp/pkg/ncscripts-master"
        New-Item -ItemType Directory -Force -Path $root | Out-Null
        Copy-Item (Join-Path $Repo "windows") $root -Recurse
        Copy-Item (Join-Path $Repo "docker") $root -Recurse
        Remove-Item "$root/windows/drivers" -Recurse -Force
        & $Change $root
        Remove-Item /tmp/pkg/ncscripts.zip -Force -ErrorAction SilentlyContinue
        Push-Location /tmp/pkg
        & zip -qr ncscripts.zip ncscripts-master
        Pop-Location
        $env:NCOMMERCE_SCRIPTS_ZIP_URL = "file:///tmp/pkg/ncscripts.zip"
    }
}

Describe "atualizar" {
    It "versao nova publicada: baixa, troca e confere" {
        Reset-Store
        Set-Knob "published_api" "sha256:api2"; Set-Knob "published_web" "sha256:web2"
        Invoke-StoreUpdate
        $Rc | Should -Be 0
        $Out | Should -Match "ATUALIZACAO CONCLUIDA. VERSAO v2 FUNCIONANDO"
        Get-Running "api" | Should -Be "sha256:api2"
        Get-Running "web" | Should -Be "sha256:web2"
        Get-UpdateStateText | Should -Be ""
        (Get-Calls) | Should -Not -Match "mysqldump"
        $calls = Get-Calls
        $calls.IndexOf("compose pull") | Should -BeLessThan $calls.IndexOf("compose up")
        @(Get-ChildItem "$Loja/logs" -Filter "atualizacao-*.log").Count | Should -Be 1
        (Get-Content -Raw (Get-ChildItem "$Loja/logs" -Filter "atualizacao-*.log")[0].FullName) | Should -Match "ATUALIZACAO CONCLUIDA"
    }

    It "versao que muda o banco guarda copia antes da troca" {
        Reset-Store
        Set-Knob "published_api" "sha256:api3"; Set-Knob "migration_sha256_api3" "20260202000000"
        Invoke-StoreUpdate
        $Rc | Should -Be 0
        @(Get-ChildItem "$Loja/backups" -Filter "antes-de-atualizar-*.sql.gz").Count | Should -Be 1
        $calls = Get-Calls
        $calls.IndexOf("mysqldump") | Should -BeLessThan $calls.IndexOf("compose up")
    }

    # R20 (respostas da revisao geral)
    It "sem o container da api e com o banco parado, liga o banco e copia antes" {
        Reset-Store
        Remove-Item "/fake/state/containers/api", "/fake/state/containers/api.status" -Force -ErrorAction SilentlyContinue
        [IO.File]::WriteAllText("/fake/state/containers/mysql.status", "exited`n")
        Set-Knob "published_api" "sha256:api2"
        Invoke-StoreUpdate
        $Rc | Should -Be 0
        $calls = Get-Calls
        $calls | Should -Match "compose up -d mysql"
        @(Get-ChildItem "$Loja/backups" -Filter "antes-de-atualizar-*.sql.gz").Count | Should -Be 1
        $calls.IndexOf("mysqldump") | Should -BeLessThan $calls.LastIndexOf("compose up -d")
    }

    It "guarda sempre a primeira copia de uma serie de tentativas, e a serie termina quando da certo" {
        Reset-Store
        New-Item -ItemType Directory -Force -Path "$Loja/backups" | Out-Null
        $i = 0
        foreach ($d in @("20260101-000001", "20260101-000002", "20260101-000003", "20260101-000004")) {
            $i++
            $f = "$Loja/backups/antes-de-atualizar-$d.sql.gz"
            & sh -c "echo velho | gzip > '$f'"
            (Get-Item $f).LastWriteTime = (Get-Date "2026-01-01").AddMinutes($i)
        }
        [IO.File]::WriteAllText("$Loja/backups/.serie-antes-de-atualizar", "antes-de-atualizar-20260101-000001.sql.gz`n")
        Set-Knob "published_api" "sha256:api3"; Set-Knob "migration_sha256_api3" "20260202000000"
        Invoke-StoreUpdate
        $Rc | Should -Be 0
        Test-Path "$Loja/backups/antes-de-atualizar-20260101-000001.sql.gz" | Should -BeTrue
        Test-Path "$Loja/backups/antes-de-atualizar-20260101-000002.sql.gz" | Should -BeFalse
        @(Get-ChildItem "$Loja/backups" -Filter "antes-de-atualizar-*.sql.gz").Count | Should -Be 4
        Test-Path "$Loja/backups/.serie-antes-de-atualizar" | Should -BeFalse
    }

    It "sem copia do banco nao atualiza e a etiqueta latest volta" {
        Reset-Store
        Set-Knob "published_api" "sha256:api3"; Set-Knob "migration_sha256_api3" "20260202000000"; Set-Knob "dump_fail"
        Invoke-StoreUpdate
        $Rc | Should -Not -Be 0
        $Out | Should -Match "A ATUALIZACAO NAO FOI FEITA. A LOJA CONTINUA NA VERSAO EM QUE ESTAVA"
        (Get-Calls) | Should -Not -Match "compose up"
        Get-Running "api" | Should -Be "sha256:api1"
        Get-Ref "$Reg/ncommerce/api:latest" | Should -Be "sha256:api1"
    }

    It "internet cai no meio do download (api baixou, web nao): loja intocada" {
        Reset-Store
        Set-Knob "published_api" "sha256:api2"; Set-Knob "published_web" "sha256:web2"; Set-Knob "pull_partial" "9"
        Invoke-StoreUpdate
        $Rc | Should -Not -Be 0
        $Out | Should -Match "A LOJA CONTINUA NA VERSAO EM QUE ESTAVA"
        (Get-Calls) | Should -Not -Match "compose up"
        Get-Ref "$Reg/ncommerce/api:latest" | Should -Be "sha256:api1"
        Get-Ref "$Reg/ncommerce/web:latest" | Should -Be "sha256:web1"
        Get-EnvLine "NCOMMERCE_TAG" | Should -Be "NCOMMERCE_TAG=latest"
        Get-UpdateStateText | Should -Be ""
        (Get-Calls).Split("`n").Where({ $_ -like "docker compose pull*" }).Count | Should -Be 3
    }

    It "loja numa versao guardada so muda de tag depois do download" {
        Reset-Store
        [IO.File]::WriteAllText((Join-Path $Loja ".env"), "NCOMMERCE_REGISTRY=$Reg`nNCOMMERCE_TAG=keep-v1`n")
        [IO.File]::WriteAllText("/fake/state/images/reg.test_5050_ncommerce_api_keep-v1", "sha256:api1`n")
        Set-Knob "pull_fail" "9"
        Invoke-StoreUpdate
        $Rc | Should -Not -Be 0
        Get-EnvLine "NCOMMERCE_TAG" | Should -Be "NCOMMERCE_TAG=keep-v1"
        Remove-Knob "pull_fail"
        Invoke-StoreUpdate
        $Rc | Should -Be 0
        Get-EnvLine "NCOMMERCE_TAG" | Should -Be "NCOMMERCE_TAG=latest"
    }

    It "versao nova nao liga: volta para a anterior" {
        Reset-Store
        Set-Knob "published_api" "sha256:api2"; Set-Knob "published_web" "sha256:web2"; Set-Knob "up_fail" "2"
        Invoke-StoreUpdate
        $Rc | Should -Be 1
        $Out | Should -Match "VOLTOU PARA A VERSAO ANTERIOR"
        Get-Running "api" | Should -Be "sha256:api1"
        Get-Running "web" | Should -Be "sha256:web1"
        Get-Ref "$Reg/ncommerce/api:latest" | Should -Be "sha256:api1"
        Get-UpdateStateText | Should -Be ""
    }

    It "versao guardada que nao liga volta para a guardada" {
        Reset-Store
        [IO.File]::WriteAllText((Join-Path $Loja ".env"), "NCOMMERCE_REGISTRY=$Reg`nNCOMMERCE_TAG=keep-v1`n")
        [IO.File]::WriteAllText("/fake/state/images/reg.test_5050_ncommerce_api_keep-v1", "sha256:api1`n")
        [IO.File]::WriteAllText("/fake/state/images/reg.test_5050_ncommerce_web_keep-v1", "sha256:web1`n")
        Set-Knob "published_api" "sha256:api2"; Set-Knob "up_fail" "2"
        Invoke-StoreUpdate
        $Rc | Should -Be 1
        Get-EnvLine "NCOMMERCE_TAG" | Should -Be "NCOMMERCE_TAG=keep-v1"
        Get-Running "api" | Should -Be "sha256:api1"
    }

    It "a guarda voltou a versao sozinha" {
        Reset-Store
        Set-Knob "published_api" "sha256:api2"
        [IO.File]::WriteAllText("$Loja/control/versions.txt", "v1|sha256:api1|sha256:web1|1|good|1`nv2|sha256:api2|sha256:web1|2|new|1`n")
        $p = Start-StoreUpdate
        Wait-Call "compose up" | Should -BeTrue
        Start-Sleep -Seconds 3
        [IO.File]::WriteAllText("/fake/state/containers/api", "sha256:api1`n")
        $p.WaitForExit()
        $p.ExitCode | Should -Be 1
        (Get-Content -Raw /tmp/upd-bg.out) | Should -Match "VOLTOU SOZINHO PARA A VERSAO v1"
    }

    It "versao ainda em teste quando o tempo acaba" {
        Reset-Store
        $env:NCOMMERCE_UPDATE_WAIT_S = "1"
        try {
            Set-Knob "published_api" "sha256:api2"
            [IO.File]::WriteAllText("$Loja/control/versions.txt", "v2|sha256:api2|sha256:web1|2|new|1`n")
            Invoke-StoreUpdate
        } finally { $env:NCOMMERCE_UPDATE_WAIT_S = "20" }
        $Rc | Should -Be 0
        $Out | Should -Match "AINDA ESTA EM TESTE"
    }

    It "duas atualizacoes ao mesmo tempo: a segunda sai sem mexer" {
        Reset-Store
        Set-Knob "pull_sleep" "4"
        $p = Start-StoreUpdate
        Wait-Call "compose pull" | Should -BeTrue
        Invoke-StoreUpdate
        $Rc | Should -Be 2
        $Out | Should -Match "ja esta rodando em outra janela"
        $p.WaitForExit()
        $p.ExitCode | Should -Be 0
        (Get-Calls).Split("`n").Where({ $_ -like "docker compose pull*" }).Count | Should -Be 1
    }

    It "disco quase cheio: nao comeca" {
        Reset-Store
        $env:NCOMMERCE_MIN_FREE_GB = "999999"
        try { Invoke-StoreUpdate } finally { Remove-Item Env:NCOMMERCE_MIN_FREE_GB }
        $Rc | Should -Not -Be 0
        $Out | Should -Match "quase cheio"
        (Get-Calls) | Should -Not -Match "compose pull"
    }

    It "sem a lib nao toca na loja" {
        Reset-Store
        Remove-Item (Join-Path $Loja "instalador-lib.ps1")
        Invoke-StoreUpdate
        $Rc | Should -Be 1
        (Get-Calls) | Should -Not -Match "compose"
    }

    It "janela fechada no download (processo morto): a proxima atualizacao desfaz e termina" {
        Reset-Store
        Set-Knob "published_api" "sha256:api2"; Set-Knob "published_web" "sha256:web2"; Set-Knob "pull_sleep" "30"
        $p = Start-StoreUpdate
        Wait-Call "compose pull" | Should -BeTrue
        Get-UpdateStateText | Should -Match "^pull\|"
        # Como o X da janela: sem finally. A api nova ja chegou, o web nao.
        $p.Kill($true); $p.WaitForExit()
        [IO.File]::WriteAllText("/fake/state/images/reg.test_5050_ncommerce_api_latest", "sha256:api2`n")
        Remove-Knob "pull_sleep"
        Get-UpdateStateText | Should -Match "^pull\|\d+\|sha256:api1\|sha256:web1\|latest$"
        Invoke-StoreUpdate
        $Rc | Should -Be 0
        $Out | Should -Match "interrompida durante o download"
        Get-Running "api" | Should -Be "sha256:api2"
        Get-Running "web" | Should -Be "sha256:web2"
    }
}

Describe "logon depois de atualizacao interrompida (-Recuperar)" {
    It "download interrompido: etiqueta latest volta para a versao em uso antes de ligar" {
        Reset-Store
        [IO.File]::WriteAllText("$Loja/control/update.state", "pull|1|sha256:api1|sha256:web1|latest`n")
        [IO.File]::WriteAllText("/fake/state/images/reg.test_5050_ncommerce_api_latest", "sha256:api2`n")
        Invoke-StoreUpdate @("-Recuperar")
        $Rc | Should -Be 0
        Get-Ref "$Reg/ncommerce/api:latest" | Should -Be "sha256:api1"
        Get-Ref "$Reg/ncommerce/web:latest" | Should -Be "sha256:web1"
        Get-UpdateStateText | Should -Be ""
        (Get-Calls) | Should -Not -Match "compose (pull|up)"
    }
    It "troca interrompida: deixa a versao nova para o compose up do logon" {
        Reset-Store
        [IO.File]::WriteAllText("$Loja/control/update.state", "up|1|sha256:api1|sha256:web1|latest`n")
        [IO.File]::WriteAllText("/fake/state/images/reg.test_5050_ncommerce_api_latest", "sha256:api2`n")
        Invoke-StoreUpdate @("-Recuperar")
        $Rc | Should -Be 0
        Get-Ref "$Reg/ncommerce/api:latest" | Should -Be "sha256:api2"
        Get-UpdateStateText | Should -Match "^up\|"
    }
    It "versao guardada que sumiu: volta para a publicada" {
        Reset-Store
        [IO.File]::WriteAllText((Join-Path $Loja ".env"), "NCOMMERCE_REGISTRY=$Reg`nNCOMMERCE_TAG=keep-sumiu`n")
        Invoke-StoreUpdate @("-Recuperar")
        Get-EnvLine "NCOMMERCE_TAG" | Should -Be "NCOMMERCE_TAG=latest"
    }
    It ".env vazio volta da copia" {
        Reset-Store
        Copy-Item (Join-Path $Loja ".env") (Join-Path $Loja ".env.bak")
        [IO.File]::WriteAllText((Join-Path $Loja ".env"), "")
        Invoke-StoreUpdate @("-Recuperar")
        Get-EnvLine "NCOMMERCE_REGISTRY" | Should -Be "NCOMMERCE_REGISTRY=$Reg"
    }
    It "atualizacao rodando: sai com 2 sem mexer" {
        Reset-Store
        Set-Knob "pull_sleep" "4"
        $p = Start-StoreUpdate
        Wait-Call "compose pull" | Should -BeTrue
        Invoke-StoreUpdate @("-Recuperar")
        $Rc | Should -Be 2
        Get-UpdateStateText | Should -Match "^pull\|"
        $p.WaitForExit()
    }
}

Describe "scripts novos (update-host.ps1)" {
    It "troca os scripts do pacote e segue com o atualizador novo" {
        Reset-Store
        New-Package {
            param($r)
            Add-Content "$r/windows/rollback.bat" "rem marca-nova"
            Add-Content "$r/windows/ncommerce-update.ps1" "# marca-nova"
            Add-Content "$r/windows/ncommerce-docker-update.bat" "rem marca-nova"
        }
        Set-Knob "published_api" "sha256:api2"
        Invoke-StoreUpdate @()
        $Rc | Should -Be 0
        $Out | Should -Match "Scripts do NCommerce atualizados"
        $Out | Should -Match "O atualizador mudou"
        (Get-Content -Raw "$Loja/rollback.bat") | Should -Match "marca-nova"
        (Get-Content -Raw "$Loja/ncommerce-update.ps1") | Should -Match "marca-nova"
        # O .bat em execucao fica em .new; ele mesmo se troca no fim.
        (Get-Content -Raw "$Loja/ncommerce-docker-update.bat") | Should -Not -Match "marca-nova"
        (Get-Content -Raw "$Loja/ncommerce-docker-update.bat.new") | Should -Match "marca-nova"
        (Get-Calls).Split("`n").Where({ $_ -like "docker compose pull*" }).Count | Should -Be 1
        Get-Running "api" | Should -Be "sha256:api2"
        @(Get-ChildItem "$Loja" -Filter "*.novo").Count | Should -Be 0
    }
    It "loja antiga sem lib e sem ncommerce-update.ps1 recebe os dois" {
        Reset-Store
        Remove-Item "$Loja/instalador-lib.ps1", "$Loja/ncommerce-update.ps1"
        New-Package {}
        & pwsh -NoProfile -File "$Loja/update-host.ps1" $Loja | Out-Null
        Test-Path "$Loja/instalador-lib.ps1" | Should -BeTrue
        Test-Path "$Loja/ncommerce-update.ps1" | Should -BeTrue
    }
    It "pacote com .ps1 danificado nao troca nenhum script" {
        Reset-Store
        New-Package {
            param($r)
            Add-Content "$r/windows/rollback.bat" "rem marca-boa"
            Add-Content "$r/windows/net-check.ps1" "if (`$a -eq { "
        }
        Invoke-StoreUpdate @()
        $Rc | Should -Be 0
        $Out | Should -Match "Nao troquei nenhum script"
        (Get-Content -Raw "$Loja/rollback.bat") | Should -Not -Match "marca-boa"
    }
    It "docker-compose.yml que nao passa no compose config nao troca nenhum" {
        Reset-Store
        New-Package { param($r) Add-Content "$r/windows/rollback.bat" "rem marca-boa" }
        Set-Knob "config_fail"
        & pwsh -NoProfile -File "$Loja/update-host.ps1" $Loja | Out-String | Should -Match "nao passou na conferencia"
        (Get-Content -Raw "$Loja/rollback.bat") | Should -Not -Match "marca-boa"
    }
    It "pacote cortado e ignorado e a atualizacao segue" {
        Reset-Store
        New-Package {}
        $bytes = [IO.File]::ReadAllBytes("/tmp/pkg/ncscripts.zip")
        [IO.File]::WriteAllBytes("/tmp/pkg/ncscripts.zip", $bytes[0..3000])
        Invoke-StoreUpdate @()
        $Rc | Should -Be 0
        $Out | Should -Match "danificado"
        $Out | Should -Match "ATUALIZACAO CONCLUIDA"
    }
    It "sem internet: so avisa" {
        Reset-Store
        $env:NCOMMERCE_SCRIPTS_ZIP_URL = "http://127.0.0.1:9/nada.zip"
        & pwsh -NoProfile -File "$Loja/update-host.ps1" $Loja | Out-String | Should -Match "Nao consegui baixar"
        $LASTEXITCODE | Should -Be 0
    }
}
