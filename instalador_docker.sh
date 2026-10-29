#!/bin/bash
# Instalador Docker do NCommerce no Linux.
# Nao use sudo neste arquivo. Ele chama sudo so onde precisa.
# Pede um codigo de 8 caracteres. O mestre troca esse codigo, uma vez,
# pelo token da empresa e pela chave privada de leitura (access key SSH).
# A chave e apagada depois do clone.
# Reexecutar nao apaga volume.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="${NCOMMERCE_INSTALL_DIR:-/opt/ncommerce}"
MASTER_URL="${NCOMMERCE_MASTER_URL:-https://ncommerce.app:3001}"
REQUESTED_REGISTRY="${NCOMMERCE_REGISTRY:-}"
REQUESTED_TAG="${NCOMMERCE_TAG:-}"

if [ "$(id -u)" -eq 0 ]; then
  echo "Rode sem sudo. Exemplo: ./instalador_docker.sh"
  exit 1
fi

if [ ! -f "$ROOT/docker/docker-compose.yml" ]; then
  echo "Nao achei $ROOT/docker/docker-compose.yml."
  exit 1
fi

read_code() {
  local raw code
  while true; do
    read -r -p "Codigo de instalacao (8 caracteres): " raw
    code="$(printf '%s' "$raw" | tr -d '[:space:]-' | tr '[:lower:]' '[:upper:]')"
    if printf '%s' "$code" | grep -Eq '^[A-Z0-9]{8}$'; then
      printf '%s' "$code"
      return 0
    fi
    echo "Use 8 letras ou numeros." >&2
  done
}

ensure_download_tools() {
  if command -v curl >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
    return 0
  fi
  if ! command -v apt-get >/dev/null 2>&1; then
    echo "Preciso de curl e python3. Instale os dois e rode de novo."
    exit 1
  fi
  echo "Instalando curl e python3..."
  sudo apt-get update
  sudo apt-get install -y curl python3 ca-certificates
}

machine_id() {
  local dir="$HOME/.ncommerce-docker" file
  file="$dir/machine-id"
  mkdir -p "$dir"
  if [ ! -s "$file" ]; then
    if [ -r /proc/sys/kernel/random/uuid ]; then
      tr -d '[:space:]' < /proc/sys/kernel/random/uuid > "$file"
    else
      openssl rand -hex 16 > "$file"
    fi
    chmod 600 "$file"
  fi
  tr -d '[:space:]' < "$file"
}

redeem() {
  local code="$1" body http mid host
  ensure_download_tools
  mid="$(machine_id)"
  host="$(hostname | tr -cd 'A-Za-z0-9.-' | cut -c1-100)"
  body="$(mktemp)"
  http="$(curl -sS -o "$body" -w "%{http_code}" --max-time 30 \
    -X POST -H "Content-Type: application/json" \
    -d "{\"code\":\"${code}\",\"machine_id\":\"${mid}\",\"hostname\":\"${host}\"}" \
    "${MASTER_URL}/install/redeem" || true)"
  if [ "$http" != "200" ]; then
    rm -f "$body"
    echo "Codigo recusado (HTTP ${http}). Invalido, expirado, ja usado em outro PC, ou o mestre ainda nao tem a access key."
    exit 1
  fi
  KEY_FILE="$(mktemp)"
  chmod 600 "$KEY_FILE"
  NCOMMERCE_TOKEN="$(python3 - "$body" "$KEY_FILE" <<'PY' || true
import json, sys
body_path, key_path = sys.argv[1], sys.argv[2]
d = json.load(open(body_path))
token = d.get("token") or d.get("ncommerce_token") or ""
key = d.get("git_private_key") or ""
if not isinstance(token, str):
    token = ""
if not isinstance(key, str):
    key = ""
key = key.replace("\r\n", "\n").replace("\r", "\n")
if key and not key.endswith("\n"):
    key += "\n"
open(key_path, "w").write(key)
sys.stdout.write(token)
PY
)"
  rm -f "$body"
  if [ -z "${NCOMMERCE_TOKEN}" ] || ! grep -q "PRIVATE KEY" "$KEY_FILE"; then
    rm -f "$KEY_FILE"
    echo "A resposta do mestre nao trouxe o token do ncommerce e a chave de leitura."
    exit 1
  fi
}

# 200 grava o zip. 204 significa empresa sem backup. Outro HTTP aborta.
download_backup() {
  local code="$1" mid http dest tmp
  mid="$(machine_id)"
  dest="$INSTALL_DIR/ncommerce.zip"
  tmp="$(mktemp)"
  sudo mkdir -p "$INSTALL_DIR"
  http="$(curl -sS -o "$tmp" -w "%{http_code}" --max-time 600 \
    "${MASTER_URL}/install/${code}/backup?machine_id=${mid}" || true)"
  if [ "$http" = "204" ]; then
    rm -f "$tmp"
    sudo rm -f "$dest"
    echo "Esta empresa nao tem backup no mestre. A instalacao segue vazia."
    return 0
  fi
  if [ "$http" != "200" ] || [ ! -s "$tmp" ]; then
    rm -f "$tmp"
    echo "Nao consegui baixar o backup (HTTP ${http})."
    exit 1
  fi
  sudo mv "$tmp" "$dest"
  sudo chown "$USER:$USER" "$dest" 2>/dev/null || true
  echo "Backup baixado em ${dest}."
}

restore_backup_into_docker() {
  local zip="$INSTALL_DIR/ncommerce.zip" work pass marker
  marker="$INSTALL_DIR/.backup-restored"
  if [ -f "$marker" ] || [ ! -s "$zip" ]; then
    return 0
  fi
  if ! command -v unzip >/dev/null 2>&1; then
    sudo apt-get update
    sudo apt-get install -y unzip
  fi
  pass="${NCOMMERCE_TOKEN:0:6}"
  work="$(mktemp -d)"
  if ! unzip -P "$pass" -o "$zip" -d "$work" >/tmp/ncommerce-unzip.log 2>&1; then
    rm -rf "$work"
    echo "Nao abri o backup. A senha sao os 6 primeiros caracteres do token, e o zip ficou em ${zip}."
    exit 1
  fi
  if [ ! -f "$work/backup.sql" ]; then
    rm -rf "$work"
    echo "O backup nao tem backup.sql. O zip ficou em ${zip}."
    exit 1
  fi
  echo "Restaurando o banco no container..."
  sudo docker compose exec -T mysql mysql -uroot -pncommerce_root -e \
    "CREATE DATABASE IF NOT EXISTS ncommerce_api_production CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
  sudo docker compose exec -T mysql mysql -uroot -pncommerce_root ncommerce_api_production < "$work/backup.sql"
  if [ -f "$work/docs.zip" ]; then
    unzip -o "$work/docs.zip" -d "$work" >/dev/null
  fi
  if [ -d "$work/business_docs" ]; then
    sudo docker compose cp "$work/business_docs" api:/app/ncommerce_api/ || true
  fi
  if [ -f "$work/nfce.zip" ]; then
    unzip -o "$work/nfce.zip" -d "$work" >/dev/null
  fi
  if [ -d "$work/essentials" ]; then
    sudo docker compose cp "$work/essentials" api:/data/nfce/ || true
  fi
  if [ -d "$work/notas_output" ]; then
    sudo docker compose cp "$work/notas_output" api:/data/nfce/ || true
  fi
  if [ -f "$work/printers.conf" ]; then
    sudo docker compose cp "$work/printers.conf" api:/etc/cups/printers.conf || true
  fi
  rm -rf "$work"
  sudo touch "$marker"
  echo "Backup restaurado nos containers."
}

cleanup_secrets() {
  unset GIT_SSH_COMMAND || true
  if [ -n "${KEY_FILE:-}" ] && [ -f "$KEY_FILE" ]; then
    shred -u "$KEY_FILE" 2>/dev/null || rm -f "$KEY_FILE"
  fi
  if [ -n "${KNOWN_HOSTS:-}" ] && [ -f "$KNOWN_HOSTS" ]; then
    rm -f "$KNOWN_HOSTS"
  fi
}
trap cleanup_secrets EXIT

clone_repos() {
  local repo dest
  if ! command -v git >/dev/null 2>&1 || ! command -v ssh >/dev/null 2>&1; then
    sudo apt-get update
    sudo apt-get install -y git openssh-client
  fi
  sudo mkdir -p "$INSTALL_DIR/src"
  sudo chown "$USER:$USER" "$INSTALL_DIR" "$INSTALL_DIR/src"
  KNOWN_HOSTS="$(mktemp)"
  chmod 600 "$KNOWN_HOSTS"
  ssh-keyscan -T 10 -t ed25519,rsa bitbucket.org > "$KNOWN_HOSTS" 2>/dev/null || true
  if ! grep -q bitbucket.org "$KNOWN_HOSTS"; then
    echo "Nao consegui obter a chave do servidor bitbucket.org."
    exit 1
  fi
  export GIT_SSH_COMMAND="ssh -i ${KEY_FILE} -o IdentitiesOnly=yes -o UserKnownHostsFile=${KNOWN_HOSTS} -o StrictHostKeyChecking=yes"
  for repo in ncommerce_api ncommerce nfce; do
    dest="$INSTALL_DIR/src/$repo"
    if [ -d "$dest/.git" ]; then
      echo "$repo ja esta em $dest"
      continue
    fi
    rm -rf "$dest"
    echo "Clonando $repo..."
    if ! git clone --quiet "git@bitbucket.org:Aleksandrus/${repo}.git" "$dest"; then
      rm -rf "$dest"
      echo "Nao consegui clonar $repo. A chave de leitura do Bitbucket foi recusada."
      exit 1
    fi
  done
  unset GIT_SSH_COMMAND
}

port_busy() {
  local port="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -ltn | grep -Eq ":${port}([^0-9]|$)"
    return
  fi
  return 1
}

read_env_key() {
  local file="$1" key="$2" line
  [ -f "$file" ] || return 0
  line="$(grep -E "^${key}=" "$file" | tail -n 1 || true)"
  printf '%s' "${line#*=}"
}

CODE="$(read_code)"
redeem "$CODE"
clone_repos
cleanup_secrets

if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
  echo "Instalando Docker Engine..."
  if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update
    sudo apt-get install -y docker.io docker-compose-v2 || sudo apt-get install -y docker.io || true
  fi
fi

if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
  echo "O pacote da distro nao trouxe o Docker Compose. Usando https://get.docker.com ..."
  curl -fsSL https://get.docker.com | sudo sh
fi

if ! docker compose version >/dev/null 2>&1; then
  echo "Docker Compose nao ficou disponivel. Confira a instalacao e rode de novo."
  exit 1
fi

sudo systemctl enable --now docker
if ! id -nG "$USER" | grep -qw docker; then
  sudo usermod -aG docker "$USER"
fi

CUPS_PORT=631
if port_busy 631; then
  CUPS_PORT=6631
  echo "A porta 631 ja esta em uso. O CUPS do container fica em http://127.0.0.1:6631."
fi

file_registry="$(read_env_key "$INSTALL_DIR/.env" NCOMMERCE_REGISTRY)"
file_tag="$(read_env_key "$INSTALL_DIR/.env" NCOMMERCE_TAG)"
REGISTRY="${REQUESTED_REGISTRY:-${file_registry:-ncommerce.app:5050}}"
TAG="${REQUESTED_TAG:-${file_tag:-latest}}"

sudo mkdir -p "$INSTALL_DIR"
sudo cp "$ROOT/docker/docker-compose.yml" "$INSTALL_DIR/docker-compose.yml"
sudo cp "$ROOT/docker/update.sh" "$INSTALL_DIR/update.sh"
sudo chmod 755 "$INSTALL_DIR/update.sh"
sudo tee "$INSTALL_DIR/.env" >/dev/null <<EOF
CUPS_PORT=${CUPS_PORT}
NCOMMERCE_REGISTRY=${REGISTRY}
NCOMMERCE_TAG=${TAG}
EOF
sudo chmod 644 "$INSTALL_DIR/.env" "$INSTALL_DIR/docker-compose.yml"

if command -v ufw >/dev/null 2>&1 && sudo ufw status | grep -q "Status: active"; then
  sudo ufw allow 3000/tcp
  sudo ufw allow 4200/tcp
fi

cd "$INSTALL_DIR"
sudo docker compose pull
sudo docker compose up -d

echo "Esperando a API para gravar o token..."
ready=0
for _ in $(seq 1 40); do
  if curl -sf -m 3 http://127.0.0.1:3000/api/v1/docker_setup >/dev/null; then
    ready=1
    break
  fi
  sleep 3
done
if [ "$ready" -ne 1 ]; then
  echo "A API nao respondeu em http://127.0.0.1:3000. Os containers subiram; o token ainda nao foi gravado."
  exit 1
fi

download_backup "$CODE"
unset CODE
cd "$INSTALL_DIR"
restore_backup_into_docker

python3 - "$NCOMMERCE_TOKEN" <<'PY'
import json, sys, urllib.request
token = sys.argv[1]
data = json.dumps({"token": token}).encode()
req = urllib.request.Request(
    "http://127.0.0.1:3000/api/v1/docker_setup",
    data=data,
    headers={"Content-Type": "application/json"},
    method="POST",
)
try:
    urllib.request.urlopen(req, timeout=40).read()
except Exception as exc:
    sys.stderr.write("A API recusou o token: %s\n" % exc)
    sys.exit(1)
PY
unset NCOMMERCE_TOKEN

ip_addr="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
ip_addr="${ip_addr:-127.0.0.1}"
echo
echo "NCommerce no ar."
echo "  Site:  http://${ip_addr}:4200"
echo "  API:   http://${ip_addr}:3000"
echo "  CUPS:  http://127.0.0.1:${CUPS_PORT}"
echo "Codigo-fonte em ${INSTALL_DIR}/src (ncommerce_api, ncommerce, nfce)."
echo "Atualizar as imagens: ${INSTALL_DIR}/update.sh"
