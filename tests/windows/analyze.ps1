# Analise estatica dos .ps1 do Windows: sintaxe do PowerShell 5.1 (o do Windows
# 10/11) e os comandos/tipos que existem no 5.1. Sai com 1 se achar problema.
$settings = @{
    IncludeRules = @('PSUseCompatibleSyntax', 'PSUseCompatibleCommands', 'PSUseCompatibleTypes',
        'PSAvoidUsingCmdletAliases', 'PSUseDeclaredVarsMoreThanAssignments', 'PSAvoidAssignmentToAutomaticVariable',
        'PSPossibleIncorrectComparisonWithNull', 'PSMisleadingBacktick', 'PSAvoidUsingEmptyCatchBlock')
    Rules = @{
        PSUseCompatibleSyntax = @{ Enable = $true; TargetVersions = @('5.1') }
        PSUseCompatibleCommands = @{ Enable = $true; TargetProfiles = @('win-48_x64_10.0.17763.0_5.1.17763.316_x64_4.0.30319.42000_framework') }
        PSUseCompatibleTypes = @{ Enable = $true; TargetProfiles = @('win-48_x64_10.0.17763.0_5.1.17763.316_x64_4.0.30319.42000_framework') }
    }
}
$files = @(Get-ChildItem -Path (Join-Path $PSScriptRoot '../../windows') -Filter *.ps1) + @(Get-ChildItem -Path (Join-Path $PSScriptRoot '../../advanced/windows-wsl') -Filter *.ps1)
$found = @()
foreach ($f in $files) {
    $found += @(Invoke-ScriptAnalyzer -Path $f.FullName -Settings $settings |
        Where-Object { $_.RuleName -ne 'PSAvoidUsingEmptyCatchBlock' })
    $bytes = [IO.File]::ReadAllBytes($f.FullName)
    if (@($bytes | Where-Object { $_ -gt 127 }).Count -gt 0) {
        Write-Host "$($f.Name): tem caractere fora do ASCII (o PowerShell 5.1 le arquivo sem BOM na pagina de codigo do Windows)"
        $found += 'ascii'
    }
}
# Os .bat: o cmd nao tem /dev/null (o redirecionamento falha e o comando nem roda).
$bats = @(Get-ChildItem -Path (Join-Path $PSScriptRoot '../..') -Recurse -Filter *.bat | Where-Object { $_.FullName -notmatch '[\\/]tests[\\/]' })
foreach ($b in $bats) {
    $n = 0
    foreach ($line in [IO.File]::ReadAllLines($b.FullName)) {
        $n++
        if ($line -match '/dev/null') {
            Write-Host "$($b.Name):$n usa /dev/null (no cmd e >nul)"
            $found += 'bat'
        }
    }
}
$found | Where-Object { $_ -isnot [string] } | ForEach-Object { "{0}:{1} {2} {3}" -f (Split-Path -Leaf $_.ScriptPath), $_.Line, $_.RuleName, $_.Message }
"Analise: $($files.Count) arquivos .ps1 e $($bats.Count) .bat, $($found.Count) problemas."
if ($found.Count -gt 0) { exit 1 }
