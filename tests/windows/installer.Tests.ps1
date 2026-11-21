# Testes de partes do windows/instalador_windows.ps1 no PowerShell 7 do Linux.
# O instalador inteiro so roda no Windows (WSL, Docker Desktop, tarefas,
# firewall): aqui as funcoes dele sao carregadas uma a uma e testadas com o
# mestre de mentira (tests/fake/server.py), o docker de mentira e o curl de
# verdade. Fail, que fecharia o processo, vira uma excecao.

BeforeAll {
    $script:Repo = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path
    . (Join-Path $Repo "windows/instalador-lib.ps1")
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $Repo "windows/instalador_windows.ps1"), [ref]$tokens, [ref]$errors)
    foreach ($fn in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
        . ([scriptblock]::Create($fn.Extent.Text))
    }
    function Fail([string]$What, [string]$Hint = "") { Undo-LiveStoreChanges; throw "FALHA: $What" }

    $script:InstallDir = "/tmp/loja"
    $script:DataDir = "/tmp/programdata"
    $script:Root = "/tmp/instalador"
    $script:DefaultRegistry = "reg.test:5050"
    $script:MasterUrl = "http://127.0.0.1:8088"
    $script:DockerExe = Join-Path $Repo "tests/fake/bin/docker"
    $script:Bin = "/tmp/fakebin"
    New-Item -ItemType Directory -Force -Path $Bin | Out-Null
    & ln -sf (Join-Path $Repo "tests/fake/bin/mysqldump") (Join-Path $Bin "mysqldump")
    $env:PATH = "${Bin}:$env:PATH"

    New-Item -ItemType Directory -Force -Path "/fake/knobs", "/env" | Out-Null
    [IO.File]::WriteAllText("/fake/calls.log", "")
    $script:Master = Start-Process python3 -ArgumentList @((Join-Path $Repo "tests/fake/server.py"), "master") -PassThru
    for ($i = 0; $i -lt 50; $i++) {
        & curl -s -o /dev/null http://127.0.0.1:8088/ 2>$null
        if ($LASTEXITCODE -eq 0) { break }
        Start-Sleep -Milliseconds 100
    }

    function Set-Knob([string]$Name, [string]$Value = "1") { [IO.File]::WriteAllText("/fake/knobs/$Name", "$Value`n") }
    function Remove-Knob([string]$Name) { Remove-Item "/fake/knobs/$Name" -Force -ErrorAction SilentlyContinue }
    function Get-Ref([string]$Ref) {
        $f = "/fake/state/images/" + ($Ref -replace '[/:]', '_')
        if (Test-Path $f) { return (Get-Content -Raw $f).Trim() }
        return ""
    }
    function Get-Calls { return "$(Get-Content -Raw /fake/calls.log)" }
    function New-BackupZip([string]$Dest, [string]$Password) {
        $w = "/tmp/zipw"
        Remove-Item $w -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Force -Path $w | Out-Null
        [IO.File]::WriteAllText("$w/backup.sql", "CREATE TABLE t (id int);`n")
        $rnd = New-Object byte[] 300000
        (New-Object System.Random 7).NextBytes($rnd)
        [IO.File]::WriteAllBytes("$w/enchimento.bin", $rnd)
        Remove-Item $Dest -Force -ErrorAction SilentlyContinue
        Push-Location $w
        & zip -q --password $Password $Dest backup.sql enchimento.bin
        Pop-Location
    }
    # Loja instalada, rodando api1/web1.
    function Reset-Store {
        foreach ($d in @("/fake/state", $InstallDir, $DataDir)) { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
        Get-ChildItem /fake/knobs | Remove-Item -Force
        New-Item -ItemType Directory -Force -Path "/fake/state/images", "/fake/state/containers", "$InstallDir/control", $DataDir | Out-Null
        [IO.File]::WriteAllText("/fake/calls.log", "")
        Set-Knob "api_never_starts"
        [IO.File]::WriteAllText("$InstallDir/docker-compose.yml", "services: {} # antes`n")
        [IO.File]::WriteAllText("$InstallDir/.env", "NCOMMERCE_REGISTRY=reg.test:5050`nNCOMMERCE_TAG=latest`nCUPS_PORT=631`n")
        [IO.File]::WriteAllText("/fake/state/images/reg.test_5050_ncommerce_api_latest", "sha256:api1`n")
        [IO.File]::WriteAllText("/fake/state/images/reg.test_5050_ncommerce_web_latest", "sha256:web1`n")
        foreach ($s in @("mysql", "redis", "api", "web", "guard")) {
            [IO.File]::WriteAllText("/fake/state/containers/$s", "sha256:$s`n")
            [IO.File]::WriteAllText("/fake/state/containers/$s.status", "running`n")
        }
        [IO.File]::WriteAllText("/fake/state/containers/api", "sha256:api1`n")
        [IO.File]::WriteAllText("/fake/state/containers/web", "sha256:web1`n")
        $script:StoreAlreadyLive = $true
        $script:SnapTaken = $false
        $script:RollingBack = $false
        $script:Registry = "reg.test:5050"
        $script:Tag = "latest"
        $script:Mode = "instalacao"
    }
    Mock Start-Sleep { }
}

AfterAll {
    if ($script:Master) { try { $script:Master.Kill() } catch { } }
}

Describe "codigo de instalacao" {
    BeforeEach { Reset-Store }
    It "codigo certo devolve token e empresa" {
        $g = Get-InstallGrant "GOODCODE"
        $g.token | Should -Be "tok123456789"
        $g.company | Should -Be "lojateste"
        Test-Path "$DataDir/machine-id" | Should -BeTrue
    }
    It "codigo recusado devolve vazio" {
        Get-InstallGrant "RUIMRUIM" | Should -BeNullOrEmpty
    }
    It "mestre fora do ar: sem-resposta" {
        Set-Knob "master_500"
        Get-InstallGrant "GOODCODE" | Should -Be "sem-resposta"
    }
    It "machine-id estragado e refeito" {
        [IO.File]::WriteAllText("$DataDir/machine-id", "")
        $id = Get-MachineId
        $id | Should -Match '^[0-9a-f\-]{36}$'
        Get-MachineId | Should -Be $id
    }
    It "codigo-instalacao.txt com espaco e minuscula" {
        New-Item -ItemType Directory -Force -Path $Root | Out-Null
        [IO.File]::WriteAllText("$Root/codigo-instalacao.txt", " good-code `r`n")
        Read-CodeFile | Should -Be "GOODCODE"
        [IO.File]::WriteAllText("$Root/codigo-instalacao.txt", "curto")
        Read-CodeFile | Should -BeNullOrEmpty
    }
}

Describe "backup do servidor" {
    BeforeEach { Reset-Store; Remove-Item /fake/master-backup.zip -Force -ErrorAction SilentlyContinue }
    It "baixa e confere" {
        New-BackupZip "/fake/master-backup.zip" "tok123"
        Save-CompanyBackup "GOODCODE" "tok123456789"
        Get-BackupZipProblem "$InstallDir/ncommerce.zip" "tok123456789" | Should -Be ""
        Test-Path "$DataDir/ncommerce.zip.part" | Should -BeFalse
    }
    It "internet cai no meio: continua de onde parou" {
        New-BackupZip "/fake/master-backup.zip" "tok123"
        Set-Knob "backup_cut" "100000"
        Save-CompanyBackup "GOODCODE" "tok123456789"
        Get-BackupZipProblem "$InstallDir/ncommerce.zip" "tok123456789" | Should -Be ""
        (Get-Calls) | Should -Match "backup"
        (Get-Item "$InstallDir/ncommerce.zip").Length | Should -Be (Get-Item /fake/master-backup.zip).Length
    }
    It "pedaco de um backup velho: comeca do zero" {
        New-BackupZip "/fake/master-backup.zip" "tok123"
        [IO.File]::WriteAllBytes("$DataDir/ncommerce.zip.part", (New-Object byte[] 1000))
        Save-CompanyBackup "GOODCODE" "tok123456789"
        Get-BackupZipProblem "$InstallDir/ncommerce.zip" "tok123456789" | Should -Be ""
    }
    It "empresa sem backup segue com a loja vazia" {
        Set-Knob "no_backup"
        Save-CompanyBackup "GOODCODE" "tok123456789"
        Test-Path "$InstallDir/ncommerce.zip" | Should -BeFalse
    }
    It "backup de outra empresa para a instalacao" {
        New-BackupZip "/fake/master-backup.zip" "outra1"
        { Save-CompanyBackup "GOODCODE" "tok123456789" } | Should -Throw "*danificado*"
        Test-Path "$InstallDir/ncommerce.zip" | Should -BeFalse
    }
}

Describe "volta ao estado anterior (loja que ja funcionava)" {
    BeforeEach { Reset-Store }
    It "guarda compose, .env e as imagens em uso" {
        Save-LiveStoreSnapshot
        $script:SnapTaken | Should -BeTrue
        (Get-Content -Raw "$InstallDir/control/antes-da-instalacao/imagens").Trim() | Should -Be "sha256:api1|sha256:web1|latest|reg.test:5050"
        Test-Path "$InstallDir/control/antes-da-instalacao/.env" | Should -BeTrue
    }
    It "loja nova (nao estava no ar) nao guarda nada" {
        $script:StoreAlreadyLive = $false
        Save-LiveStoreSnapshot
        Test-Path "$InstallDir/control/antes-da-instalacao" | Should -BeFalse
    }
    It "copia de uma execucao anterior que nao terminou fica" {
        Save-LiveStoreSnapshot
        [IO.File]::WriteAllText("$InstallDir/docker-compose.yml", "services: {} # novo`n")
        $script:SnapTaken = $false
        Save-LiveStoreSnapshot
        (Get-Content -Raw "$InstallDir/control/antes-da-instalacao/docker-compose.yml") | Should -Match "antes"
    }
    It "copia com mais de 2 dias e refeita" {
        Save-LiveStoreSnapshot
        (Get-Item "$InstallDir/control/antes-da-instalacao/imagens").LastWriteTime = (Get-Date).AddDays(-3)
        [IO.File]::WriteAllText("$InstallDir/docker-compose.yml", "services: {} # novo`n")
        $script:SnapTaken = $false
        Save-LiveStoreSnapshot
        (Get-Content -Raw "$InstallDir/control/antes-da-instalacao/docker-compose.yml") | Should -Match "novo"
    }
    It "falha com a loja respondendo: nada e desfeito" {
        Save-LiveStoreSnapshot
        [IO.File]::WriteAllText("$InstallDir/docker-compose.yml", "services: {} # novo`n")
        Mock Wait-ApiUp { $true }
        { Fail "teste" } | Should -Throw
        (Get-Content -Raw "$InstallDir/docker-compose.yml") | Should -Match "novo"
        (Get-Calls) | Should -Not -Match "compose up"
    }
    It "falha com a loja fora do ar: arquivos e imagens voltam e a loja e religada" {
        Save-LiveStoreSnapshot
        [IO.File]::WriteAllText("$InstallDir/docker-compose.yml", "services: {} # novo`n")
        [IO.File]::WriteAllText("$InstallDir/.env", "NCOMMERCE_REGISTRY=reg.test:5050`nNCOMMERCE_TAG=latest`nNOVO=1`n")
        [IO.File]::WriteAllText("/fake/state/images/reg.test_5050_ncommerce_api_latest", "sha256:api2`n")
        $script:waits = 0
        Mock Wait-ApiUp { $script:waits++; return ($script:waits -ge 2) }
        { Fail "teste" } | Should -Throw
        (Get-Content -Raw "$InstallDir/docker-compose.yml") | Should -Match "antes"
        (Get-Content -Raw "$InstallDir/.env") | Should -Not -Match "NOVO"
        Get-Ref "reg.test:5050/ncommerce/api:latest" | Should -Be "sha256:api1"
        Get-Ref "reg.test:5050/ncommerce/web:latest" | Should -Be "sha256:web1"
        (Get-Calls) | Should -Match "compose up -d"
        Test-Path "$InstallDir/control/antes-da-instalacao" | Should -BeFalse
    }
    It "nao conseguiu religar: a copia fica para o suporte" {
        Save-LiveStoreSnapshot
        Mock Wait-ApiUp { $false }
        { Fail "teste" } | Should -Throw
        Test-Path "$InstallDir/control/antes-da-instalacao/imagens" | Should -BeTrue
    }
    It "versao guardada (keep-) nao mexe na etiqueta latest" {
        [IO.File]::WriteAllText("$InstallDir/.env", "NCOMMERCE_REGISTRY=reg.test:5050`nNCOMMERCE_TAG=keep-v1`n")
        Save-LiveStoreSnapshot
        [IO.File]::WriteAllText("/fake/state/images/reg.test_5050_ncommerce_api_latest", "sha256:api2`n")
        Restore-SnapshotTags
        Get-Ref "reg.test:5050/ncommerce/api:latest" | Should -Be "sha256:api2"
    }
    It "versao nova que muda o banco: copia antes" {
        Save-LiveStoreSnapshot
        [IO.File]::WriteAllText("/fake/state/images/reg.test_5050_ncommerce_api_latest", "sha256:api3`n")
        Set-Knob "migration_sha256_api1" "20260101000000"; Set-Knob "migration_sha256_api3" "20260202000000"
        Save-DumpIfDbChanges
        @(Get-ChildItem "$InstallDir/backups" -Filter "antes-de-atualizar-*.sql.gz").Count | Should -Be 1
    }
    It "versao nova sem mudar o banco: sem copia" {
        Save-LiveStoreSnapshot
        [IO.File]::WriteAllText("/fake/state/images/reg.test_5050_ncommerce_api_latest", "sha256:api3`n")
        Set-Knob "migration_sha256_api1" "20260101000000"; Set-Knob "migration_sha256_api3" "20260101000000"
        Save-DumpIfDbChanges
        Test-Path "$InstallDir/backups" | Should -BeFalse
    }
    It "sem copia do banco a troca nao acontece e a etiqueta volta" {
        Save-LiveStoreSnapshot
        [IO.File]::WriteAllText("/fake/state/images/reg.test_5050_ncommerce_api_latest", "sha256:api3`n")
        Set-Knob "migration_sha256_api1" "1"; Set-Knob "migration_sha256_api3" "2"; Set-Knob "dump_fail"
        Mock Wait-ApiUp { $true }
        { Save-DumpIfDbChanges } | Should -Throw "*copia do banco*"
        Get-Ref "reg.test:5050/ncommerce/api:latest" | Should -Be "sha256:api1"
    }
}

Describe "atualizacao interrompida encontrada pelo instalador" {
    BeforeEach { Reset-Store }
    It "download pela metade: etiqueta volta e o arquivo some" {
        [IO.File]::WriteAllText("$InstallDir/control/update.state", "pull|1|sha256:api1|sha256:web1|latest`n")
        [IO.File]::WriteAllText("/fake/state/images/reg.test_5050_ncommerce_api_latest", "sha256:api2`n")
        Repair-InterruptedUpdate "reg.test:5050" | Should -Match "durante o download"
        Get-Ref "reg.test:5050/ncommerce/api:latest" | Should -Be "sha256:api1"
        Test-Path "$InstallDir/control/update.state" | Should -BeFalse
    }
    It "arquivo estragado e so apagado" {
        [IO.File]::WriteAllText("$InstallDir/control/update.state", "lixo")
        Repair-InterruptedUpdate "reg.test:5050" | Should -Be ""
        Test-Path "$InstallDir/control/update.state" | Should -BeFalse
    }
}
