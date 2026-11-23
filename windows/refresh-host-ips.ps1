# Grava os IPs desta maquina para o menu do NCommerce dentro do container.
# Uso: powershell -File refresh-host-ips.ps1 C:\NCommerce
param(
    [string]$Dir = "C:\NCommerce"
)

$ErrorActionPreference = "Stop"

function Get-HostLanIps {
    $skip = 'Loopback|vEthernet|Docker|WSL|VirtualBox|VMware|Hyper-V|Bluetooth|Teredo|isatap'
    $ips = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object {
            $_.IPAddress -match '^\d+(\.\d+){3}$' -and
            $_.IPAddress -notlike '127.*' -and
            $_.IPAddress -notlike '169.254.*' -and
            $_.InterfaceAlias -notmatch $skip
        } |
        Select-Object -ExpandProperty IPAddress -Unique)
    return ($ips -join ',')
}

$ips = Get-HostLanIps
New-Item -ItemType Directory -Force -Path (Join-Path $Dir "bin") | Out-Null
$ipCmd = Join-Path $Dir "bin\ip"
if ((Test-Path $ipCmd) -and (Get-Item $ipCmd).PSIsContainer) {
    Remove-Item -Recurse -Force $ipCmd
}

$lines = @('#!/bin/sh', '# IPs do servidor, no formato de `ip a`.')
if ($ips) {
    foreach ($ip in ($ips -split ',')) {
        if ($ip -match '^\d+(\.\d+){3}$') {
            $lines += "printf 'inet $ip/24\n'"
        }
    }
}
$utf8 = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText($ipCmd, (($lines -join "`n") + "`n"), $utf8)

# O .env e UTF-8 sem BOM (e assim que o docker compose le). O Get-Content do
# PowerShell 5.1 leria na pagina de codigo do Windows e, gravado de volta em
# UTF-8, um caminho com acento (C:\Users\Joao com til) ficaria mais estragado a
# cada logon. Um .env antigo que nao e UTF-8 valido e lido na pagina do Windows.
# Gravado ao lado e trocado de uma vez: queda de energia nao deixa .env vazio.
$envFile = Join-Path $Dir ".env"
if (Test-Path $envFile) {
    $bytes = [System.IO.File]::ReadAllBytes($envFile)
    try {
        $text = (New-Object System.Text.UTF8Encoding $false, $true).GetString($bytes)
    } catch {
        $text = [System.Text.Encoding]::Default.GetString($bytes)
    }
    $text = $text.TrimStart([char]0xFEFF)
    $kept = @($text -split "\r?\n" | Where-Object { $_ -and $_ -notlike 'NCOMMERCE_HOST_IPS=*' })
    $kept += "NCOMMERCE_HOST_IPS=$ips"
    $tmp = "$envFile.novo"
    [System.IO.File]::WriteAllText($tmp, (($kept -join "`n") + "`n"), $utf8)
    if ([System.IO.File]::Exists($envFile)) {
        [System.IO.File]::Replace($tmp, $envFile, [NullString]::Value)
    } else {
        [System.IO.File]::Move($tmp, $envFile)
    }
}

if ($ips) {
    Write-Host "IPs do servidor: $($ips -replace ',', ', ')"
} else {
    Write-Host "Nao achei um IP de rede nesta maquina."
}
