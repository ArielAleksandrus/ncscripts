#!/bin/bash
# Instalador Docker do NCommerce no Linux.
# Nao use sudo neste arquivo. Ele chama sudo so onde precisa.
# Usa o codigo de 8 caracteres do codigo-instalacao.txt (zip de ncommerce.app/instalar)
# ou pede para digitar. O mestre troca esse codigo, uma vez,
# pelo token da empresa. A maquina recebe so as imagens do registry, sem codigo-fonte.
# Reexecutar nao apaga volume.
#   --ignorar-requisitos  instala num PC abaixo do minimo (suporte, por conta e risco).
#   --backup ARQUIVO.zip  restaura este zip de backup em vez do backup do mestre.
#                         Sem a opcao, o instalador pergunta: arraste o zip para o
#                         terminal ou tecle Enter para usar o do mestre.
set -euo pipefail

IGNORAR_REQUISITOS=0
BACKUP_ZIP_ARG=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --ignorar-requisitos) IGNORAR_REQUISITOS=1 ;;
    --backup)
      [ "$#" -ge 2 ] || { echo "Use: --backup /caminho/ncommerce.zip"; exit 1; }
      BACKUP_ZIP_ARG="$2"
      shift
      ;;
    --backup=*) BACKUP_ZIP_ARG="${1#--backup=}" ;;
    *) echo "Opcao desconhecida: $1"; exit 1 ;;
  esac
  shift
done

ROOT="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="${NCOMMERCE_INSTALL_DIR:-/opt/ncommerce}"
MASTER_URL="${NCOMMERCE_MASTER_URL:-https://ncommerce.app:3001}"
REQUESTED_REGISTRY="${NCOMMERCE_REGISTRY:-}"
REQUESTED_TAG="${NCOMMERCE_TAG:-}"

if [ "$(id -u)" -eq 0 ]; then
  echo "Rode sem sudo. Exemplo: ./instalador_linux.sh"
  exit 1
fi

if [ ! -f "$ROOT/docker/docker-compose.yml" ]; then
  echo "Nao achei $ROOT/docker/docker-compose.yml."
  exit 1
fi

# Sem o Docker Desktop do Windows, MySQL, API e CUPS cabem em 4 GB. Ubuntu 20.04 e o mais
# antigo com Docker Compose v2 nos pacotes da distro. Clock nao e exigido: um processador
# com 4 threads dificilmente e lento demais.
assert_minimum_hardware() {
  local problems=() threads mem_kb version
  if [ -r /etc/os-release ]; then
    . /etc/os-release
    version="${VERSION_ID:-0}"
    if [ "${ID:-}" != "ubuntu" ] || [ "${version%%.*}" -lt 20 ]; then
      problems+=("Ubuntu 20.04 ou mais novo (este e ${PRETTY_NAME:-desconhecido})")
    fi
  fi
  threads="$(nproc 2>/dev/null || echo 0)"
  if [ "$threads" -lt 4 ]; then
    problems+=("processador com 4 threads (este tem $threads)")
  fi
  # Um PC de 4 GB informa menos no MemTotal: kernel, firmware e video integrado reservam ate
  # ~1 GB. 3 GB (3145728 kB) aceita esse PC e barra o de 3 GB ou menos.
  mem_kb="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
  if [ "$mem_kb" -lt 3145728 ]; then
    problems+=("4 GB de RAM (este tem $(awk -v k="$mem_kb" 'BEGIN { printf "%.1f", k / 1048576 }') GB)")
  fi
  if [ "${#problems[@]}" -eq 0 ]; then
    return 0
  fi
  echo "Este computador nao atende o minimo do NCommerce:"
  printf '  - %s\n' "${problems[@]}"
  if [ "$IGNORAR_REQUISITOS" = "1" ]; then
    echo "Seguindo mesmo assim (--ignorar-requisitos)."
    return 0
  fi
  echo "Use um computador com Ubuntu 20.04 ou mais novo, 4 threads e 4 GB de RAM."
  exit 1
}
assert_minimum_hardware

if ! command -v sudo >/dev/null 2>&1; then
  echo "Preciso do sudo."
  exit 1
fi
sudo -v

ensure_base_packages() {
  local missing=() cmd
  for cmd in curl python3 ssh unzip ss hostname; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  if [ "${#missing[@]}" -eq 0 ]; then
    return 0
  fi
  if ! command -v apt-get >/dev/null 2>&1; then
    echo "Faltam comandos: ${missing[*]}. Instale e rode de novo."
    exit 1
  fi
  echo "Instalando curl, python3, ssh, unzip e ss..."
  sudo DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get update
  sudo DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get install -y \
    curl python3 ca-certificates openssh-client unzip iproute2 hostname
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

# AnyDesk para o suporte entrar na tela do cliente. Falha aqui nao para a instalacao.
install_anydesk() {
  if command -v anydesk >/dev/null 2>&1; then
    echo "AnyDesk ja instalado."
    return 0
  fi
  if grep -qi microsoft /proc/version 2>/dev/null; then
    echo "WSL: o AnyDesk vai no Windows. Pulando."
    return 0
  fi
  echo "Instalando o AnyDesk..."
  curl -fsSL https://keys.anydesk.com/repos/DEB-GPG-KEY \
    | sudo gpg --dearmor --yes -o /etc/apt/trusted.gpg.d/anydesk.gpg || return 1
  echo "deb http://deb.anydesk.com/ all main" | sudo tee /etc/apt/sources.list.d/anydesk-stable.list >/dev/null
  sudo DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get update || return 1
  sudo DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get install -y anydesk || return 1
  echo "AnyDesk ID: $(anydesk --get-id 2>/dev/null || echo 'abra o AnyDesk para ver')"
}

install_anydesk || echo "Nao consegui instalar o AnyDesk. Instale depois em https://anydesk.com."

# O suporte pede para o cliente abrir o AnyDesk. Fixado na barra lateral, e so clicar no icone vermelho.
pin_anydesk_to_dock() {
  local apps bus
  command -v gsettings >/dev/null 2>&1 || return 0
  [ -f /usr/share/applications/anydesk.desktop ] || return 0
  bus="/run/user/$(id -u)/bus"
  if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] && [ -S "$bus" ]; then
    export DBUS_SESSION_BUS_ADDRESS="unix:path=$bus"
  fi
  apps="$(gsettings get org.gnome.shell favorite-apps 2>/dev/null)" || return 0
  case "$apps" in
    *"'anydesk.desktop'"*) return 0 ;;
    "@as []"|"[]") apps="['anydesk.desktop']" ;;
    *) apps="${apps%]}, 'anydesk.desktop']" ;;
  esac
  if gsettings set org.gnome.shell favorite-apps "$apps" 2>/dev/null; then
    echo "AnyDesk fixado na barra lateral."
  fi
}

pin_anydesk_to_dock

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

# O zip baixado em ncommerce.app/instalar traz o codigo neste arquivo, para o cliente nao digitar.
code_from_file() {
  local file="$ROOT/codigo-instalacao.txt" code
  [ -f "$file" ] || return 0
  code="$(tr -d '[:space:]-' < "$file" | tr '[:lower:]' '[:upper:]')"
  if printf '%s' "$code" | grep -Eq '^[A-Z0-9]{8}$'; then
    printf '%s' "$code"
  fi
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
  # Codigo recusado volta 1 em vez de sair, para o instalador pedir outro codigo.
  if [ "$http" != "200" ]; then
    echo "Codigo ${code} recusado (HTTP ${http})."
    if [ -s "$body" ]; then
      head -c 500 "$body" >&2 || true
      echo >&2
    fi
    rm -f "$body"
    return 1
  fi
  grant="$(python3 - "$body" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
token = d.get("token") or d.get("ncommerce_token") or ""
company = d.get("company") or ""
registry = d.get("registry") or ""
anydesk_password = d.get("anydesk_password") or ""
if not isinstance(token, str):
    token = ""
if not isinstance(company, str):
    company = ""
if not isinstance(registry, str):
    registry = ""
if not isinstance(anydesk_password, str) or "\n" in anydesk_password:
    anydesk_password = ""
sys.stdout.write("%s\n%s\n%s\n%s" % (token, company, registry, anydesk_password))
PY
)"
  rm -f "$body"
  NCOMMERCE_TOKEN="$(printf '%s\n' "$grant" | sed -n '1p')"
  COMPANY_NAME="$(printf '%s\n' "$grant" | sed -n '2p')"
  REGISTRY_FROM_MASTER="$(printf '%s\n' "$grant" | sed -n '3p')"
  ANYDESK_PASSWORD="$(printf '%s\n' "$grant" | sed -n '4p')"
  if [ -z "${NCOMMERCE_TOKEN}" ]; then
    echo "A resposta do mestre nao trouxe o token do ncommerce."
    exit 1
  fi
  if [ -z "${COMPANY_NAME}" ]; then
    echo "A resposta do mestre nao trouxe o nome da empresa para entrar no registry."
    exit 1
  fi
}

# Caminho de um arquivo arrastado para o terminal. O GNOME Terminal cola
# '/caminho com espaco/x.zip' entre aspas e com espaco no fim; outros terminais
# escapam os espacos (\ ) ou colam file:///caminho%20x.zip.
normalize_dropped_path() {
  python3 -c '
import sys, urllib.parse
p = sys.argv[1].strip()
if len(p) >= 2 and p[0] == p[-1] and p[0] in "\x27\x22":
    p = p[1:-1]
elif p.startswith("file://"):
    p = urllib.parse.unquote(p[len("file://"):])
else:
    p = p.replace("\\ ", " ")
sys.stdout.write(p)
' "$1"
}

# Um zip de backup do NCommerce desta empresa: criptografado com os 6 primeiros
# caracteres do token (o backup.sh grava assim), abre com eles e traz o backup.sql.
# Escreve o motivo quando o zip nao serve; nada quando serve.
backup_zip_problem() {
  local zip="$1" pass="${NCOMMERCE_TOKEN:0:6}"
  if [ ! -f "$zip" ]; then
    echo "Nao achei o arquivo ${zip}."
  elif [ ! -r "$zip" ]; then
    echo "Sem permissao para ler ${zip}."
  elif ! unzip -Z1 "$zip" >/dev/null 2>&1; then
    echo "${zip} nao e um arquivo zip."
  elif ! unzip -Z1 "$zip" 2>/dev/null | grep -qx 'backup.sql'; then
    echo "${zip} nao e um backup do NCommerce: falta o backup.sql."
  elif unzip -tqq -P "nao-e-a-senha-$$" "$zip" >/dev/null 2>&1; then
    echo "${zip} nao esta criptografado. Backup do NCommerce sempre vem com senha."
  elif ! unzip -tqq -P "$pass" "$zip" >/dev/null 2>&1; then
    echo "${zip} nao abre com o token desta empresa${COMPANY_NAME:+ (${COMPANY_NAME})}: e backup de outra empresa ou esta corrompido."
  fi
}

# Backup que a instalacao restaura: o zip de --backup, um zip arrastado para o
# terminal ou, sem nenhum, o do mestre (BACKUP_ZIP fica vazio).
BACKUP_ZIP=""
choose_backup_zip() {
  local raw path problem
  if [ -n "$BACKUP_ZIP_ARG" ]; then
    path="$(normalize_dropped_path "$BACKUP_ZIP_ARG")"
    problem="$(backup_zip_problem "$path")"
    if [ -n "$problem" ]; then
      echo "$problem"
      exit 1
    fi
    BACKUP_ZIP="$(readlink -f "$path")"
    echo "Backup avulso valido: ${BACKUP_ZIP}."
    return 0
  fi
  [ -r /dev/tty ] || return 0
  echo
  echo "Backup: para restaurar um zip de backup avulso, arraste o arquivo para esta janela e tecle Enter."
  echo "Para usar o backup guardado no servidor, so tecle Enter."
  while true; do
    read -r -p "Zip de backup (Enter = servidor): " raw < /dev/tty || raw=""
    path="$(normalize_dropped_path "$raw")"
    if [ -z "$path" ]; then
      echo "Usando o backup do servidor."
      return 0
    fi
    problem="$(backup_zip_problem "$path")"
    if [ -z "$problem" ]; then
      BACKUP_ZIP="$(readlink -f "$path")"
      echo "Backup avulso valido: ${BACKUP_ZIP}."
      return 0
    fi
    echo "$problem"
    echo "Arraste outro zip, ou tecle Enter para usar o backup do servidor."
  done
}

# Um zip avulso entra no lugar do backup do mestre. Escolhido de proposito,
# ele e restaurado mesmo numa maquina que ja restaurou um backup antes.
use_backup_zip() {
  local dest="$INSTALL_DIR/ncommerce.zip"
  sudo mkdir -p "$INSTALL_DIR"
  if [ "$(readlink -f "$dest" 2>/dev/null || true)" != "$BACKUP_ZIP" ]; then
    sudo cp "$BACKUP_ZIP" "$dest"
  fi
  sudo chown "$USER:$USER" "$dest" 2>/dev/null || true
  sudo rm -f "$INSTALL_DIR/.backup-restored"
  echo "Backup avulso copiado para ${dest}."
}

# Instalacao nativa antiga nesta maquina (nginx + Passenger em ~/NCommerce).
# Tirar so os sites do nginx nao basta: o Sidekiq e o tunel SSH nativos sao
# processos soltos e continuariam buscando pedidos do iFood, falando com o
# mestre com o mesmo token e segurando as portas do tunel. Quem desliga e o
# tools/desligar_nativo.sh, que anota tudo para o tools/religar_nativo.sh
# voltar a loja nativa se a migracao der errado.
native_install_present() {
  local site pid
  for site in ncommerce ncommerce-api; do
    if [ -e "/etc/nginx/sites-enabled/$site" ]; then return 0; fi
  done
  for pid in $(pgrep -f '^sidekiq [0-9]|^ssh .*-R .*tunnel[.]nlabs[.]live' 2>/dev/null || true); do
    if ! grep -qE 'docker|containerd' "/proc/$pid/cgroup" 2>/dev/null; then return 0; fi
  done
  if crontab -l 2>/dev/null | grep -qiE 'ncommerce|nfce'; then return 0; fi
  if sudo crontab -l 2>/dev/null | grep -qiE 'ncommerce|nfce'; then return 0; fi
  return 1
}
stop_native_install() {
  native_install_present || return 0
  echo "Achei uma instalacao nativa do NCommerce. Desligando para o Docker assumir"
  echo "(para voltar a loja nativa: tools/religar_nativo.sh):"
  if ! bash "$ROOT/tools/desligar_nativo.sh"; then
    echo "Nao consegui desligar a instalacao nativa. Confira o que ficou no ar e rode de novo."
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

# Impressoras, drivers (.ppd) e filtros do backup no CUPS do container. A imagem
# traz o ncommerce-restore-cups, que para o cupsd, troca os arquivos e religa.
# Imagem antiga sem ele: so o printers.conf, como antes. Falha aqui nao para a
# instalacao: as impressoras podem ser configuradas de novo pela web do CUPS.
restore_printers() {
  local work="$1" f files=()
  for f in printers.conf cups_ppd.tar.gz cups_filters.tar.gz; do
    if [ -f "$work/$f" ]; then files+=("$f"); fi
  done
  [ "${#files[@]}" -gt 0 ] || return 0
  if sudo docker compose exec -T api sh -c 'command -v ncommerce-restore-cups' >/dev/null 2>&1 < /dev/null; then
    sudo docker compose exec -T api sh -c 'rm -rf /tmp/ncommerce-cups && mkdir -p /tmp/ncommerce-cups' < /dev/null || true
    for f in "${files[@]}"; do
      sudo docker compose cp "$work/$f" "api:/tmp/ncommerce-cups/$f" || true
    done
    sudo docker compose exec -T api sh -c 'ncommerce-restore-cups /tmp/ncommerce-cups; s=$?; rm -rf /tmp/ncommerce-cups; exit $s' < /dev/null \
      || echo "Nao restaurei todas as impressoras. Configure as que faltarem em http://127.0.0.1:${CUPS_PORT:-631}."
  elif [ -f "$work/printers.conf" ]; then
    sudo docker compose cp "$work/printers.conf" api:/etc/cups/printers.conf || true
  fi
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
    "CREATE DATABASE IF NOT EXISTS ncommerce_api_production CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" \
    < /dev/null
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
  # backup/ guarda os XML dos meses anteriores, que o relatorio de impostos le.
  for part in essentials notas_output backup notas_compra notas_input notas_log; do
    if [ -d "$work/$part" ]; then
      sudo docker compose cp "$work/$part" api:/data/nfce/ || true
    fi
  done
  # Segundo CNPJ: a pasta inteira, com o .last_id que numera as notas dele.
  if [ -f "$work/nfce_ext.zip" ]; then
    mkdir -p "$work/nfce_ext"
    unzip -o "$work/nfce_ext.zip" -d "$work/nfce_ext" >/dev/null
    sudo docker compose exec -T api mkdir -p /data/nfce/externo < /dev/null || true
    sudo docker compose cp "$work/nfce_ext/." api:/data/nfce/externo/ || true
  fi
  restore_printers "$work"
  # Plugins voltam para Documentos/ncommerce/plugins; a API so carrega ao subir.
  if [ -f "$work/plugins.zip" ]; then
    unzip -o "$work/plugins.zip" -d "$PLUGINS_DIR" >/dev/null
    echo "Plugins restaurados em ${PLUGINS_DIR}."
    sudo docker compose restart api
    wait_api_up
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
    raw="$(sudo docker compose exec -T api sh -c 'if [ -f /env/.env.production ]; then grep -m1 "^NCOMMERCE_SERVER_TOKEN=" /env/.env.production || true; else echo __NOFILE__; fi' < /dev/null 2>/dev/null || echo __EXEC_FAIL__)"
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
# Documentos do usuario (Documentos ou Documents, conforme o idioma). O compose monta
# Documentos/ncommerce/plugins em app/lib/plugins: quem tem plugin copia o arquivo para la.
prepare_plugins_dir() {
  local docs=""
  if command -v xdg-user-dir >/dev/null 2>&1; then
    docs="$(xdg-user-dir DOCUMENTS 2>/dev/null || true)"
  fi
  # Sem pasta configurada o xdg-user-dir responde a HOME.
  if [ -z "$docs" ] || [ "$docs" = "$HOME" ]; then
    if [ -d "$HOME/Documentos" ]; then docs="$HOME/Documentos"; else docs="$HOME/Documents"; fi
  fi
  PLUGINS_DIR="$docs/ncommerce/plugins"
  mkdir -p "$PLUGINS_DIR"
  cat > "$docs/ncommerce/LEIA-ME.txt" <<'EOF'
Plugins do NCommerce

Copie o arquivo do plugin (.rb) para a pasta plugins, ao lado deste arquivo.
Depois entre como admin e use o botao Reiniciar NCommerce em
Configuracoes > Empresa. O plugin entra no backup da loja.
EOF
}

# Fuso do host, para o container emitir a NFC-e no mesmo horario.
host_timezone() {
  local tz=""
  tz="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
  if [ -z "$tz" ] && [ -f /etc/timezone ]; then tz="$(cat /etc/timezone)"; fi
  if [ -z "$tz" ]; then tz="$(readlink -f /etc/localtime 2>/dev/null | sed -n 's#^/usr/share/zoneinfo/##p')"; fi
  echo "${tz:-America/Sao_Paulo}"
}

# Espera a API responder de novo depois de um restart do container.
wait_api_up() {
  local i
  for i in $(seq 1 60); do
    if [ "$(api_setup /dev/null)" = "200" ]; then return 0; fi
    sleep 3
  done
  echo "A API demorou para voltar depois de carregar os plugins."
}

api_setup() {
  local dest="$1"
  curl -sS -o "$dest" -w "%{http_code}" -m 5 \
    -H "Host: localhost" \
    "http://127.0.0.1:3000/api/v1/docker_setup" 2>/dev/null || true
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

# Senha do acesso nao supervisionado. E a mesma em todos os clientes, por isso vem
# do mestre no resgate do codigo e nao fica escrita neste arquivo nem no disco.
set_anydesk_password() {
  if [ -z "${ANYDESK_PASSWORD:-}" ] || ! command -v anydesk >/dev/null 2>&1; then
    return 0
  fi
  local out
  sudo -v
  if out="$(printf '%s' "$ANYDESK_PASSWORD" | sudo anydesk --set-password 2>&1)"; then
    echo "Acesso nao supervisionado do AnyDesk configurado."
  else
    echo "Nao consegui configurar a senha do AnyDesk (saida $?): ${out:-sem mensagem}"
  fi
}

# No boot o systemd grava o ID do AnyDesk em $INSTALL_DIR/host. A API manda ao mestre.
install_anydesk_id_service() {
  sudo cp "$ROOT/docker/anydesk-id.sh" "$INSTALL_DIR/anydesk-id.sh"
  sudo chmod 755 "$INSTALL_DIR/anydesk-id.sh"
  sudo mkdir -p "$INSTALL_DIR/host"
  sudo tee /etc/systemd/system/ncommerce-anydesk-id.service >/dev/null <<EOF
[Unit]
Description=Grava o ID do AnyDesk para o NCommerce
After=anydesk.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$INSTALL_DIR/anydesk-id.sh $INSTALL_DIR

[Install]
WantedBy=multi-user.target
EOF
  sudo systemctl daemon-reload
  sudo systemctl enable ncommerce-anydesk-id.service >/dev/null 2>&1 || true
  sudo "$INSTALL_DIR/anydesk-id.sh" "$INSTALL_DIR" || true
}

CODE="$(code_from_file)"
if [ -n "$CODE" ]; then
  echo "Usando o codigo de instalacao $CODE do arquivo codigo-instalacao.txt."
fi
if [ -z "$CODE" ] || ! redeem "$CODE"; then
  if [ -n "$CODE" ]; then
    echo "Peca um codigo novo ao suporte e digite abaixo."
  fi
  CODE="$(read_code)"
  redeem "$CODE" || exit 1
fi
set_anydesk_password
unset ANYDESK_PASSWORD
choose_backup_zip
stop_native_install
# Instaladores antigos clonavam o codigo-fonte em src/. A stack roda das
# imagens e nada usa essa pasta.
if [ -d "$INSTALL_DIR/src" ]; then
  sudo rm -rf "$INSTALL_DIR/src"
fi

if ! command -v docker >/dev/null 2>&1 || ! sudo docker compose version >/dev/null 2>&1; then
  echo "Instalando Docker Engine..."
  if command -v apt-get >/dev/null 2>&1; then
    sudo DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get update
    sudo DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get install -y docker.io docker-compose-v2 \
      || sudo DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get install -y docker.io || true
  fi
fi

if ! command -v docker >/dev/null 2>&1 || ! sudo docker compose version >/dev/null 2>&1; then
  echo "O pacote da distro nao trouxe o Docker Compose. Usando https://get.docker.com ..."
  curl -fsSL https://get.docker.com | sudo sh
fi

if ! sudo docker compose version >/dev/null 2>&1; then
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

prepare_plugins_dir
sudo mkdir -p "$INSTALL_DIR"
sudo cp "$ROOT/docker/docker-compose.yml" "$INSTALL_DIR/docker-compose.yml"
sudo cp "$ROOT/docker/docker-compose.usb.yml" "$INSTALL_DIR/docker-compose.usb.yml"
sudo cp "$ROOT/docker/update.sh" "$INSTALL_DIR/update.sh"
sudo cp "$ROOT/docker/host-ips.sh" "$INSTALL_DIR/host-ips.sh"
sudo cp "$ROOT/docker/update-host.sh" "$INSTALL_DIR/update-host.sh"
sudo cp "$ROOT/docker/guard.sh" "$INSTALL_DIR/guard.sh"
sudo cp "$ROOT/docker/rollback.sh" "$INSTALL_DIR/rollback.sh"
sudo cp "$ROOT/docker/net-check.sh" "$INSTALL_DIR/net-check.sh"
sudo chmod 755 "$INSTALL_DIR/update.sh" "$INSTALL_DIR/update-host.sh" "$INSTALL_DIR/guard.sh" "$INSTALL_DIR/rollback.sh" \
  "$INSTALL_DIR/net-check.sh"
sudo mkdir -p "$INSTALL_DIR/control"
install_anydesk_id_service
# Conflito de IP na rede da loja, para o chat de suporte (host/net_check).
sudo "$INSTALL_DIR/net-check.sh" --install "$INSTALL_DIR" || true
sudo tee "$INSTALL_DIR/.env" >/dev/null <<EOF
CUPS_PORT=${CUPS_PORT}
NCOMMERCE_REGISTRY=${REGISTRY}
NCOMMERCE_TAG=${TAG}
COMPOSE_FILE=docker-compose.yml:docker-compose.usb.yml
NCOMMERCE_PLUGINS_DIR=${PLUGINS_DIR}
TZ=$(host_timezone)
EOF
sudo chmod 644 "$INSTALL_DIR/.env" "$INSTALL_DIR/docker-compose.yml" "$INSTALL_DIR/docker-compose.usb.yml" "$INSTALL_DIR/host-ips.sh"

# A impressora USB passa a ser do CUPS do container. Uma fila USB no CUPS do host disputa o aparelho.
# O system-config-printer-udev cria essa fila sozinho quando a impressora e plugada. O link para
# /dev/null anula a regra dele; o CUPS do host continua ligado.
sudo ln -sfn /dev/null /etc/udev/rules.d/70-printers.rules
sudo udevadm control --reload || true
host_usb_queues="$(lpstat -v 2>/dev/null | grep -E 'usb://' || true)"
if [ -n "$host_usb_queues" ]; then
  echo "O CUPS do Ubuntu tem fila USB. Remova com lpadmin -x <fila> e cadastre a impressora no CUPS do container:"
  echo "$host_usb_queues"
fi

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

if [ -n "$BACKUP_ZIP" ]; then
  use_backup_zip
else
  download_backup "$CODE"
fi
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
  for dir in "$xdg" "${HOME}/Desktop" "${HOME}/Área de Trabalho" "${HOME}/Área de trabalho"; do
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
echo "Atualizar: atalho Atualizar NCommerce na area de trabalho."
