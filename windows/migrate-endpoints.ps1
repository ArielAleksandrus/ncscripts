# O mestre e o registry ganharam nomes proprios: api.ncommerce.app e
# registry.ncommerce.app:5050. Com o proxy da Cloudflare ligado em ncommerce.app,
# as portas 3001 e 5050 desse nome param de responder.
# O ncommerce-docker-startup.bat chama este script no "Atualizar NCommerce",
# com o Docker ja pronto. Qualquer falha so avisa: segue o endereco antigo.
param([string]$InstallDir = "C:\NCommerce")

# Continue: no PowerShell 5.1, stderr de programa externo com Stop vira excecao.
$ErrorActionPreference = "Continue"
$DockerExe = Join-Path $env:ProgramFiles "Docker\Docker\resources\bin\docker.exe"
$OldRegistry = "ncommerce.app:5050"
$NewRegistry = "registry.ncommerce.app:5050"

# Usuario e senha do registry antigo, do jeito que o docker login gravou.
function Get-RegistryCredential([string]$HostName) {
    $configFile = Join-Path $env:USERPROFILE ".docker\config.json"
    if (-not (Test-Path $configFile)) { return $null }
    $conf = Get-Content $configFile -Raw | ConvertFrom-Json
    if ($conf.auths) {
        foreach ($p in $conf.auths.PSObject.Properties) {
            $key = ($p.Name -replace '^[a-z]+://', '').TrimEnd('/')
            if ($key -eq $HostName -and $p.Value.auth) {
                $plain = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($p.Value.auth))
                $i = $plain.IndexOf(':')
                return @{ User = $plain.Substring(0, $i); Secret = $plain.Substring($i + 1) }
            }
        }
    }
    $store = $null
    if ($conf.credHelpers -and $conf.credHelpers.$HostName) { $store = $conf.credHelpers.$HostName }
    elseif ($conf.credsStore) { $store = $conf.credsStore }
    if (-not $store) { return $null }
    $helper = Join-Path (Split-Path $DockerExe) "docker-credential-$store.exe"
    if (-not (Test-Path $helper)) { $helper = "docker-credential-$store" }
    $out = $HostName | & $helper get 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $out) { return $null }
    $data = ($out -join "`n") | ConvertFrom-Json
    return @{ User = $data.Username; Secret = $data.Secret }
}

function Invoke-Login([string]$Registry, [string]$User, [string]$Secret) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $DockerExe
    $psi.Arguments = "login `"$Registry`" --username `"$User`" --password-stdin"
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $proc = [System.Diagnostics.Process]::Start($psi)
    $proc.StandardInput.Write($Secret)
    $proc.StandardInput.Close()
    $proc.WaitForExit()
    return ($proc.ExitCode -eq 0)
}

try {
    $envFile = Join-Path $InstallDir ".env"
    $text = [IO.File]::ReadAllText($envFile)
    if ($text -match "(?m)^NCOMMERCE_REGISTRY=$([regex]::Escape($OldRegistry))\r?$") {
        $cred = Get-RegistryCredential $OldRegistry
        if (-not $cred) {
            Write-Host "Nao achei o login de $OldRegistry. Sigo com ele."
        } elseif (Invoke-Login $NewRegistry $cred.User $cred.Secret) {
            $text = $text -replace "(?m)^NCOMMERCE_REGISTRY=$([regex]::Escape($OldRegistry))(\r?)$", "NCOMMERCE_REGISTRY=$NewRegistry`$1"
            [IO.File]::WriteAllText($envFile, $text)
            Write-Host "Registry trocado para $NewRegistry."
            # A guarda le o registry so ao ligar, e ao ligar renomeia as versoes guardadas.
            Push-Location $InstallDir
            & $DockerExe compose restart guard 2>$null | Out-Null
            Pop-Location
        } else {
            Write-Host "Nao consegui entrar em $NewRegistry. Sigo com $OldRegistry."
        }
    }
} catch {
    Write-Host "Nao troquei o registry ($($_.Exception.Message)). Sigo com $OldRegistry."
}

# O endereco do mestre fica no volume api_env (/env/.env.production). Vale a partir
# do proximo reinicio da api; o endereco antigo segue no ar enquanto isso.
try {
    Push-Location $InstallDir
    $running = & $DockerExe compose ps -q api 2>$null
    if ($running) {
        $script = "grep -q '^NCOMMERCE_SERVER_URL=.*ncommerce\.app:3001' /env/.env.production 2>/dev/null || exit 0; " +
                  "sed -i '/^NCOMMERCE_SERVER_URL=/s#https://ncommerce\.app:3001#https://api.ncommerce.app#' /env/.env.production; " +
                  "echo 'Mestre trocado para https://api.ncommerce.app.'"
        & $DockerExe compose exec -T api sh -c $script
    }
} catch {
    Write-Host "Nao troquei o endereco do mestre ($($_.Exception.Message))."
} finally {
    Pop-Location
}
exit 0
