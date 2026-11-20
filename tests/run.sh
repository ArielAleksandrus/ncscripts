#!/bin/bash
# Roda os testes dos scripts Linux num container descartavel, sem rede (so o
# loopback) e sem o socket do Docker: nada do computador de quem roda e tocado.
#   tests/run.sh            todos
#   tests/run.sh guard      so os que tem "guard" no nome
set -euo pipefail
cd "$(dirname "$0")/.."
docker build -q -t ncscripts-tests:v2 tests >/dev/null
# Os scripts como estao hoje nas lojas (antes do v2), para testar a passagem
# dos antigos para os novos.
OLD_COMMIT=a9b09c6
old="$(mktemp -d)"
trap 'rm -rf "$old"' EXIT
for f in update.sh update-host.sh guard.sh rollback.sh host-ips.sh; do
  git show "$OLD_COMMIT:docker/$f" > "$old/$f"
done
chmod -R a+rX "$old"
status=0
docker run --rm --network none --name "ncscripts-tests-$$" -v "$PWD:/repo:ro" -v "$old:/master-scripts:ro" \
  ncscripts-tests:v2 bash /repo/tests/suite.sh "${1:-}" || status=$?
# A guarda roda em sh do Alpine (busybox), como no servico guard de verdade.
if [ -z "${1:-}" ] || [[ "guard" == *"${1:-}"* ]] || [[ "${1:-}" == *guard* ]]; then
  docker run --rm --network none --name "ncscripts-tests-guard-$$" -v "$PWD:/repo:ro" \
    --entrypoint sh docker:27.5.1-cli /repo/tests/guard_suite.sh || status=$?
fi
exit "$status"
