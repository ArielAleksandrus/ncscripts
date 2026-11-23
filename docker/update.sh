#!/bin/bash
# Baixa a versao publicada no registry e recria o que mudou.
# Os volumes (banco, notas, certificado, fotos, .env) ficam.
# Antes, atualiza os scripts desta pasta com o ncscripts do GitHub (update-host.sh).
# Depois, espera o servico guard dizer se a versao nova funciona. Se ela nao
# funcionar, o guard ja voltou para a anterior: veja ./rollback.sh lista.
#
# A loja so e tocada depois que a versao nova inteira esta baixada. Internet
# caindo, janela fechada ou Ctrl+C durante o download deixam a loja na versao
# em que estava. Se a versao nova muda o banco, uma copia dele fica antes em
# backups/ (as 3 ultimas). O log de cada atualizacao fica em ~/ncommerce-logs/.
set -euo pipefail

INSTALL_DIR="${NCOMMERCE_INSTALL_DIR:-/opt/ncommerce}"
WAIT_S="${NCOMMERCE_UPDATE_WAIT_S:-390}"
RETRY_WAIT_S="${NCOMMERCE_RETRY_WAIT_S:-15}"
STATE_DIR="$HOME/.ncommerce-docker"
LOG_DIR="$HOME/ncommerce-logs"
UPDATE_STATE="$INSTALL_DIR/control/update.state"

if [ "$(id -u)" -eq 0 ]; then
  echo "Rode sem sudo: $INSTALL_DIR/update.sh"
  exit 1
fi

if [ ! -f "$INSTALL_DIR/docker-compose.yml" ]; then
  echo "Nao achei $INSTALL_DIR/docker-compose.yml. Rode instalador_linux.sh antes."
  exit 1
fi

cd "$INSTALL_DIR"

# Duas atualizacoes ao mesmo tempo (dois cliques no atalho), ou uma atualizacao
# com o instalador aberto, brigariam pelo Docker. A trava e a mesma do
# instalador; o kernel solta sozinho se o processo morrer.
# Depois do exec mais abaixo, a trava e o log ja vem abertos da execucao anterior.
if [ "${NCOMMERCE_UPDATE_LOCKED:-}" != "1" ]; then
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  if command -v flock >/dev/null 2>&1 && [ -d "$STATE_DIR" ]; then
    exec 8>>"$STATE_DIR/instalador.lock"
    if ! flock -n 8; then
      echo "Uma atualizacao (ou o instalador) do NCommerce ja esta rodando em outra janela."
      echo "Espere ela terminar. Esta janela pode ser fechada."
      exit 2
    fi
    export NCOMMERCE_UPDATE_LOCKED=1
  fi
fi

if [ -z "${NCOMMERCE_UPDATE_LOG:-}" ]; then
  if mkdir -p "$LOG_DIR" 2>/dev/null; then
    NCOMMERCE_UPDATE_LOG="$LOG_DIR/atualizacao-$(date '+%Y%m%d-%H%M%S').log"
    export NCOMMERCE_UPDATE_LOG
    : > "$NCOMMERCE_UPDATE_LOG" 2>/dev/null || true
    # Ficam os 10 logs mais recentes. Sem o "|| true", a primeira atualizacao
    # (nenhum log ainda) parava aqui em silencio por causa do pipefail.
    # shellcheck disable=SC2012
    { ls -1t "$LOG_DIR"/atualizacao-*.log 2>/dev/null || true; } | tail -n +11 | while IFS= read -r old; do rm -f -- "$old"; done
    exec > >(trap '' INT HUP TERM; exec tee -a "$NCOMMERCE_UPDATE_LOG") 2>&1
    echo "[info] update.sh, $(date '+%Y-%m-%d %H:%M:%S %z')"
  fi
fi

# Scripts novos primeiro. Se este update.sh mudou, segue com o novo.
if [ "${NCOMMERCE_SCRIPTS_UPDATED:-}" != "1" ] && [ -x "$INSTALL_DIR/update-host.sh" ]; then
  before="$(sha256sum "$INSTALL_DIR/update.sh")"
  "$INSTALL_DIR/update-host.sh" "$INSTALL_DIR" || true
  if [ "$(sha256sum "$INSTALL_DIR/update.sh")" != "$before" ]; then
    NCOMMERCE_SCRIPTS_UPDATED=1 exec "$INSTALL_DIR/update.sh" "$@"
  fi
fi

PHASE="inicio"
PREV_TAG=""
OLD_API=""
OLD_WEB=""
REG=""
FINISHED=0
SIGNALED=""
KEEPALIVE_PID=""

compose() { sudo docker compose "$@"; }

env_value() { sed -n "s/^$1=//p" .env 2>/dev/null | tail -n 1 | tr -d '\r'; }

# Troca uma chave do .env num arquivo novo e poe no lugar com mv: uma queda de
# energia deixa o .env antigo ou o novo, nunca a metade.
env_set() {
  local key="$1" value="$2" tmp
  tmp="$(mktemp)"
  { grep -v "^$key=" .env || true; printf '%s=%s\n' "$key" "$value"; } > "$tmp"
  sudo install -m 644 "$tmp" "$INSTALL_DIR/.env.novo" && sudo mv -f "$INSTALL_DIR/.env.novo" "$INSTALL_DIR/.env"
  rm -f "$tmp"
}

container_image() {
  local cid
  cid="$(compose ps -aq "$1" 2>/dev/null | sed -n '1p')"
  [ -n "$cid" ] || return 0
  sudo docker inspect -f '{{.Image}}' "$cid" 2>/dev/null || true
}

image_id() { sudo docker image inspect -f '{{.Id}}' "$1" 2>/dev/null || true; }

# O download parou no meio: a etiqueta "latest" de api e web volta para as
# imagens em uso, para api e web nunca ficarem de versoes diferentes.
restore_latest_tags() {
  [ "$PREV_TAG" = "latest" ] || return 0
  if [ -n "$OLD_API" ]; then sudo docker tag "$OLD_API" "$REG/ncommerce/api:latest" 2>/dev/null || true; fi
  if [ -n "$OLD_WEB" ]; then sudo docker tag "$OLD_WEB" "$REG/ncommerce/web:latest" 2>/dev/null || true; fi
}

write_update_state() {
  local tmp
  tmp="$(mktemp)"
  printf '%s|%s|%s|%s|%s\n' "$1" "$(date +%s)" "$OLD_API" "$OLD_WEB" "$PREV_TAG" > "$tmp"
  sudo install -m 644 "$tmp" "$UPDATE_STATE.tmp" && sudo mv -f "$UPDATE_STATE.tmp" "$UPDATE_STATE"
  rm -f "$tmp"
}

clear_update_state() { sudo rm -f "$UPDATE_STATE" "$UPDATE_STATE.tmp" 2>/dev/null || true; }

verdict() {
  echo
  echo "=================================================================="
  echo "  $1"
  echo "=================================================================="
  shift
  local line
  for line in "$@"; do echo "$line"; done
  if [ -n "${NCOMMERCE_UPDATE_LOG:-}" ]; then
    echo "Log desta atualizacao: $NCOMMERCE_UPDATE_LOG"
  fi
}

on_exit() {
  local rc=$?
  trap - EXIT INT TERM HUP
  set +e
  if [ "$FINISHED" != "1" ]; then
    case "$PHASE" in
      baixando)
        restore_latest_tags
        clear_update_state
        verdict "A ATUALIZACAO NAO FOI FEITA. A LOJA CONTINUA NA VERSAO EM QUE ESTAVA." \
          "${SIGNALED:+A atualizacao foi interrompida (janela fechada ou Ctrl+C).}" \
          "O que fazer: confira a internet e use o atalho Atualizar NCommerce de novo."
        ;;
      ligando)
        # Parou no meio da troca dos containers: termina de ligar. Se nem isso
        # der, o servico guard liga sozinho em ate 2 minutos.
        echo "A atualizacao parou no meio da troca. Ligando o NCommerce de novo..."
        if compose up -d; then clear_update_state; fi
        verdict "A ATUALIZACAO FOI INTERROMPIDA NO MEIO DA TROCA." \
          "O NCommerce esta sendo religado. Espere 2 minutos e confira se o sistema abre." \
          "Depois use o atalho Atualizar NCommerce de novo. Se o sistema nao abrir, chame o suporte."
        ;;
      conferindo)
        # A versao nova ja esta no lugar; so a espera pelo veredito parou.
        verdict "ATUALIZACAO FEITA. A CONFERENCIA DA VERSAO NOVA CONTINUA SOZINHA." \
          "Se ela falhar, o NCommerce volta sozinho para a anterior. Veja em alguns minutos se o sistema abre."
        ;;
      *)
        if [ "$rc" -ne 0 ] && [ "$rc" -ne 2 ]; then
          verdict "A ATUALIZACAO NAO FOI FEITA (codigo $rc). A LOJA CONTINUA COMO ESTAVA." \
            "O que fazer: use o atalho Atualizar NCommerce de novo. Se repetir, mande o log para o suporte."
        fi
        ;;
    esac
  fi
  if [ -n "$KEEPALIVE_PID" ]; then kill "$KEEPALIVE_PID" 2>/dev/null; fi
  # Fecha a saida e espera o tee gravar o fim do log antes de devolver o terminal.
  exec >&- 2>&-
  wait 2>/dev/null
  exit "$rc"
}
trap on_exit EXIT
trap 'SIGNALED=1; exit 130' INT
trap 'SIGNALED=1; exit 143' TERM
trap 'SIGNALED=1; exit 129' HUP

echo "Atualizando o NCommerce. NAO FECHE ESTA JANELA ate aparecer o resultado."
echo "A loja continua funcionando durante o download."

# Digitar a senha uma vez e manter o sudo valido durante o download.
sudo -v
( while sudo -n -v 2>/dev/null; do sleep 50; done ) >/dev/null 2>&1 8>&- &
KEEPALIVE_PID=$!

if ! sudo docker info >/dev/null 2>&1; then
  echo "O Docker nao esta respondendo. Ligando..."
  sudo systemctl start docker >/dev/null 2>&1 || true
  sleep 5
  if ! sudo docker info >/dev/null 2>&1; then
    echo "O Docker deste computador nao liga. Reinicie o computador e tente de novo; se repetir, chame o suporte."
    exit 1
  fi
fi

# Instaladores antigos clonavam o codigo-fonte em src/. Nada usa essa pasta.
if [ -d "$INSTALL_DIR/src" ]; then
  sudo rm -rf "$INSTALL_DIR/src"
fi
if [ -f "$INSTALL_DIR/host-ips.sh" ]; then
  # shellcheck disable=SC1091
  . "$INSTALL_DIR/host-ips.sh"
  write_host_ip_files "$INSTALL_DIR"
fi
if [ -x "$INSTALL_DIR/anydesk-id.sh" ]; then
  sudo "$INSTALL_DIR/anydesk-id.sh" "$INSTALL_DIR" || true
fi
# Lojas antigas ganham aqui o timer que procura conflito de IP (host/net_check).
if [ -x "$INSTALL_DIR/net-check.sh" ] && [ ! -f /etc/systemd/system/ncommerce-net-check.timer ]; then
  sudo "$INSTALL_DIR/net-check.sh" --install "$INSTALL_DIR" || true
fi
# Lojas antigas ganham o timer que troca a rota do tunel se a interface cair.
if [ -x "$INSTALL_DIR/tunnel-route.sh" ] && [ ! -f /etc/systemd/system/ncommerce-tunnel-route.timer ]; then
  sudo "$INSTALL_DIR/tunnel-route.sh" --install "$INSTALL_DIR" || true
fi

sudo mkdir -p "$INSTALL_DIR/control"

# O mestre e o registry ganharam nomes proprios: api.ncommerce.app e
# registry.ncommerce.app:5050. Com o proxy da Cloudflare ligado em ncommerce.app,
# as portas 3001 e 5050 desse nome param de responder.
OLD_REGISTRY=ncommerce.app:5050
NEW_REGISTRY=registry.ncommerce.app:5050

# Usuario e senha do registry antigo, do jeito que o docker login gravou.
registry_credentials() {
  sudo python3 - "$1" <<'PY'
import base64, json, subprocess, sys
host = sys.argv[1]
try:
    conf = json.load(open("/root/.docker/config.json"))
except Exception:
    sys.exit(1)
for key, value in conf.get("auths", {}).items():
    if key.split("://")[-1].rstrip("/") == host and value.get("auth"):
        print(base64.b64decode(value["auth"]).decode())
        sys.exit(0)
store = conf.get("credHelpers", {}).get(host) or conf.get("credsStore")
if store:
    out = subprocess.run(["docker-credential-" + store, "get"], input=host, capture_output=True, text=True)
    if out.returncode == 0:
        data = json.loads(out.stdout)
        print(data["Username"] + ":" + data["Secret"])
        sys.exit(0)
sys.exit(1)
PY
}

migrate_registry() {
  local creds
  grep -qx "NCOMMERCE_REGISTRY=$OLD_REGISTRY" .env || return 0
  if ! creds="$(registry_credentials "$OLD_REGISTRY")" || [ -z "$creds" ]; then
    echo "Nao achei o login de $OLD_REGISTRY. Sigo com ele."
    return 0
  fi
  if printf '%s' "${creds#*:}" | sudo docker login "$NEW_REGISTRY" --username "${creds%%:*}" --password-stdin >/dev/null 2>&1; then
    env_set NCOMMERCE_REGISTRY "$NEW_REGISTRY"
    echo "Registry trocado para $NEW_REGISTRY."
    # A guarda le o registry so ao ligar, e ao ligar renomeia as versoes guardadas.
    compose restart guard >/dev/null 2>&1 || true
  else
    echo "Nao consegui entrar em $NEW_REGISTRY. Sigo com $OLD_REGISTRY."
  fi
}

# O endereco do mestre fica no volume api_env (/env/.env.production). Vale a partir
# do proximo reinicio da api; o endereco antigo segue no ar enquanto isso.
migrate_master_url() {
  [ -n "$(compose ps -q api 2>/dev/null)" ] || return 0
  compose exec -T api sh -c \
    "grep -q '^NCOMMERCE_SERVER_URL=.*ncommerce\.app:3001' /env/.env.production 2>/dev/null || exit 0
     sed -i '/^NCOMMERCE_SERVER_URL=/s#https://ncommerce\.app:3001#https://api.ncommerce.app#' /env/.env.production
     echo 'Mestre trocado para https://api.ncommerce.app.'" < /dev/null || true
}

migrate_registry
migrate_master_url

# A versao nova precisa de espaco para baixar ao lado da atual.
free_kb="$(df -Pk /var/lib/docker 2>/dev/null | awk 'NR == 2 { print $4 }')"
if [ -n "${free_kb:-}" ] && [ "$free_kb" -lt 2097152 ]; then
  echo "O disco deste computador esta quase cheio ($(awk -v k="$free_kb" 'BEGIN { printf "%.1f", k / 1048576 }') GB livres)."
  echo "A atualizacao precisa de pelo menos 2 GB. Chame o suporte NCommerce para liberar espaco."
  exit 1
fi

last_migration() {
  sudo docker run --rm --network none --entrypoint sh "$1" -c \
    'ls /app/ncommerce_api/db/migrate 2>/dev/null | sort | tail -n 1 | cut -c1-14' 2>/dev/null < /dev/null || true
}

# Copia do banco antes de uma versao que muda as tabelas. Fica em backups/
# (so root le), as 3 mais recentes.
dump_database() {
  local dir="$INSTALL_DIR/backups" name
  name="antes-de-atualizar-$(date '+%Y%m%d-%H%M%S').sql.gz"
  sudo mkdir -p "$dir"
  sudo chmod 700 "$dir"
  # Sem pipe: o codigo de saida do mysqldump e a ultima linha ("Dump completed") valem.
  # shellcheck disable=SC2016
  if ! compose exec -T mysql sh -c 'rm -f /tmp/ncommerce-dump.sql /tmp/ncommerce-dump.sql.gz
      mysqldump -uroot -p"$MYSQL_ROOT_PASSWORD" --single-transaction --quick --routines --no-tablespaces \
        --result-file=/tmp/ncommerce-dump.sql ncommerce_api_production 2>/dev/null \
      && tail -c 300 /tmp/ncommerce-dump.sql | grep -q "Dump completed" \
      && gzip -f /tmp/ncommerce-dump.sql' < /dev/null; then
    compose exec -T mysql rm -f /tmp/ncommerce-dump.sql /tmp/ncommerce-dump.sql.gz < /dev/null || true
    return 1
  fi
  compose cp "mysql:/tmp/ncommerce-dump.sql.gz" "$dir/$name.part" >/dev/null || return 1
  compose exec -T mysql rm -f /tmp/ncommerce-dump.sql.gz < /dev/null || true
  sudo gzip -t "$dir/$name.part" || { sudo rm -f "$dir/$name.part"; return 1; }
  sudo mv -f "$dir/$name.part" "$dir/$name"
  # shellcheck disable=SC2012
  sudo sh -c "ls -1t '$dir'/antes-de-atualizar-*.sql.gz 2>/dev/null | tail -n +4 | while IFS= read -r old; do rm -f -- \"\$old\"; done"
  echo "Copia do banco guardada em $dir/$name."
}

REG="$(env_value NCOMMERCE_REGISTRY)"
REG="${REG:-registry.ncommerce.app:5050}"
PREV_TAG="$(env_value NCOMMERCE_TAG)"
PREV_TAG="${PREV_TAG:-latest}"
OLD_API="$(container_image api)"
OLD_WEB="$(container_image web)"

# ---- 1. Download. A loja segue no ar, na versao atual. O .env ainda nao muda:
# a etiqueta "latest" vai so no ambiente deste comando.
PHASE="baixando"
write_update_state pull
echo
echo "Baixando a versao publicada. Pode levar de 2 a 30 minutos, conforme a internet."
pulled=0
for attempt in 1 2 3; do
  if sudo NCOMMERCE_TAG=latest docker compose pull; then pulled=1; break; fi
  if [ "$attempt" -lt 3 ]; then
    echo "O download parou (tentativa $attempt de 3). Tentando de novo em $((attempt * RETRY_WAIT_S)) segundos..."
    sleep $((attempt * RETRY_WAIT_S))
  fi
done
if [ "$pulled" -ne 1 ]; then
  echo "Nao consegui baixar a versao nova: a internet caiu ou o servidor nao respondeu."
  exit 1
fi

NEW_API="$(image_id "$REG/ncommerce/api:latest")"
if [ -n "$NEW_API" ] && [ -n "$OLD_API" ] && [ "$NEW_API" != "$OLD_API" ] && [ "${NCOMMERCE_SKIP_DB_BACKUP:-}" != "1" ]; then
  old_mig="$(last_migration "$OLD_API")"
  new_mig="$(last_migration "$NEW_API")"
  if [ -z "$old_mig" ] || [ "$old_mig" != "$new_mig" ]; then
    echo "A versao nova muda o banco de dados. Guardando uma copia antes..."
    if ! dump_database; then
      echo "Nao consegui guardar a copia do banco (disco cheio ou banco parado), entao nao atualizei."
      echo "Chame o suporte NCommerce."
      exit 1
    fi
  fi
fi

# ---- 2. Troca. Daqui em diante a versao nova inteira esta no computador.
# Uma troca de versao (guard) deixa NCOMMERCE_TAG=keep-<versao>. Atualizar volta para a publicada.
PHASE="ligando"
write_update_state up
if [ "$PREV_TAG" != "latest" ]; then
  env_set NCOMMERCE_TAG latest
fi
echo "Trocando para a versao nova. O sistema fica fora do ar por cerca de um minuto..."
if ! compose up -d; then
  echo "O Docker nao conseguiu ligar a versao nova. Tentando mais uma vez..."
  sleep 10
  if ! compose up -d; then
    echo "Nao ligou. Voltando para a versao anterior..."
    if [ "$PREV_TAG" != "latest" ]; then
      env_set NCOMMERCE_TAG "$PREV_TAG"
    else
      restore_latest_tags
    fi
    compose up -d || true
    clear_update_state
    FINISHED=1
    verdict "A ATUALIZACAO FALHOU E A LOJA VOLTOU PARA A VERSAO ANTERIOR." \
      "Confira se o sistema abre. Mande o log para o suporte NCommerce."
    exit 1
  fi
fi
clear_update_state
# A copia que o instalador guarda para voltar a loja ficou velha.
sudo rm -rf "$INSTALL_DIR/control/antes-da-instalacao" 2>/dev/null || true
PHASE="conferindo"

# Espera o guard: a versao fica "good" depois de 5 minutos respondendo.
wait_verdict() {
  local reg tag new_img cid img line name state i
  [ -n "$(compose ps -q guard 2>/dev/null)" ] || return 0
  reg="$(sed -n 's/^NCOMMERCE_REGISTRY=//p' .env | tail -n 1)"
  tag="$(sed -n 's/^NCOMMERCE_TAG=//p' .env | tail -n 1)"
  new_img="$(sudo docker image inspect -f '{{.Id}}' "${reg:-registry.ncommerce.app:5050}/ncommerce/api:${tag:-latest}" 2>/dev/null || true)"
  name=""
  echo
  echo "Conferindo a versao nova (ate $((WAIT_S / 60)) minutos). Pode fechar: a conferencia continua sozinha."
  for ((i = 0; i < WAIT_S; i += 10)); do
    cid="$(compose ps -aq api 2>/dev/null | sed -n '1p')"
    img="$(sudo docker inspect -f '{{.Image}}' "$cid" 2>/dev/null || true)"
    line="$(grep "^[^|]*|$img|" control/versions.txt 2>/dev/null | sed -n '1p' || true)"
    name="$(echo "$line" | cut -d'|' -f1)"
    state="$(echo "$line" | cut -d'|' -f5)"
    if [ -n "$new_img" ] && [ -n "$img" ] && [ "$img" != "$new_img" ]; then
      VERDICT_NAME="${name:-anterior}"
      return 1
    fi
    if [ "$state" = "good" ]; then
      VERDICT_NAME="$name"
      return 0
    fi
    sleep 10
  done
  VERDICT_NAME="${name:-nova}"
  return 3
}

VERDICT_NAME=""
status=0
wait_verdict || status=$?
compose ps || true
FINISHED=1
case "$status" in
  0)
    verdict "ATUALIZACAO CONCLUIDA. ${VERDICT_NAME:+VERSAO $VERDICT_NAME }FUNCIONANDO." "Pode fechar esta janela."
    ;;
  1)
    verdict "A VERSAO NOVA NAO FUNCIONOU. O NCOMMERCE VOLTOU SOZINHO PARA A VERSAO $VERDICT_NAME." \
      "A loja esta funcionando na versao anterior. Avise o suporte NCommerce."
    ;;
  *)
    status=0
    verdict "ATUALIZACAO FEITA. A VERSAO $VERDICT_NAME AINDA ESTA EM TESTE." \
      "Se ela falhar, o NCommerce volta sozinho para a anterior. Pode fechar esta janela."
    ;;
esac
exit "$status"
