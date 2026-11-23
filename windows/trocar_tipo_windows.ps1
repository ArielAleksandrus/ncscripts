<#
  Troca o tipo da loja (restaurante / comercio em geral / industria) na versao
  Docker do NCommerce no Windows. Abra pelo manutencao\TrocarTipoWindows.bat.

  A troca APAGA TODO O BANCO DE DADOS e recria a loja como uma instalacao nova
  do tipo escolhido. Ficam: os dados da empresa, os administradores (mesma
  senha), a configuracao e a numeracao da NFC-e, as notas (XML) em disco, a
  conexao com o mestre e o resto que fica fora do banco. Antes, uma copia de
  seguranca do banco FORA da instalacao (C:\NCommerce-backup-troca-tipo-<data>),
  conferida: restaurada num banco temporario e comparada tabela por tabela. Se
  ela falhar, nada e apagado. Recusa com caixa ou comanda aberta (diz quais).
  Nota fiscal sem resposta da SEFAZ ou o mestre fora do ar nao impedem: avisa
  e pede para digitar SEGUIR.

  -Tipo         restaurante, comercio ou industria (sem isto, pergunta).
  -Simular      so mostra o que seria feito. Nao muda nada.
  -PastaBackup  pasta onde criar a copia, por exemplo um pen drive (E:\). Padrao: C:\.
  -Confirmacao  uso do suporte (por SSH, sem teclado): o texto APAGAR TUDO.
  -Seguir       uso do suporte (por SSH, sem teclado): o texto SEGUIR, que responde
                os avisos (nota sem resposta da SEFAZ, mestre fora do ar).

  Pode ser interrompida (janela fechada, queda de energia) e aberta de novo:
  continua de onde parou e nao refaz a copia. Progresso e log em
  C:\ProgramData\NCommerce-troca-tipo.
#>
param([string]$Tipo = "", [switch]$Simular, [string]$PastaBackup = "", [string]$Confirmacao = "", [string]$Seguir = "")

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$ConfirmWord = "APAGAR TUDO"
# Para seguir com nota fiscal sem resposta da SEFAZ ou com o mestre fora do ar (decisao X2, 23/11).
$SeguirWord = "SEGUIR"
$script:PendingNotes = ""
$script:MasterDown = $false
$InstallDir = "C:\NCommerce"
if ($env:NCOMMERCE_INSTALL_DIR) { $InstallDir = $env:NCOMMERCE_INSTALL_DIR }
$InstallDir = $InstallDir.TrimEnd('\', '/')
$TrocaDir = Join-Path $env:ProgramData "NCommerce-troca-tipo"
if ($env:NCOMMERCE_DOCKER_EXE) {
    $DockerExe = $env:NCOMMERCE_DOCKER_EXE
} elseif ($env:ProgramFiles) {
    $DockerExe = Join-Path $env:ProgramFiles "Docker\Docker\resources\bin\docker.exe"
} else {
    $DockerExe = ""
}
$MysqlWait = 180
if ($env:NCOMMERCE_MYSQL_WAIT_S) { $MysqlWait = [int]$env:NCOMMERCE_MYSQL_WAIT_S }
$RetryWait = 5
if ($env:TT_RETRY_WAIT_S) { $RetryWait = [int]$env:TT_RETRY_WAIT_S }
$Db = "ncommerce_api_production"
$DbConf = "ncommerce_troca_conferencia"
$KeepName = "manter.json"
# Arquivos da loja no Docker que vao para a copia (o banco vai pelo dump).
$VolumeCopies = @(
    @{ Volume = "api_env"; Service = "api"; Path = "/env"; What = "token e endereco do mestre" },
    @{ Volume = "nfce_data"; Service = "api"; Path = "/data/nfce"; What = "notas fiscais (XML) e certificado" }
)

# rake da API num container de uma vez (a api fica parada), com o .env da loja e a copia em /troca.
$InApi = 'set -a; [ ! -f /env/.env.production ] || . /env/.env.production; set +a; export RAILS_ENV=production DBHOST=mysql DBPORT=3306 REDISHOST=redis REDISPORT=6379 NFCE_JAR=/opt/nfce NFCE_DATA=/data/nfce NFCE_EXTERNAL=/data/nfce/externo APP_ROOT=/app/ncommerce_api; cd /app/ncommerce_api && exec bundle exec rake "$@"'

# Dentro do container do mysql: copia do banco (sem pipe: vale o codigo do mysqldump).
$DumpSh = 'rm -f /tmp/ncommerce-dump.sql /tmp/ncommerce-dump.sql.gz; mysqldump -uroot -p"$MYSQL_ROOT_PASSWORD" --single-transaction --quick --routines --no-tablespaces --result-file=/tmp/ncommerce-dump.sql ncommerce_api_production 2>/dev/null && tail -c 300 /tmp/ncommerce-dump.sql | grep -q "Dump completed" && gzip -f /tmp/ncommerce-dump.sql'

# Restaura a copia num banco temporario e conta as linhas de cada tabela dos dois bancos.
$ConfereSh = 'P="$MYSQL_ROOT_PASSWORD"; c() { s=$(mysql -uroot -p"$P" -N -e "SET SESSION group_concat_max_len = 4194304; SELECT GROUP_CONCAT(CONCAT(''SELECT '''''', table_name, '''''', COUNT(*) FROM \`'', table_schema, ''\`.\`'', table_name, ''\`'') ORDER BY table_name SEPARATOR '' UNION ALL '') FROM information_schema.tables WHERE table_schema = ''$1'' AND table_type = ''BASE TABLE''" 2>/dev/null) && [ -n "$s" ] && [ "$s" != NULL ] && printf "%s;\n" "$s" | mysql -uroot -p"$P" -N 2>/dev/null; }; mysql -uroot -p"$P" -e "DROP DATABASE IF EXISTS ncommerce_troca_conferencia; CREATE DATABASE ncommerce_troca_conferencia" 2>/dev/null || exit 1; ok=1; gzip -dc /tmp/ncommerce-dump.sql.gz | mysql -uroot -p"$P" ncommerce_troca_conferencia 2>/dev/null || ok=0; c ncommerce_api_production > /tmp/conf-loja.txt || ok=0; c ncommerce_troca_conferencia > /tmp/conf-copia.txt || ok=0; mysql -uroot -p"$P" -e "DROP DATABASE IF EXISTS ncommerce_troca_conferencia" 2>/dev/null; [ "$ok" = 1 ] || exit 1; echo "== loja"; cat /tmp/conf-loja.txt; echo "== copia"; cat /tmp/conf-copia.txt'

$lib = Join-Path $PSScriptRoot "instalador-lib.ps1"
if (-not (Test-Path -LiteralPath $lib)) {
    Write-Host ""
    Write-Host "Falta o arquivo $lib." -ForegroundColor Red
    Write-Host "Extraia o zip do instalador inteiro e abra o manutencao\TrocarTipoWindows.bat de dentro da pasta extraida."
    exit 1
}
. $lib

$script:Verdict = ""
$script:Lock = $null
$script:NewType = ""
$script:Backup = ""
$script:MasterPending = $false
$script:StoppedHere = $false
$script:NcStepTotal = 5

# ============================================================ ajudantes

function Get-TipoLabel([string]$T) {
    switch ($T) {
        "restaurant" { return "Restaurante" }
        "general" { return "Comercio em geral" }
        "industry" { return "Industria" }
    }
    return $T
}

function ConvertTo-Tipo([string]$Text) {
    switch (("$Text".ToLower()) -replace '\s', '') {
        { $_ -in @("1", "restaurante", "restaurant") } { return "restaurant" }
        { $_ -in @("2", "comercio", "comercioemgeral", "general", "geral") } { return "general" }
        { $_ -in @("3", "industria", "industry") } { return "industry" }
    }
    return ""
}

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

function Close-Changer {
    Restore-NcConsole
    Exit-NcLock $script:Lock
    $script:Lock = $null
}

# Liga a loja de novo, se foi desligada e o banco nao foi tocado.
function Restore-StoreIfStopped {
    if (-not $script:StoppedHere -and -not (Get-NcState "loja_parada")) { return }
    if (Get-NcState "reset_iniciado") { return }
    Say "Religando a loja como estava..."
    if ((Start-Store) -eq 0) {
        if ($script:NcStateFile) {
            Remove-NcState "loja_parada"
            # Ligada, a loja volta a vender: a copia feita com ela parada deixa de
            # ser a do banco de agora. A proxima execucao faz outra (esta fica).
            if (Test-NcStepDone "backup") {
                foreach ($k in @("etapa_backup", "etapa_prepare", "backup_pasta")) { Remove-NcState $k }
            }
        }
        $script:StoppedHere = $false
    } else {
        Say "Nao consegui religar a loja. Reinicie o computador: ela liga sozinha." "Yellow"
    }
}

# Antes do reset, desistir ou ser recusado apaga o progresso (a copia, se feita, fica).
function Clear-StateBeforeReset {
    if ($Simular -or -not $script:NcStateFile) { return }
    if (Get-NcState "reset_iniciado") { return }
    Remove-Item -LiteralPath $script:NcStateFile, "$($script:NcStateFile).novo" -Force -ErrorAction SilentlyContinue
}

function Stop-Changer([int]$Code, [string]$Verdict) {
    $script:Verdict = $Verdict
    Restore-StoreIfStopped
    Clear-StateBeforeReset
    Close-Changer
    exit $Code
}

function Fail([string]$What, [string]$Hint = "") {
    Say ""
    Say "==================================================================" "Red"
    Say "  A TROCA DE TIPO NAO TERMINOU." "Red"
    Say "==================================================================" "Red"
    Say "O que aconteceu: $What"
    if ($script:NcStateFile -and (Get-NcState "reset_iniciado") -and -not (Test-NcStepDone "reset")) {
        Say "O banco da loja ja comecou a ser apagado e ainda nao esta pronto: a loja fica desligada" "Yellow"
        Say "ate a troca terminar. Abra o TrocarTipoWindows.bat de novo: ela continua daqui." "Yellow"
        Say "(Para voltar como estava, chame o suporte NCommerce com a copia de seguranca.)"
    } elseif ($script:NcStateFile -and (Test-NcStepDone "reset")) {
        Say "O que fazer: abra o TrocarTipoWindows.bat de novo. Ele continua de onde parou."
    } else {
        Restore-StoreIfStopped
        Say "Nada foi apagado."
        if ($Hint) { Say "O que fazer: $Hint" } else { Say "O que fazer: abra o TrocarTipoWindows.bat de novo quando quiser." }
    }
    if ($script:NcStateFile -and (Test-NcStepDone "backup")) { Say "Copia de seguranca conferida: $(Get-NcState 'backup_pasta')" }
    if ($script:NcLogFile) { Say "Log: $($script:NcLogFile)" }
    $script:Verdict = "falha"
    Close-Changer
    exit 1
}

function Invoke-Rake([string[]]$RakeArgs) {
    $mount = @()
    $bk = ""
    if ($script:NcStateFile) { $bk = Get-NcState "backup_pasta" }
    if ($bk -and (Test-Path -LiteralPath $bk)) { $mount = @("-v", "${bk}:/troca") }
    $out = Invoke-ComposeExec -ArgList (@("run", "--rm", "--no-deps", "-T") + $mount + @("--entrypoint", "bash", "api", "-c", $InApi, "bash") + $RakeArgs)
    $code = $LASTEXITCODE
    $lines = @("$out" -split "`r?`n" | Where-Object { $_ -ne "" })
    foreach ($l in $lines) {
        if ($l -notmatch '^(PREPARE_OK|RESET_OK|MASTER_OK)') { Say "  $l" } else { Write-NcLog $l }
    }
    if ($code -ne 0 -and "$out" -match "Don't know how to build task") {
        Fail "esta versao do NCommerce ainda nao tem a troca de tipo." "atualize o NCommerce (atalho Atualizar NCommerce) e abra o TrocarTipoWindows.bat de novo."
    }
    return [pscustomobject]@{ Code = $code; Text = "$out" }
}

function Invoke-MysqlSh([string]$Script) {
    $out = Invoke-ComposeExec exec -T mysql sh -c $Script
    return [pscustomobject]@{ Code = $LASTEXITCODE; Text = "$out" }
}

function Wait-MysqlReady {
    $running = @(Get-ComposeLines @("ps", "--status", "running", "--services"))
    if ($running -notcontains "mysql") {
        if ((Invoke-Compose -Arguments @("up", "-d", "mysql", "redis") -Quiet) -ne 0) { return $false }
    }
    for ($waited = 0; $waited -le $MysqlWait; $waited += 3) {
        Invoke-ComposeExec exec -T mysql sh -c 'mysqladmin ping -h 127.0.0.1 -uroot -p"$MYSQL_ROOT_PASSWORD" --silent' | Out-Null
        if ($LASTEXITCODE -eq 0) { return $true }
        if ($waited -lt $MysqlWait) { Start-Sleep -Seconds 3 }
    }
    return $false
}

function Get-ComposeLines([string[]]$Arguments) {
    return @((Get-DockerText (@("compose") + $Arguments)) -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

# Guarda primeiro (ela religa container parado); o aviso de pausa tambem a segura.
# Sempre para (parar o que ja esta parado nao custa): numa retomada a loja pode
# ter sido ligada no logon, e copia, prepare e reset nao rodam com ela vendendo.
function Stop-Store {
    Say "Desligando a loja (nenhuma venda entra depois da copia)..."
    Set-NcState "loja_parada" "1"
    $script:StoppedHere = $true
    [System.IO.Directory]::CreateDirectory((Join-Path $InstallDir "control")) | Out-Null
    Write-FileAtomic (Join-Path $InstallDir "control\pausa") "troca de tipo`n"
    if ((Invoke-Compose -Arguments @("stop", "guard", "web", "api") -Quiet) -ne 0) { Fail "nao consegui desligar a loja para a copia." }
}

function Start-Store {
    $code = Invoke-Compose -Arguments @("up", "-d") -Quiet
    if ($code -eq 0) { Remove-Item -LiteralPath (Join-Path $InstallDir "control\pausa") -Force -ErrorAction SilentlyContinue }
    return $code
}

function Show-Warning {
    Say ""
    Say "ATENCAO: trocar o tipo APAGA TODO O BANCO DE DADOS da loja e comeca de novo," "Yellow"
    Say "como uma instalacao nova do tipo escolhido." "Yellow"
    Say ""
    Say "Sera APAGADO: todos os produtos e categorias, comandas, pedidos, vendas,"
    Say "caixas, clientes, fornecedores, estoque, reservas, cardapios, usuarios que"
    Say "nao sao administradores e todas as opcoes e configuracoes da loja (taxas,"
    Say "formas de pagamento, qual impressora imprime o que...)."
    Say ""
    Say "FICA:"
    Say "  - os dados da empresa (nome, razao social, CNPJ, endereco, contatos, logo),"
    Say "    ja com o tipo novo, e os responsaveis;"
    Say "  - os ADMINISTRADORES, com o mesmo login e a MESMA SENHA;"
    Say "  - a configuracao da NFC-e (CSC, serie, ambiente, certificado) e a NUMERACAO:"
    Say "    a proxima nota continua de onde parou (numero repetido a SEFAZ recusa);"
    Say "  - as notas fiscais (XML) guardadas no computador (guarda de 5 anos);"
    Say "  - a conexao com o NCommerce (mestre), o tunel, o iFood conectado e as"
    Say "    impressoras instaladas."
    Say ""
    Say "Antes de apagar e feita uma COPIA DE SEGURANCA do banco, fora da instalacao,"
    Say "conferida (restaurada num banco temporario e comparada tabela por tabela)."
    Say "Se a copia falhar, nada e apagado. Precisa: nenhum caixa aberto e nenhuma"
    Say "comanda aberta (feche antes). Nota fiscal sem resposta da SEFAZ ou o mestre"
    Say "fora do ar nao impedem: o script avisa e pede para digitar SEGUIR."
}

# Pede SEGUIR. No -Simular so diz que pediria.
function Read-Seguir {
    if ($Simular) {
        Say "  [simular] aqui seria pedido para digitar $SeguirWord para continuar."
        return $true
    }
    $answer = $Seguir
    if (-not $answer) { $answer = Read-Host "Para continuar mesmo assim, digite $SeguirWord (em maiusculas) e tecle Enter (qualquer outra coisa cancela)" }
    return ("$answer".Trim() -ceq $SeguirWord)
}

function Stop-Seguir {
    $bk = ""
    if ($script:NcStateFile -and (Test-NcStepDone "backup")) { $bk = Get-NcState "backup_pasta" }
    if ($bk) { Say "Cancelado. Nada foi apagado; a copia ficou em $bk." } else { Say "Cancelado. Nada foi apagado." }
    Stop-Changer 1 "cancelado"
}

# Nota fiscal sem resposta da SEFAZ (a lista e a explicacao vieram do rake, acima): nao impede, pede SEGUIR.
function Confirm-PendingNotes {
    Say ""
    Say "AVISO: ha nota fiscal sem resposta da SEFAZ (acima). Ela NAO impede a troca:" "Yellow"
    Say "  - os arquivos dela (o .envio e os XMLs) NAO sao apagados: ficam na pasta da NFC-e"
    Say "    e vao na copia de seguranca;"
    Say "  - a lista vai no notas-fiscais.csv, na copia (coluna sem_resposta_sefaz);"
    Say "  - a numeracao continua depois dela (nenhum numero e repetido)."
    if (-not (Read-Seguir)) { Stop-Seguir }
    $script:PendingNotes = $SeguirWord
}

function Read-Tipo {
    if ($Tipo) {
        $t = ConvertTo-Tipo $Tipo
        if (-not $t) {
            Say "Tipo desconhecido: $Tipo (use restaurante, comercio ou industria)."
            Stop-Changer 2 "tipo"
        }
        return $t
    }
    Say ""
    Say "Para qual tipo a loja vai passar?"
    Say "  1) Restaurante"
    Say "  2) Comercio em geral"
    Say "  3) Industria"
    $t = ConvertTo-Tipo (Read-Host "Digite 1, 2 ou 3 e tecle Enter")
    if (-not $t) {
        Say "Resposta nao reconhecida. Nada foi mudado."
        Stop-Changer 1 "cancelado"
    }
    return $t
}

function Read-Confirmation {
    Say ""
    Say "Para APAGAR TODO O BANCO e trocar a loja para $(Get-TipoLabel $script:NewType),"
    $answer = $Confirmacao
    if (-not $answer) { $answer = Read-Host "digite $ConfirmWord (em maiusculas) e tecle Enter (qualquer outra coisa cancela)" }
    return ("$answer".Trim() -ceq $ConfirmWord)
}

function Test-Store {
    Say ""
    Say "Conferindo a loja (caixas e comandas abertos, o que fica e o que sai)..."
    $r = Invoke-Rake @("store:commerce_type:check", "TO=$($script:NewType)")
    switch ($r.Code) {
        0 { return }
        7 { Confirm-PendingNotes; return }
        3 {
            Say ""
            Say "Feche os caixas e as comandas acima e abra de novo."
            Say "Nada foi mudado."
            Stop-Changer 3 "recusado"
        }
        4 {
            Say ""
            Say "A loja ja e do tipo $(Get-TipoLabel $script:NewType). Nada foi mudado."
            Stop-Changer 4 "mesmo"
        }
    }
    Fail "nao consegui conferir a loja (codigo $($r.Code))."
}

function Test-Master {
    Say ""
    Say "Conferindo a conexao com o NCommerce (mestre)..."
    $r = Invoke-Rake @("store:commerce_type:notify_master", "TO=$($script:NewType)", "DRY_RUN=1")
    if ($r.Code -eq 0) { return }
    if ($r.Code -eq 8) {
        Say ""
        Say "AVISO: o NCommerce (mestre) nao respondeu (internet ou o mestre fora do ar)." "Yellow"
        Say "A troca pode ser feita so na loja. O mestre e avisado no fim, se voltar;"
        Say "senao, abra o TrocarTipoWindows.bat de novo com internet e ele avisa o mestre (nada e refeito)."
        if (-not (Read-Seguir)) { Stop-Seguir }
        $script:MasterDown = $true
        return
    }
    Fail "o NCommerce (mestre) recusou a troca (acima)." "fale com o suporte NCommerce."
}

function Show-Plan {
    Say ""
    Say "O que sera feito:"
    Say "  1. desligar a loja (api, web e guarda; o banco fica ligado)"
    Say "  2. copia de seguranca em $(Get-BackupTarget): banco (mysqldump) conferido num"
    Say "     banco temporario ($DbConf), token, notas e configuracao"
    Say "  3. guardar o que fica (dados da empresa, administradores, NFC-e) em $KeepName, na copia"
    Say "  4. APAGAR e recriar o banco $Db como uma loja nova do tipo $(Get-TipoLabel $script:NewType) e repor o que fica"
    if ($script:MasterDown) {
        Say "  5. avisar o NCommerce (mestre) da troca (fora do ar agora: se nao voltar, abra de novo depois)"
    } else {
        Say "  5. avisar o NCommerce (mestre) da troca"
    }
    Say "  6. ligar a loja"
}

function Get-BackupTarget {
    if ($script:NcStateFile) {
        $saved = Get-NcState "backup_pasta"
        if ($saved) { return $saved }
    }
    $root = $PastaBackup
    if (-not $root -and $env:SystemDrive) { $root = "$($env:SystemDrive)\" }
    if (-not $root) { $root = Split-Path -Parent $InstallDir }
    return (Join-Path $root ("NCommerce-backup-troca-tipo-{0}" -f (Get-Date -Format "yyyyMMdd-HHmmss")))
}

# ============================================================ etapas

function Save-Backup {
    $final = Get-NcState "backup_pasta"
    if (-not $final) {
        $final = Get-BackupTarget
        Set-NcState "backup_pasta" $final
    }
    $partial = "$final.parcial"
    Remove-Item -LiteralPath $partial -Recurse -Force -ErrorAction SilentlyContinue
    Stop-Store
    Say "Copia de seguranca em $final"
    try {
        New-Item -ItemType Directory -Force -Path $partial | Out-Null
    } catch {
        Fail "nao consegui criar a pasta $partial ($($_.Exception.Message))."
    }
    if (-not (Wait-MysqlReady)) { Fail "o banco de dados nao respondeu para a copia." }
    Say "  - banco de dados (pode levar alguns minutos)"
    $r = Invoke-MysqlSh $DumpSh
    if ($r.Code -ne 0) { Fail "a copia do banco de dados (mysqldump) falhou." }
    Say "  - conferindo a copia: restaurando num banco temporario ($DbConf)"
    $r = Invoke-MysqlSh $ConfereSh
    $parts = "$($r.Text)" -split "== copia"
    $loja = @(); $copia = @()
    if ($parts.Count -eq 2) {
        $loja = @(($parts[0] -replace '^\s*== loja', '') -split "`r?`n" | Where-Object { $_.Trim() })
        $copia = @($parts[1] -split "`r?`n" | Where-Object { $_.Trim() })
    }
    Write-FileAtomic (Join-Path $partial "conferencia-banco-da-loja.txt") (($loja -join "`n") + "`n")
    Write-FileAtomic (Join-Path $partial "conferencia-copia-restaurada.txt") (($copia -join "`n") + "`n")
    if ($r.Code -ne 0 -or $loja.Count -eq 0 -or (($loja -join "`n") -ne ($copia -join "`n"))) {
        Remove-Item -LiteralPath $partial -Recurse -Force -ErrorAction SilentlyContinue
        Remove-NcState "backup_pasta"
        Fail "a copia do banco nao passou na conferencia (restaurada num banco temporario)."
    }
    Say "  - copia conferida: $($loja.Count) tabelas, linhas iguais em todas"
    New-Item -ItemType Directory -Force -Path (Join-Path $partial "banco") | Out-Null
    $dump = Join-Path $partial "banco\banco-$Db.sql.gz"
    $code = Invoke-Compose -Arguments @("cp", "mysql:/tmp/ncommerce-dump.sql.gz", $dump) -Quiet
    Invoke-ComposeExec exec -T mysql rm -f /tmp/ncommerce-dump.sql.gz /tmp/conf-loja.txt /tmp/conf-copia.txt | Out-Null
    if ($code -ne 0 -or -not (Test-DumpComplete $dump)) {
        Remove-Item -LiteralPath $partial -Recurse -Force -ErrorAction SilentlyContinue
        Fail "a copia do banco de dados ficou incompleta."
    }
    foreach ($c in $VolumeCopies) {
        $cid = @(Get-ComposeLines @("ps", "-aq", $c.Service))[0]
        $dest = Join-Path $partial "volumes\$($c.Volume)"
        New-Item -ItemType Directory -Force -Path (Join-Path $partial "volumes") | Out-Null
        $code = 1
        if ($cid) { $code = Invoke-Native -Exe $DockerExe -Arguments @("cp", "${cid}:$($c.Path)", $dest) -Quiet }
        if ($code -ne 0) {
            Remove-Item -LiteralPath $partial -Recurse -Force -ErrorAction SilentlyContinue
            Fail "nao consegui copiar $($c.What) (volume $($c.Volume))."
        }
        Say "  - $($c.What)"
    }
    try {
        foreach ($f in @(".env", "docker-compose.yml")) {
            $src = Join-Path $InstallDir $f
            if (Test-Path -LiteralPath $src) {
                New-Item -ItemType Directory -Force -Path (Join-Path $partial "C_NCommerce") | Out-Null
                [System.IO.File]::Copy($src, (Join-Path $partial "C_NCommerce\$f"), $true)
            }
        }
        $readme = @(
            "Copia feita pela troca de tipo da loja do NCommerce em $(Get-Date -Format 'dd/MM/yyyy HH:mm'),",
            "antes de apagar o banco (tipo novo: $(Get-TipoLabel $script:NewType)).",
            "",
            "banco\banco-$Db.sql.gz   banco de dados da loja (mysqldump), conferido: restaurado num",
            "                         banco temporario, mesmas tabelas e mesmo numero de linhas",
            "conferencia-*.txt        a contagem de linhas de cada tabela (loja e copia)",
            "$KeepName              o que a troca repoe (empresa, administradores, NFC-e)",
            "notas-fiscais.csv        a lista das notas fiscais que estavam no banco (sem_resposta_sefaz = sim: sem resposta da SEFAZ)",
            "volumes\                 token, notas fiscais (XML) e certificado",
            "C_NCommerce\             .env e docker-compose.yml",
            "",
            "Tem o token e senhas: guarde num lugar seguro, fora do OneDrive.",
            "Para voltar a loja como estava, chame o suporte NCommerce com esta pasta."
        )
        Write-FileAtomic (Join-Path $partial "LEIA-ME.txt") (($readme -join "`r`n") + "`r`n")
        [System.IO.Directory]::Move($partial, $final)
    } catch {
        Remove-Item -LiteralPath $partial -Recurse -Force -ErrorAction SilentlyContinue
        Fail "nao consegui terminar a copia ($($_.Exception.Message))."
    }
    Say "COPIA DE SEGURANCA PRONTA E CONFERIDA: $final" "Green"
}

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

function Save-Keep {
    Stop-Store
    $keep = Join-Path (Get-NcState "backup_pasta") $KeepName
    # Gravado de uma vez (temporario + rename): se existe, esta completo.
    if ((Get-NcFileLength $keep) -gt 0) {
        Say "O que fica ja foi guardado: $keep"
        return
    }
    $who = "$env:USERNAME@$env:COMPUTERNAME (trocar_tipo_windows.ps1)"
    $r = Invoke-Rake @("store:commerce_type:prepare", "TO=$($script:NewType)", "KEEP_FILE=/troca/$KeepName", "CHANGED_BY=$who", "PENDING_NOTES=$($script:PendingNotes)")
    if ($r.Code -eq 7 -and $script:PendingNotes -ne $SeguirWord) {
        # continuando uma troca (ou nota nova depois da conferencia): pede o SEGUIR aqui
        Confirm-PendingNotes
        $r = Invoke-Rake @("store:commerce_type:prepare", "TO=$($script:NewType)", "KEEP_FILE=/troca/$KeepName", "CHANGED_BY=$who", "PENDING_NOTES=$($script:PendingNotes)")
    }
    if ($r.Code -eq 3 -or $r.Code -eq 4) {
        Say ""
        Say "A troca foi recusada (acima). Nada foi apagado; a copia ficou em $(Get-NcState 'backup_pasta')."
        Stop-Changer $r.Code "recusado"
    }
    if ($r.Code -ne 0) { Fail "nao consegui guardar o que fica (codigo $($r.Code))." }
    if ((Get-NcFileLength $keep) -le 0) { Fail "o arquivo $KeepName nao apareceu na copia." }
}

function Reset-Database {
    if (Get-NcState "reset_iniciado") { Say "Uma execucao anterior parou no meio do reset. Recomecando o reset a partir do que foi guardado." "Yellow" }
    Stop-Store
    Set-NcState "reset_iniciado" ([string][DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
    Say "Apagando e recriando o banco (pode levar alguns minutos)..."
    $r = Invoke-Rake @("store:commerce_type:reset", "KEEP_FILE=/troca/$KeepName", "CONFIRM=APAGAR_TUDO", "ENV_FILE=/env/.env.production")
    try { [System.IO.File]::WriteAllText((Join-Path (Get-NcState "backup_pasta") "reset.txt"), $r.Text) } catch { }
    if ($r.Code -ne 0 -or $r.Text -notmatch '(?m)^RESET_OK') { Fail "o reset do banco nao terminou (codigo $($r.Code))." }
}

function Send-Master {
    Say "Avisando o NCommerce (mestre) da troca..."
    for ($i = 1; $i -le 3; $i++) {
        $r = Invoke-Rake @("store:commerce_type:notify_master", "KEEP_FILE=/troca/$KeepName")
        if ($r.Code -eq 0) { return $true }
        if ($i -lt 3) { Start-Sleep -Seconds $RetryWait }
    }
    $script:MasterPending = $true
    Warn "o NCommerce (mestre) nao foi avisado. A troca na loja valeu; abra o TrocarTipoWindows.bat de novo com internet para avisar."
    return $false
}

function Invoke-ChangeStep([int]$Number, [string]$Name, [string]$Title, [scriptblock]$Action) {
    if (Test-NcStepDone $Name) {
        Say ("=== Etapa {0} de {1}: {2}: ja feita ===" -f $Number, $script:NcStepTotal, $Title) "Cyan"
        return
    }
    Step $Number $Title
    $done = & $Action
    if ($done -ne $false) { Set-NcStepDone $Name }
}

function Show-Final {
    $bk = Get-NcState "backup_pasta"
    Say ""
    Say "==================================================================" "Green"
    Say "  TIPO DA LOJA TROCADO: agora e $(Get-TipoLabel $script:NewType)." "Green"
    Say "==================================================================" "Green"
    Say "Copia de seguranca (banco conferido e configuracao): $bk"
    Say "  Tem o token e senhas: guarde num lugar seguro, fora do OneDrive."
    Say ""
    Say "Os administradores entram com o MESMO login e a MESMA senha de antes."
    Say "A NFC-e continua com a mesma configuracao e a numeracao continua de onde parou."
    Say "As notas (XML) continuam no computador; a lista delas esta em notas-fiscais.csv na copia."
    if ($script:PendingNotes -eq $SeguirWord) {
        Say "Nota(s) sem resposta da SEFAZ: os arquivos continuam na pasta da NFC-e. Para saber se foram"
        Say "autorizadas, o suporte roda na pasta da NFC-e: java -jar NFCe.jar --pendentes (so consulta)."
    }
    Say ""
    Say "Configure de novo, como numa instalacao nova:"
    Say "  - produtos, categorias e cardapios;"
    if ($script:NewType -eq "restaurant") { Say "  - usuarios (caixas, garcons, cozinha) e as permissoes;" } else { Say "  - usuarios (caixas, vendedores) e as permissoes;" }
    Say "  - impressoras: qual imprime o que (Configuracoes > Impressoras);"
    Say "  - taxas, formas de pagamento, entrega e as opcoes da loja (Configuracoes);"
    Say "  - clientes e fornecedores (se quiser, o suporte importa da copia)."
    Say "Nao ha usuarios de exemplo: ficam so os administradores (e o usuario interno do iFood)."
    if ($script:MasterPending) {
        Say ""
        Say "FALTA avisar o NCommerce (mestre): abra o TrocarTipoWindows.bat de novo com internet." "Yellow"
    }
    if ($script:NcWarnings.Count -gt 0) {
        Say ""
        Say "Avisos:" "Yellow"
        foreach ($w in $script:NcWarnings) { Say "  - $w" "Yellow" }
    }
    if ($script:NcLogFile) { Say "Log: $($script:NcLogFile)" }
}

# ============================================================ roteiro

$exitCode = 1
try {
    if (-not $Simular -and -not (Test-IsAdmin)) {
        Write-Host "A troca de tipo precisa de administrador. Abra pelo manutencao\TrocarTipoWindows.bat (ele pede)." -ForegroundColor Red
        $script:Verdict = "admin"
        exit 1
    }
    if ($PastaBackup -and (Test-UnderPath $PastaBackup $InstallDir)) {
        Write-Host "A pasta da copia ($PastaBackup) nao pode ficar dentro de $InstallDir." -ForegroundColor Red
        $script:Verdict = "pasta"
        exit 1
    }
    if (-not (Test-Path -LiteralPath (Join-Path $InstallDir "docker-compose.yml"))) {
        Write-Host "Nao achei a loja do NCommerce em $InstallDir (docker-compose.yml)." -ForegroundColor Red
        $script:Verdict = "sem loja"
        exit 1
    }
    if (-not $Simular) {
        # A mesma trava do instalador, da atualizacao e do desinstalador.
        $script:Lock = Enter-NcLock "Global\NCommerceInstalador"
        if (-not $script:Lock) {
            Write-Host "O instalador, uma atualizacao ou outra janela do NCommerce esta aberta. Espere terminar e abra de novo. Nada foi mudado." -ForegroundColor Yellow
            $script:Verdict = "ocupado"
            exit 2
        }
    }

    $stateFile = Join-Path $TrocaDir "troca.estado"
    if ([System.IO.File]::Exists($stateFile)) { $script:NcStateFile = $stateFile }
    $resuming = [bool]($script:NcStateFile -and (Get-NcState "tipo") -and (Test-NcStepDone "backup"))

    Say "=================================================================="
    if ($Simular) {
        Say "  TROCAR O TIPO DA LOJA - SIMULACAO (nada sera alterado)"
    } else {
        Say "  TROCAR O TIPO DA LOJA (restaurante / comercio em geral / industria)"
    }
    Say "=================================================================="
    if (-not (Test-DockerUp)) {
        $script:Verdict = "docker"
        Say "O Docker Desktop nao esta respondendo. Abra o Docker Desktop, espere ficar pronto e abra de novo. Nada foi mudado." "Red"
        Close-Changer
        exit 1
    }

    # A loja ligada (no logon, ou religada depois de uma falha) vendeu depois da
    # copia: ela nao e mais a do banco de agora. Comeca de novo, com copia nova.
    if ($resuming -and -not $Simular -and -not (Get-NcState "reset_iniciado")) {
        $running = @(Get-ComposeLines @("ps", "--status", "running", "--services"))
        if ($running -contains "api") {
            Say "A loja voltou a funcionar depois da copia de $(Get-NcState 'backup_pasta'). Essa copia nao vale mais:" "Yellow"
            Say "sera feita outra antes de apagar (a anterior fica onde esta)." "Yellow"
            foreach ($k in @("etapa_backup", "etapa_prepare", "backup_pasta", "loja_parada")) { Remove-NcState $k }
            $resuming = $false
        }
    }

    if ($resuming) {
        $script:NewType = Get-NcState "tipo"
        if ($Tipo -and (ConvertTo-Tipo $Tipo) -ne $script:NewType) {
            Say "Uma troca para $(Get-TipoLabel $script:NewType) ja esta em andamento. Ela precisa terminar antes de outra."
            $script:Verdict = "andamento"
            Close-Changer
            exit 2
        }
        Say "Continuando a troca para $(Get-TipoLabel $script:NewType). A copia conferida ja esta em $(Get-NcState 'backup_pasta') (nao sera refeita)." "Yellow"
        if ($Simular) {
            Say "SIMULACAO: nada foi alterado."
            $script:Verdict = "simulacao"
            $exitCode = 0
            exit 0
        }
        Start-NcLog $TrocaDir "troca-tipo"
        Initialize-NcState $stateFile
        if (-not (Get-NcState "reset_iniciado")) {
            Show-Warning
            if (-not (Read-Confirmation)) {
                Say "Cancelado. Nada foi apagado; a copia ficou em $(Get-NcState 'backup_pasta')."
                Stop-Changer 1 "cancelado"
            }
        }
    } else {
        Show-Warning
        $script:NewType = Read-Tipo
        if (-not (Wait-MysqlReady)) { Fail "o banco de dados da loja nao respondeu." }
        Test-Store
        Test-Master
        Show-Plan
        if ($Simular) {
            Say ""
            Say "SIMULACAO: nada foi alterado. Para trocar de verdade, abra o TrocarTipoWindows.bat sem -Simular."
            $script:Verdict = "simulacao"
            $exitCode = 0
            exit 0
        }
        if (-not (Read-Confirmation)) {
            Say "Cancelado. Nada foi apagado."
            Stop-Changer 1 "cancelado"
        }
        Start-NcLog $TrocaDir "troca-tipo"
        Initialize-NcState $stateFile
        Set-NcState "tipo" $script:NewType
        if (-not (Get-NcState "inicio")) { Set-NcState "inicio" ([string][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) }
    }
    Initialize-NcConsole "NCommerce - trocando o tipo da loja - NAO FECHE ESTA JANELA"
    if ($script:NcLogFile) { Say "Log: $($script:NcLogFile)" }
    Say "NAO FECHE ESTA JANELA. Se parar, abra o TrocarTipoWindows.bat de novo: continua de onde parou." "Yellow"

    Invoke-ChangeStep 1 "backup" "Copia de seguranca conferida" { Save-Backup }
    Invoke-ChangeStep 2 "prepare" "Guardar o que fica" { Save-Keep }
    Invoke-ChangeStep 3 "reset" "Apagar e recriar o banco como $(Get-TipoLabel $script:NewType)" { Reset-Database }
    Invoke-ChangeStep 4 "mestre" "Avisar o NCommerce (mestre)" { Send-Master }
    Invoke-ChangeStep 5 "ligar" "Ligar a loja" {
        if ((Start-Store) -ne 0) { Fail "nao consegui ligar a loja." "reinicie o computador (ela liga sozinha) ou abra o TrocarTipoWindows.bat de novo." }
        Remove-NcState "loja_parada"
    }

    Show-Final
    if (-not $script:MasterPending) {
        Remove-Item -LiteralPath $stateFile, "$stateFile.novo" -Force -ErrorAction SilentlyContinue
    }
    $script:Verdict = "ok"
    $exitCode = 0
} catch {
    if ($script:Verdict -eq "") {
        $detail = "$($_.Exception.Message)"
        Write-NcLog "ERRO inesperado: $detail"
        Write-NcLog "$($_.ScriptStackTrace)"
        if (-not ($script:NcStateFile -and (Get-NcState "reset_iniciado"))) { Restore-StoreIfStopped }
        Say ""
        Say "A TROCA DE TIPO NAO TERMINOU: um passo falhou de um jeito inesperado ($detail)." "Red"
        Say "Abra o TrocarTipoWindows.bat de novo: ela continua de onde parou."
        if ($script:NcLogFile) { Say "Se repetir, mande este arquivo para o suporte NCommerce: $($script:NcLogFile)" }
        $script:Verdict = "falha"
    }
} finally {
    if ($script:Verdict -eq "") {
        Write-NcLog "Troca de tipo interrompida (Ctrl+C ou janela fechada)."
        if (-not ($script:NcStateFile -and (Get-NcState "reset_iniciado"))) { Restore-StoreIfStopped }
        Write-Host ""
        Write-Host "A TROCA DE TIPO FOI INTERROMPIDA. Abra o TrocarTipoWindows.bat de novo: ela continua de onde parou." -ForegroundColor Yellow
    }
    Close-Changer
}
exit $exitCode
