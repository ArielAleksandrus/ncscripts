# Chamado por tests/run-windows.sh dentro do container.
param([string]$Filter = "")
$c = New-PesterConfiguration
$c.Run.Path = @(Get-ChildItem $PSScriptRoot -Filter "*$Filter*.Tests.ps1" | ForEach-Object FullName)
$c.Run.Exit = $true
$c.Output.Verbosity = "Detailed"
$c.Output.RenderMode = "Plaintext"
Invoke-Pester -Configuration $c
