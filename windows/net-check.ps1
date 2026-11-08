# Procura conflito de IP na rede da loja e grava <dir>\host\net_check, no mesmo
# formato do docker/net-check.sh do Linux. O chat de suporte (SupportContext na API)
# le esse arquivo. O container nao enxerga o ARP da loja, por isso roda no Windows.
# A tarefa "NCommerce Impressoras USB" (SYSTEM, a cada 2 minutos) chama este arquivo.
# Uso: powershell -File net-check.ps1 [C:\NCommerce]
#
# Formato (campos separados por TAB):
#   checked_at  <hora ISO>
#   server      <interface> <ip> ok|conflict <MACs que tambem responderam por esse IP>
#   neighbor    <ip> <mac> <fabricante>
# O Windows mesmo detecta o conflito do seu IP: marca o endereco como Duplicate e grava
# o evento 4199 do Tcpip com o MAC do outro aparelho. Ele nao ve dois MACs no mesmo IP
# de outro aparelho; a tabela ARP mostra so o ultimo.

param([string]$InstallDir = $PSScriptRoot)

$ErrorActionPreference = "SilentlyContinue"

$virtual = "vEthernet|WSL|Hyper-V|VMware|VirtualBox|Loopback|Bluetooth|TAP|Tailscale|ZeroTier|WireGuard"
$lines = @("checked_at`t$(Get-Date -Format o)")

# Conflitos dos ultimos 10 minutos: "...conflito de endereco IP 192.168.1.172 ... 00-11-22-33-44-55".
$recent = @{}
$events = Get-WinEvent -FilterHashtable @{ LogName = "System"; ProviderName = "Tcpip"; Id = 4199; StartTime = (Get-Date).AddMinutes(-10) }
foreach ($e in $events) {
    $msg = [string]$e.Message
    $ip = [regex]::Match($msg, "\b(\d{1,3}(\.\d{1,3}){3})\b").Value
    $mac = [regex]::Match($msg, "([0-9A-Fa-f]{2}[-:]){5}[0-9A-Fa-f]{2}").Value
    if ($ip -and $mac) {
        if (-not $recent[$ip]) { $recent[$ip] = @() }
        $recent[$ip] += $mac.Replace("-", ":").ToLower()
    }
}

$adapters = @(Get-NetAdapter | Where-Object { $_.Status -eq "Up" -and $_.InterfaceDescription -notmatch $virtual -and $_.Name -notmatch $virtual })
foreach ($a in $adapters) {
    $addrs = @(Get-NetIPAddress -AddressFamily IPv4 -InterfaceIndex $a.ifIndex | Where-Object { $_.IPAddress -notlike "169.254.*" })
    foreach ($addr in $addrs) {
        $others = @($recent[$addr.IPAddress] | Sort-Object -Unique)
        if ($addr.AddressState -eq "Duplicate" -or $others.Count -gt 0) {
            $lines += "server`t$($a.Name)`t$($addr.IPAddress)`tconflict`t$($others -join ',')"
        } else {
            $lines += "server`t$($a.Name)`t$($addr.IPAddress)`tok`t"
        }
    }
    Get-NetNeighbor -AddressFamily IPv4 -InterfaceIndex $a.ifIndex |
        Where-Object { $_.State -in @("Reachable", "Stale", "Delay", "Probe", "Permanent") -and
                       $_.LinkLayerAddress -and $_.LinkLayerAddress -notmatch "^(00-00-00-00-00-00|FF-FF-FF-FF-FF-FF|01-00-5E)" } |
        ForEach-Object { $lines += "neighbor`t$($_.IPAddress)`t$($_.LinkLayerAddress.Replace('-', ':').ToLower())`t" }
}

$hostDir = Join-Path $InstallDir "host"
New-Item -ItemType Directory -Force -Path $hostDir | Out-Null
$tmp = Join-Path $hostDir ".net_check.tmp"
$utf8 = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText($tmp, (($lines | ForEach-Object { "$_`n" }) -join ""), $utf8)
Move-Item -Force $tmp (Join-Path $hostDir "net_check")
