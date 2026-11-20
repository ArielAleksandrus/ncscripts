#!/bin/bash
# Apoio dos testes: zera o ambiente de mentira, roda o instalador e confere.
SRC="/home/loja/Área de Trabalho/ncscripts master"
export PATH="/repo/tests/fake/bin:$PATH"
export NCOMMERCE_MASTER_URL="http://127.0.0.1:8088"
export NCOMMERCE_REGISTRY="127.0.0.1:5050"
export NCOMMERCE_INSTALL_DIR="/opt/ncommerce"
export NCOMMERCE_SCRIPTS_URL="http://127.0.0.1:8088/ncscripts.tar.gz"
export NCOMMERCE_RETRY_WAIT_S=1 NCOMMERCE_API_WAIT_S=10 NCOMMERCE_UPDATE_WAIT_S=1
export USER=loja
OUT=/tmp/out.txt
PASS=0
FAILED=0
CURRENT=""

wait_port() {
  local i
  for i in $(seq 1 50); do
    if grep -q ":$1 " <<< "$(/usr/bin/ss -ltn)"; then return 0; fi
    sleep 0.1
  done
  echo "porta $1 nao abriu" >&2
  return 1
}

reset_all() {
  pkill -f 'fake/server.py' 2>/dev/null || true
  pkill -f 'sleep 3600' 2>/dev/null || true
  sleep 0.3
  rm -rf /opt/ncommerce "$HOME/.ncommerce-docker" "$HOME/ncommerce-logs" "$HOME/.config" \
    /fake/state /fake/knobs /fake/calls.log /fake/master-backup.zip /fake/ncscripts.tar.gz \
    /etc/nginx/sites-enabled/* /etc/systemd/system/* /etc/udev/rules.d/* "$HOME/Desktop" "$HOME/Documents" \
    "$(dirname "$SRC")" /tmp/out.txt /tmp/zip
  find /env /data/nfce /app/ncommerce_api -mindepth 1 -delete 2>/dev/null || true
  mkdir -p /fake/knobs /fake/state "$HOME/Desktop" "$(dirname "$SRC")"
  : > /fake/calls.log
  cp -r /repo "$SRC"
  rm -rf "$SRC/.git" "$SRC/codigo-instalacao.txt"
  (python3 /repo/tests/fake/server.py master >/dev/null 2>&1 &)
  (python3 /repo/tests/fake/server.py registry >/dev/null 2>&1 &)
  wait_port 8088 && wait_port 5050
}

knob() { printf '%s\n' "${2:-1}" > "/fake/knobs/$1"; }
unknob() { rm -f "/fake/knobs/$1"; }
code_file() { printf '%s\n' "${1:-GOODCODE}" > "$SRC/codigo-instalacao.txt"; }

# make_backup ARQUIVO [marca]: zip de backup da loja de teste (senha tok123).
make_backup() {
  local dest="$1" mark="${2:-BACKUP-A}" w
  w="$(mktemp -d)"
  ( cd "$w"
    printf -- '-- %s\nCREATE TABLE t (id int);\n' "$mark" > backup.sql
    mkdir -p business_docs essentials/config
    echo "doc" > business_docs/contrato.txt
    echo "cert" > essentials/config/dados_emitente.json
    zip -qr docs.zip business_docs
    zip -qr nfce.zip essentials
    head -c 300000 /dev/urandom > enchimento.bin
    zip -q --password tok123 ncommerce.zip backup.sql docs.zip nfce.zip enchimento.bin )
  mv "$w/ncommerce.zip" "$dest"
  rm -rf "$w"
}

# run_installer [opcoes]: saida em $OUT, codigo em $RC. STDIN_TEXT vira o teclado.
run_installer() {
  RC=0
  printf '%s' "${STDIN_TEXT:-}" | bash "$SRC/instalador_linux.sh" "$@" > "$OUT" 2>&1 || RC=$?
}

# Roda em segundo plano num grupo de processos proprio, com o SIGINT no padrao
# (um script nao interativo larga os filhos em segundo plano com SIGINT ignorado).
start_installer_bg() {
  setsid env --default-signal=INT,HUP,TERM bash "$SRC/instalador_linux.sh" "$@" > "$OUT" 2>&1 < /dev/null &
  BG_PID=$!
}

wait_call() {
  local i
  for i in $(seq 1 150); do
    if grep -q -- "$1" /fake/calls.log 2>/dev/null; then return 0; fi
    sleep 0.1
  done
  echo "nao vi a chamada: $1" >&2
  return 1
}

signal_group() { kill "-$1" -- "-$BG_PID" 2>/dev/null || true; }

wait_bg() { RC=0; wait "$BG_PID" 2>/dev/null || RC=$?; }

t() {
  [ -z "${T0:-}" ] || echo "    ($(( $(date +%s) - T0 ))s)"
  T0=$(date +%s)
  CURRENT="$1"
  echo "--- $1"
}

ok() { PASS=$((PASS + 1)); }

bad() {
  FAILED=$((FAILED + 1))
  echo "    FALHOU [$CURRENT]: $1"
  if [ -f "$OUT" ] && [ "${SHOW_OUT:-1}" = "1" ]; then
    echo "    ---- fim da saida ----"
    tail -n 25 "$OUT" | sed 's/^/    | /'
  fi
}

check() {
  local msg="$1"
  shift
  if "$@"; then ok; else bad "$msg"; fi
}

out_has() { grep -qF -- "$1" "$OUT"; }
out_lacks() { ! grep -qF -- "$1" "$OUT"; }
called() { grep -qF -- "$1" /fake/calls.log; }
not_called() { ! grep -qF -- "$1" /fake/calls.log; }
count_calls() { grep -cF -- "$1" /fake/calls.log || true; }
env_is() { grep -qxF -- "$1" /opt/ncommerce/.env; }
state_has() { grep -q -- "^$1" "$HOME/.ncommerce-docker/instalacao.estado"; }
imports() { if [ -f /fake/state/db_imports ]; then wc -l < /fake/state/db_imports; else echo 0; fi; }
lock_free() { flock -n "$HOME/.ncommerce-docker/instalador.lock" true; }

summary() {
  echo
  echo "Testes: $PASS conferencias certas, $FAILED erradas."
  [ "$FAILED" -eq 0 ]
}
