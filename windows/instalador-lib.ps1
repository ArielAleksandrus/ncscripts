# Funcoes do instalador_windows.ps1 que nao dependem da loja: log, trava contra
# duas execucoes, registro de progresso em disco, escrita atomica de arquivos,
# .env, download que continua de onde parou e a conferencia do zip de backup.
# Este arquivo so define funcoes; quem usa faz `. instalador-lib.ps1`.
# Compativel com o Windows PowerShell 5.1 (sem operadores do PowerShell 7) e
# so com caracteres ASCII: o 5.1 le arquivo sem BOM na pagina de codigo do Windows.
# Os testes (tests/windows-lib.Tests.ps1) rodam no PowerShell 7 do Linux.

$script:NcLogFile = $null
$script:NcStepNow = 0
$script:NcStepTotal = 0
$script:NcStepTitle = ""
$script:NcWarnings = New-Object System.Collections.Generic.List[string]
$script:NcStateFile = $null
$script:NcUtf8 = New-Object System.Text.UTF8Encoding $false

# ------------------------------------------------------------------ mensagens

function Start-NcLog([string]$Dir, [string]$Prefix) {
    try {
        [System.IO.Directory]::CreateDirectory($Dir) | Out-Null
        $script:NcLogFile = Join-Path $Dir ("{0}-{1}.log" -f $Prefix, (Get-Date -Format "yyyyMMdd-HHmmss"))
        [System.IO.File]::WriteAllText($script:NcLogFile, "", $script:NcUtf8)
        # Ficam os 10 logs mais recentes.
        Get-ChildItem -LiteralPath $Dir -Filter "$Prefix-*.log" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -Skip 10 |
            Remove-Item -Force -ErrorAction SilentlyContinue
    } catch {
        $script:NcLogFile = $null
    }
}

function Write-NcLog([string]$Text) {
    if (-not $script:NcLogFile) { return }
    try {
        $line = "[{0}] {1}`r`n" -f (Get-Date -Format "HH:mm:ss"), $Text
        [System.IO.File]::AppendAllText($script:NcLogFile, $line, $script:NcUtf8)
    } catch { }
}

# Tudo que aparece na tela vai tambem para o log.
function Say([string]$Text = "", [string]$Color = "") {
    if ($Color) { Write-Host $Text -ForegroundColor $Color } else { Write-Host $Text }
    Write-NcLog $Text
}

# Aviso que nao para a instalacao. Volta no resumo do fim.
function Warn([string]$Text) {
    $script:NcWarnings.Add($Text)
    Say "AVISO: $Text" "Yellow"
}

function Step([int]$Number, [string]$Title) {
    $script:NcStepNow = $Number
    $script:NcStepTitle = $Title
    Say ""
    Say ("=== Etapa {0} de {1}: {2} ===" -f $Number, $script:NcStepTotal, $Title) "Cyan"
}

# --------------------------------------------------------------------- trava

# Devolve o mutex quando esta execucao pegou a trava, ou $null quando outra
# esta viva. O Windows solta o mutex sozinho se o processo morrer (janela
# fechada, queda): nao existe trava orfa.
function Enter-NcLock([string]$Name) {
    $mutex = $null
    try {
        $mutex = New-Object System.Threading.Mutex($false, $Name)
    } catch {
        # Sem acesso ao mutex: e de outra execucao (como administrador).
        return $null
    }
    $got = $false
    try {
        $got = $mutex.WaitOne(0)
    } catch [System.Threading.AbandonedMutexException] {
        $got = $true
    }
    if (-not $got) {
        $mutex.Dispose()
        return $null
    }
    return $mutex
}

function Exit-NcLock($Mutex) {
    if (-not $Mutex) { return }
    try { $Mutex.ReleaseMutex() } catch { }
    try { $Mutex.Dispose() } catch { }
}

# ---------------------------------------------------------- escrita atomica

# Grava num arquivo temporario na mesma pasta, manda para o disco e troca de
# uma vez. Uma queda de energia deixa o arquivo antigo ou o novo, nunca a
# metade. Com -Backup o anterior fica em <arquivo>.bak.
function Write-FileAtomic([string]$Path, [string]$Text, [switch]$Backup) {
    $tmp = "$Path.novo"
    $bytes = $script:NcUtf8.GetBytes($Text)
    $fs = New-Object System.IO.FileStream($tmp, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try {
        $fs.Write($bytes, 0, $bytes.Length)
        $fs.Flush($true)
    } finally {
        $fs.Dispose()
    }
    Move-FileAtomic $tmp $Path -Backup:$Backup
}

function Move-FileAtomic([string]$Source, [string]$Destination, [switch]$Backup) {
    if ([System.IO.File]::Exists($Destination)) {
        if ($Backup) {
            [System.IO.File]::Replace($Source, $Destination, "$Destination.bak")
        } else {
            [System.IO.File]::Replace($Source, $Destination, [NullString]::Value)
        }
    } else {
        [System.IO.File]::Move($Source, $Destination)
    }
}

# Tamanho em bytes; -1 quando o arquivo nao existe. Sem o Get-Item, que no
# PowerShell do Linux (testes) nao acha arquivo que comeca com ponto (.env).
function Get-NcFileLength([string]$Path) {
    if (-not [System.IO.File]::Exists($Path)) { return -1 }
    return (New-Object System.IO.FileInfo $Path).Length
}

# Copia para <destino>.novo, confere o tamanho e troca. Nao regrava o que ja e igual.
function Copy-FileAtomic([string]$Source, [string]$Destination, [switch]$Backup) {
    if (-not [System.IO.File]::Exists($Source)) { throw "Nao achei $Source." }
    if ([System.IO.File]::Exists($Destination)) {
        if ((Get-FileHash -LiteralPath $Source).Hash -eq (Get-FileHash -LiteralPath $Destination).Hash) { return $false }
    }
    $tmp = "$Destination.novo"
    [System.IO.File]::Copy($Source, $tmp, $true)
    if ((Get-NcFileLength $tmp) -ne (Get-NcFileLength $Source)) {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        throw "A copia de $Source ficou incompleta."
    }
    Move-FileAtomic $tmp $Destination -Backup:$Backup
    return $true
}

# -------------------------------------------------------- arquivo de estado

# Linhas chave=valor, regravadas inteiras a cada mudanca.
function Initialize-NcState([string]$Path) {
    $script:NcStateFile = $Path
    [System.IO.Directory]::CreateDirectory((Split-Path -Parent $Path)) | Out-Null
    Remove-Item -LiteralPath "$Path.novo" -Force -ErrorAction SilentlyContinue
    if ([System.IO.File]::Exists($Path)) {
        # Arquivo ilegivel (queda de energia, disco cheio) nao pode travar o
        # instalador: comeca de novo. As etapas conferem o que ja existe.
        $bad = $false
        try {
            foreach ($line in [System.IO.File]::ReadAllLines($Path, $script:NcUtf8)) {
                if ($line -notmatch '^[A-Za-z0-9_]+=[^\x00-\x1F]*$') { $bad = $true; break }
            }
        } catch { $bad = $true }
        if ($bad) {
            Remove-Item -LiteralPath "$Path.ilegivel" -Force -ErrorAction SilentlyContinue
            try { [System.IO.File]::Move($Path, "$Path.ilegivel") } catch { Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue }
        }
    }
    if (-not [System.IO.File]::Exists($Path)) { Write-FileAtomic $Path "" }
}

function Get-NcStateLines {
    if (-not $script:NcStateFile -or -not [System.IO.File]::Exists($script:NcStateFile)) { return @() }
    return @([System.IO.File]::ReadAllLines($script:NcStateFile, $script:NcUtf8))
}

function Get-NcState([string]$Key) {
    $value = ""
    foreach ($line in (Get-NcStateLines)) {
        if ($line.StartsWith("$Key=")) { $value = $line.Substring($Key.Length + 1) }
    }
    return $value
}

function Set-NcState([string]$Key, [string]$Value) {
    $kept = @(Get-NcStateLines | Where-Object { $_ -and -not $_.StartsWith("$Key=") })
    $kept += "$Key=$Value"
    Write-FileAtomic $script:NcStateFile (($kept -join "`n") + "`n")
}

function Remove-NcState([string]$Key) {
    $kept = @(Get-NcStateLines | Where-Object { $_ -and -not $_.StartsWith("$Key=") })
    $text = ""
    if ($kept.Count -gt 0) { $text = ($kept -join "`n") + "`n" }
    Write-FileAtomic $script:NcStateFile $text
}

function Set-NcStepDone([string]$Name) {
    Set-NcState "etapa_$Name" ([string][DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
}

function Test-NcStepDone([string]$Name) {
    return [bool](Get-NcState "etapa_$Name")
}

# ----------------------------------------------------------------------- .env

# O .env e UTF-8 sem BOM. O Get-Content do PowerShell 5.1 leria na pagina de
# codigo do Windows e estragaria uma pasta com acento (C:/Users/Usuario com
# acento/Documents) a cada gravacao.
function Read-EnvLines([string]$Path) {
    if (-not [System.IO.File]::Exists($Path)) { return @() }
    $text = [System.IO.File]::ReadAllText($Path, $script:NcUtf8)
    return @($text -split "`r?`n" | Where-Object { $_ -ne "" })
}

function Get-EnvValue([string]$Path, [string]$Key, [string]$Default = "") {
    $value = $null
    foreach ($line in (Read-EnvLines $Path)) {
        if ($line.StartsWith("$Key=")) { $value = $line.Substring($Key.Length + 1) }
    }
    if ($null -eq $value -or $value -eq "") { return $Default }
    return $value
}

# Troca ou acrescenta as chaves dadas e mantem as outras linhas. O anterior
# fica em .env.bak. Nao regrava quando nada mudou.
function Set-EnvValues([string]$Path, [System.Collections.IDictionary]$Values) {
    $old = @(Read-EnvLines $Path)
    $kept = @()
    foreach ($line in $old) {
        $key = ($line -split "=", 2)[0]
        if (-not $Values.Contains($key)) { $kept += $line }
    }
    foreach ($key in $Values.Keys) { $kept += ("{0}={1}" -f $key, $Values[$key]) }
    if (($old -join "`n") -eq ($kept -join "`n")) { return $false }
    Write-FileAtomic $Path (($kept -join "`n") + "`n") -Backup
    return $true
}

# Um .env vazio (queda de energia no meio de uma gravacao antiga) faria o
# compose subir com os padroes. A copia .env.bak volta no lugar.
function Repair-EnvFile([string]$Path) {
    if (-not [System.IO.File]::Exists($Path)) { return $false }
    if ((Get-NcFileLength $Path) -gt 0) { return $false }
    $bak = "$Path.bak"
    if ((Get-NcFileLength $bak) -le 0) { return $false }
    [System.IO.File]::Copy($bak, "$Path.novo", $true)
    Move-FileAtomic "$Path.novo" $Path
    return $true
}

# -------------------------------------------------------------- programas

# Roda um programa de linha de comando mostrando e gravando no log cada linha
# da saida. Devolve o codigo de saida. No PowerShell 5.1, o stderr de um
# programa vira erro com ErrorActionPreference=Stop: por isso o Continue local.
function Invoke-Native {
    param([string]$Exe, [string[]]$Arguments = @(), [switch]$Quiet)
    $ErrorActionPreference = "Continue"
    $code = 1
    try {
        & $Exe @Arguments 2>&1 | ForEach-Object {
            $line = "$_".TrimEnd()
            # Barras de progresso e roletas do winget nao sao texto.
            if ($line -and $line -notmatch '^[\s\-\\|/]*$' -and $line -notmatch "[\u2580-\u259F]") {
                if ($Quiet) { Write-NcLog "  $line" } else { Say "  $line" }
            }
        }
        $code = $LASTEXITCODE
    } catch {
        Write-NcLog "  falha ao rodar ${Exe}: $($_.Exception.Message)"
        $code = 1
    }
    if ($null -eq $code) { $code = 1 }
    return [int]$code
}

# Tenta ate $Times vezes, esperando $WaitSeconds * tentativa entre elas.
# O bloco devolve $true quando deu certo.
function Invoke-Retry([int]$Times, [int]$WaitSeconds, [scriptblock]$Action) {
    for ($i = 1; $i -le $Times; $i++) {
        if (& $Action) { return $true }
        if ($i -lt $Times) {
            Say "Nao deu certo (tentativa $i de $Times). Tentando de novo em $($WaitSeconds * $i) segundos..."
            Start-Sleep -Seconds ($WaitSeconds * $i)
        }
    }
    return $false
}

# ------------------------------------------------------------------ download

# Baixa com o curl.exe do Windows continuando do ponto em que <arquivo>.part
# parou. Devolve o codigo HTTP final como texto: "200"/"206" (veio tudo), "204"
# (nao ha o que baixar), "416" (o .part ja estava completo) ou outro (falhou).
# Quem chama confere o arquivo antes de usar. Sem tempo maximo: um arquivo
# grande numa internet lenta termina; a conexao so e largada se ficar 60
# segundos abaixo de 1 KB/s.
function Get-FileResumable([string]$Url, [string]$PartFile, [int]$Tries = 5) {
    $http = "000"
    for ($i = 1; $i -le $Tries; $i++) {
        $ErrorActionPreference = "Continue"
        $http = & curl.exe -sS -f -L -C - --connect-timeout 20 --speed-limit 1024 --speed-time 60 `
            -o $PartFile -w "%{http_code}" $Url 2>$null
        $code = $LASTEXITCODE
        $http = "$http".Trim()
        if ($http -notmatch '^\d{3}$') { $http = "000" }
        if ($code -eq 0 -and ($http -eq "200" -or $http -eq "206" -or $http -eq "204")) { return $http }
        if ($code -eq 22 -and $http -eq "416") { return $http }
        if ($code -eq 33) {
            # O servidor nao aceita continuar: recomeca do zero.
            Remove-Item -LiteralPath $PartFile -Force -ErrorAction SilentlyContinue
        } elseif ($code -eq 22 -and $http -match '^4' -and $http -ne "408" -and $http -ne "429") {
            # 4xx nao melhora tentando de novo.
            return $http
        }
        if ($i -lt $Tries) { Start-Sleep -Seconds (5 * $i) }
    }
    if ($http -eq "200" -or $http -eq "206") { return "000" }
    return $http
}

# Diferenca, em segundos, entre o relogio deste computador e a hora do
# servidor (cabecalho Date). -k: so a data e lida, e com o relogio errado o
# certificado nao confere. $null se nao conseguir.
function Get-ClockSkewSeconds([string]$Url) {
    try {
        $ErrorActionPreference = "Continue"
        $headers = & curl.exe -skI --max-time 15 $Url 2>$null
        foreach ($line in @($headers)) {
            if ("$line" -match '^\s*date:\s*(.+)$') {
                $remote = [DateTime]::Parse($Matches[1].Trim(), [System.Globalization.CultureInfo]::InvariantCulture,
                    [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal)
                return [int][Math]::Abs(([DateTime]::UtcNow - $remote).TotalSeconds)
            }
        }
    } catch { }
    return $null
}

# ------------------------------------------------------------ zip de backup

# Caminho de um arquivo arrastado para a janela: o Windows cola entre aspas
# quando tem espaco, e o PowerShell ISE cola com "& " na frente.
function ConvertFrom-DroppedPath([string]$Raw) {
    $p = "$Raw".Trim()
    if ($p.StartsWith("& ")) { $p = $p.Substring(2).Trim() }
    if ($p.Length -ge 2 -and (($p[0] -eq '"' -and $p[-1] -eq '"') -or ($p[0] -eq "'" -and $p[-1] -eq "'"))) {
        $p = $p.Substring(1, $p.Length - 2)
    }
    if ($p.StartsWith("file:///")) { $p = [System.Uri]::UnescapeDataString($p.Substring(8)) }
    return $p
}

$script:Crc32Table = $null
function Update-Crc32([uint32]$Crc, [byte]$B) {
    if (-not $script:Crc32Table) {
        $t = New-Object 'uint32[]' 256
        for ($n = 0; $n -lt 256; $n++) {
            [uint32]$c = $n
            for ($k = 0; $k -lt 8; $k++) {
                if ($c -band 1) { $c = [uint32]([uint32]3988292384 -bxor ($c -shr 1)) } else { $c = [uint32]($c -shr 1) }
            }
            $t[$n] = $c
        }
        $script:Crc32Table = $t
    }
    return [uint32]($script:Crc32Table[($Crc -bxor $B) -band 0xFF] -bxor ($Crc -shr 8))
}

# Confere a senha de uma entrada ZipCrypto (zip --password): os 12 bytes de
# cabecalho cifrado terminam no byte alto do CRC (ou da hora, com o bit 3).
# Uma entrada so deixa passar 1 senha errada em 256; o instalador confere todas,
# e o unzip do container ainda confere o zip inteiro.
function Test-ZipCryptoPassword([byte[]]$Header, [string]$Password, [byte]$Check) {
    [uint32]$k0 = 0x12345678; [uint32]$k1 = 0x23456789; [uint32]$k2 = 0x34567890
    $update = {
        param([byte]$c)
        $script:zk0 = Update-Crc32 $script:zk0 $c
        $script:zk1 = [uint32]((([uint64]$script:zk1 + ($script:zk0 -band 0xFF)) * [uint64]134775813 + 1) -band [uint64]4294967295)
        $script:zk2 = Update-Crc32 $script:zk2 ([byte](($script:zk1 -shr 24) -band 0xFF))
    }
    $script:zk0 = $k0; $script:zk1 = $k1; $script:zk2 = $k2
    foreach ($ch in [System.Text.Encoding]::ASCII.GetBytes($Password)) { & $update $ch }
    [byte]$last = 0
    foreach ($b in $Header) {
        [uint32]$temp = ($script:zk2 -bor 2) -band 0xFFFF
        [byte]$plain = $b -bxor ((([uint64]$temp * [uint64]($temp -bxor 1)) -shr 8) -band 0xFF)
        & $update $plain
        $last = $plain
    }
    return ($last -eq $Check)
}

# Um zip de backup do NCommerce desta empresa: traz o backup.sql, criptografado
# (o backup.sh grava com zip --password) e com a senha dos 6 primeiros
# caracteres do token. Devolve o motivo quando nao serve; vazio quando serve.
# Um zip cortado no meio (download ou copia interrompida) nao tem o indice do
# fim do arquivo e cai em "nao e um arquivo zip".
function Get-BackupZipProblem([string]$Zip, [string]$Token) {
    if (-not (Test-Path -LiteralPath $Zip -PathType Leaf)) { return "Nao achei o arquivo $Zip." }
    $fs = $null
    try {
        $fs = [System.IO.File]::OpenRead($Zip)
        $br = New-Object System.IO.BinaryReader($fs)
        $tail = [int][Math]::Min($fs.Length, 65557)
        if ($tail -lt 22) { return "$Zip nao e um arquivo zip (ou foi copiado pela metade)." }
        $fs.Seek(-$tail, [System.IO.SeekOrigin]::End) | Out-Null
        $buf = $br.ReadBytes($tail)
        $eocd = -1
        for ($i = $buf.Length - 22; $i -ge 0; $i--) {
            if ($buf[$i] -eq 0x50 -and $buf[$i + 1] -eq 0x4B -and $buf[$i + 2] -eq 0x05 -and $buf[$i + 3] -eq 0x06) { $eocd = $i; break }
        }
        if ($eocd -lt 0) { return "$Zip nao e um arquivo zip (ou foi copiado pela metade)." }
        $entries = [BitConverter]::ToUInt16($buf, $eocd + 10)
        $cdOffset = [BitConverter]::ToUInt32($buf, $eocd + 16)
        if ($cdOffset -ge $fs.Length) { return "$Zip esta corrompido." }
        $fs.Seek($cdOffset, [System.IO.SeekOrigin]::Begin) | Out-Null
        $found = $null
        $encrypted = @()
        for ($e = 0; $e -lt $entries; $e++) {
            $h = $br.ReadBytes(46)
            if ($h.Length -lt 46 -or [BitConverter]::ToUInt32($h, 0) -ne 0x02014b50) { return "$Zip esta corrompido." }
            $nameLen = [BitConverter]::ToUInt16($h, 28)
            $skip = [BitConverter]::ToUInt16($h, 30) + [BitConverter]::ToUInt16($h, 32)
            $name = [System.Text.Encoding]::UTF8.GetString($br.ReadBytes($nameLen))
            $fs.Seek($skip, [System.IO.SeekOrigin]::Current) | Out-Null
            $entry = @{
                Flags = [BitConverter]::ToUInt16($h, 8)
                Time = [BitConverter]::ToUInt16($h, 12)
                Crc = [BitConverter]::ToUInt32($h, 16)
                Offset = [BitConverter]::ToUInt32($h, 42)
            }
            if ($name -eq "backup.sql") { $found = $entry }
            if ($entry.Flags -band 1) { $encrypted += $entry }
        }
        if (-not $found) { return "$Zip nao e um backup do NCommerce: falta o backup.sql." }
        if (($found.Flags -band 1) -eq 0) { return "$Zip nao esta criptografado. Backup do NCommerce sempre vem com senha." }
        if ($Token.Length -lt 6) { return "Token curto demais para conferir o backup." }
        # Cada entrada cifrada confere 1 byte: juntas, uma senha errada quase nunca passa.
        foreach ($entry in $encrypted) {
            $fs.Seek($entry.Offset, [System.IO.SeekOrigin]::Begin) | Out-Null
            $lh = $br.ReadBytes(30)
            if ($lh.Length -lt 30 -or [BitConverter]::ToUInt32($lh, 0) -ne 0x04034b50) { return "$Zip esta corrompido." }
            $fs.Seek([BitConverter]::ToUInt16($lh, 26) + [BitConverter]::ToUInt16($lh, 28), [System.IO.SeekOrigin]::Current) | Out-Null
            $encHeader = $br.ReadBytes(12)
            if ($entry.Flags -band 8) { [byte]$check = ($entry.Time -shr 8) -band 0xFF } else { [byte]$check = ($entry.Crc -shr 24) -band 0xFF }
            if (-not (Test-ZipCryptoPassword $encHeader $Token.Substring(0, 6) $check)) {
                return "$Zip nao abre com o token desta empresa: e backup de outra empresa ou esta corrompido."
            }
        }
        return ""
    } catch {
        return "Nao consegui ler ${Zip}: $($_.Exception.Message)"
    } finally {
        if ($fs) { $fs.Dispose() }
    }
}

# -------------------------------------------------------------------- janela

# Console do Windows: um clique na janela (QuickEdit) congela o script ate
# alguem apertar Enter; o X fecha no meio de uma etapa; e o computador pode
# dormir. Nada aqui e essencial: qualquer falha e ignorada (Windows Terminal,
# antivirus que barra o Add-Type).
function Initialize-NcConsole([string]$Title) {
    try { $Host.UI.RawUI.WindowTitle = $Title } catch { }
    try {
        if (-not ("NCommerce.ConsoleTweaks" -as [type])) {
            Add-Type -Namespace NCommerce -Name ConsoleTweaks -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int nStdHandle);
[DllImport("kernel32.dll")] public static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);
[DllImport("kernel32.dll")] public static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")] public static extern IntPtr GetSystemMenu(IntPtr hWnd, bool bRevert);
[DllImport("user32.dll")] public static extern bool DeleteMenu(IntPtr hMenu, uint uPosition, uint uFlags);
[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint esFlags);
'@
        }
        # QuickEdit desligado: ENABLE_QUICK_EDIT_MODE = 0x40, ENABLE_EXTENDED_FLAGS = 0x80.
        $stdin = [NCommerce.ConsoleTweaks]::GetStdHandle(-10)
        [uint32]$mode = 0
        if ([NCommerce.ConsoleTweaks]::GetConsoleMode($stdin, [ref]$mode)) {
            $mode = ($mode -band (-bnot [uint32]0x40)) -bor [uint32]0x80
            [NCommerce.ConsoleTweaks]::SetConsoleMode($stdin, $mode) | Out-Null
        }
        # Sem o botao X (SC_CLOSE = 0xF060). No Windows Terminal nao tem efeito.
        $window = [NCommerce.ConsoleTweaks]::GetConsoleWindow()
        if ($window -ne [IntPtr]::Zero) {
            $menu = [NCommerce.ConsoleTweaks]::GetSystemMenu($window, $false)
            if ($menu -ne [IntPtr]::Zero) { [NCommerce.ConsoleTweaks]::DeleteMenu($menu, 0xF060, 0) | Out-Null }
        }
        # Nao dormir nem apagar a tela: ES_CONTINUOUS | ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED.
        [NCommerce.ConsoleTweaks]::SetThreadExecutionState([uint32]2147483651) | Out-Null
    } catch {
        Write-NcLog "Ajustes da janela nao aplicados: $($_.Exception.Message)"
    }
}

function Restore-NcConsole {
    try {
        if ("NCommerce.ConsoleTweaks" -as [type]) {
            # ES_CONTINUOUS sozinho devolve o controle de energia ao Windows.
            [NCommerce.ConsoleTweaks]::SetThreadExecutionState([uint32]2147483648) | Out-Null
            $window = [NCommerce.ConsoleTweaks]::GetConsoleWindow()
            if ($window -ne [IntPtr]::Zero) { [NCommerce.ConsoleTweaks]::GetSystemMenu($window, $true) | Out-Null }
        }
    } catch { }
}

# ------------------------------------------------------------------- docker
# As funcoes abaixo usam $DockerExe e $InstallDir de quem faz o `. instalador-lib.ps1`.

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

# docker compose <args> na pasta da loja, com a saida na tela e no log.
function Invoke-Compose {
    param([string[]]$Arguments, [switch]$Quiet)
    Push-Location $InstallDir
    try {
        return (Invoke-Native -Exe $DockerExe -Arguments (@("compose") + $Arguments) -Quiet:$Quiet)
    } finally {
        Pop-Location
    }
}

# Saida de um comando do docker, sem mostrar. Vazio quando falha.
function Get-DockerText([string[]]$Arguments) {
    $ErrorActionPreference = "Continue"
    Push-Location $InstallDir
    try {
        $out = & $DockerExe @Arguments 2>$null
        if ($LASTEXITCODE -ne 0) { return "" }
        return ("$(@($out) -join "`n")").Trim()
    } catch {
        return ""
    } finally {
        Pop-Location
    }
}

function Test-DockerUp {
    $ErrorActionPreference = "Continue"
    try { & $DockerExe info *> $null } catch { return $false }
    return ($LASTEXITCODE -eq 0)
}

# ID da imagem do container de um servico (api, web); vazio sem container.
function Get-ServiceImage([string]$Service) {
    $cid = @((Get-DockerText @("compose", "ps", "-aq", $Service)) -split "`n" | Where-Object { $_ })[0]
    if (-not $cid) { return "" }
    return (Get-DockerText @("inspect", "-f", "{{.Image}}", $cid))
}

function Get-ImageId([string]$Image) {
    return (Get-DockerText @("image", "inspect", "-f", "{{.Id}}", $Image))
}

# Confere um .gz lendo ate o fim: arquivo cortado (disco cheio, queda) falha.
function Test-GzipFile([string]$Path) {
    $fs = $null
    try {
        $fs = [System.IO.File]::OpenRead($Path)
        $gz = New-Object System.IO.Compression.GZipStream($fs, [System.IO.Compression.CompressionMode]::Decompress)
        $buf = New-Object byte[] 65536
        while ($gz.Read($buf, 0, $buf.Length) -gt 0) { }
        return $true
    } catch {
        return $false
    } finally {
        if ($fs) { $fs.Dispose() }
    }
}

# Copia do banco antes de mexer nele (restaurar backup, versao nova que muda as
# tabelas). Fica em <loja>\backups, as 3 mais recentes de cada tipo.
function Save-DatabaseDump([string]$Label) {
    $dir = Join-Path $InstallDir "backups"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $name = "{0}-{1}.sql.gz" -f $Label, (Get-Date -Format "yyyyMMdd-HHmmss")
    Say "Guardando uma copia do banco de dados atual..."
    $ErrorActionPreference = "Continue"
    # Sem pipe: o codigo de saida do mysqldump e a ultima linha ("Dump completed") valem.
    $dump = 'rm -f /tmp/ncommerce-dump.sql /tmp/ncommerce-dump.sql.gz; mysqldump -uroot -p"$MYSQL_ROOT_PASSWORD" --single-transaction --quick --routines --no-tablespaces --result-file=/tmp/ncommerce-dump.sql ncommerce_api_production 2>/dev/null && tail -c 300 /tmp/ncommerce-dump.sql | grep -q "Dump completed" && gzip -f /tmp/ncommerce-dump.sql'
    Invoke-ComposeExec exec -T mysql sh -c $dump | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Invoke-ComposeExec exec -T mysql rm -f /tmp/ncommerce-dump.sql /tmp/ncommerce-dump.sql.gz | Out-Null
        return $false
    }
    $part = Join-Path $dir "$name.part"
    $code = Invoke-Compose -Arguments @("cp", "mysql:/tmp/ncommerce-dump.sql.gz", $part) -Quiet
    Invoke-ComposeExec exec -T mysql rm -f /tmp/ncommerce-dump.sql.gz | Out-Null
    if ($code -ne 0 -or (Get-NcFileLength $part) -lt 20 -or -not (Test-GzipFile $part)) {
        Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
        return $false
    }
    [System.IO.File]::Move($part, (Join-Path $dir $name))
    Get-ChildItem -LiteralPath $dir -Filter "$Label-*.sql.gz" | Sort-Object LastWriteTime -Descending |
        Select-Object -Skip 3 | Remove-Item -Force -ErrorAction SilentlyContinue
    Say "Copia guardada em $(Join-Path $dir $name)."
    return $true
}

# ----------------------------------------------- atualizacao em andamento
# control\update.state: fase|epoch|api_antiga|web_antiga|tag, o mesmo formato do
# update.sh do Linux. A guarda le a fase: "up" (troca em andamento) ela nao
# atropela e, se ficar velha, termina de ligar.

function Get-UpdateStatePath { return (Join-Path $InstallDir "control\update.state") }

function Write-UpdateState([string]$Phase, [string]$OldApi, [string]$OldWeb, [string]$PrevTag) {
    $path = Get-UpdateStatePath
    [System.IO.Directory]::CreateDirectory((Split-Path -Parent $path)) | Out-Null
    $line = "{0}|{1}|{2}|{3}|{4}`n" -f $Phase, [DateTimeOffset]::UtcNow.ToUnixTimeSeconds(), $OldApi, $OldWeb, $PrevTag
    Write-FileAtomic $path $line
}

# $null sem atualizacao pendente (ou arquivo estragado).
function Read-UpdateState {
    $path = Get-UpdateStatePath
    if (-not [System.IO.File]::Exists($path)) { return $null }
    try {
        $f = ([System.IO.File]::ReadAllText($path).Trim()) -split '\|'
    } catch {
        return $null
    }
    if ($f.Count -lt 5 -or ($f[0] -ne "pull" -and $f[0] -ne "up")) { return $null }
    return @{ Phase = $f[0]; At = $f[1]; OldApi = $f[2]; OldWeb = $f[3]; PrevTag = $f[4] }
}

function Clear-UpdateState {
    $path = Get-UpdateStatePath
    Remove-Item -LiteralPath $path, "$path.novo" -Force -ErrorAction SilentlyContinue
}

# Download parado no meio: a etiqueta "latest" de api e web volta para as
# imagens que estavam em uso, para nunca subir api de uma versao e web de outra.
function Restore-LatestTags([string]$Registry, [string]$PrevTag, [string]$OldApi, [string]$OldWeb) {
    if ($PrevTag -ne "latest") { return }
    $ErrorActionPreference = "Continue"
    if ($OldApi) { & $DockerExe tag $OldApi "$Registry/ncommerce/api:latest" *> $null }
    if ($OldWeb) { & $DockerExe tag $OldWeb "$Registry/ncommerce/web:latest" *> $null }
}

# Atualizacao que morreu sem se arrumar (janela fechada, queda de energia).
# Quem chama tem a trava: nenhuma outra atualizacao esta rodando. Devolve o
# que foi feito, para a tela.
function Repair-InterruptedUpdate([string]$Registry) {
    $st = Read-UpdateState
    if (-not $st) {
        Clear-UpdateState
        return ""
    }
    if ($st.Phase -eq "pull") {
        Restore-LatestTags $Registry $st.PrevTag $st.OldApi $st.OldWeb
        Clear-UpdateState
        return "Uma atualizacao foi interrompida durante o download. A loja continua na versao em que estava."
    }
    # "up": a versao nova ja estava inteira no computador. Quem chama liga a loja.
    return "Uma atualizacao foi interrompida no meio da troca. Terminando de ligar a versao nova."
}
