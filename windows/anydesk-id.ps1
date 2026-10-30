# Grava o ID do AnyDesk deste computador em <dir>\host\anydesk_id.
# O container le esse arquivo e a API manda o ID para o mestre, que leva ao cadastro no manager.
# A tarefa de logon chama este arquivo. Uso: powershell -File anydesk-id.ps1 C:\NCommerce
param(
    [string]$Dir = "C:\NCommerce"
)

$exe = @("${env:ProgramFiles(x86)}\AnyDesk\AnyDesk.exe", "$env:ProgramFiles\AnyDesk\AnyDesk.exe") |
    Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $exe) { exit 0 }

# Logo depois do logon o servico do AnyDesk ainda nao tem ID e responde 0.
# O pipe faz o PowerShell esperar a saida do AnyDesk, que e um programa de janela.
$id = ""
for ($i = 0; $i -lt 24; $i++) {
    $id = ((& $exe --get-id | Out-String) -replace '[^0-9]', '')
    if ($id -and $id -ne "0") { break }
    $id = ""
    Start-Sleep -Seconds 5
}

if (-not $id) {
    Write-Host "O AnyDesk nao informou o ID."
    exit 0
}

$hostDir = Join-Path $Dir "host"
New-Item -ItemType Directory -Force -Path $hostDir | Out-Null
$utf8 = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText((Join-Path $hostDir "anydesk_id"), "$id`n", $utf8)
Write-Host "AnyDesk ID: $id"
