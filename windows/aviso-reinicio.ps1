# Roda uma vez, como SYSTEM, na inicializacao depois que o instalador pediu
# para reiniciar o Windows. Avise o mestre: ele manda o WhatsApp pedindo para
# abrir o InstaladorWindows.bat de novo. Sem internet, a tarefa fica para o
# proximo boot. 200 (avisou, ou nao havia WhatsApp) e 404 (codigo sumiu) encerram.
$ErrorActionPreference = "Continue"
$dir = Join-Path $env:ProgramData "NCommerce"
$configPath = Join-Path $dir "aviso-reinicio.json"
$script:TaskName = "NCommerce Aviso Reinicio"

function Finish {
    Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false -ErrorAction SilentlyContinue
    if (Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue) { return }
    Remove-Item -LiteralPath $configPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $PSCommandPath -Force -ErrorAction SilentlyContinue
}

if (-not (Test-Path -LiteralPath $configPath)) {
    Finish
    exit 0
}

try {
    $config = Get-Content -Raw -LiteralPath $configPath | ConvertFrom-Json
} catch {
    Finish
    exit 0
}

if ($config.task_name) { $script:TaskName = [string]$config.task_name }
$code = [string]$config.code
$master = ([string]$config.master_url).TrimEnd("/")
if (-not $code -or -not $master) {
    Finish
    exit 0
}

$curl = Join-Path $env:SystemRoot "System32\curl.exe"
if (-not (Test-Path -LiteralPath $curl)) { $curl = "curl.exe" }
$payloadFile = Join-Path $dir "aviso-reinicio-body.json"
$outFile = Join-Path $dir "aviso-reinicio-out.txt"
$payload = @{ code = $code; hostname = $env:COMPUTERNAME } | ConvertTo-Json -Compress
$utf8 = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText($payloadFile, $payload, $utf8)

$done = $false
for ($i = 0; $i -lt 8; $i++) {
    $http = & $curl -sS -o $outFile -w "%{http_code}" --max-time 15 `
        -X POST -H "Content-Type: application/json" --data-binary "@$payloadFile" `
        "$master/install/reboot_notice"
    $http = "$http".Trim()
    if ($http -eq "200" -or $http -eq "404") { $done = $true; break }
    Start-Sleep -Seconds 15
}

Remove-Item -LiteralPath $payloadFile -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue
if ($done) { Finish }
exit 0
