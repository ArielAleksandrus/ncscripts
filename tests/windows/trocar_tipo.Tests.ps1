# Testes do windows/trocar_tipo_windows.ps1 no PowerShell 7 do Linux. O script
# roda inteiro, num processo proprio, contra uma loja de mentira em /tmp/troca:
# docker de tests/windows/fake/docker (por cima do tests/fake/bin/docker), o
# mysql/mysqldump de tests/fake/bin e o rake de mentira da API
# (tests/fake/troca_rake.sh, loja em /fake/state/loja). Nada toca o Docker de
# verdade. Rode por tests/run-windows.sh.

BeforeAll {
    $script:Repo = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path
    $script:Changer = Join-Path $Repo "windows/trocar_tipo_windows.ps1"
    $script:U = "/tmp/troca"
    $script:Loja = "$U/NCommerce"
    $script:PD = "$U/ProgramData"
    $script:BK = "$U/bk"
    $script:StateFile = "$PD/NCommerce-troca-tipo/troca.estado"

    $script:SavedEnv = @{}
    foreach ($k in @("NCOMMERCE_DOCKER_EXE", "NCOMMERCE_INSTALL_DIR", "NCOMMERCE_MYSQL_WAIT_S", "TT_RETRY_WAIT_S", "ProgramData", "TEMP", "PATH")) {
        $SavedEnv[$k] = [Environment]::GetEnvironmentVariable($k)
    }
    $script:Bin = "/tmp/troca-bin"
    New-Item -ItemType Directory -Force -Path $Bin | Out-Null
    foreach ($tool in @("mysqldump", "mysql")) { & ln -sf (Join-Path $Repo "tests/fake/bin/$tool") (Join-Path $Bin $tool) }
    $env:NCOMMERCE_DOCKER_EXE = Join-Path $Repo "tests/windows/fake/docker"
    $env:NCOMMERCE_INSTALL_DIR = $Loja
    $env:NCOMMERCE_MYSQL_WAIT_S = "3"
    $env:TT_RETRY_WAIT_S = "0"
    $env:ProgramData = $PD
    $env:TEMP = "$U/temp"
    $env:PATH = "$(Join-Path $Repo 'tests/windows/fake'):${Bin}:$($SavedEnv['PATH'])"

    function Set-Knob([string]$Name, [string]$Value = "1") { [IO.File]::WriteAllText("/fake/knobs/$Name", "$Value`n") }
    function Remove-Knob([string]$Name) { Remove-Item "/fake/knobs/$Name" -Force -ErrorAction SilentlyContinue }
    function Get-Calls { if (Test-Path /fake/calls.log) { return "$(Get-Content -Raw /fake/calls.log)" } return "" }
    function Write-File([string]$Path, [string]$Text) {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
        [IO.File]::WriteAllText($Path, $Text)
    }
    function Get-Tipo { return (Get-Content -Raw /fake/state/loja/tipo).Trim() }

    # Uma loja restaurante instalada e rodando.
    function Reset-Store {
        & pkill -9 -f "trocar_tipo_windows.ps1" 2>$null
        foreach ($d in @("/fake", $U, "/tmp/ncommerce-dump.sql", "/tmp/ncommerce-dump.sql.gz")) { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
        New-Item -ItemType Directory -Force -Path "/fake/state/images", "/fake/state/containers", "/fake/state/volumes", "/fake/state/networks",
            "/fake/state/loja", "/fake/knobs", "$U/temp", $BK | Out-Null
        [IO.File]::WriteAllText("/fake/calls.log", "")
        Set-Knob "api_never_starts"
        Write-File "/fake/state/loja/tipo" "restaurant`n"
        New-Item -ItemType Directory -Force -Path $Loja | Out-Null
        Copy-Item (Join-Path $Repo "docker/docker-compose.yml") "$Loja/docker-compose.yml"
        Write-File "$Loja/.env" "NCOMMERCE_REGISTRY=reg.test:5050`nNCOMMERCE_TAG=latest`n"
        foreach ($s in @("mysql", "redis", "api", "web", "guard")) {
            Write-File "/fake/state/containers/$s" "sha256:$s`n"
            Write-File "/fake/state/containers/$s.status" "running`n"
        }
        Write-File "/fake/ctr/env/.env.production" "NCOMMERCE_SERVER_TOKEN=tok123456789`n"
        Write-File "/fake/ctr/data/nfce/notas_output/dados_nota_100_1234.xml" "<nfe/>"
    }

    function Invoke-Change([string[]]$Arguments = @(), [string]$Answer = "") {
        $all = @("-PastaBackup", $BK) + $Arguments
        $script:Out = ($Answer | & pwsh -NoProfile -File $Changer @all 2>&1 | Out-String)
        $script:Rc = $LASTEXITCODE
    }
    function Get-BackupDirs { return @(Get-ChildItem $BK -Directory -ErrorAction SilentlyContinue) }
    function Test-NothingChanged {
        Get-Tipo | Should -Be "restaurant"
        $calls = Get-Calls
        foreach ($bad in @("commerce_type:prepare", "commerce_type:reset", "mysqldump", "compose stop")) {
            $calls | Should -Not -Match ([regex]::Escape($bad))
        }
        Get-BackupDirs | Should -BeNullOrEmpty
    }
    function Get-Line([string]$Text, [switch]$Last) {
        $lines = @((Get-Calls) -split "`n")
        $found = @(for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i].Contains($Text)) { $i } })
        if ($found.Count -eq 0) { return -1 }
        if ($Last) { return $found[-1] }
        return $found[0]
    }
}

AfterAll {
    & pkill -9 -f "trocar_tipo_windows.ps1" 2>$null
    foreach ($k in $SavedEnv.Keys) { [Environment]::SetEnvironmentVariable($k, $SavedEnv[$k]) }
}

Describe "antes de apagar" {
    BeforeEach { Reset-Store }

    It "-Simular mostra o aviso, a conferencia e o plano sem mudar nada" {
        Invoke-Change @("-Simular", "-Tipo", "comercio")
        $Rc | Should -Be 0
        $Out | Should -Match "APAGA TODO O BANCO DE DADOS"
        $Out | Should -Match "MESMA SENHA"
        $Out | Should -Match "Sai: 12 produtos"
        $Out | Should -Match "SIMULACAO: nada foi alterado"
        (Get-Calls) | Should -Match "notify_master TO=general DRY_RUN=1"
        Test-NothingChanged
        Test-Path $StateFile | Should -BeFalse
    }

    It "recusa com caixa ou comanda aberta e diz quais" {
        Write-File "/fake/state/loja/bloqueios" "Caixa #3 aberto por Maria`nComanda Mesa 4 (#88) aberta`n"
        Invoke-Change @("-Tipo", "industria", "-Confirmacao", "APAGAR TUDO")
        $Rc | Should -Be 3
        $Out | Should -Match "Caixa #3 aberto por Maria"
        $Out | Should -Match "Comanda Mesa 4"
        Test-NothingChanged
    }

    It "recusa o mesmo tipo" {
        Invoke-Change @("-Tipo", "restaurante", "-Confirmacao", "APAGAR TUDO")
        $Rc | Should -Be 4
        Test-NothingChanged
    }

    It "confirmacao errada cancela" {
        Invoke-Change @("-Tipo", "comercio", "-Confirmacao", "apagar tudo")
        $Rc | Should -Be 1
        $Out | Should -Match "Cancelado. Nada foi apagado."
        Test-NothingChanged
    }

    It "mestre fora do ar antes: nada muda" {
        Set-Knob "master_dry_fail"
        Invoke-Change @("-Tipo", "comercio", "-Confirmacao", "APAGAR TUDO")
        $Rc | Should -Be 1
        $Out | Should -Match "Nada foi apagado"
        Test-NothingChanged
    }

    It "API antiga pede para atualizar" {
        Set-Knob "rake_antiga"
        Invoke-Change @("-Tipo", "comercio", "-Confirmacao", "APAGAR TUDO")
        $Rc | Should -Be 1
        $Out | Should -Match "Atualizar NCommerce"
        Test-NothingChanged
    }

    It "copia que nao bate na conferencia: nada apagado e a loja religada" {
        Set-Knob "restore_mismatch"
        Invoke-Change @("-Tipo", "comercio", "-Confirmacao", "APAGAR TUDO")
        $Rc | Should -Be 1
        $Out | Should -Match "nao passou na conferencia"
        $Out | Should -Match "Nada foi apagado"
        Get-Tipo | Should -Be "restaurant"
        (Get-Calls) | Should -Not -Match "commerce_type:prepare"
        Get-BackupDirs | Should -BeNullOrEmpty
        (Get-Line "compose up -d" -Last) | Should -BeGreaterThan (Get-Line "compose stop guard web api")
        Test-Path "$Loja/control/pausa" | Should -BeFalse
    }
}

Describe "troca" {
    BeforeEach { Reset-Store }

    It "troca para comercio pelo menu, com copia conferida, e avisa o mestre" {
        Invoke-Change @("-Confirmacao", "APAGAR TUDO") "2"
        $Rc | Should -Be 0
        $Out | Should -Match "TIPO DA LOJA TROCADO: agora e Comercio em geral"
        $Out | Should -Match "MESMA senha"
        $Out | Should -Match "Nao ha usuarios de exemplo"
        $Out | Should -Not -Match "cashier123"
        Get-Tipo | Should -Be "general"
        (Get-Content -Raw /fake/state/loja/mestre).Trim() | Should -Be "general"
        $dirs = Get-BackupDirs
        $dirs.Count | Should -Be 1
        $b = $dirs[0].FullName
        $b | Should -Match "NCommerce-backup-troca-tipo-"
        Test-Path "$b/banco/banco-ncommerce_api_production.sql.gz" | Should -BeTrue
        Test-Path "$b/manter.json" | Should -BeTrue
        Test-Path "$b/notas-fiscais.csv" | Should -BeTrue
        Test-Path "$b/LEIA-ME.txt" | Should -BeTrue
        Test-Path "$b/volumes/nfce_data/notas_output/dados_nota_100_1234.xml" | Should -BeTrue
        Test-Path "$b/volumes/api_env/.env.production" | Should -BeTrue
        (Get-Content -Raw "$b/conferencia-banco-da-loja.txt") | Should -Be (Get-Content -Raw "$b/conferencia-copia-restaurada.txt")
        (Get-Content -Raw "$b/conferencia-banco-da-loja.txt") | Should -Match "bills"
        (Get-Calls) | Should -Match ([regex]::Escape("-v ${b}:/troca"))
        $stop = Get-Line "compose stop guard web api"
        $dump = Get-Line "mysqldump"
        $prep = Get-Line "commerce_type:prepare"
        $reset = Get-Line "commerce_type:reset"
        $master = Get-Line "notify_master KEEP_FILE"
        $up = Get-Line "compose up -d" -Last
        $stop | Should -BeLessThan $dump
        $dump | Should -BeLessThan $prep
        $prep | Should -BeLessThan $reset
        $reset | Should -BeLessThan $master
        $master | Should -BeLessThan $up
        Test-Path "$Loja/control/pausa" | Should -BeFalse
        Test-Path $StateFile | Should -BeFalse
    }

    It "reset interrompido: loja fica parada; abrir de novo continua sem refazer a copia" {
        Set-Knob "reset_fail" "1"
        Invoke-Change @("-Tipo", "industria", "-Confirmacao", "APAGAR TUDO")
        $Rc | Should -Be 1
        $Out | Should -Match "ja comecou a ser apagado"
        (Get-Content -Raw /fake/state/loja/banco).Trim() | Should -Be "meio"
        Test-Path "$Loja/control/pausa" | Should -BeTrue
        Invoke-Change @("-Tipo", "restaurante")
        $Rc | Should -Be 2
        Invoke-Change @()
        $Rc | Should -Be 0
        $Out | Should -Match "Continuando a troca para Industria"
        Get-Tipo | Should -Be "industry"
        ([regex]::Matches((Get-Calls), "(?m)^mysqldump")).Count | Should -Be 1
        @(Get-Content /fake/state/loja/resets).Count | Should -Be 2
        (Get-BackupDirs).Count | Should -Be 1
        Test-Path "$Loja/control/pausa" | Should -BeFalse
    }

    It "falha antes do reset religa a loja: a copia velha nao serve, abrir de novo faz outra" {
        Set-Knob "prepare_fail"
        Invoke-Change @("-Tipo", "comercio", "-Confirmacao", "APAGAR TUDO")
        $Rc | Should -Be 1
        $Out | Should -Match "Nada foi apagado"
        Test-Path "$Loja/control/pausa" | Should -BeFalse
        Remove-Knob "prepare_fail"
        Invoke-Change @("-Tipo", "comercio", "-Confirmacao", "APAGAR TUDO")
        $Rc | Should -Be 0
        Get-Tipo | Should -Be "general"
        ([regex]::Matches((Get-Calls), "(?m)^mysqldump")).Count | Should -Be 2
        (Get-BackupDirs).Count | Should -Be 2
    }

    It "parada antes do reset (loja nao religou): pede de novo, da para desistir, e a loja volta" {
        Set-Knob "prepare_fail"
        Set-Knob "up_fail" "1"
        Invoke-Change @("-Tipo", "comercio", "-Confirmacao", "APAGAR TUDO")
        $Rc | Should -Be 1
        $Out | Should -Match "Nada foi apagado"
        Remove-Knob "prepare_fail"
        Remove-Knob "up_fail"
        Invoke-Change @("-Confirmacao", "nao")
        $Rc | Should -Be 1
        $Out | Should -Match "Cancelado. Nada foi apagado; a copia ficou em"
        Get-Tipo | Should -Be "restaurant"
        Test-Path $StateFile | Should -BeFalse
        Test-Path "$Loja/control/pausa" | Should -BeFalse
    }

    It "loja ligada no logon depois da copia: faz copia nova antes de apagar" {
        Set-Knob "prepare_fail"
        Set-Knob "up_fail" "1"
        Invoke-Change @("-Tipo", "comercio", "-Confirmacao", "APAGAR TUDO")
        $Rc | Should -Be 1
        Remove-Knob "prepare_fail"
        Remove-Knob "up_fail"
        Write-File "/fake/state/containers/api.status" "running`n"
        Invoke-Change @("-Tipo", "comercio", "-Confirmacao", "APAGAR TUDO")
        $Rc | Should -Be 0
        $Out | Should -Match "Essa copia nao vale mais"
        Get-Tipo | Should -Be "general"
        ([regex]::Matches((Get-Calls), "(?m)^mysqldump")).Count | Should -Be 2
        (Get-BackupDirs).Count | Should -Be 2
        # Parou a loja de novo entre a copia nova e o prepare.
        $lines = @((Get-Calls) -split "`n")
        $dump = Get-Line "mysqldump" -Last
        $prep = Get-Line "commerce_type:prepare" -Last
        @($lines[$dump..$prep] | Where-Object { $_.Contains("compose stop guard web api") }).Count | Should -BeGreaterThan 0
    }

    It "mestre fora do ar depois do reset: a troca vale e abrir de novo avisa" {
        Set-Knob "master_fail" "3"
        Invoke-Change @("-Tipo", "comercio", "-Confirmacao", "APAGAR TUDO")
        $Rc | Should -Be 0
        $Out | Should -Match "FALTA avisar o NCommerce"
        Get-Tipo | Should -Be "general"
        Test-Path $StateFile | Should -BeTrue
        Test-Path "/fake/state/loja/mestre" | Should -BeFalse
        Invoke-Change @()
        $Rc | Should -Be 0
        (Get-Content -Raw /fake/state/loja/mestre).Trim() | Should -Be "general"
        Test-Path $StateFile | Should -BeFalse
        @(Get-Content /fake/state/loja/resets).Count | Should -Be 1
    }
}
