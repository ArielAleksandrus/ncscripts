#!/bin/bash
# Troca o tipo da loja (restaurante / comercio em geral / industria) na versao
# Docker do NCommerce no Linux (a do instalador_linux.sh).
# Rode da pasta do instalador, sem sudo: ./manutencao/trocar_tipo_linux.sh
#
# A troca APAGA TODO O BANCO DE DADOS e recria a loja como uma instalacao nova
# do tipo escolhido. Ficam: os dados da empresa, os administradores (mesma
# senha), a configuracao e a numeracao da NFC-e, as notas em disco, a conexao
# com o mestre e o resto que esta fora do banco. Antes, uma copia do banco
# conferida (restaurada num banco temporario e comparada) numa pasta FORA da
# instalacao; se ela falhar, nada e apagado. Recusa com caixa ou comanda aberta.
# Nota sem resposta da SEFAZ ou o mestre fora do ar: avisa e pede SEGUIR.
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
    -h|--help|--ajuda) sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "Opcao desconhecida: $1"; exit 1 ;;
  esac
  shift
done

ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
INSTALL_DIR="${NCOMMERCE_INSTALL_DIR:-/opt/ncommerce}"
INSTALLER_STATE_DIR="$HOME/.ncommerce-docker"
TT_DIR="$HOME/.ncommerce-troca-tipo"
LOG_DIR="$HOME/ncommerce-logs"
PROJECT="$(basename "$INSTALL_DIR" | tr '[:upper:]' '[:lower:]')"
TT_BACKUP_BASE="${TT_BACKUP_BASE:-$HOME}"
TT_SCRIPT="./manutencao/trocar_tipo_linux.sh"
# Volumes que vao para a copia (o banco vai pelo dump).
TT_VOLUMES="nfce_data api_env cups_data api_uploads api_docs"
# Pasta da copia vista de dentro do container da API.
TT_KEEP_IN="/troca/manter.json"
DOCKER_OK=0

if [ "$(id -u)" -eq 0 ]; then
  echo "Rode sem sudo. Exemplo: ./manutencao/trocar_tipo_linux.sh"
  exit 1
fi
for needed in lib/instalador.sh lib/desinstalador.sh lib/loja_docker.sh lib/trocar_tipo.sh; do
  if [ ! -f "$ROOT/$needed" ]; then
    echo "Nao achei $ROOT/$needed. Extraia o zip do instalador inteiro e rode de dentro da pasta extraida."
    exit 1
  fi
done
# shellcheck source=lib/instalador.sh
. "$ROOT/lib/instalador.sh"
# shellcheck source=lib/desinstalador.sh
. "$ROOT/lib/desinstalador.sh"
# shellcheck source=lib/loja_docker.sh
. "$ROOT/lib/loja_docker.sh"
# shellcheck source=lib/trocar_tipo.sh
. "$ROOT/lib/trocar_tipo.sh"

if path_inside "$TT_BACKUP_BASE" "$INSTALL_DIR"; then
  echo "A copia nao pode ficar dentro de $INSTALL_DIR. Escolha outra pasta com --backup-em."
  exit 1
fi
TT_CHANGED_BY="$USER@$(hostname 2>/dev/null || echo linux) (trocar_tipo_linux.sh)"

# ---------------------------------------------------------------- o que e do Docker

# rake da API num container de uma vez (a api fica parada durante a troca), com
# o .env da loja (volume /env) e a pasta da copia em /troca.
TT_IN_API='set -a; [ ! -f /env/.env.production ] || . /env/.env.production; set +a
export RAILS_ENV=production DBHOST=mysql DBPORT=3306 REDISHOST=redis REDISPORT=6379 \
  NFCE_JAR=/opt/nfce NFCE_DATA=/data/nfce NFCE_EXTERNAL=/data/nfce/externo APP_ROOT=/app/ncommerce_api
cd /app/ncommerce_api && exec bundle exec rake "$@"'

tt_rake() {
  local mount=()
  [ -z "$TT_BACKUP_DIR" ] || mount=(-v "$TT_BACKUP_DIR:/troca")
  compose run --rm --no-deps -T "${mount[@]}" --entrypoint bash api -c "$TT_IN_API" bash "$@" < /dev/null
}

tt_env_file_dentro() { echo /env/.env.production; }

tt_mysql_root() {
  compose exec -T mysql sh -c 'exec mysql -uroot -p"$MYSQL_ROOT_PASSWORD" "$@"' sh "$@"
}

tt_banco_pronto() {
  if ! mysql_running; then
    compose up -d mysql redis >/dev/null 2>&1 || return 1
  fi
  wait_mysql
}

tt_dump() { dump_to "$1"; }

tt_copiar_resto() {
  local dir="$1" volume name volumes
  echo "  - configuracao ($INSTALL_DIR)"
  sudo cp -a "$INSTALL_DIR" "$dir/instalacao" || return 1
  mkdir -p "$dir/volumes"
  volumes="$(docker_volumes)"
  for name in $TT_VOLUMES; do
    volume="${PROJECT}_$name"
    printf '%s\n' "$volumes" | grep -qx "$volume" || continue
    echo "  - volume $name"
    archive_volume "$volume" "$dir/volumes" || return 1
  done
  sudo chown -R "$(id -u):$(id -g)" "$dir" 2>/dev/null || true
}

# A guarda religa container parado: primeiro o aviso de pausa, depois ela.
tt_parar_loja() {
  sudo mkdir -p "$INSTALL_DIR/control" && sudo touch "$INSTALL_DIR/control/pausa" || return 1
  compose stop guard web api >/dev/null
}

tt_ligar_loja() {
  compose up -d >/dev/null || return 1
  sudo rm -f "$INSTALL_DIR/control/pausa"
}

tt_preparar() {
  [ "$UN_SIMULAR" = "1" ] || echo "A senha do computador pode ser pedida (para o Docker)."
  sudo -v || { echo "Sem a senha do sudo nao consigo continuar."; exit 1; }
  if ! has_compose; then
    tt_fail "nao achei a loja Docker em $INSTALL_DIR (docker-compose.yml). Para a instalacao sem Docker use manutencao/trocar_tipo_nativo.sh."
  fi
  if command -v docker >/dev/null 2>&1 && sudo docker info >/dev/null 2>&1; then
    DOCKER_OK=1
  else
    tt_fail "o Docker nao esta respondendo. Ligue o Docker (sudo systemctl start docker) e rode de novo. Nada foi mudado."
  fi
  # O banco precisa estar ligado para conferir a loja.
  if [ "$UN_SIMULAR" != "1" ] && ! mysql_running; then
    compose up -d mysql redis >/dev/null 2>&1 || true
  fi
  wait_mysql || tt_fail "o banco de dados da loja nao respondeu. Nada foi mudado."
}

# ================================================================ inicio

# A mesma trava do instalador e da atualizacao: nenhum dos dois roda junto.
if [ "$UN_SIMULAR" != "1" ]; then
  if ! lock_acquire "$INSTALLER_STATE_DIR/instalador.lock"; then
    echo "O instalador, uma atualizacao ou outra troca de tipo do NCommerce esta rodando agora."
    echo "Espere terminar e rode de novo. Nada foi mudado."
    exit 2
  fi
fi

trap tt_on_exit EXIT
trap 'NC_SIGNAL=INT; exit 130' INT
trap 'NC_SIGNAL=TERM; exit 143' TERM
trap 'NC_SIGNAL=HUP; exit 129' HUP

tt_main
