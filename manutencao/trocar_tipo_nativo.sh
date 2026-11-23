#!/bin/bash
# Troca o tipo da loja (restaurante / comercio em geral / industria) na
# instalacao NATIVA do NCommerce (sem Docker: a do advanced/instalador_nativo.sh,
# num Ubuntu ou dentro do WSL do Windows).
# Rode da pasta do instalador, sem sudo: ./manutencao/trocar_tipo_nativo.sh
#
# A troca APAGA TODO O BANCO DE DADOS e recria a loja como uma instalacao nova
# do tipo escolhido. Ficam: os dados da empresa, os administradores (mesma
# senha), a configuracao e a numeracao da NFC-e, as notas em disco, a conexao
# com o mestre e o resto que esta fora do banco. Antes, uma copia do banco
# conferida (restaurada num banco temporario e comparada) numa pasta FORA da
# instalacao; se ela falhar, nada e apagado. Recusa com caixa ou comanda aberta.
#   --tipo T           restaurante, comercio ou industria (sem isto, pergunta)
#   --simular          so mostra o que faria. Nao muda nada e nao pede confirmacao.
#   --backup-em PASTA  onde criar a pasta da copia (padrao: a pasta pessoal, ~).
#
# Pede para digitar APAGAR TUDO. Pode ser interrompida e rodada de novo: continua
# de onde parou (progresso em ~/.ncommerce-troca-tipo) e nao refaz a copia.
set -Eeuo pipefail

UN_SIMULAR=0
TT_BACKUP_BASE=""
TT_TIPO_PEDIDO=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --simular|--dry-run) UN_SIMULAR=1 ;;
    --tipo)
      [ "$#" -ge 2 ] || { echo "Use: --tipo restaurante|comercio|industria"; exit 1; }
      TT_TIPO_PEDIDO="$2"
      shift
      ;;
    --tipo=*) TT_TIPO_PEDIDO="${1#--tipo=}" ;;
    --backup-em)
      [ "$#" -ge 2 ] || { echo "Use: --backup-em /caminho/da/pasta"; exit 1; }
      TT_BACKUP_BASE="$2"
      shift
      ;;
    --backup-em=*) TT_BACKUP_BASE="${1#--backup-em=}" ;;
    -h|--help|--ajuda) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "Opcao desconhecida: $1"; exit 1 ;;
  esac
  shift
done

ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
NC_HOME="$HOME/NCommerce"
API_DIR="$NC_HOME/ncommerce_api"
ENV_FILE="$API_DIR/.env.production"
ENVIRONMENT_FILE="${NCOMMERCE_ENVIRONMENT_FILE:-/etc/environment}"
NGINX_DIR="${NCOMMERCE_NGINX_DIR:-/etc/nginx}"
TT_DIR="$HOME/.ncommerce-troca-tipo"
LOG_DIR="$HOME/ncommerce-logs"
TT_BACKUP_BASE="${TT_BACKUP_BASE:-$HOME}"
TT_SCRIPT="./manutencao/trocar_tipo_nativo.sh"
SIDEKIQ_PATTERN='^sidekiq [0-9]'

if [ "$(id -u)" -eq 0 ]; then
  echo "Rode sem sudo. Exemplo: ./manutencao/trocar_tipo_nativo.sh"
  exit 1
fi
for needed in lib/instalador.sh lib/desinstalador.sh lib/trocar_tipo.sh; do
  if [ ! -f "$ROOT/$needed" ]; then
    echo "Nao achei $ROOT/$needed. Rode de dentro da pasta do instalador inteira."
    exit 1
  fi
done
# shellcheck source=lib/instalador.sh
. "$ROOT/lib/instalador.sh"
# shellcheck source=lib/desinstalador.sh
. "$ROOT/lib/desinstalador.sh"
# shellcheck source=lib/trocar_tipo.sh
. "$ROOT/lib/trocar_tipo.sh"

if path_inside "$TT_BACKUP_BASE" "$NC_HOME"; then
  echo "A copia nao pode ficar dentro de $NC_HOME. Escolha outra pasta com --backup-em."
  exit 1
fi
TT_CHANGED_BY="$USER@$(hostname 2>/dev/null || echo linux) (trocar_tipo_nativo.sh)"

# ---------------------------------------------------------------- o que e da instalacao nativa

tt_rake() {
  (
    cd "$API_DIR" || exit 1
    export PATH="$HOME/.rbenv/shims:$HOME/.rbenv/bin:$PATH" RAILS_ENV=production
    exec bundle exec rake "$@"
  ) < /dev/null
}

tt_env_file_dentro() { echo "$ENV_FILE"; }

tt_mysql_root() { sudo mysql "$@"; }

tt_banco_pronto() {
  local i
  for i in $(seq 1 30); do
    sudo mysql -e "SELECT 1" >/dev/null 2>&1 < /dev/null && return 0
    [ "$i" != 1 ] || { sudo systemctl start mysql >/dev/null 2>&1 || sudo service mysql start >/dev/null 2>&1 || true; }
    sleep 2
  done
  return 1
}

tt_dump() {
  local dest="$1" raw="${1%.gz}"
  rm -f "$raw" "$dest"
  sudo mysqldump --single-transaction --quick --routines --no-tablespaces \
    --result-file="$raw" "$TT_DB" < /dev/null || return 1
  sudo chown "$(id -u):$(id -g)" "$raw" 2>/dev/null || true
  tail -c 300 "$raw" | grep -q "Dump completed" || return 1
  gzip -f "$raw" || return 1
  dump_ok "$dest"
}

tt_copiar_resto() {
  local dir="$1"
  echo "  - configuracao (.env.production e $ENVIRONMENT_FILE)"
  mkdir -p "$dir/config"
  if [ -f "$ENV_FILE" ]; then
    cp -p "$ENV_FILE" "$dir/config/env.production" || return 1
  fi
  if [ -f "$ENVIRONMENT_FILE" ]; then
    sudo cat "$ENVIRONMENT_FILE" > "$dir/config/environment" || return 1
  fi
}

# Sem nginx a API (Passenger) e o front param; o Sidekiq nativo sai junto.
tt_parar_loja() {
  local pids pid
  sudo systemctl stop nginx >/dev/null 2>&1 || sudo service nginx stop >/dev/null 2>&1 || return 1
  pids=""
  for pid in $(pgrep -f "$SIDEKIQ_PATTERN" 2>/dev/null || true); do
    grep -qE 'docker|containerd' "/proc/$pid/cgroup" 2>/dev/null || pids="$pids $pid"
  done
  # shellcheck disable=SC2086
  [ -z "${pids// /}" ] || sudo kill $pids >/dev/null 2>&1 || true
}

# O Passenger sobe a API no primeiro pedido, e ela religa o Sidekiq (SidekiqWatchdog).
tt_ligar_loja() {
  sudo systemctl start nginx >/dev/null 2>&1 || sudo service nginx start >/dev/null 2>&1 || return 1
  curl -fsS -m 60 -o /dev/null "http://127.0.0.1:3000/" >/dev/null 2>&1 || true
}

# O tipo tambem fica no /etc/environment (o instalador copiou o .env para la).
tt_depois_do_reset() {
  local tmp
  [ -f "$ENVIRONMENT_FILE" ] || return 0
  grep -q '^NCOMMERCE_COMMERCE_TYPE=' "$ENVIRONMENT_FILE" || return 0
  tmp="$(mktemp)"
  sed "s/^NCOMMERCE_COMMERCE_TYPE=.*/NCOMMERCE_COMMERCE_TYPE=$TT_TIPO/" "$ENVIRONMENT_FILE" > "$tmp"
  echo "  - $ENVIRONMENT_FILE: NCOMMERCE_COMMERCE_TYPE=$TT_TIPO"
  sudo cp "$tmp" "$ENVIRONMENT_FILE"
  local rc=$?
  rm -f "$tmp"
  return "$rc"
}

tt_preparar() {
  [ "$UN_SIMULAR" = "1" ] || echo "A senha do computador pode ser pedida (para o MySQL e o nginx)."
  sudo -v || { echo "Sem a senha do sudo nao consigo continuar."; exit 1; }
  if [ ! -f "$API_DIR/Rakefile" ]; then
    tt_fail "nao achei a instalacao nativa em $API_DIR. Para a versao Docker use manutencao/trocar_tipo_linux.sh."
  fi
  tt_banco_pronto || tt_fail "o MySQL nao respondeu (sudo systemctl start mysql). Nada foi mudado."
}

# ================================================================ inicio

if [ "$UN_SIMULAR" != "1" ]; then
  mkdir -p "$TT_DIR"
  chmod 700 "$TT_DIR" 2>/dev/null || true
  if ! lock_acquire "$TT_DIR/troca.lock"; then
    echo "A troca de tipo ja esta aberta em outra janela."
    exit 2
  fi
fi

trap tt_on_exit EXIT
trap 'NC_SIGNAL=INT; exit 130' INT
trap 'NC_SIGNAL=TERM; exit 143' TERM
trap 'NC_SIGNAL=HUP; exit 129' HUP

tt_main
