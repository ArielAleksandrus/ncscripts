#!/bin/bash
# Roda os testes dos scripts do Windows no PowerShell 7 de um container
# descartavel, sem rede e sem o socket do Docker. Confere:
#   - sintaxe e comandos do PowerShell 5.1 (PSScriptAnalyzer), so ASCII;
#   - a logica da lib, da atualizacao e da volta de versao (Pester), com
#     docker e curl.exe de mentira.
# A primeira vez precisa de internet para montar a imagem (Pester).
#   tests/run-windows.sh            tudo
#   tests/run-windows.sh update     so os arquivos de teste com "update" no nome
set -euo pipefail
cd "$(dirname "$0")/.."
docker build -q -t ncscripts-tests-windows:v2 tests/windows >/dev/null
status=0
docker run --rm --network none --name "ncscripts-tests-win-$$" -v "$PWD:/repo:ro" ncscripts-tests-windows:v2 \
  pwsh -NoProfile -File /repo/tests/windows/analyze.ps1 || status=$?
docker run --rm --network none --name "ncscripts-tests-win-pester-$$" -v "$PWD:/repo:ro" ncscripts-tests-windows:v2 \
  pwsh -NoProfile -File /repo/tests/windows/run.ps1 "${1:-}" || status=$?
exit "$status"
