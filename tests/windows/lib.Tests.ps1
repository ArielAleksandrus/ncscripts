# Testes do windows/instalador-lib.ps1 no PowerShell 7 do Linux (Pester 5).
# Rode por tests/run-windows.sh. O que so existe no Windows (console, tarefas,
# Authenticode) fica de fora.

BeforeAll {
    . (Join-Path $PSScriptRoot "../../windows/instalador-lib.ps1")
    function New-TestDir {
        $d = Join-Path ([IO.Path]::GetTempPath()) ("nc-" + [guid]::NewGuid().ToString("N"))
        [IO.Directory]::CreateDirectory($d) | Out-Null
        return $d
    }
    # Zip de backup como o backup.sh da loja grava (zip --password).
    function New-BackupZip([string]$Dir, [string]$Password, [switch]$NoSql, [switch]$Plain) {
        $w = Join-Path $Dir ("w" + [guid]::NewGuid().ToString("N"))
        [IO.Directory]::CreateDirectory($w) | Out-Null
        if (-not $NoSql) { [IO.File]::WriteAllText((Join-Path $w "backup.sql"), "CREATE TABLE t (id int);`n") }
        [IO.File]::WriteAllText((Join-Path $w "docs.zip"), "x" * 5000)
        $zip = Join-Path $Dir ("b" + [guid]::NewGuid().ToString("N") + ".zip")
        Push-Location $w
        try {
            if ($Plain) { & zip -q $zip (Get-ChildItem -Name) } else { & zip -q --password $Password $zip (Get-ChildItem -Name) }
        } finally { Pop-Location }
        return $zip
    }
}

# R19 (respostas da revisao geral)
Describe "pasta da copia de seguranca" {
    It "fica so para Administradores e SYSTEM (pelos SIDs, sem heranca)" {
        $d = New-TestDir
        $log = Join-Path $d "icacls.log"
        $fake = Join-Path $d "icacls"
        [IO.File]::WriteAllText($fake, "#!/bin/sh`necho `"`$@`" >> '$log'`n")
        & chmod +x $fake
        $env:NCOMMERCE_ICACLS_EXE = $fake
        try {
            Protect-NcBackupDir (Join-Path $d "copia") | Should -BeTrue
        } finally { Remove-Item Env:NCOMMERCE_ICACLS_EXE }
        (Get-Content -Raw $log).Trim() | Should -Be "$(Join-Path $d 'copia') /inheritance:r /grant:r *S-1-5-32-544:(OI)(CI)F *S-1-5-18:(OI)(CI)F"
    }

    It "so avisa quando nao da (pen drive sem permissoes)" {
        $d = New-TestDir
        $fake = Join-Path $d "icacls"
        [IO.File]::WriteAllText($fake, "#!/bin/sh`nexit 5`n")
        & chmod +x $fake
        $env:NCOMMERCE_ICACLS_EXE = $fake
        try {
            Protect-NcBackupDir (Join-Path $d "copia") | Should -BeFalse
        } finally { Remove-Item Env:NCOMMERCE_ICACLS_EXE }
    }
}

# R18 (respostas da revisao geral): o .bat nao roda no Linux; confere o texto.
Describe "logon com troca de tipo pela metade" {
    It "com control\pausa sobe so o banco e avisa, antes de qualquer outra coisa" {
        $bat = Get-Content -Raw (Join-Path $PSScriptRoot "../../windows/ncommerce-docker-startup.bat")
        $pausa = $bat.IndexOf('if exist "%DIR%\control\pausa"')
        $pausa | Should -BeGreaterThan 0
        $pausa | Should -BeLessThan $bat.IndexOf('if /I "%~1"=="pull"')
        $pausa | Should -BeLessThan $bat.IndexOf('ncommerce-update.ps1" -Recuperar')
        $block = $bat.Substring($pausa, $bat.IndexOf("exit /b 0", $pausa) - $pausa)
        $block | Should -Match 'compose up -d mysql redis'
        $block | Should -Match 'troca do tipo da loja em andamento'
        $block | Should -Not -Match 'compose up -d\r?\n'
    }
}

Describe "escrita atomica" {
    It "grava, troca e guarda o anterior em .bak" {
        $d = New-TestDir
        $f = Join-Path $d "a.txt"
        Write-FileAtomic $f "um"
        Write-FileAtomic $f "dois" -Backup
        [IO.File]::ReadAllText($f) | Should -Be "dois"
        [IO.File]::ReadAllText("$f.bak") | Should -Be "um"
        Test-Path "$f.novo" | Should -BeFalse
    }
    It "grava UTF-8 sem BOM" {
        $d = New-TestDir
        $f = Join-Path $d "a.txt"
        Write-FileAtomic $f ("C:/Users/Jo" + [char]0xE3 + "o")
        $bytes = [IO.File]::ReadAllBytes($f)
        $bytes[0] | Should -Not -Be 0xEF
        [IO.File]::ReadAllText($f, [Text.Encoding]::UTF8) | Should -Be ("C:/Users/Jo" + [char]0xE3 + "o")
    }
    It "Copy-FileAtomic nao regrava arquivo igual" {
        $d = New-TestDir
        [IO.File]::WriteAllText("$d/src", "abc")
        Copy-FileAtomic "$d/src" "$d/dst" | Should -BeTrue
        Copy-FileAtomic "$d/src" "$d/dst" | Should -BeFalse
        [IO.File]::WriteAllText("$d/src", "abcd")
        Copy-FileAtomic "$d/src" "$d/dst" -Backup | Should -BeTrue
        [IO.File]::ReadAllText("$d/dst") | Should -Be "abcd"
        [IO.File]::ReadAllText("$d/dst.bak") | Should -Be "abc"
    }
    It "Copy-FileAtomic recusa origem ausente" {
        $d = New-TestDir
        { Copy-FileAtomic "$d/nada" "$d/dst" } | Should -Throw
        Test-Path "$d/dst" | Should -BeFalse
    }
}

Describe "arquivo de estado" {
    It "guarda, le, troca e tira chaves" {
        $d = New-TestDir
        Initialize-NcState "$d/estado"
        Set-NcState "a" "1"; Set-NcState "b" "dois tres"; Set-NcState "a" "5"
        Get-NcState "a" | Should -Be "5"
        Get-NcState "b" | Should -Be "dois tres"
        Get-NcState "nada" | Should -Be ""
        Set-NcStepDone "x"
        Test-NcStepDone "x" | Should -BeTrue
        Test-NcStepDone "y" | Should -BeFalse
        Remove-NcState "a"
        Get-NcState "a" | Should -Be ""
        Get-NcState "b" | Should -Be "dois tres"
    }
    It "arquivo ilegivel e posto de lado e o estado recomeca" {
        $d = New-TestDir
        [IO.File]::WriteAllText("$d/estado", "lixo`u{1}binario`nsem igual`n")
        [IO.File]::WriteAllText("$d/estado.novo", "sobra")
        Initialize-NcState "$d/estado"
        Test-Path "$d/estado.ilegivel" | Should -BeTrue
        (Get-Item "$d/estado").Length | Should -Be 0
        Test-Path "$d/estado.novo" | Should -BeFalse
    }
    It "estado bom sobrevive a reabertura" {
        $d = New-TestDir
        Initialize-NcState "$d/estado"
        Set-NcState "codigo" "ABCD1234"
        Initialize-NcState "$d/estado"
        Get-NcState "codigo" | Should -Be "ABCD1234"
    }
}

Describe ".env" {
    It "troca so as chaves pedidas, mantem as outras e guarda .bak" {
        $d = New-TestDir
        $f = "$d/.env"
        [IO.File]::WriteAllText($f, "A=1`r`nB=2`r`nSEGREDO=x`r`n")
        Set-EnvValues $f ([ordered]@{ B = "3"; C = "4" }) | Should -BeTrue
        Get-EnvValue $f "A" | Should -Be "1"
        Get-EnvValue $f "B" | Should -Be "3"
        Get-EnvValue $f "C" | Should -Be "4"
        Get-EnvValue $f "SEGREDO" | Should -Be "x"
        Get-EnvValue $f "NADA" "padrao" | Should -Be "padrao"
        Test-Path "$f.bak" | Should -BeTrue
    }
    It "nao regrava quando nada mudou" {
        $d = New-TestDir
        $f = "$d/.env"
        Set-EnvValues $f ([ordered]@{ A = "1" }) | Should -BeTrue
        Set-EnvValues $f ([ordered]@{ A = "1" }) | Should -BeFalse
    }
    It "pasta com acento sobrevive a varias gravacoes" {
        $d = New-TestDir
        $f = "$d/.env"
        $dir = "C:/Users/Jo" + [char]0xE3 + "o/Documents"
        Set-EnvValues $f ([ordered]@{ NCOMMERCE_PLUGINS_DIR = $dir }) | Out-Null
        Set-EnvValues $f ([ordered]@{ X = "1" }) | Out-Null
        Set-EnvValues $f ([ordered]@{ Y = "1" }) | Out-Null
        Get-EnvValue $f "NCOMMERCE_PLUGINS_DIR" | Should -Be $dir
    }
    It "Repair-EnvFile traz a copia quando o .env ficou vazio" {
        $d = New-TestDir
        $f = "$d/.env"
        [IO.File]::WriteAllText("$f.bak", "A=1`n")
        [IO.File]::WriteAllText($f, "")
        Repair-EnvFile $f | Should -BeTrue
        Get-EnvValue $f "A" | Should -Be "1"
        Repair-EnvFile $f | Should -BeFalse
    }
    It "Repair-EnvFile nao troca vazio por vazio" {
        $d = New-TestDir
        $f = "$d/.env"
        [IO.File]::WriteAllText("$f.bak", "")
        [IO.File]::WriteAllText($f, "")
        Repair-EnvFile $f | Should -BeFalse
    }
}

Describe "trava" {
    It "uma segunda execucao (outro processo) nao pega a trava; solta, pega" {
        $name = "Global\NCommerceTeste" + [guid]::NewGuid().ToString("N")
        $lib = Join-Path $PSScriptRoot "../../windows/instalador-lib.ps1"
        $m = Enter-NcLock $name
        $m | Should -Not -BeNullOrEmpty
        $other = Start-Job -ScriptBlock { param($l, $n) . $l; $x = Enter-NcLock $n; [bool]$x } -ArgumentList $lib, $name
        Receive-Job $other -Wait -AutoRemoveJob | Should -BeFalse
        Exit-NcLock $m
        $again = Start-Job -ScriptBlock { param($l, $n) . $l; $x = Enter-NcLock $n; [bool]$x } -ArgumentList $lib, $name
        Receive-Job $again -Wait -AutoRemoveJob | Should -BeTrue
    }
    It "processo que morreu com a trava nao deixa trava orfa" {
        $name = "Global\NCommerceTeste" + [guid]::NewGuid().ToString("N")
        $lib = Join-Path $PSScriptRoot "../../windows/instalador-lib.ps1"
        $p = Start-Process pwsh -ArgumentList @("-NoProfile", "-Command", ". '$lib'; `$m = Enter-NcLock '$name'; Start-Sleep 30") -PassThru
        Start-Sleep -Seconds 3
        $p.Kill()
        $p.WaitForExit()
        $m = Enter-NcLock $name
        $m | Should -Not -BeNullOrEmpty
        Exit-NcLock $m
    }
}

Describe "zip de backup" {
    BeforeAll { $script:d = New-TestDir }
    It "aceita o backup certo" {
        $zip = New-BackupZip $d "tok123"
        Get-BackupZipProblem $zip "tok123XYZ" | Should -Be ""
    }
    It "recusa backup de outra empresa" {
        $zip = New-BackupZip $d "outra1"
        Get-BackupZipProblem $zip "tok123XYZ" | Should -Match "outra empresa"
    }
    It "recusa zip cortado no meio" {
        $zip = New-BackupZip $d "tok123"
        $bytes = [IO.File]::ReadAllBytes($zip)
        $cut = "$zip.cortado.zip"
        [IO.File]::WriteAllBytes($cut, $bytes[0..([int]($bytes.Length / 2))])
        Get-BackupZipProblem $cut "tok123XYZ" | Should -Match "pela metade"
    }
    It "recusa zip sem backup.sql" {
        $zip = New-BackupZip $d "tok123" -NoSql
        Get-BackupZipProblem $zip "tok123XYZ" | Should -Match "falta o backup.sql"
    }
    It "recusa zip sem senha" {
        $zip = New-BackupZip $d "" -Plain
        Get-BackupZipProblem $zip "tok123XYZ" | Should -Match "criptografado"
    }
    It "recusa arquivo que nao existe" {
        Get-BackupZipProblem "$d/nada.zip" "tok123XYZ" | Should -Match "Nao achei"
    }
}

Describe "caminho arrastado para a janela" {
    It "tira aspas, & do ISE e file:///" {
        ConvertFrom-DroppedPath '"C:\Users\a b\x.zip"' | Should -Be 'C:\Users\a b\x.zip'
        ConvertFrom-DroppedPath "& 'C:\x.zip'" | Should -Be 'C:\x.zip'
        ConvertFrom-DroppedPath "file:///C:/a%20b/x.zip" | Should -Be 'C:/a b/x.zip'
        ConvertFrom-DroppedPath "   " | Should -Be ""
    }
}

Describe "download que continua" {
    BeforeAll {
        # curl.exe de mentira: devolve o codigo e o HTTP pedidos em sequencia.
        $script:bin = New-TestDir
        $script:seq = Join-Path $bin "seq"
        $fake = @'
#!/bin/sh
n=$(cat "$SEQ.n" 2>/dev/null || echo 0); n=$((n + 1)); echo $n > "$SEQ.n"
line=$(sed -n "${n}p" "$SEQ")
echo "$*" >> "$SEQ.calls"
code=${line%% *}; http=${line#* }
out=""; prev=""
for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
[ -n "$out" ] && [ "$code" = 0 ] && printf 'dados' >> "$out"
printf '%s' "$http"
exit $code
'@
        [IO.File]::WriteAllText((Join-Path $bin "curl.exe"), $fake.Replace("`r", ""))
        & chmod +x (Join-Path $bin "curl.exe")
        $script:oldPath = $env:PATH
        $env:PATH = "${bin}:$env:PATH"
        $env:SEQ = $seq
        Mock Start-Sleep { }
    }
    AfterAll { $env:PATH = $script:oldPath }
    BeforeEach { Remove-Item "$seq*" -Force -ErrorAction SilentlyContinue }
    It "tenta de novo depois de queda e devolve 206" {
        [IO.File]::WriteAllText($seq, "56 000`n0 206`n")
        Get-FileResumable "http://x/y" "$bin/arq.part" 5 | Should -Be "206"
        @(Get-Content "$seq.calls").Count | Should -Be 2
        (Get-Content "$seq.calls")[0] | Should -Match "-C -"
    }
    It "servidor que nao continua (33) apaga o pedaco e recomeca" {
        [IO.File]::WriteAllText("$bin/arq.part", "velho")
        [IO.File]::WriteAllText($seq, "33 200`n0 200`n")
        Get-FileResumable "http://x/y" "$bin/arq.part" 5 | Should -Be "200"
        [IO.File]::ReadAllText("$bin/arq.part") | Should -Be "dados"
    }
    It "416: o pedaco ja estava completo" {
        [IO.File]::WriteAllText($seq, "22 416`n")
        Get-FileResumable "http://x/y" "$bin/arq.part" 5 | Should -Be "416"
    }
    It "404 nao tenta de novo" {
        [IO.File]::WriteAllText($seq, "22 404`n0 200`n")
        Get-FileResumable "http://x/y" "$bin/arq.part" 5 | Should -Be "404"
        @(Get-Content "$seq.calls").Count | Should -Be 1
    }
    It "sem internet em todas as tentativas devolve 000" {
        [IO.File]::WriteAllText($seq, "6 000`n6 000`n6 000`n")
        Get-FileResumable "http://x/y" "$bin/arq.part" 3 | Should -Be "000"
    }
}

Describe "programas e tentativas" {
    It "Invoke-Native devolve o codigo de saida e grava a saida no log" {
        $d = New-TestDir
        Start-NcLog $d "teste"
        Invoke-Native -Exe "sh" -Arguments @("-c", "echo linha-do-programa; echo erro >&2; exit 3") -Quiet | Should -Be 3
        $script:NcLogFile | Should -Not -BeNullOrEmpty
        (Get-Content -Raw $script:NcLogFile) | Should -Match "linha-do-programa"
        (Get-Content -Raw $script:NcLogFile) | Should -Match "erro"
    }
    It "Invoke-Native com programa que nao existe devolve 1" {
        Invoke-Native -Exe "/nao/existe" -Quiet | Should -Be 1
    }
    It "Invoke-Retry para na primeira que da certo" {
        Mock Start-Sleep { }
        $script:n = 0
        Invoke-Retry 4 1 { $script:n++; return ($script:n -ge 2) } | Should -BeTrue
        $script:n | Should -Be 2
        Invoke-Retry 2 1 { return $false } | Should -BeFalse
    }
    It "Start-NcLog guarda so os 10 logs mais recentes" {
        $d = New-TestDir
        for ($i = 0; $i -lt 12; $i++) {
            $f = Join-Path $d ("teste-2026010{0:D2}-000000.log" -f $i)
            [IO.File]::WriteAllText($f, "")
            (Get-Item $f).LastWriteTime = (Get-Date).AddMinutes(-100 + $i)
        }
        Start-NcLog $d "teste"
        @(Get-ChildItem $d -Filter "teste-*.log").Count | Should -Be 10
    }
}

Describe "refresh-host-ips.ps1" {
    It "mantem o .env em UTF-8: caminho com acento nao estraga a cada logon" {
        $d = New-TestDir
        $u8 = New-Object System.Text.UTF8Encoding $false
        $plug = "C:/Users/Jo" + [char]0x00E3 + "o/Documents/ncommerce/plugins"
        [IO.File]::WriteAllText((Join-Path $d ".env"), "NCOMMERCE_PLUGINS_DIR=$plug`nNCOMMERCE_HOST_IPS=1.2.3.4`n", $u8)
        $script = Join-Path $PSScriptRoot "../../windows/refresh-host-ips.ps1"
        for ($i = 0; $i -lt 2; $i++) {
            & pwsh -NoProfile -Command "function Get-NetIPAddress { }; & '$script' '$d'" | Out-Null
            $LASTEXITCODE | Should -Be 0
        }
        $text = [IO.File]::ReadAllText((Join-Path $d ".env"), $u8)
        $text | Should -Match ([regex]::Escape("NCOMMERCE_PLUGINS_DIR=$plug"))
        @($text -split "`n" | Where-Object { $_ -like "NCOMMERCE_HOST_IPS=*" }).Count | Should -Be 1
        Test-Path (Join-Path $d ".env.novo") | Should -BeFalse
    }
}
