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
#>
param([switch]$IgnorarRequisitos, [string]$Backup = "")

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
# Este script fica em windows/; a raiz do ncscripts (docker/, windows/, codigo-instalacao.txt) e a pasta acima.
$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)

function Fail($msg) {
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

# O zip baixado em ncommerce.app/instalar traz o codigo neste arquivo, para o cliente nao digitar.
function Read-CodeFile {
    $file = Join-Path $Root "codigo-instalacao.txt"
    if (-not (Test-Path $file)) { return $null }
    $code = ((Get-Content -Raw -Path $file) -replace "[\s\-]", "").ToUpper()
    if ($code -match "^[A-Z0-9]{8}$") { return $code }
    return $null
}

# Nome igual ao de windows/aviso-reinicio.ps1. A tarefa sobe com o Windows,
# depois do reinicio que liga o WSL2, e pede ao mestre o WhatsApp.
$RebootTaskName = "NCommerce Aviso Reinicio"

function Clear-RebootNotice {
    try {
        Unregister-ScheduledTask -TaskName $RebootTaskName -Confirm:$false -ErrorAction SilentlyContinue
        $dir = Join-Path $env:ProgramData "NCommerce"
        foreach ($name in @("aviso-reinicio.ps1", "aviso-reinicio.json", "aviso-reinicio-body.json", "aviso-reinicio-out.txt")) {
            Remove-Item -LiteralPath (Join-Path $dir $name) -Force -ErrorAction SilentlyContinue
        }
    } catch {
        Write-Host "Nao consegui remover o aviso de reinicio anterior: $($_.Exception.Message)"
    }
}

# Agenda o aviso para a proxima inicializacao. Sem a tarefa, avisa na hora.
# Sem codigo-instalacao.txt nao ha como saber de quem e o WhatsApp.
function Register-RebootNotice {
    $code = Read-CodeFile
    if (-not $code) {
        Write-Host "Sem o arquivo codigo-instalacao.txt: o WhatsApp depois do reinicio nao sera enviado."
        return $false
    }
    try {
        $dir = Join-Path $env:ProgramData "NCommerce"
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $scriptSrc = Join-Path $PSScriptRoot "aviso-reinicio.ps1"
        if (-not (Test-Path -LiteralPath $scriptSrc)) {
            throw "Nao achei $scriptSrc."
        }
        $scriptDst = Join-Path $dir "aviso-reinicio.ps1"
        Copy-Item -LiteralPath $scriptSrc -Destination $scriptDst -Force
        $utf8 = New-Object System.Text.UTF8Encoding $false
        $config = @{ code = $code; master_url = $MasterUrl; task_name = $RebootTaskName } | ConvertTo-Json -Compress
        [System.IO.File]::WriteAllText((Join-Path $dir "aviso-reinicio.json"), $config, $utf8)

        $ps = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
        $action = New-ScheduledTaskAction -Execute $ps -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptDst`""
        $boot = New-ScheduledTaskTrigger -AtStartup
        try { $boot.Delay = "PT45S" } catch { }
        $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
            -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 6)
        Register-ScheduledTask -TaskName $RebootTaskName -Action $action -Trigger $boot -Principal $principal `
            -Settings $settings -Description "Avisa o NCommerce para mandar WhatsApp pedindo o InstaladorWindows.bat." -Force | Out-Null
        Write-Host "Quando o computador ligar, o WhatsApp do cadastro recebe o aviso para abrir o InstaladorWindows.bat de novo."
        return $true
    } catch {
        Write-Host "Nao consegui agendar o aviso de reinicio: $($_.Exception.Message)"
        if (Send-RebootNoticeNow $code) {
            Write-Host "Avisamos agora pelo WhatsApp: depois do reinicio, abra o InstaladorWindows.bat de novo."
            return $true
        }
        Write-Host "Nao consegui avisar pelo WhatsApp. Depois do reinicio, abra o InstaladorWindows.bat de novo."
        return $false
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
            "$MasterUrl/install/reboot_notice"
        $ErrorActionPreference = "Stop"
        return ("$http".Trim() -eq "200")
    } catch {
        return $false
    } finally {
        Remove-Item $payloadFile.FullName, $bodyFile.FullName -Force -ErrorAction SilentlyContinue
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

# Com -Soft, codigo recusado devolve $null em vez de encerrar, para pedir outro codigo.
function Get-InstallGrant([string]$Code, [switch]$Soft) {
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
        if ($Soft) {
            Write-Host "Codigo $Code recusado (HTTP $http). $detail"
            return $null
        }
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
    if (-not $grant.token) {
        Fail "A resposta do mestre nao trouxe o token do ncommerce."
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

# Caminho de um arquivo arrastado para a janela: o Windows cola entre aspas
# quando tem espaco, e o PowerShell ISE cola com "& " na frente.
function ConvertFrom-DroppedPath([string]$Raw) {
    $p = $Raw.Trim()
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
function Get-BackupZipProblem([string]$Zip, [string]$Token) {
    if (-not (Test-Path -LiteralPath $Zip -PathType Leaf)) { return "Nao achei o arquivo $Zip." }
    $fs = $null
    try {
        $fs = [System.IO.File]::OpenRead($Zip)
        $br = New-Object System.IO.BinaryReader($fs)
        $tail = [int][Math]::Min($fs.Length, 65557)
        if ($tail -lt 22) { return "$Zip nao e um arquivo zip." }
        $fs.Seek(-$tail, [System.IO.SeekOrigin]::End) | Out-Null
        $buf = $br.ReadBytes($tail)
        $eocd = -1
        for ($i = $buf.Length - 22; $i -ge 0; $i--) {
            if ($buf[$i] -eq 0x50 -and $buf[$i + 1] -eq 0x4B -and $buf[$i + 2] -eq 0x05 -and $buf[$i + 3] -eq 0x06) { $eocd = $i; break }
        }
        if ($eocd -lt 0) { return "$Zip nao e um arquivo zip." }
        $entries = [BitConverter]::ToUInt16($buf, $eocd + 10)
        $cdOffset = [BitConverter]::ToUInt32($buf, $eocd + 16)
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

# Backup que a instalacao restaura: o zip de -Backup, um zip arrastado para a
# janela ou, sem nenhum, o do mestre (devolve vazio).
function Select-BackupZip([string]$Token) {
    if ($Backup) {
        $path = ConvertFrom-DroppedPath $Backup
        $problem = Get-BackupZipProblem $path $Token
        if ($problem) { Fail $problem }
        $full = (Resolve-Path -LiteralPath $path).Path
        Write-Host "Backup avulso valido: $full."
        return $full
    }
    Write-Host ""
    Write-Host "Backup: para restaurar um zip de backup avulso, arraste o arquivo para esta janela e tecle Enter."
    Write-Host "Para usar o backup guardado no servidor, so tecle Enter."
    while ($true) {
        $path = ConvertFrom-DroppedPath (Read-Host "Zip de backup (Enter = servidor)")
        if (-not $path) {
            Write-Host "Usando o backup do servidor."
            return ""
        }
        $problem = Get-BackupZipProblem $path $Token
        if (-not $problem) {
            $full = (Resolve-Path -LiteralPath $path).Path
            Write-Host "Backup avulso valido: $full."
            return $full
        }
        Write-Host $problem
        Write-Host "Arraste outro zip, ou tecle Enter para usar o backup do servidor."
    }
}

# Um zip avulso entra no lugar do backup do mestre. Escolhido de proposito,
# ele e restaurado mesmo num PC que ja restaurou um backup antes.
function Use-BackupZip([string]$Zip) {
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    $dest = Join-Path $InstallDir "ncommerce.zip"
    if ([System.IO.Path]::GetFullPath($Zip) -ne [System.IO.Path]::GetFullPath($dest)) {
        Copy-Item -LiteralPath $Zip -Destination $dest -Force
    }
    Remove-Item (Join-Path $InstallDir ".backup-restored") -Force -ErrorAction SilentlyContinue
    Write-Host "Backup avulso copiado para $dest."
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
    Restore-BackupPlugins
    New-Item -ItemType File -Force -Path $marker | Out-Null
    Write-Host "Backup restaurado nos containers."
}

# O restore deixou os plugins do backup em /tmp/ncommerce-plugins no container.
# Eles vao para Documentos\ncommerce\plugins e a API reinicia para carregar.
function Restore-BackupPlugins {
    Push-Location $InstallDir
    $ErrorActionPreference = "Continue"
    $list = Invoke-ComposeExec exec -T api find /tmp/ncommerce-plugins -type f
    if ($LASTEXITCODE -eq 0 -and $list.Trim()) {
        & $DockerExe compose cp "api:/tmp/ncommerce-plugins/." $PluginsDir
        Write-Host "Plugins restaurados em $PluginsDir."
        & $DockerExe compose restart api
        $probe = New-TemporaryFile
        for ($i = 1; $i -le 60; $i++) {
            if ((Get-DockerSetup $probe.FullName) -eq "200") { break }
            Start-Sleep -Seconds 3
        }
        Remove-Item $probe.FullName -Force -ErrorAction SilentlyContinue
    }
    Invoke-ComposeExec exec -T api rm -rf /tmp/ncommerce-plugins | Out-Null
    $ErrorActionPreference = "Stop"
    Pop-Location
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
    $docs = [Environment]::GetFolderPath("MyDocuments")
    $dir = Join-Path $docs "ncommerce\plugins"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $readme = "Plugins do NCommerce`r`n`r`nCopie o arquivo do plugin (.rb) para a pasta plugins, ao lado deste arquivo.`r`nDepois entre como admin e use o botao Reiniciar NCommerce em`r`nConfiguracoes > Empresa. O plugin entra no backup da loja.`r`n"
    [System.IO.File]::WriteAllText((Join-Path $docs "ncommerce\LEIA-ME.txt"), $readme)
    return $dir
}

# MySQL, API, CUPS e o WSL do Docker Desktop juntos nao cabem em 4 GB: o PC passa a
# usar o arquivo de paginacao e o caixa fica lento. 6 GB bastam. Clock nao e exigido:
# um processador com 4 threads dificilmente e lento demais. Barra antes de qualquer instalacao.
function Assert-MinimumHardware {
    $problems = @()
    $build = [int](Get-CimInstance Win32_OperatingSystem).BuildNumber
    # 19045 e o Windows 10 22H2, o mais antigo que o Docker Desktop aceita.
    if ($build -lt 19045) { $problems += "Windows 10 22H2 ou Windows 11 (este e o build $build)" }
    $threads = (Get-CimInstance Win32_Processor | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
    if ($threads -lt 4) { $problems += "processador com 4 threads (este tem $threads)" }
    # Um PC de 6 GB informa menos: o firmware e o video integrado reservam ate ~1 GB. 5 GB
    # aceita esse PC e barra o de 4 GB, que informa no maximo 4.
    $ramGb = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1)
    if ($ramGb -lt 5.0) { $problems += "6 GB de RAM (este tem $ramGb GB)" }
    if ($problems.Count -eq 0) { return }

    Write-Host ""
    Write-Host "Este computador nao atende o minimo do NCommerce:" -ForegroundColor Red
    $problems | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    if ($IgnorarRequisitos) {
        Write-Host "Seguindo mesmo assim (-IgnorarRequisitos)." -ForegroundColor Yellow
        return
    }
    Fail "Use um computador com Windows 10 22H2 ou Windows 11, 4 threads e 6 GB de RAM."
}

Assert-MinimumHardware

# O Docker Desktop roda em cima do WSL2. Num Windows recem-formatado o WSL nao esta ligado,
# o Docker pede reinicio e o codigo de instalacao, que so vale uma vez, ja teria sido gasto.
# Por isso o WSL e preparado aqui, antes de pedir o codigo.
function Initialize-Wsl {
    if (Test-DockerReady) { return }

    # Com o hypervisor ja rodando, o Windows informa VirtualizationFirmwareEnabled = False.
    $hypervisor = (Get-CimInstance Win32_ComputerSystem).HypervisorPresent
    $firmware = (Get-CimInstance Win32_Processor | Select-Object -First 1).VirtualizationFirmwareEnabled
    if (-not $hypervisor -and -not $firmware) {
        Fail "A virtualizacao esta desligada na BIOS. Ligue Intel VT-x (ou AMD-V / SVM) e rode o instalador de novo."
    }

    $rebootNeeded = $false
    foreach ($f in @("Microsoft-Windows-Subsystem-Linux", "VirtualMachinePlatform")) {
        if ((Get-WindowsOptionalFeature -Online -FeatureName $f).State -ne "Enabled") {
            Write-Host "Ligando $f..."
            $result = Enable-WindowsOptionalFeature -Online -FeatureName $f -All -NoRestart
            if ($result.RestartNeeded) { $rebootNeeded = $true }
        }
    }
    if ($rebootNeeded) {
        Write-Host ""
        Write-Host "O Windows precisa reiniciar para terminar de ligar o WSL2." -ForegroundColor Yellow
        Register-RebootNotice | Out-Null
        Write-Host "Depois do reinicio, rode o InstaladorWindows.bat de novo. O codigo de instalacao ainda nao foi usado." -ForegroundColor Yellow
        Read-Host "Pressione Enter para reiniciar agora (ou feche a janela para reiniciar depois)"
        Restart-Computer
        exit 0
    }

    # O WSL que vem no Windows e antigo para o Docker Desktop. Falha aqui nao para a instalacao:
    # o proprio Docker Desktop pede a atualizacao no primeiro uso.
    Write-Host "Atualizando o WSL..."
    $ErrorActionPreference = "Continue"
    & wsl.exe --update *> $null
    $updateCode = $LASTEXITCODE
    & wsl.exe --set-default-version 2 *> $null
    $ErrorActionPreference = "Stop"
    if ($updateCode -ne 0) { Write-Host "Nao consegui atualizar o WSL (codigo $updateCode)." }
}

# Uma tentativa anterior pode ter agendado o aviso e o usuario abriu o
# instalador antes da tarefa rodar. Quem chegou aqui nao precisa do aviso,
# a menos que este run peca o reinicio de novo e registre outra vez.
Clear-RebootNotice

Initialize-Wsl

# Windows recem-instalado marca a rede como Publica, e a regra do OpenSSH so vale em rede Privada.
# A rede em que o PC esta agora e a da loja, entao ela vira Privada. Redes de dominio ficam como estao.
function Set-StoreNetworkPrivate {
    try {
        $public = @(Get-NetConnectionProfile -ErrorAction Stop | Where-Object { $_.NetworkCategory -eq "Public" })
        foreach ($p in $public) {
            Set-NetConnectionProfile -InterfaceIndex $p.InterfaceIndex -NetworkCategory Private -ErrorAction Stop
            Write-Host "Rede '$($p.Name)' marcada como Privada."
        }
    } catch {
        Write-Host "Nao consegui marcar a rede como Privada: $($_.Exception.Message)"
    }
}

Set-StoreNetworkPrivate

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
    if (-not (Initialize-Winget)) {
        Write-Host "Sem winget. Instale o AnyDesk depois em https://anydesk.com."
        return
    }
    Write-Host "Instalando o AnyDesk..."
    & winget install --source winget --exact --id AnyDesk.AnyDesk --accept-package-agreements --accept-source-agreements --disable-interactivity
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

# O Docker fica pronto antes de pedir o codigo: se ele travar, o codigo nao e gasto.
if (-not (Test-Path $DockerExe)) {
    if (-not (Initialize-Winget)) {
        Fail "Docker Desktop nao esta instalado e o winget nao existe. Instale o Docker Desktop e rode este arquivo de novo."
    }
    Write-Host "Instalando Docker Desktop. Isso pode levar varios minutos."
    # --accept-license pula a tela de termos no primeiro uso. --always-run-service deixa o servico
    # do Docker subir sem admin, para a tarefa de logon funcionar com o usuario comum.
    & winget install --source winget --exact --id Docker.DockerDesktop --accept-package-agreements --accept-source-agreements --disable-interactivity `
        --override "install --quiet --accept-license --backend=wsl-2 --always-run-service"
    if (-not (Test-Path $DockerExe)) {
        Register-RebootNotice | Out-Null
        Fail "Docker Desktop nao apareceu. Se o Windows pediu reinicio, reinicie e rode o instalador de novo."
    }
}

# Quem usa o PC precisa estar no grupo docker-users para a tarefa de logon falar com o Docker.
$me = "$env:USERDOMAIN\$env:USERNAME"
$members = @(Get-LocalGroupMember -Group "docker-users" -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
if ($members -notcontains $me) {
    try {
        Add-LocalGroupMember -Group "docker-users" -Member $me -ErrorAction Stop
    } catch {
        Write-Host "Nao consegui colocar $me no grupo docker-users: $($_.Exception.Message)"
    }
}

if (-not (Test-DockerReady)) {
    # Pelo explorer o Docker Desktop abre como o usuario comum, e nao como admin, igual ao logon.
    if (Test-Path $DockerDesktop) { Start-Process explorer.exe -ArgumentList "`"$DockerDesktop`"" }
    Write-Host "Esperando o Docker Desktop ficar pronto. Na primeira vez pode levar uns 10 minutos..."
    $ready = $false
    for ($i = 0; $i -lt 150; $i++) {
        if (Test-DockerReady) { $ready = $true; break }
        Start-Sleep -Seconds 5
    }
    if (-not $ready) {
        Register-RebootNotice | Out-Null
        Fail "O Docker nao ficou pronto. Reinicie o computador e rode este instalador de novo. O codigo de instalacao ainda nao foi usado."
    }
}

$grant = $null
$installCode = Read-CodeFile
if ($installCode) {
    Write-Host "Usando o codigo de instalacao $installCode do arquivo codigo-instalacao.txt."
    $grant = Get-InstallGrant $installCode -Soft
    if (-not $grant) { Write-Host "Peca um codigo novo ao suporte e digite abaixo." }
}
if (-not $grant) {
    $installCode = Read-InstallCode
    $grant = Get-InstallGrant $installCode
}
Set-AnyDeskPassword ([string]$grant.anydesk_password)
$grant.PSObject.Properties.Remove("anydesk_password")
$ncommerceToken = [string]$grant.token
$grant.PSObject.Properties.Remove("git_private_key")
$backupZip = Select-BackupZip $ncommerceToken

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
Copy-Item (Join-Path $Root "windows\net-check.ps1") (Join-Path $InstallDir "net-check.ps1") -Force
Copy-Item (Join-Path $Root "windows\update-host.ps1") (Join-Path $InstallDir "update-host.ps1") -Force
Copy-Item (Join-Path $Root "docker\guard.sh") (Join-Path $InstallDir "guard.sh") -Force
Copy-Item (Join-Path $Root "windows\rollback.bat") (Join-Path $InstallDir "rollback.bat") -Force
New-Item -ItemType Directory -Force -Path (Join-Path $InstallDir "control") | Out-Null
Copy-Item (Join-Path $Root "windows\drivers") $InstallDir -Recurse -Force

$PluginsDir = Initialize-PluginsDir
$envFile = Join-Path $InstallDir ".env"
$registry = $env:NCOMMERCE_REGISTRY
if (-not $registry) { $registry = [string]$grant.registry }
if (-not $registry) { $registry = Read-EnvValue $envFile "NCOMMERCE_REGISTRY" "ncommerce.app:5050" }
$tag = $env:NCOMMERCE_TAG
if (-not $tag) { $tag = Read-EnvValue $envFile "NCOMMERCE_TAG" "latest" }
$envBody = "CUPS_PORT=$cupsPort`nNCOMMERCE_REGISTRY=$registry`nNCOMMERCE_TAG=$tag`nNCOMMERCE_PLUGINS_DIR=$($PluginsDir.Replace('\', '/'))`nTZ=$(Get-IanaTimeZone)`n"
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

if ($backupZip) {
    Use-BackupZip $backupZip
} else {
    Save-CompanyBackup $installCode
}
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
    $shortcut.Description = "Atualiza os scripts deste PC, baixa a versao publicada e recria os containers"
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
Write-Host "A tarefa '$TaskName' sobe a stack quando alguem entra no Windows."
Write-Host "Depois de uma queda de energia o PC precisa logar sozinho: netplwiz."
Write-Host "Atualizar: atalho Atualizar NCommerce na Area de Trabalho."
Write-Host "Impressora USB plugada depois: o Windows compartilha sozinho e ela aparece no CUPS em ate 5 minutos."
