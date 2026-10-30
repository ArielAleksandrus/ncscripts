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

if ! command -v sudo >/dev/null 2>&1; then
  echo "Preciso do sudo."
  exit 1
fi
sudo -v

ensure_base_packages() {
  local missing=() cmd
  for cmd in curl python3 git ssh unzip ss hostname; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  if [ "${#missing[@]}" -eq 0 ]; then
    return 0
  fi
  if ! command -v apt-get >/dev/null 2>&1; then
    echo "Faltam comandos: ${missing[*]}. Instale e rode de novo."
    exit 1
  fi
  echo "Instalando curl, python3, git, ssh, unzip e ss..."
  sudo DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get update
  sudo DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get install -y \
    curl python3 ca-certificates git openssh-client unzip iproute2 hostname
}

ensure_base_packages

# Ubuntu recem-instalado nao traz o servidor SSH. Abre cedo, antes do
# download das imagens, para a maquina continuar acessivel se um passo seguinte parar.
enable_ssh() {
  echo "Abrindo o SSH na porta 22..."
  if ! dpkg -s openssh-server >/dev/null 2>&1; then
    sudo DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get update
    sudo DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get install -y openssh-server
  fi
  if ! sudo systemctl enable --now ssh; then
    sudo systemctl enable --now ssh.socket
  fi
  if command -v ufw >/dev/null 2>&1; then
    sudo ufw allow 22/tcp >/dev/null || true
  fi
  if ss -ltn | grep -Eq ':22[[:space:]]'; then
    echo "SSH escutando na porta 22. Usuario: ${USER}."
  else
    echo "O SSH foi instalado, mas a porta 22 nao esta escutando."
    exit 1
  fi
}

enable_ssh

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
  local code="$1" body http mid host grant
  mid="$(machine_id)"
  host="$(hostname | tr -cd 'A-Za-z0-9.-' | cut -c1-100)"
  body="$(mktemp)"
  http="$(curl -sS -o "$body" -w "%{http_code}" --max-time 30 \
    -X POST -H "Content-Type: application/json" \
    -d "{\"code\":\"${code}\",\"machine_id\":\"${mid}\",\"hostname\":\"${host}\"}" \
    "${MASTER_URL}/install/redeem")" || {
    rm -f "$body"
    echo "Nao consegui falar com ${MASTER_URL}. Confira a rede e se o mestre esta no ar."
    exit 1
  }
  if [ "$http" != "200" ]; then
    echo "Codigo recusado (HTTP ${http})."
    if [ -s "$body" ]; then
      head -c 500 "$body" >&2 || true
      echo >&2
    fi
    rm -f "$body"
    exit 1
  fi
  KEY_FILE="$(mktemp)"
  chmod 600 "$KEY_FILE"
  grant="$(python3 - "$body" "$KEY_FILE" <<'PY'
import json, sys
body_path, key_path = sys.argv[1], sys.argv[2]
d = json.load(open(body_path))
token = d.get("token") or d.get("ncommerce_token") or ""
key = d.get("git_private_key") or ""
company = d.get("company") or ""
registry = d.get("registry") or ""
if not isinstance(token, str):
    token = ""
if not isinstance(key, str):
    key = ""
if not isinstance(company, str):
    company = ""
if not isinstance(registry, str):
    registry = ""
key = key.replace("\r\n", "\n").replace("\r", "\n")
if key and not key.endswith("\n"):
    key += "\n"
open(key_path, "w").write(key)
sys.stdout.write("%s\n%s\n%s" % (token, company, registry))
PY
)"
  rm -f "$body"
  NCOMMERCE_TOKEN="$(printf '%s\n' "$grant" | sed -n '1p')"
  COMPANY_NAME="$(printf '%s\n' "$grant" | sed -n '2p')"
  REGISTRY_FROM_MASTER="$(printf '%s\n' "$grant" | sed -n '3p')"
  if [ -z "${NCOMMERCE_TOKEN}" ] || ! grep -q "PRIVATE KEY" "$KEY_FILE"; then
    rm -f "$KEY_FILE"
    echo "A resposta do mestre nao trouxe o token do ncommerce e a chave de leitura."
    exit 1
  fi
  if [ -z "${COMPANY_NAME}" ]; then
    rm -f "$KEY_FILE"
    echo "A resposta do mestre nao trouxe o nome da empresa para entrar no registry."
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

# O token fica em /env/.env.production, no volume da API. Da para ler isso
# enquanto o Rails ainda roda db:prepare e a porta 3000 nao responde.
token_already_on_volume() {
  local i raw value
  for i in $(seq 1 15); do
    raw="$(sudo docker compose exec -T api sh -c 'if [ -f /env/.env.production ]; then grep -m1 "^NCOMMERCE_SERVER_TOKEN=" /env/.env.production || true; else echo __NOFILE__; fi' 2>/dev/null || echo __EXEC_FAIL__)"
    case "$raw" in
      __NOFILE__|"")
        return 1
        ;;
      NCOMMERCE_SERVER_TOKEN=*)
        value="${raw#NCOMMERCE_SERVER_TOKEN=}"
        value="${value#\'}"
        value="${value#\"}"
        value="${value%\'}"
        value="${value%\"}"
        value="${value//[[:space:]]/}"
        [ -n "$value" ]
        return
        ;;
      *)
        sleep 1
        ;;
    esac
  done
  return 1
}

# A imagem publicada responde 403 para Host 127.0.0.1. localhost esta permitido.
# Conectamos no IP e enviamos esse Host, senao o curl -f desiste e o token nao e gravado.
api_setup() {
  local dest="$1"
  curl -sS -o "$dest" -w "%{http_code}" -m 5 \
    -H "Host: localhost" \
    "http://127.0.0.1:3000/api/v1/docker_setup" 2>/dev/null || true
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
    sudo DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get update
    sudo DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get install -y docker.io docker-compose-v2 \
      || sudo DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get install -y docker.io || true
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
REGISTRY="${REQUESTED_REGISTRY:-${file_registry:-${REGISTRY_FROM_MASTER:-ncommerce.app:5050}}}"
TAG="${REQUESTED_TAG:-${file_tag:-latest}}"

sudo mkdir -p "$INSTALL_DIR"
sudo cp "$ROOT/docker/docker-compose.yml" "$INSTALL_DIR/docker-compose.yml"
sudo cp "$ROOT/docker/update.sh" "$INSTALL_DIR/update.sh"
sudo cp "$ROOT/docker/host-ips.sh" "$INSTALL_DIR/host-ips.sh"
sudo chmod 755 "$INSTALL_DIR/update.sh"
sudo tee "$INSTALL_DIR/.env" >/dev/null <<EOF
CUPS_PORT=${CUPS_PORT}
NCOMMERCE_REGISTRY=${REGISTRY}
NCOMMERCE_TAG=${TAG}
EOF
sudo chmod 644 "$INSTALL_DIR/.env" "$INSTALL_DIR/docker-compose.yml" "$INSTALL_DIR/host-ips.sh"
# shellcheck disable=SC1091
. "$INSTALL_DIR/host-ips.sh"
write_host_ip_files "$INSTALL_DIR"

# Grava as regras mesmo com o firewall desligado. Um ufw enable depois nao fecha a loja nem o SSH.
if command -v ufw >/dev/null 2>&1; then
  sudo ufw allow 22/tcp >/dev/null || true
  sudo ufw allow 3000/tcp >/dev/null || true
  sudo ufw allow 4200/tcp >/dev/null || true
fi

cd "$INSTALL_DIR"
echo "Entrando no registry ${REGISTRY} como ${COMPANY_NAME}..."
sudo -v
printf '%s' "$NCOMMERCE_TOKEN" | sudo -n docker login "$REGISTRY" --username "$COMPANY_NAME" --password-stdin

sudo docker compose pull
sudo docker compose up -d

skip_token_post=0
if token_already_on_volume; then
  echo "O token desta maquina ja esta gravado."
  skip_token_post=1
else
  echo "Esperando a API para gravar o token..."
  ready=0
  setup_probe="$(mktemp)"
  setup_http=""
  for i in $(seq 1 90); do
    setup_http="$(api_setup "$setup_probe")"
    if [ "$setup_http" = "200" ]; then
      ready=1
      break
    fi
    if [ $((i % 5)) -eq 0 ]; then
      echo "A API ainda nao aceitou o setup (HTTP ${setup_http:-000})."
    fi
    sleep 4
  done
  rm -f "$setup_probe"
  if [ "$ready" -ne 1 ]; then
    if token_already_on_volume; then
      echo "O token desta maquina ja esta gravado."
      skip_token_post=1
    else
      echo "A API nao aceitou o setup (ultimo HTTP ${setup_http:-000}) e nao ha token no volume."
      sudo docker compose ps || true
      sudo docker compose logs --tail 60 api || true
      exit 1
    fi
  fi
fi

download_backup "$CODE"
unset CODE
cd "$INSTALL_DIR"
restore_backup_into_docker

if [ "$skip_token_post" -eq 0 ]; then
  setup_body="$(mktemp)"
  setup_http="$(api_setup "$setup_body")"
  if [ "$setup_http" = "200" ] && grep -Eq '"setup_required":[[:space:]]*false' "$setup_body"; then
    rm -f "$setup_body"
    echo "O token desta maquina ja esta gravado."
  else
    rm -f "$setup_body"
    payload="$(mktemp)"
    post_body="$(mktemp)"
    chmod 600 "$payload" "$post_body"
    python3 - "$NCOMMERCE_TOKEN" "$payload" <<'PY'
import json, sys
open(sys.argv[2], "w").write(json.dumps({"token": sys.argv[1]}))
PY
    post_http="$(curl -sS -o "$post_body" -w "%{http_code}" -m 40 \
      -H "Host: localhost" \
      -H "Content-Type: application/json" \
      --data-binary "@${payload}" \
      "http://127.0.0.1:3000/api/v1/docker_setup" 2>/dev/null || true)"
    rm -f "$payload"
    if [ "$post_http" != "200" ] || ! grep -Eq '"ok":[[:space:]]*true' "$post_body"; then
      echo "A API recusou o token (HTTP ${post_http:-000})." >&2
      head -c 300 "$post_body" >&2 || true
      echo >&2
      rm -f "$post_body"
      exit 1
    fi
    rm -f "$post_body"
    if ! token_already_on_volume; then
      echo "A API nao gravou /env/.env.production."
      exit 1
    fi
    echo "Token gravado."
  fi
fi
unset NCOMMERCE_TOKEN

write_update_shortcut() {
  local wrapper tmp dir xdg
  wrapper="$INSTALL_DIR/atualizar-terminal.sh"
  sudo tee "$wrapper" >/dev/null <<EOF
#!/bin/bash
cd "$INSTALL_DIR"
./update.sh
status=\$?
echo
if [ "\$status" -eq 0 ]; then
  echo "Atualizacao concluida."
else
  echo "Atualizacao falhou (codigo \$status)."
fi
read -r -p "Pressione Enter para fechar. "
EOF
  sudo chmod 755 "$wrapper"

  tmp="$(mktemp)"
  cat > "$tmp" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=Atualizar NCommerce
Comment=Baixa a versao publicada e recria os containers
Exec=$wrapper
Icon=system-software-update
Terminal=true
Categories=Utility;
EOF
  chmod +x "$tmp"

  # Desktop no Ubuntu em ingles, Area de Trabalho no Ubuntu em portugues.
  # xdg-user-dir aponta para a pasta que o sistema esta usando.
  xdg=""
  if command -v xdg-user-dir >/dev/null 2>&1; then
    xdg="$(xdg-user-dir DESKTOP 2>/dev/null || true)"
  fi
  if [ -n "$xdg" ]; then
    mkdir -p "$xdg"
  fi
  seen=" "
  for dir in "$xdg" "${HOME}/Desktop" "${HOME}/Área de Trabalho"; do
    [ -n "$dir" ] && [ -d "$dir" ] || continue
    case "$seen" in
      *" $dir "*) continue ;;
    esac
    seen="$seen$dir "
    cp "$tmp" "$dir/Atualizar NCommerce.desktop"
    chmod +x "$dir/Atualizar NCommerce.desktop"
    gio set "$dir/Atualizar NCommerce.desktop" metadata::trusted true 2>/dev/null || true
    echo "Atalho: $dir/Atualizar NCommerce.desktop"
  done
  rm -f "$tmp"
}

write_update_shortcut

ip_addr="$(host_lan_ips | cut -d, -f1)"
ip_addr="${ip_addr:-127.0.0.1}"
echo
echo "NCommerce no ar."
echo "  Site:  http://${ip_addr}:4200"
echo "  API:   http://${ip_addr}:3000"
echo "  CUPS:  http://127.0.0.1:${CUPS_PORT}"
echo "  SSH:   ${USER}@${ip_addr} porta 22"
echo "Codigo-fonte em ${INSTALL_DIR}/src (ncommerce_api, ncommerce, nfce)."
echo "Atualizar: atalho Atualizar NCommerce na area de trabalho."
