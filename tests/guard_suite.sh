#!/bin/sh
# Testes do docker/guard.sh no sh do Alpine (busybox), a mesma imagem do servico
# guard, com o Docker de mentira de tests/fake/bin. Rode por tests/run.sh.
if [ ! -d /repo/tests/fake/bin ] || [ -S /var/run/docker.sock ]; then
  echo "Rode por tests/run.sh (container de testes, sem o socket do Docker)."
  exit 1
fi
mkdir -p /fake/bin2
cat > /fake/bin2/wget <<'EOS'
#!/bin/sh
# A api "responde" quando existe /fake/knobs/api_answers.
case "$*" in
  *api:3000*) [ -e /fake/knobs/api_answers ] && { echo "  HTTP/1.1 403 Forbidden" >&2; exit 8; }; exit 4 ;;
  *) echo "wget $*" >> /fake/calls.log; exit 0 ;;
esac
EOS
chmod +x /fake/bin2/wget
export PATH="/fake/bin2:/repo/tests/fake/bin:$PATH"
PASS=0; FAILED=0; CURRENT=""
t() { CURRENT="$1"; echo "--- $1"; }
check() {
  msg="$1"; shift
  if "$@"; then PASS=$((PASS + 1)); else
    FAILED=$((FAILED + 1)); echo "    FALHOU [$CURRENT]: $msg"
    tail -n 12 /tmp/guard.log 2>/dev/null | sed 's/^/    | /'
  fi
}
called() { grep -qF -- "$1" /fake/calls.log; }
not_called() { ! grep -qF -- "$1" /fake/calls.log; }

setup() {
  rm -rf /fake/state /fake/knobs /fake/calls.log /ncommerce /tmp/guard.log
  mkdir -p /fake/state/images /fake/state/containers /fake/knobs /ncommerce/control
  : > /fake/calls.log
  cp /repo/docker/guard.sh /ncommerce/guard.sh
  printf 'NCOMMERCE_REGISTRY=reg.test:5050\nNCOMMERCE_TAG=latest\nCUPS_PORT=631\n' > /ncommerce/.env
  echo sha256:api1 > /fake/state/images/reg.test_5050_ncommerce_api_latest
  echo sha256:web1 > /fake/state/images/reg.test_5050_ncommerce_web_latest
  for s in mysql redis api web guard; do
    echo "sha256:$s" > "/fake/state/containers/$s"; echo running > "/fake/state/containers/$s.status"
  done
  echo sha256:api1 > /fake/state/containers/api
  echo sha256:web1 > /fake/state/containers/web
  touch /fake/knobs/api_answers
}
# run_guard SEGUNDOS: o laco da guarda com volta de 1 segundo.
run_guard() {
  GUARD_LOOP_S=1 GUARD_HEALTHY_S="${HEALTHY:-300}" GUARD_UPDATE_GRACE_S="${GRACE:-1200}" \
    timeout "$1" sh /ncommerce/guard.sh >> /tmp/guard.log 2>&1
  return 0
}
status_of() { cat "/fake/state/containers/$1.status" 2>/dev/null; }

t "guard: registra a versao em uso e nao mexe em loja saudavel"
setup; run_guard 3
check "versao registrada" grep -q '|sha256:api1|sha256:web1|' /ncommerce/control/versions.txt
check "versions.json escrito" grep -q '"versions":\[{' /ncommerce/control/versions.json
check "nenhum start" not_called "docker start"
check "nenhum up" not_called "up -d"

t "guard: versao que responde pelo tempo pedido fica boa"
setup; HEALTHY=0 run_guard 3
check "estado good" grep -q '|good|' /ncommerce/control/versions.txt

t "guard: container parado e religado depois de 3 voltas"
setup; echo exited > /fake/state/containers/api.status
run_guard 2
check "ainda nao (menos de 3 voltas)" not_called "docker start"
run_guard 4
check "docker start na api" called "docker start api"
check "api rodando" [ "$(status_of api)" = running ]
check "sem recriar nada" not_called "up -d"

t "guard: container que sumiu e recriado sem recriar os outros"
setup; rm -f /fake/state/containers/web /fake/state/containers/web.status
run_guard 5
check "up --no-recreate" called "up -d --no-recreate"
check "web de volta" [ "$(status_of web)" = running ]

t "guard: control/pausa segura a mao"
setup; echo exited > /fake/state/containers/api.status; touch /ncommerce/control/pausa
run_guard 5
check "nao religa" not_called "docker start"

t "guard: container reiniciando nao e caso de religar"
setup; echo restarting > /fake/state/containers/api.status
run_guard 5
check "nao religa" not_called "docker start"

t "guard: troca de versao em andamento nao e atropelada"
setup; rm -f /fake/state/containers/api /fake/state/containers/api.status
echo "up|$(date +%s)|sha256:api1|sha256:web1|latest" > /ncommerce/control/update.state
run_guard 5
check "nao mexe durante a troca" not_called "up -d"
check "estado da troca fica" [ -f /ncommerce/control/update.state ]

t "guard: troca interrompida (velha) e terminada"
setup; rm -f /fake/state/containers/api /fake/state/containers/api.status
echo sha256:api2 > /fake/state/images/reg.test_5050_ncommerce_api_latest
echo "up|$(( $(date +%s) - 5000 ))|sha256:api1|sha256:web1|latest" > /ncommerce/control/update.state
run_guard 5
check "termina com up -d" called "up -d"
check "api nova no ar" [ "$(cat /fake/state/containers/api)" = sha256:api2 ]
check "estado da troca removido" [ ! -e /ncommerce/control/update.state ]

t "guard: download em andamento + container parado = so start"
setup; echo exited > /fake/state/containers/api.status
echo sha256:api2 > /fake/state/images/reg.test_5050_ncommerce_api_latest
echo "pull|$(date +%s)|sha256:api1|sha256:web1|latest" > /ncommerce/control/update.state
run_guard 5
check "start" called "docker start api"
check "sem meia atualizacao" [ "$(cat /fake/state/containers/api)" = sha256:api1 ]

t "guard: troca pedida que da certo"
setup; HEALTHY=0 run_guard 3
echo sha256:api2 > /fake/state/images/reg.test_5050_ncommerce_api_latest
echo sha256:api2 > /fake/state/containers/api
HEALTHY=0 run_guard 3
old="$(grep '|sha256:api1|' /ncommerce/control/versions.txt | cut -d'|' -f1)"
echo "1||terminal" > /ncommerce/control/request
run_guard 3
check "resultado ok" grep -q '^1|ok|' /ncommerce/control/request.result
check ".env na versao guardada" grep -qx "NCOMMERCE_TAG=keep-$old" /ncommerce/.env
check ".env mantem as outras chaves" grep -qx 'CUPS_PORT=631' /ncommerce/.env
check "sem temporario do .env" [ ! -e /ncommerce/.env.guard.tmp ]

t "guard: troca pedida que falha deixa o .env como estava"
setup; HEALTHY=0 run_guard 3
echo sha256:api2 > /fake/state/images/reg.test_5050_ncommerce_api_latest
echo sha256:api2 > /fake/state/containers/api
HEALTHY=0 run_guard 3
echo 9 > /fake/knobs/up_fail
echo "2||terminal" > /ncommerce/control/request
run_guard 3
check "resultado erro" grep -q '^2|erro|' /ncommerce/control/request.result
check ".env volta para latest" grep -qx 'NCOMMERCE_TAG=latest' /ncommerce/.env

t "guard: recarrega quando o guard.sh e trocado"
setup
( sleep 2; { cat /repo/docker/guard.sh; echo '# versao nova'; } > /ncommerce/guard.sh.new; mv /ncommerce/guard.sh.new /ncommerce/guard.sh ) &
run_guard 6
check "recarregou" grep -q 'guard.sh foi atualizado' /tmp/guard.log
check "seguiu rodando depois" [ "$(grep -c 'Guarda do NCommerce' /tmp/guard.log)" -ge 2 ]
setup
( sleep 2; echo 'if [ ; then' > /ncommerce/guard.sh ) &
run_guard 6
check "arquivo novo com erro nao derruba a guarda" [ "$(grep -c 'Guarda do NCommerce' /tmp/guard.log)" = 1 ] && ! grep -q 'syntax error' /tmp/guard.log

echo
echo "Testes da guarda: $PASS conferencias certas, $FAILED erradas."
[ "$FAILED" -eq 0 ]
