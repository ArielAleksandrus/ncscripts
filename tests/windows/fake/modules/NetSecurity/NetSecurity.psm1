# Firewall de mentira para os testes: uma regra e um arquivo em /fake/win/fw (nome = DisplayName).
function Get-NetFirewallRule {
    [CmdletBinding()]
    param([string]$DisplayName)
    $f = Join-Path "/fake/win/fw" $DisplayName
    if (Test-Path -LiteralPath $f) { return [pscustomobject]@{ DisplayName = $DisplayName; Enabled = "True" } }
    Write-Error "No MSFT_NetFirewallRule objects found with property 'DisplayName' equal to '$DisplayName'."
}

function Remove-NetFirewallRule {
    [CmdletBinding()]
    param([string]$DisplayName)
    [IO.File]::AppendAllText("/fake/calls.log", "Remove-NetFirewallRule $DisplayName`n")
    $f = Join-Path "/fake/win/fw" $DisplayName
    if (-not (Test-Path -LiteralPath $f)) { Write-Error "No rule matches '$DisplayName'."; return }
    Remove-Item -LiteralPath $f -Force
}
