# Tarefas agendadas de mentira para os testes: uma tarefa e um arquivo em /fake/win/tasks.
function Get-ScheduledTask {
    [CmdletBinding()]
    param([string]$TaskName)
    $f = Join-Path "/fake/win/tasks" $TaskName
    if (Test-Path -LiteralPath $f) { return [pscustomobject]@{ TaskName = $TaskName; State = "Ready" } }
    Write-Error "No MSFT_ScheduledTask objects found with property 'TaskName' equal to '$TaskName'."
}

function Unregister-ScheduledTask {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([string]$TaskName)
    [IO.File]::AppendAllText("/fake/calls.log", "Unregister-ScheduledTask $TaskName`n")
    $f = Join-Path "/fake/win/tasks" $TaskName
    if (-not (Test-Path -LiteralPath $f)) { Write-Error "The system cannot find the file specified."; return }
    if ($PSCmdlet.ShouldProcess($TaskName)) { Remove-Item -LiteralPath $f -Force }
}
