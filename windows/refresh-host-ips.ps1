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

$envFile = Join-Path $Dir ".env"
if (Test-Path $envFile) {
    $kept = @(Get-Content -Path $envFile | Where-Object { $_ -notlike 'NCOMMERCE_HOST_IPS=*' })
    $kept += "NCOMMERCE_HOST_IPS=$ips"
    [System.IO.File]::WriteAllText($envFile, (($kept -join "`n") + "`n"), $utf8)
}

if ($ips) {
    Write-Host "IPs do servidor: $($ips -replace ',', ', ')"
} else {
    Write-Host "Nao achei um IP de rede nesta maquina."
}
