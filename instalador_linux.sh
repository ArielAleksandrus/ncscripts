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
#   --reinstalar          pede o codigo de novo mesmo com a loja ja instalada.
#
# Pode ser interrompido em qualquer ponto (janela fechada, Ctrl+C, queda de
# energia) e rodado de novo: cada etapa confere o que ja existe antes de fazer.
# O progresso fica em ~/.ncommerce-docker/instalacao.estado e o log de cada
# execucao em ~/ncommerce-logs/. Num computador com a loja ja instalada ele so
# confere e conserta, sem pedir codigo e sem tocar nos dados.
set -Eeuo pipefail

IGNORAR_REQUISITOS=0
BACKUP_ZIP_ARG=""
REINSTALAR=0
RETOMADA=0
ORIG_ARGS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --ignorar-requisitos) IGNORAR_REQUISITOS=1; ORIG_ARGS+=("$1") ;;
    --backup)
      [ "$#" -ge 2 ] || { echo "Use: --backup /caminho/ncommerce.zip"; exit 1; }
      BACKUP_ZIP_ARG="$2"
      shift
      ;;
    --backup=*) BACKUP_ZIP_ARG="${1#--backup=}" ;;
    --reinstalar) REINSTALAR=1; ORIG_ARGS+=("$1") ;;
    # Uso interno: o atalho de retomada chama assim depois de uma queda de energia.
    --retomada) RETOMADA=1 ;;
    -h|--help|--ajuda) sed -n '2,19p' "$0"; exit 0 ;;
    *) echo "Opcao desconhecida: $1"; exit 1 ;;
  esac
  shift
done

ROOT="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="${NCOMMERCE_INSTALL_DIR:-/opt/ncommerce}"
MASTER_URL="${NCOMMERCE_MASTER_URL:-https://api.ncommerce.app}"
REQUESTED_REGISTRY="${NCOMMERCE_REGISTRY:-}"
REQUESTED_TAG="${NCOMMERCE_TAG:-}"
DEFAULT_REGISTRY="registry.ncommerce.app:5050"
OLD_REGISTRY="ncommerce.app:5050"
STATE_DIR="$HOME/.ncommerce-docker"
LOG_DIR="$HOME/ncommerce-logs"
AUTOSTART_FILE="$HOME/.config/autostart/ncommerce-instalador.desktop"
RESUME_SCRIPT="$STATE_DIR/retomar-instalacao.sh"
MAX_AUTO_RESUMES=3

if [ "$(id -u)" -eq 0 ]; then
  echo "Rode sem sudo. Exemplo: ./instalador_linux.sh"
  exit 1
fi

# Quem abre o instalador de dentro do zip (sem extrair) recebe so este arquivo.
for needed in lib/instalador.sh docker/docker-compose.yml docker/update.sh docker/guard.sh tools/desligar_nativo.sh; do
  if [ ! -f "$ROOT/$needed" ]; then
    echo "Nao achei $ROOT/$needed."
    echo "Extraia o zip do instalador inteiro (botao direito no zip > Extrair aqui) e rode de novo de dentro da pasta extraida."
    exit 1
  fi
done

# shellcheck source=lib/instalador.sh
. "$ROOT/lib/instalador.sh"

NC_STEP_TOTAL=10
NC_VERDICT=""
NC_FAIL_MSG=""
NC_FAIL_HINT=""
NC_SIGNAL=""
WORK=""
KEEPALIVE_PID=""
INHIBIT_PID=""
MODE="instalacao"
STORE_ALREADY_LIVE=0
NATIVE_STOPPED_NOW=0
APT_UPDATED=0
CODE=""
NCOMMERCE_TOKEN=""
COMPANY_NAME=""
REGISTRY_FROM_MASTER=""
ANYDESK_PASSWORD=""
BACKUP_ZIP=""
PLUGINS_DIR=""
CUPS_PORT=631
REGISTRY=""
TAG=""

# Para a instalacao com um motivo e o que fazer. Nao use dentro de $(...).
fail() {
  NC_FAIL_MSG="$1"
  NC_FAIL_HINT="${2:-}"
  exit 1
}

print_failure() {
  local rc="$1"
  echo
  echo "=================================================================="
  if [ -n "$NC_SIGNAL" ]; then
    echo "  A INSTALACAO FOI INTERROMPIDA (janela fechada ou Ctrl+C)."
  else
    echo "  A INSTALACAO NAO TERMINOU."
  fi
  echo "=================================================================="
  if [ "$NC_STEP_NOW" -gt 0 ]; then
    echo "Parou na etapa $NC_STEP_NOW de $NC_STEP_TOTAL: $NC_STEP_TITLE."
  fi
  if [ -n "$NC_FAIL_MSG" ]; then
    echo "O que aconteceu: $NC_FAIL_MSG"
  elif [ -z "$NC_SIGNAL" ]; then
    echo "O que aconteceu: um comando falhou (codigo $rc). O detalhe esta no arquivo de log."
  fi
  if [ -n "$NC_FAIL_HINT" ]; then
    echo "O que fazer: $NC_FAIL_HINT"
  else
    echo "O que fazer: rode o instalador de novo. Ele continua de onde parou e nao apaga nada."
  fi
  if [ -n "$NC_LOG_FILE" ]; then
    echo "Se parar de novo no mesmo ponto, mande este arquivo para o suporte NCommerce:"
    echo "  $NC_LOG_FILE"
  fi
}

# A loja nativa foi desligada nesta execucao e o Docker nao assumiu: volta a
# nativa, para a loja nao ficar sem nenhuma das duas.
restore_native_after_failure() {
  [ "$NATIVE_STOPPED_NOW" = "1" ] || return 0
  NATIVE_STOPPED_NOW=0
  if [ "$NC_SIGNAL" = "HUP" ]; then
    echo "A loja antiga (sem Docker) ficou desligada. Rode o instalador de novo para terminar,"
    echo "ou $ROOT/tools/religar_nativo.sh para voltar a loja antiga."
    return 0
  fi
  echo
  echo "O Docker nao assumiu a loja. Religando a instalacao antiga (sem Docker)..."
  if bash "$ROOT/tools/religar_nativo.sh"; then
    # O que foi restaurado no Docker ficou velho: a loja antiga volta a vender.
    sudo rm -f "$INSTALL_DIR/.backup-restored" 2>/dev/null || true
    echo "A loja antiga esta no ar de novo. Nada foi perdido."
  else
    echo "NAO consegui religar a loja antiga. Chame o suporte NCommerce agora."
    echo "Comando para tentar de novo: $ROOT/tools/religar_nativo.sh"
  fi
}

on_exit() {
  local rc=$?
  trap - EXIT ERR INT TERM HUP
  set +e
  if [ "$NC_VERDICT" != "ok" ] && [ "$NC_VERDICT" != "quiet" ]; then
    if [ "$rc" -eq 0 ]; then rc=1; fi
    restore_native_after_failure
    print_failure "$rc"
  fi
  [ -n "$KEEPALIVE_PID" ] && kill "$KEEPALIVE_PID" 2>/dev/null
  [ -n "$INHIBIT_PID" ] && kill "$INHIBIT_PID" 2>/dev/null
  [ -n "$WORK" ] && rm -rf "$WORK"
  lock_release
  log_stop
  exit "$rc"
}

on_err() {
  # So o texto do comando, sem os valores das variaveis: token e senha nao vao para o log.
  echo "[erro] linha $1: $2" >&2
}

# ============================================================ inicio

mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR" 2>/dev/null || true

if ! lock_acquire "$STATE_DIR/instalador.lock"; then
  echo "O instalador do NCommerce ja esta aberto em outra janela (ou uma atualizacao esta rodando)."
  echo "Espere ela terminar. Esta janela pode ser fechada."
  exit 2
fi

log_start "$LOG_DIR" instalacao || { echo "Nao consegui criar o log em $LOG_DIR. Sigo sem ele."; NC_LOG_FILE=""; }
trap on_exit EXIT
trap 'on_err "$LINENO" "$BASH_COMMAND"' ERR
trap 'NC_SIGNAL=INT; exit 130' INT
trap 'NC_SIGNAL=TERM; exit 143' TERM
trap 'NC_SIGNAL=HUP; exit 129' HUP

state_init "$STATE_DIR/instalacao.estado"
WORK="$(mktemp -d)"
chmod 700 "$WORK"

echo "=================================================================="
echo "  INSTALADOR DO NCOMMERCE"
echo "=================================================================="
echo "Sao $NC_STEP_TOTAL etapas e leva de 10 a 40 minutos, conforme a internet."
echo "NAO FECHE ESTA JANELA e nao desligue o computador ate aparecer o resultado."
echo "Se a instalacao parar por qualquer motivo, e so rodar de novo: ela continua."
if [ -n "$NC_LOG_FILE" ]; then
  echo "Log desta instalacao: $NC_LOG_FILE"
fi
{
  echo "[info] instalador v2, $(date '+%Y-%m-%d %H:%M:%S %z'), pasta $ROOT"
  echo "[info] $(uname -srm); $(. /etc/os-release 2>/dev/null && printf '%s' "${PRETTY_NAME:-}")"
} >> "${NC_LOG_FILE:-/dev/null}" 2>/dev/null || true

state_set versao_instalador 2
state_set ultima_execucao "$(date +%s)"
state_set tentativas "$(( $(state_get tentativas || echo 0) + 1 ))"

# ============================================================ ajudantes

apt_get() {
  sudo DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get \
    -o DPkg::Lock::Timeout=600 -o Acquire::Retries=3 "$@"
}

# Uma fonte de pacotes quebrada (comum em PC reaproveitado) faz o update sair
# com erro mesmo quando o que precisamos esta disponivel. So avisa.
apt_update_once() {
  [ "$APT_UPDATED" = "0" ] || return 0
  APT_UPDATED=1
  apt_get update || echo "O apt-get update avisou de erro em alguma fonte de pacotes. Sigo."
}

# Instalacao de pacote interrompida (janela fechada, queda de energia) deixa o
# dpkg pela metade, e todo apt-get seguinte falha ate alguem consertar.
apt_repair() {
  if [ -n "$(sudo dpkg --audit 2>/dev/null)" ]; then
    echo "Terminando uma instalacao de pacotes que ficou pela metade..."
    sudo DEBIAN_FRONTEND=noninteractive dpkg --configure -a || true
    apt_get -f install -y || true
  fi
}

apt_install() {
  apt_update_once
  if apt_get install -y "$@"; then return 0; fi
  echo "A instalacao dos pacotes falhou. Consertando e tentando mais uma vez..."
  apt_repair
  APT_UPDATED=0
  apt_update_once
  apt_get install -y "$@"
}

# Mantem o sudo valido durante os downloads longos, para nao pedir a senha de
# novo com a pessoa longe do computador.
start_sudo_keepalive() {
  ( while sudo -n -v 2>/dev/null; do sleep 50; done ) >/dev/null 2>&1 8>&- &
  KEEPALIVE_PID=$!
}

# Impede o computador de dormir no meio da instalacao.
start_sleep_inhibit() {
  command -v systemd-inhibit >/dev/null 2>&1 || return 0
  systemd-inhibit --what=sleep:idle:handle-lid-switch --who="NCommerce" \
    --why="Instalando o NCommerce" --mode=block sleep 86400 >/dev/null 2>&1 8>&- &
  INHIBIT_PID=$!
}

is_wsl() { grep -qi microsoft /proc/version 2>/dev/null; }

has_desktop() {
  ! is_wsl && [ -n "${XDG_CURRENT_DESKTOP:-}${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]
}

# Depois de uma queda de energia ninguem lembra de abrir o instalador de novo.
# Este atalho abre um terminal com ele no proximo login. Sai quando a
# instalacao termina, ou depois de MAX_AUTO_RESUMES tentativas.
register_resume_trigger() {
  has_desktop || return 0
  local arg quoted=""
  for arg in "${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}"; do
    quoted="$quoted $(printf '%q' "$arg")"
  done
  cat > "$RESUME_SCRIPT.tmp" <<EOF
#!/bin/bash
# Criado pelo instalador do NCommerce. Some sozinho quando a instalacao termina.
installer=$(printf '%q' "$ROOT/instalador_linux.sh")
if [ ! -f "\$installer" ]; then
  rm -f $(printf '%q' "$AUTOSTART_FILE") "\$0"
  exit 0
fi
echo "A instalacao do NCommerce nao terminou da ultima vez. Continuando..."
bash "\$installer" --retomada$quoted
echo
read -r -p "Pressione Enter para fechar. " _ || true
EOF
  chmod 700 "$RESUME_SCRIPT.tmp"
  mv -f "$RESUME_SCRIPT.tmp" "$RESUME_SCRIPT"
  mkdir -p "$(dirname "$AUTOSTART_FILE")"
  cat > "$AUTOSTART_FILE.tmp" <<EOF
[Desktop Entry]
Type=Application
Name=Continuar a instalacao do NCommerce
Exec="$RESUME_SCRIPT"
Terminal=true
X-GNOME-Autostart-enabled=true
EOF
  mv -f "$AUTOSTART_FILE.tmp" "$AUTOSTART_FILE"
}

clear_resume_trigger() {
  rm -f "$AUTOSTART_FILE" "$AUTOSTART_FILE.tmp" "$RESUME_SCRIPT" "$RESUME_SCRIPT.tmp"
  state_unset retomadas || true
}

port_busy() {
  ss -ltn 2>/dev/null | grep -Eq ":$1([^0-9]|$)"
}

# Nome do programa que escuta na porta (precisa de root para ver o dos outros).
port_owner() {
  sudo ss -ltnp 2>/dev/null | grep -E ":$1[[:space:]]" | sed -n 's/.*users:(("\([^"]*\)".*/\1/p' | head -n 1
}

compose() { sudo docker compose "$@"; }

# A imagem publicada responde 403 para Host 127.0.0.1. localhost esta permitido.
# Conectamos no IP e enviamos esse Host, senao o curl -f desiste e o token nao e gravado.
api_setup() {
  local dest="$1"
  curl -sS -o "$dest" -w "%{http_code}" -m 5 \
    -H "Host: localhost" \
    "http://127.0.0.1:3000/api/v1/docker_setup" 2>/dev/null || true
}

# Espera a API responder. wait_api_up SEGUNDOS
wait_api_up() {
  local limit="$1" waited=0 http=""
  while [ "$waited" -lt "$limit" ]; do
    http="$(api_setup /dev/null)"
    if [ "$http" = "200" ]; then return 0; fi
    if [ "$waited" -gt 0 ] && [ $((waited % 30)) -eq 0 ]; then
      echo "  ainda esperando o sistema responder (${waited}s de ate ${limit}s)..."
    fi
    sleep 5
    waited=$((waited + 5))
  done
  return 1
}

# O token fica em /env/.env.production, no volume da API. Da para ler isso
# enquanto o Rails ainda roda db:prepare e a porta 3000 nao responde.
token_already_on_volume() {
  local tries="${1:-15}" i raw value
  for ((i = 1; i <= tries; i++)); do
    raw="$(compose exec -T api sh -c 'if [ -f /env/.env.production ]; then grep -m1 "^NCOMMERCE_SERVER_TOKEN=" /env/.env.production || true; else echo __NOFILE__; fi' < /dev/null 2>/dev/null || echo __EXEC_FAIL__)"
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
        [ "$i" -lt "$tries" ] && sleep 1
        ;;
    esac
  done
  return 1
}

# O mesmo, com a API parada: le o volume api_env direto, com uma imagem que ja
# esta no computador.
token_on_stopped_volume() {
  local project volume image
  project="$(basename "$INSTALL_DIR" | tr '[:upper:]' '[:lower:]')"
  volume="$(sudo docker volume ls -q --filter "label=com.docker.compose.project=$project" \
    --filter "label=com.docker.compose.volume=api_env" 2>/dev/null | head -n 1)"
  [ -n "$volume" ] || return 1
  for image in redis:7-alpine docker:27.5.1-cli mysql:8.0; do
    if sudo docker image inspect "$image" >/dev/null 2>&1; then
      sudo docker run --rm --network none --entrypoint sh -v "$volume:/env:ro" "$image" \
        -c 'grep -q "^NCOMMERCE_SERVER_TOKEN=..*" /env/.env.production' >/dev/null 2>&1 < /dev/null
      return
    fi
  done
  return 1
}

docker_usable() {
  command -v docker >/dev/null 2>&1 && sudo docker info >/dev/null 2>&1 && sudo docker compose version >/dev/null 2>&1
}

# A loja ja foi instalada e configurada neste computador?
store_already_installed() {
  docker_usable || return 1
  [ -f "$INSTALL_DIR/docker-compose.yml" ] && [ -f "$INSTALL_DIR/.env" ] || return 1
  if (cd "$INSTALL_DIR" && token_already_on_volume 1); then return 0; fi
  token_on_stopped_volume
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

# ============================================================ etapa 1

# Sem o Docker Desktop do Windows, MySQL, API e CUPS cabem em 4 GB. Ubuntu 20.04 e o mais
# antigo com Docker Compose v2 nos pacotes da distro. Clock nao e exigido: um processador
# com 4 threads dificilmente e lento demais.
check_computer() {
  local problems=() os_id os_version os_name major threads mem_kb arch dir free_kb need_kb host i ok
  os_id="$(. /etc/os-release 2>/dev/null && printf '%s' "${ID:-}")" || true
  os_version="$(. /etc/os-release 2>/dev/null && printf '%s' "${VERSION_ID:-0}")" || true
  os_name="$(. /etc/os-release 2>/dev/null && printf '%s' "${PRETTY_NAME:-desconhecido}")" || true
  major="${os_version%%.*}"
  case "$major" in ""|*[!0-9]*) major=0 ;; esac
  if [ "$os_id" != "ubuntu" ] || [ "$major" -lt 20 ]; then
    problems+=("Ubuntu 20.04 ou mais novo (este e ${os_name:-desconhecido})")
  fi
  arch="$(uname -m)"
  if [ "$arch" != "x86_64" ]; then
    problems+=("processador de 64 bits Intel ou AMD (este e $arch)")
  fi
  threads="$(nproc 2>/dev/null || echo 0)"
  if [ "$threads" -lt 4 ]; then
    problems+=("processador com 4 threads (este tem $threads)")
  fi
  # Um PC de 4 GB informa menos no MemTotal: kernel, firmware e video integrado reservam ate
  # ~1 GB. 3 GB (3145728 kB) aceita esse PC e barra o de 3 GB ou menos.
  mem_kb="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
  if [ "${mem_kb:-0}" -lt 3145728 ]; then
    problems+=("4 GB de RAM (este tem $(awk -v k="${mem_kb:-0}" 'BEGIN { printf "%.1f", k / 1048576 }') GB)")
  fi
  # As imagens e o banco ficam em /var/lib/docker. Loja ja instalada so precisa
  # de folga para atualizar.
  dir=/var/lib/docker
  while [ ! -d "$dir" ]; do dir="$(dirname "$dir")"; done
  free_kb="$(df -Pk "$dir" 2>/dev/null | awk 'NR == 2 { print $4 }')"
  need_kb=10485760
  if [ -f "$INSTALL_DIR/.env" ]; then need_kb=3145728; fi
  if [ -n "$free_kb" ] && [ "$free_kb" -lt "$need_kb" ]; then
    problems+=("$((need_kb / 1048576)) GB livres no disco (este tem $(awk -v k="$free_kb" 'BEGIN { printf "%.1f", k / 1048576 }') GB livres em $dir)")
  fi

  if [ "${#problems[@]}" -gt 0 ]; then
    echo "Este computador nao atende o minimo do NCommerce. Falta:"
    printf '  - %s\n' "${problems[@]}"
    if [ "$IGNORAR_REQUISITOS" = "1" ]; then
      echo "Seguindo mesmo assim (--ignorar-requisitos)."
    else
      fail "este computador esta abaixo do minimo: ${problems[0]}." \
        "use um computador com Ubuntu 20.04 ou mais novo, 4 threads, 4 GB de RAM e 10 GB livres no disco. Rodar de novo neste nao resolve."
    fi
  else
    echo "Sistema, processador, memoria e disco: ok."
  fi

  if [ ! -d /run/systemd/system ]; then
    fail "este Linux nao usa o systemd (WSL sem systemd ou container)." \
      "o NCommerce precisa de um Ubuntu instalado no computador. No Windows use o InstaladorWindows.bat."
  fi
  if ! command -v sudo >/dev/null 2>&1; then
    fail "este Linux nao tem o comando sudo." "chame o suporte NCommerce."
  fi
  echo "Digite a senha deste computador se ela for pedida (ela nao aparece enquanto voce digita)."
  if ! sudo -v; then
    fail "a senha nao foi aceita ou este usuario nao e administrador do computador." \
      "entre com o usuario que instalou o Ubuntu e rode o instalador de novo."
  fi
  start_sudo_keepalive
  start_sleep_inhibit

  # O Wi-Fi pode ainda estar conectando logo depois de ligar.
  host="${MASTER_URL#*://}"
  host="${host%%[:/]*}"
  ok=0
  for i in 1 2 3 4; do
    if getent hosts "$host" >/dev/null 2>&1; then ok=1; break; fi
    [ "$i" -lt 4 ] && { echo "Sem internet ainda. Esperando..."; sleep 5; }
  done
  if [ "$ok" -ne 1 ]; then
    fail "este computador esta sem internet (nao achei $host)." \
      "confira o cabo de rede ou o Wi-Fi, abra um site qualquer no navegador para testar e rode o instalador de novo."
  fi
  echo "Internet: ok."
}

# ============================================================ etapa 2

ensure_base_packages() {
  local missing=() cmd
  apt_repair
  for cmd in curl python3 ssh unzip ss hostname gpg; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  if [ "${#missing[@]}" -eq 0 ]; then
    echo "Programas basicos: ja instalados."
    return 0
  fi
  if ! command -v apt-get >/dev/null 2>&1; then
    fail "faltam os programas ${missing[*]} e este Linux nao tem apt-get." "chame o suporte NCommerce."
  fi
  echo "Instalando ${missing[*]}..."
  apt_install curl python3 ca-certificates openssh-client unzip iproute2 hostname gnupg \
    || fail "nao consegui instalar os programas basicos (${missing[*]})."
}

# Com o relogio errado o HTTPS falha com erro de certificado e a SEFAZ rejeita a nota.
check_clock_and_master() {
  local skew http i
  skew="$(clock_skew_seconds "$MASTER_URL/")"
  if [ -n "$skew" ] && [ "$skew" -gt 300 ]; then
    echo "O relogio deste computador esta errado em $((skew / 60)) minutos. Acertando pela internet..."
    sudo timedatectl set-ntp true >/dev/null 2>&1 || true
    sudo systemctl restart systemd-timesyncd >/dev/null 2>&1 || true
    for i in 1 2 3 4 5 6; do
      sleep 5
      skew="$(clock_skew_seconds "$MASTER_URL/")"
      if [ -z "$skew" ] || [ "$skew" -le 300 ]; then break; fi
    done
    if [ -n "$skew" ] && [ "$skew" -gt 300 ]; then
      fail "a data e a hora deste computador estao erradas (diferenca de $((skew / 60)) minutos)." \
        "acerte a data e a hora em Configuracoes > Data e hora (ligue o ajuste automatico) e rode o instalador de novo."
    fi
    echo "Relogio acertado."
  fi
  http="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 15 --max-time 30 "$MASTER_URL/" 2>"$WORK/curl.err" || true)"
  if [ -z "$http" ] || [ "$http" = "000" ]; then
    echo "Detalhe: $(head -c 300 "$WORK/curl.err" 2>/dev/null)"
    fail "nao consegui falar com o servidor do NCommerce ($MASTER_URL)." \
      "confira a internet. Se outros sites abrem, um antivirus, firewall ou filtro da rede pode estar bloqueando: chame o suporte. Depois rode o instalador de novo."
  fi
  echo "Servidor do NCommerce: ok. Relogio: ok."
}

# ============================================================ etapa 3

machine_id() {
  local file="$STATE_DIR/machine-id" value
  value="$(tr -d '[:space:]' 2>/dev/null < "$file" || true)"
  if [ -z "$value" ]; then
    if [ -r /proc/sys/kernel/random/uuid ]; then
      value="$(tr -d '[:space:]' < /proc/sys/kernel/random/uuid)"
    else
      value="$(openssl rand -hex 16)"
    fi
    printf '%s\n' "$value" > "$file.tmp"
    chmod 600 "$file.tmp"
    mv -f "$file.tmp" "$file"
  fi
  printf '%s' "$value"
}

normalize_code() {
  printf '%s' "$1" | tr -d '[:space:]-' | tr '[:lower:]' '[:upper:]'
}

valid_code() {
  printf '%s' "$1" | grep -Eq '^[A-Z0-9]{8}$'
}

# Pede o codigo. Devolve 1 se nao ha quem digite (janela fechada).
read_code() {
  local raw
  while true; do
    if ! read -r -p "Codigo de instalacao (8 caracteres): " raw; then
      echo
      return 1
    fi
    CODE="$(normalize_code "$raw")"
    if valid_code "$CODE"; then return 0; fi
    echo "Use 8 letras ou numeros."
  done
}

# O zip baixado em ncommerce.app/instalar traz o codigo neste arquivo, para o cliente nao digitar.
code_from_file() {
  local file="$ROOT/codigo-instalacao.txt" code
  [ -f "$file" ] || return 0
  code="$(normalize_code "$(cat "$file")")"
  if valid_code "$code"; then printf '%s' "$code"; fi
}

# Troca o codigo pelo token. 0 = ok, 1 = codigo recusado, 2 = sem resposta do mestre.
# O mestre aceita o mesmo codigo de novo neste computador (machine_id).
redeem() {
  local code="$1" body http mid host grant i
  mid="$(machine_id)"
  host="$(hostname | tr -cd 'A-Za-z0-9.-' | cut -c1-100)"
  body="$WORK/redeem.json"
  http=""
  for i in 1 2 3; do
    http="$(curl -sS -o "$body" -w "%{http_code}" --connect-timeout 15 --max-time 30 \
      -X POST -H "Content-Type: application/json" \
      -d "{\"code\":\"${code}\",\"machine_id\":\"${mid}\",\"hostname\":\"${host}\"}" \
      "${MASTER_URL}/install/redeem" 2>/dev/null || true)"
    case "$http" in
      ""|000|5??) [ "$i" -lt 3 ] && sleep $((5 * i)) ;;
      *) break ;;
    esac
  done
  case "$http" in
    200) ;;
    ""|000|5??)
      rm -f "$body"
      echo "O servidor do NCommerce nao respondeu (HTTP ${http:-000})."
      return 2
      ;;
    *)
      echo "Codigo ${code} recusado (HTTP ${http})."
      if [ -s "$body" ]; then
        head -c 500 "$body" || true
        echo
      fi
      rm -f "$body"
      return 1
      ;;
  esac
  grant="$(python3 - "$body" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    d = {}
def text(key):
    v = d.get(key) or ""
    return v if isinstance(v, str) and "\n" not in v else ""
token = text("token") or text("ncommerce_token")
sys.stdout.write("%s\n%s\n%s\n%s" % (token, text("company"), text("registry"), text("anydesk_password")))
PY
)" || grant=""
  rm -f "$body"
  NCOMMERCE_TOKEN="$(printf '%s\n' "$grant" | sed -n '1p')"
  COMPANY_NAME="$(printf '%s\n' "$grant" | sed -n '2p')"
  REGISTRY_FROM_MASTER="$(printf '%s\n' "$grant" | sed -n '3p')"
  ANYDESK_PASSWORD="$(printf '%s\n' "$grant" | sed -n '4p')"
  if [ -z "${NCOMMERCE_TOKEN}" ] || [ -z "${COMPANY_NAME}" ]; then
    echo "A resposta do servidor veio incompleta (sem o token ou sem o nome da empresa)."
    return 2
  fi
  return 0
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
    echo "${zip} nao e um arquivo zip (ou foi copiado pela metade)."
  elif ! unzip -Z1 "$zip" 2>/dev/null | grep -qx 'backup.sql'; then
    echo "${zip} nao e um backup do NCommerce: falta o backup.sql."
  elif unzip -tqq -P "nao-e-a-senha-$$" "$zip" >/dev/null 2>&1; then
    echo "${zip} nao esta criptografado. Backup do NCommerce sempre vem com senha."
  elif ! unzip -tqq -P "$pass" "$zip" >/dev/null 2>&1; then
    echo "${zip} nao abre com o token desta empresa${COMPANY_NAME:+ (${COMPANY_NAME})}: e backup de outra empresa ou esta corrompido."
  fi
}

# Backup que a instalacao restaura: o zip de --backup, um zip arrastado para o
# terminal ou, sem nenhum, o do mestre (BACKUP_ZIP fica vazio). A escolha fica
# no arquivo de estado: uma retomada nao pergunta de novo.
choose_backup_zip() {
  local raw path problem saved
  if [ -n "$BACKUP_ZIP_ARG" ]; then
    path="$(normalize_dropped_path "$BACKUP_ZIP_ARG")"
    problem="$(backup_zip_problem "$path")"
    if [ -n "$problem" ]; then
      fail "$problem" "confira o arquivo de backup e rode de novo com --backup /caminho/do/arquivo.zip."
    fi
    BACKUP_ZIP="$(readlink -f "$path")"
    echo "Backup avulso valido: ${BACKUP_ZIP}."
    state_set backup_escolha "$BACKUP_ZIP"
    return 0
  fi
  saved="$(state_get backup_escolha)"
  if [ "$saved" = "servidor" ]; then
    echo "Backup: o guardado no servidor (escolhido antes)."
    return 0
  fi
  if [ -n "$saved" ] && [ -z "$(backup_zip_problem "$saved")" ]; then
    BACKUP_ZIP="$saved"
    echo "Backup avulso (escolhido antes): ${BACKUP_ZIP}."
    return 0
  fi
  if [ ! -r /dev/tty ] || ! ( : < /dev/tty ) 2>/dev/null; then
    return 0
  fi
  echo
  if native_install_present; then
    echo "ATENCAO: este computador tem o NCommerce antigo (sem Docker) funcionando."
    echo "O certo e gerar agora o backup dele (tools/backup_ubuntu.sh) e arrastar o zip aqui."
    echo "O backup guardado no servidor pode ser de dias atras: as vendas depois dele se perdem."
  fi
  echo "Backup: para restaurar um zip de backup avulso, arraste o arquivo para esta janela e tecle Enter."
  echo "Para usar o backup guardado no servidor, so tecle Enter."
  while true; do
    read -r -p "Zip de backup (Enter = servidor): " raw < /dev/tty || raw=""
    path="$(normalize_dropped_path "$raw")"
    if [ -z "$path" ]; then
      echo "Usando o backup do servidor."
      state_set backup_escolha servidor
      return 0
    fi
    problem="$(backup_zip_problem "$path")"
    if [ -z "$problem" ]; then
      BACKUP_ZIP="$(readlink -f "$path")"
      echo "Backup avulso valido: ${BACKUP_ZIP}."
      state_set backup_escolha "$BACKUP_ZIP"
      return 0
    fi
    echo "$problem"
    echo "Arraste outro zip, ou tecle Enter para usar o backup do servidor."
  done
}

get_install_code() {
  local rc candidate
  if store_already_installed; then
    STORE_ALREADY_LIVE=1
  fi
  if [ "$STORE_ALREADY_LIVE" = "1" ] && [ "$REINSTALAR" = "0" ] && [ -z "$BACKUP_ZIP_ARG" ] && ! native_install_present; then
    MODE="reparo"
    echo "O NCommerce ja esta instalado neste computador."
    echo "Vou so conferir e consertar o que precisar. Nao preciso do codigo e os dados da loja nao sao tocados."
    return 0
  fi

  # Codigo do arquivo do zip, depois o digitado numa execucao anterior, depois o teclado.
  for candidate in "$(code_from_file)" "$(state_get codigo)"; do
    [ -n "$candidate" ] || continue
    echo "Usando o codigo de instalacao $candidate."
    rc=0
    redeem "$candidate" || rc=$?
    if [ "$rc" -eq 0 ]; then CODE="$candidate"; break; fi
    if [ "$rc" -eq 2 ]; then
      fail "o servidor do NCommerce nao respondeu ao codigo de instalacao." \
        "espere alguns minutos e rode o instalador de novo. O codigo continua valendo neste computador."
    fi
  done
  while [ -z "$CODE" ]; do
    echo "Peca o codigo de instalacao ao suporte NCommerce e digite abaixo."
    if ! read_code; then
      fail "o instalador precisa do codigo de instalacao e nao ha como digitar nesta janela." \
        "abra o instalador de novo num terminal e digite o codigo de 8 caracteres."
    fi
    rc=0
    redeem "$CODE" || rc=$?
    if [ "$rc" -eq 2 ]; then
      fail "o servidor do NCommerce nao respondeu ao codigo de instalacao." \
        "espere alguns minutos e rode o instalador de novo."
    fi
    if [ "$rc" -ne 0 ]; then CODE=""; fi
  done
  state_set codigo "$CODE"
  echo "Codigo aceito. Empresa: ${COMPANY_NAME}."
  choose_backup_zip
}

# ============================================================ etapa 4

# Ubuntu recem-instalado nao traz o servidor SSH. Nada aqui para a instalacao:
# o SSH e do suporte, e a loja funciona sem ele.
enable_ssh() {
  local conf=/etc/ssh/sshd_config.d/ncommerce-keepalive.conf include_added=0
  echo "Abrindo o SSH na porta 22..."
  if ! dpkg -s openssh-server >/dev/null 2>&1; then
    apt_install openssh-server || { warn "nao consegui instalar o servidor SSH. O suporte fica sem acesso por SSH."; return 0; }
  fi
  if ! sudo systemctl enable --now ssh >/dev/null 2>&1; then
    sudo systemctl enable --now ssh.socket >/dev/null 2>&1 || true
  fi
  if command -v ufw >/dev/null 2>&1; then
    sudo ufw allow 22/tcp >/dev/null || true
  fi
  # Sessao pelo tunel fica em silencio num comando longo. Sem probe o NAT
  # derruba o TCP. Probe a cada 30s: a sessao viva nao expira; 3 falhas
  # seguidas (~90s sem resposta) desconectam.
  sudo mkdir -p /etc/ssh/sshd_config.d
  printf 'ClientAliveInterval 30\nClientAliveCountMax 3\n' > "$WORK/keepalive.conf"
  NC_SUDO=1 install_atomic "$WORK/keepalive.conf" "$conf" 644 || true
  if ! sudo grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf[[:space:]]*$' /etc/ssh/sshd_config 2>/dev/null; then
    sudo cp -p /etc/ssh/sshd_config /etc/ssh/sshd_config.ncommerce.bak 2>/dev/null || true
    if sudo sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config; then include_added=1; fi
  fi
  if ! sudo sshd -t 2>"$WORK/sshd.err"; then
    # Configuracao recusada: sai o que este instalador pos, o SSH segue como estava.
    sudo rm -f "$conf"
    if [ "$include_added" = "1" ] && ! sudo sshd -t 2>/dev/null && sudo test -f /etc/ssh/sshd_config.ncommerce.bak; then
      sudo cp -p /etc/ssh/sshd_config.ncommerce.bak /etc/ssh/sshd_config
    fi
    warn "o SSH recusou o ajuste de keepalive ($(head -c 200 "$WORK/sshd.err")). Ficou como estava."
  else
    sudo systemctl reload ssh 2>/dev/null || sudo systemctl reload ssh.service 2>/dev/null || true
  fi
  if ss -ltn | grep -Eq ':22[[:space:]]'; then
    echo "SSH escutando na porta 22. Usuario: ${USER}."
  else
    warn "a porta 22 (SSH) nao esta escutando. O suporte fica sem acesso por SSH ate isso ser resolvido."
  fi
}

# AnyDesk para o suporte entrar na tela do cliente. Falha aqui nao para a instalacao.
install_anydesk() {
  if command -v anydesk >/dev/null 2>&1; then
    echo "AnyDesk ja instalado."
    return 0
  fi
  if is_wsl; then
    echo "WSL: o AnyDesk vai no Windows. Pulando."
    return 0
  fi
  echo "Instalando o AnyDesk..."
  # A chave e baixada inteira antes de entrar no apt: download cortado nao vira chave.
  curl -fsSL --retry 3 --connect-timeout 15 --max-time 60 -o "$WORK/anydesk.key" \
    https://keys.anydesk.com/repos/DEB-GPG-KEY || return 1
  gpg --dearmor < "$WORK/anydesk.key" > "$WORK/anydesk.gpg" 2>/dev/null || return 1
  [ -s "$WORK/anydesk.gpg" ] || return 1
  NC_SUDO=1 install_atomic "$WORK/anydesk.gpg" /etc/apt/trusted.gpg.d/anydesk.gpg 644 || return 1
  echo "deb http://deb.anydesk.com/ all main" > "$WORK/anydesk.list"
  NC_SUDO=1 install_atomic "$WORK/anydesk.list" /etc/apt/sources.list.d/anydesk-stable.list 644 || return 1
  APT_UPDATED=0
  apt_install anydesk || return 1
  echo "AnyDesk ID: $(anydesk --get-id 2>/dev/null || echo 'abra o AnyDesk para ver')"
}

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

# Senha do acesso nao supervisionado. E a mesma em todos os clientes, por isso vem
# do mestre no resgate do codigo e nao fica escrita neste arquivo nem no disco.
set_anydesk_password() {
  if [ -z "${ANYDESK_PASSWORD:-}" ] || ! command -v anydesk >/dev/null 2>&1; then
    return 0
  fi
  local out
  if out="$(printf '%s' "$ANYDESK_PASSWORD" | sudo anydesk --set-password 2>&1)"; then
    echo "Acesso nao supervisionado do AnyDesk configurado."
  else
    warn "nao consegui configurar a senha do AnyDesk: ${out:-sem mensagem}"
  fi
}

setup_support_access() {
  enable_ssh
  install_anydesk || warn "nao consegui instalar o AnyDesk. O suporte instala depois (https://anydesk.com)."
  pin_anydesk_to_dock || true
  set_anydesk_password
  ANYDESK_PASSWORD=""
}

# ============================================================ etapa 5

docker_cli_ok() {
  command -v docker >/dev/null 2>&1 && sudo docker compose version >/dev/null 2>&1
}

# O compose da loja usa recursos do Docker Compose 2.24 em diante.
compose_reads_our_file() {
  (cd "$ROOT/docker" && sudo docker compose -f docker-compose.yml -f docker-compose.usb.yml config -q) >/dev/null 2>"$WORK/compose.err"
}

install_docker_from_docker_com() {
  # Baixa inteiro e confere antes de rodar como root: nada de script cortado no meio.
  if ! curl -fsSL --retry 3 --connect-timeout 15 --max-time 120 -o "$WORK/get-docker.sh" https://get.docker.com \
     || ! head -n 1 "$WORK/get-docker.sh" | grep -q '^#!/bin/sh' \
     || ! sh -n "$WORK/get-docker.sh" \
     || ! grep -q 'do_install' "$WORK/get-docker.sh"; then
    fail "nao consegui baixar o instalador do Docker (get.docker.com)."
  fi
  sudo sh "$WORK/get-docker.sh" || true
}

wait_docker_daemon() {
  local i
  for i in $(seq 1 "${1:-30}"); do
    if sudo docker info >/dev/null 2>&1; then return 0; fi
    sleep 2
  done
  return 1
}

ensure_docker() {
  local docker_path
  docker_path="$(command -v docker 2>/dev/null || true)"
  case "$docker_path" in
    /snap/*)
      fail "o Docker deste computador foi instalado pela loja de aplicativos (snap), e esse nao enxerga a pasta do NCommerce." \
        "chame o suporte NCommerce para trocar o Docker (sudo snap remove docker apaga os containers que existirem nele)."
      ;;
  esac
  if ! docker_cli_ok; then
    echo "Instalando o Docker. Pode levar alguns minutos..."
    if command -v apt-get >/dev/null 2>&1; then
      apt_install docker.io docker-compose-v2 || apt_install docker.io || true
    fi
  fi
  if ! docker_cli_ok; then
    echo "O pacote da distro nao trouxe o Docker Compose. Usando https://get.docker.com ..."
    install_docker_from_docker_com
  fi
  if ! docker_cli_ok; then
    fail "o Docker nao ficou instalado neste computador." \
      "rode o instalador de novo. Se repetir, mande o log para o suporte NCommerce."
  fi

  sudo systemctl enable docker >/dev/null 2>&1 || true
  sudo systemctl start docker >/dev/null 2>&1 || true
  if ! wait_docker_daemon 30; then
    echo "O Docker esta instalado mas nao respondeu. Reiniciando o servico..."
    sudo systemctl reset-failed docker >/dev/null 2>&1 || true
    sudo systemctl restart docker >/dev/null 2>&1 || true
    if ! wait_docker_daemon 45; then
      sudo systemctl status docker --no-pager 2>&1 | tail -n 20 || true
      sudo journalctl -u docker --no-pager -n 30 2>/dev/null || true
      fail "o Docker esta instalado mas nao liga." \
        "reinicie o computador e rode o instalador de novo. Se repetir, mande o log para o suporte NCommerce."
    fi
  fi
  # Docker Compose antigo demais para o arquivo da loja. So acontece em
  # computador novo: numa loja que ja roda, o compose dela ja le o arquivo.
  if ! compose_reads_our_file && [ ! -f "$INSTALL_DIR/.env" ]; then
    echo "O Docker Compose deste computador e antigo ($(sudo docker compose version --short 2>/dev/null || echo '?')). Instalando o atual de https://get.docker.com ..."
    install_docker_from_docker_com
    sudo systemctl start docker >/dev/null 2>&1 || true
    wait_docker_daemon 30 || true
    if ! compose_reads_our_file; then
      cat "$WORK/compose.err"
      fail "o Docker Compose deste computador nao le o arquivo do NCommerce." \
        "mande o log para o suporte NCommerce."
    fi
  fi
  if ! id -nG "$USER" | grep -qw docker; then
    sudo usermod -aG docker "$USER" || true
  fi
  echo "Docker funcionando: $(sudo docker version --format '{{.Server.Version}}' 2>/dev/null || echo '?')."
}

# ============================================================ etapa 6

# Documentos do usuario (Documentos ou Documents, conforme o idioma). O compose monta
# Documentos/ncommerce/plugins em app/lib/plugins: quem tem plugin copia o arquivo para la.
prepare_plugins_dir() {
  local docs="" saved
  # Loja ja instalada: a pasta que ela usa nao muda de lugar.
  saved="$(env_read "$INSTALL_DIR/.env" NCOMMERCE_PLUGINS_DIR)"
  if [ -n "$saved" ] && [ -d "$saved" ]; then
    PLUGINS_DIR="$saved"
    return 0
  fi
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

# No boot o systemd grava o ID do AnyDesk em $INSTALL_DIR/host. A API manda ao mestre.
install_anydesk_id_service() {
  sudo mkdir -p "$INSTALL_DIR/host"
  cat > "$WORK/anydesk-id.service" <<EOF
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
  install_atomic "$WORK/anydesk-id.service" /etc/systemd/system/ncommerce-anydesk-id.service 644
  sudo systemctl daemon-reload
  sudo systemctl enable ncommerce-anydesk-id.service >/dev/null 2>&1 || true
  # O AnyDesk recem-instalado leva ate 2 minutos para ter ID: nao segura a instalacao.
  ( sudo "$INSTALL_DIR/anydesk-id.sh" "$INSTALL_DIR" || true ) >/dev/null 2>&1 8>&- &
}

install_store_files() {
  local f file_registry file_tag saved_port
  # Arquivo cortado no download do zip nao pode chegar em /opt/ncommerce.
  for f in update.sh host-ips.sh update-host.sh rollback.sh net-check.sh tunnel-route.sh anydesk-id.sh; do
    bash -n "$ROOT/docker/$f" || fail "o arquivo docker/$f do instalador esta danificado." \
      "baixe o instalador de novo em ncommerce.app/instalar, extraia e rode de novo."
  done
  sh -n "$ROOT/docker/guard.sh" || fail "o arquivo docker/guard.sh do instalador esta danificado." \
    "baixe o instalador de novo em ncommerce.app/instalar, extraia e rode de novo."
  if ! compose_reads_our_file; then
    cat "$WORK/compose.err"
    fail "o arquivo docker-compose.yml do instalador esta danificado." \
      "baixe o instalador de novo em ncommerce.app/instalar, extraia e rode de novo."
  fi

  # Instaladores antigos clonavam o codigo-fonte em src/. A stack roda das
  # imagens e nada usa essa pasta.
  if [ -d "$INSTALL_DIR/src" ]; then
    sudo rm -rf "$INSTALL_DIR/src"
  fi

  prepare_plugins_dir
  sudo mkdir -p "$INSTALL_DIR" "$INSTALL_DIR/control" "$INSTALL_DIR/host"
  # .env vazio de uma gravacao interrompida: volta a copia.
  # shellcheck source=docker/host-ips.sh
  . "$ROOT/docker/host-ips.sh"
  repair_env_file "$INSTALL_DIR/.env"

  file_registry="$(env_read "$INSTALL_DIR/.env" NCOMMERCE_REGISTRY)"
  file_tag="$(env_read "$INSTALL_DIR/.env" NCOMMERCE_TAG)"
  saved_port="$(env_read "$INSTALL_DIR/.env" CUPS_PORT)"
  # O registry antigo sai de cena quando ha um login novo para fazer.
  if [ "$MODE" = "instalacao" ] && [ "$file_registry" = "$OLD_REGISTRY" ]; then
    file_registry=""
  fi
  REGISTRY="${REQUESTED_REGISTRY:-${file_registry:-${REGISTRY_FROM_MASTER:-$DEFAULT_REGISTRY}}}"
  TAG="${REQUESTED_TAG:-${file_tag:-latest}}"

  # A porta do CUPS e escolhida uma vez. Numa segunda execucao a 631 esta
  # ocupada pelo proprio container, e escolher de novo trocaria a porta da loja.
  case "$saved_port" in
    631|6631) CUPS_PORT="$saved_port" ;;
    *)
      CUPS_PORT=631
      if port_busy 631; then
        CUPS_PORT=6631
        echo "A porta 631 ja esta em uso. O CUPS do container fica em http://127.0.0.1:6631."
      fi
      ;;
  esac

  install_atomic "$ROOT/docker/docker-compose.yml" "$INSTALL_DIR/docker-compose.yml" 644 bak
  install_atomic "$ROOT/docker/docker-compose.usb.yml" "$INSTALL_DIR/docker-compose.usb.yml" 644 bak
  install_atomic "$ROOT/docker/host-ips.sh" "$INSTALL_DIR/host-ips.sh" 644
  for f in update.sh update-host.sh guard.sh rollback.sh net-check.sh tunnel-route.sh anydesk-id.sh; do
    install_atomic "$ROOT/docker/$f" "$INSTALL_DIR/$f" 755
  done

  env_merge "$INSTALL_DIR/.env" \
    "CUPS_PORT=${CUPS_PORT}" \
    "NCOMMERCE_REGISTRY=${REGISTRY}" \
    "NCOMMERCE_TAG=${TAG}" \
    "COMPOSE_FILE=docker-compose.yml:docker-compose.usb.yml" \
    "NCOMMERCE_PLUGINS_DIR=${PLUGINS_DIR}" \
    "TZ=$(host_timezone)"
  write_host_ip_files "$INSTALL_DIR"

  install_anydesk_id_service
  # Conflito de IP na rede da loja, para o chat de suporte (host/net_check).
  sudo "$INSTALL_DIR/net-check.sh" --install "$INSTALL_DIR" || warn "o verificador de conflito de IP nao foi instalado."
  # Rota do tunel pela interface que chega em tunnel.nlabs.live.
  sudo "$INSTALL_DIR/tunnel-route.sh" --install "$INSTALL_DIR" || warn "o ajuste de rota do tunel nao foi instalado."

  # A impressora USB passa a ser do CUPS do container. Uma fila USB no CUPS do host disputa o aparelho.
  # O system-config-printer-udev cria essa fila sozinho quando a impressora e plugada. O link para
  # /dev/null anula a regra dele; o CUPS do host continua ligado.
  sudo ln -sfn /dev/null /etc/udev/rules.d/70-printers.rules
  sudo udevadm control --reload || true
  local host_usb_queues
  host_usb_queues="$(lpstat -v 2>/dev/null | grep -E 'usb://' || true)"
  if [ -n "$host_usb_queues" ]; then
    warn "o CUPS do Ubuntu tem fila USB, que disputa a impressora com o NCommerce. O suporte remove com lpadmin -x <fila>: $(echo "$host_usb_queues" | tr '\n' ' ')"
  fi

  # Grava as regras mesmo com o firewall desligado. Um ufw enable depois nao fecha a loja nem o SSH.
  if command -v ufw >/dev/null 2>&1; then
    sudo ufw allow 22/tcp >/dev/null || true
    sudo ufw allow 3000/tcp >/dev/null || true
    sudo ufw allow 4200/tcp >/dev/null || true
  fi
  echo "Arquivos do NCommerce em $INSTALL_DIR."
}

# ============================================================ etapa 7

pull_images() {
  local http services=()
  cd "$INSTALL_DIR"
  http="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 15 --max-time 30 "https://${REGISTRY}/v2/" 2>"$WORK/curl.err" || true)"
  case "$http" in
    200|401) ;;
    *)
      echo "Detalhe: HTTP ${http:-000} $(head -c 300 "$WORK/curl.err" 2>/dev/null)"
      fail "nao consegui chegar no servidor de onde o NCommerce e baixado (${REGISTRY})." \
        "confira a internet. Se outros sites abrem, a rede pode estar bloqueando a porta ${REGISTRY##*:}: chame o suporte. Depois rode o instalador de novo."
      ;;
  esac

  if [ "$MODE" = "instalacao" ]; then
    echo "Entrando no registry ${REGISTRY} como ${COMPANY_NAME}..."
    # shellcheck disable=SC2024
    if ! printf '%s' "$NCOMMERCE_TOKEN" | sudo docker login "$REGISTRY" --username "$COMPANY_NAME" --password-stdin >"$WORK/login.out" 2>&1; then
      tail -n 5 "$WORK/login.out"
      fail "o servidor nao aceitou a entrada desta empresa (${COMPANY_NAME}) para baixar o sistema." \
        "rode o instalador de novo. Se repetir, mande o log para o suporte NCommerce."
    fi
  fi

  # Uma loja que voltou de versao fica com NCOMMERCE_TAG=keep-<versao>, que so
  # existe neste computador: nao ha o que baixar para api e web.
  case "$TAG" in
    keep-*)
      if sudo docker image inspect "${REGISTRY}/ncommerce/api:${TAG}" >/dev/null 2>&1; then
        echo "A loja esta numa versao guardada (${TAG#keep-}). Ela fica; para a publicada, use o atalho Atualizar NCommerce."
        services=(mysql redis guard)
      else
        echo "A versao guardada ${TAG#keep-} nao esta mais neste computador. Usando a publicada."
        TAG=latest
        env_merge "$INSTALL_DIR/.env" "NCOMMERCE_TAG=latest"
      fi
      ;;
  esac

  # Reparo: so baixa o que falta. A versao da loja muda no Atualizar NCommerce.
  if [ "$MODE" = "reparo" ] && [ "${#services[@]}" -eq 0 ]; then
    local img images absent=0
    images="$(compose config --images 2>/dev/null || true)"
    while IFS= read -r img; do
      [ -n "$img" ] || continue
      sudo docker image inspect "$img" >/dev/null 2>&1 || absent=1
    done <<< "$images"
    if [ -n "$images" ] && [ "$absent" = "0" ]; then
      echo "As imagens do NCommerce ja estao neste computador."
      return 0
    fi
  fi

  echo "Baixando o NCommerce. E a parte mais demorada: de 5 a 30 minutos, conforme a internet."
  echo "Se a internet cair, o que ja foi baixado fica guardado."
  if ! retry 4 15 compose pull "${services[@]+"${services[@]}"}"; then
    fail "o download do NCommerce nao terminou (internet caiu ou esta muito lenta)." \
      "confira a internet e rode o instalador de novo. Ele continua do ponto em que o download parou."
  fi
  echo "Download concluido."
}

# ============================================================ etapa 8

stop_native_install() {
  native_install_present || return 0
  echo "Achei uma instalacao antiga do NCommerce (sem Docker). Desligando para o Docker assumir."
  echo "Se algo der errado daqui para a frente, ela e religada sozinha."
  NATIVE_STOPPED_NOW=1
  state_set nativo_desligado "$(date +%s)"
  if ! bash "$ROOT/tools/desligar_nativo.sh"; then
    fail "nao consegui desligar a instalacao antiga do NCommerce." \
      "chame o suporte NCommerce. A loja antiga foi religada."
  fi
}

check_ports_free() {
  local port owner
  # Com os containers da loja ja criados, quem ocupa as portas somos nos.
  if [ -n "$(compose ps -aq 2>/dev/null)" ]; then return 0; fi
  for port in 3000 4200; do
    if port_busy "$port"; then
      owner="$(port_owner "$port")"
      fail "a porta $port, que o NCommerce usa, esta ocupada por outro programa${owner:+ ($owner)}." \
        "feche ou desinstale esse programa e rode o instalador de novo. Se nao souber qual e, chame o suporte NCommerce."
    fi
  done
}

start_stack() {
  cd "$INSTALL_DIR"
  stop_native_install
  check_ports_free
  echo "Ligando o NCommerce..."
  if ! retry 2 10 compose up -d; then
    compose ps || true
    fail "o Docker nao conseguiu ligar o NCommerce." \
      "reinicie o computador e rode o instalador de novo. Se repetir, mande o log para o suporte NCommerce."
  fi
  if [ "$MODE" = "instalacao" ] && token_already_on_volume; then
    STORE_ALREADY_LIVE=1
  fi
  echo "Esperando o sistema responder. Na primeira vez ele prepara o banco de dados: ate 8 minutos."
  if ! wait_api_up 480; then
    # Sem token a API ja responde ao setup; se nem isso, algo nao subiu.
    if ! token_already_on_volume 3; then
      compose ps || true
      compose logs --tail 60 api || true
      fail "o NCommerce foi ligado mas nao respondeu em 8 minutos." \
        "rode o instalador de novo. Se repetir, mande o log para o suporte NCommerce."
    fi
    echo "A API ainda nao respondeu, mas o token desta maquina ja esta gravado. Sigo."
  fi
  echo "Sistema respondendo."
}

# ============================================================ etapa 9

# Copia do banco antes de restaurar por cima de uma loja que ja funcionava.
# Fica em $INSTALL_DIR/backups (so root le). Ficam as 3 mais recentes.
dump_database() {
  local label="$1" dir="$INSTALL_DIR/backups" name
  name="$label-$(date '+%Y%m%d-%H%M%S').sql.gz"
  sudo mkdir -p "$dir"
  sudo chmod 700 "$dir"
  echo "Guardando uma copia do banco de dados atual..."
  # Sem pipe: o codigo de saida do mysqldump e a ultima linha ("Dump completed") valem.
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
  sudo sh -c "ls -1t '$dir'/$label-*.sql.gz 2>/dev/null | tail -n +4 | while IFS= read -r old; do rm -f -- \"\$old\"; done"
  echo "Copia guardada em $dir/$name."
}

# 200 grava o zip. 204 significa empresa sem backup. Outro HTTP aborta.
# O download continua de onde parou e o zip so vale depois de conferido.
download_backup() {
  local mid dest part _
  mid="$(machine_id)"
  dest="$INSTALL_DIR/ncommerce.zip"
  part="$STATE_DIR/ncommerce.zip.part"
  for _ in 1 2; do
    echo "Baixando o backup da loja guardado no servidor..."
    if ! download_resumable "${MASTER_URL}/install/${CODE}/backup?machine_id=${mid}" "$part" 4; then
      fail "nao consegui baixar o backup da loja (HTTP ${NC_HTTP})." \
        "confira a internet e rode o instalador de novo. O download continua de onde parou."
    fi
    if [ "$NC_HTTP" = "204" ]; then
      rm -f "$part"
      sudo rm -f "$dest"
      echo "Esta empresa nao tem backup no servidor. A instalacao segue com a loja vazia."
      return 0
    fi
    if [ -s "$part" ] && unzip -tqq -P "${NCOMMERCE_TOKEN:0:6}" "$part" >/dev/null 2>&1; then
      sudo install -m 600 -o "$(id -u)" -g "$(id -g)" "$part" "$dest.novo"
      sudo mv -f "$dest.novo" "$dest"
      rm -f "$part"
      echo "Backup baixado e conferido."
      return 0
    fi
    # Pedaco de um backup antigo ou arquivo danificado: comeca do zero uma vez.
    echo "O backup baixado nao passou na conferencia. Baixando de novo do inicio..."
    rm -f "$part"
  done
  fail "o backup baixado do servidor esta danificado." \
    "rode o instalador de novo. Se repetir, chame o suporte NCommerce."
}

# Um zip avulso entra no lugar do backup do mestre. Escolhido de proposito,
# ele e restaurado mesmo numa maquina que ja restaurou um backup antes.
use_backup_zip() {
  local dest="$INSTALL_DIR/ncommerce.zip"
  if [ "$(readlink -f "$dest" 2>/dev/null || true)" != "$BACKUP_ZIP" ]; then
    sudo install -m 600 -o "$(id -u)" -g "$(id -g)" "$BACKUP_ZIP" "$dest.novo"
    sudo mv -f "$dest.novo" "$dest"
  fi
  # Uma retomada depois de restaurar este mesmo zip nao restaura de novo.
  if [ "$(state_get backup_restaurado)" != "$BACKUP_ZIP" ]; then
    sudo rm -f "$INSTALL_DIR/.backup-restored"
  fi
  echo "Backup avulso copiado para ${dest}."
}

# Copia para dentro do container, tentando de novo. Falha vira aviso no resumo.
copy_into_api() {
  local what="$1" src="$2" dst="$3"
  if retry 3 3 compose cp "$src" "$dst" >/dev/null 2>&1; then return 0; fi
  warn "nao consegui restaurar $what do backup. Chame o suporte NCommerce para restaurar essa parte."
  return 0
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
  if compose exec -T api sh -c 'command -v ncommerce-restore-cups' >/dev/null 2>&1 < /dev/null; then
    compose exec -T api sh -c 'rm -rf /tmp/ncommerce-cups && mkdir -p /tmp/ncommerce-cups' < /dev/null || true
    for f in "${files[@]}"; do
      compose cp "$work/$f" "api:/tmp/ncommerce-cups/$f" >/dev/null || true
    done
    compose exec -T api sh -c 'ncommerce-restore-cups /tmp/ncommerce-cups; s=$?; rm -rf /tmp/ncommerce-cups; exit $s' < /dev/null \
      || warn "nem todas as impressoras do backup foram restauradas. Cadastre as que faltarem em http://127.0.0.1:${CUPS_PORT}."
  elif [ -f "$work/printers.conf" ]; then
    compose cp "$work/printers.conf" api:/etc/cups/printers.conf >/dev/null || true
  fi
}

restore_backup_into_docker() {
  local zip="$INSTALL_DIR/ncommerce.zip" work pass marker part
  marker="$INSTALL_DIR/.backup-restored"
  if [ -f "$marker" ]; then
    echo "O backup ja foi restaurado numa execucao anterior."
    return 0
  fi
  if [ ! -s "$zip" ]; then
    return 0
  fi
  pass="${NCOMMERCE_TOKEN:0:6}"
  # A pasta com o banco aberto (sem senha) fica dentro de $WORK, que some ao
  # sair, com erro ou nao.
  work="$WORK/restore"
  rm -rf "$work"
  mkdir -p "$work"
  if ! unzip -P "$pass" -o "$zip" -d "$work" >"$WORK/unzip.log" 2>&1; then
    fail "nao consegui abrir o backup (${zip}). A senha sao os 6 primeiros caracteres do token." \
      "rode o instalador de novo. Se repetir, chame o suporte NCommerce."
  fi
  if [ ! -f "$work/backup.sql" ]; then
    fail "o backup (${zip}) nao tem o banco de dados (backup.sql)." "chame o suporte NCommerce."
  fi
  if [ "$STORE_ALREADY_LIVE" = "1" ]; then
    dump_database antes-de-restaurar || fail "nao consegui guardar uma copia do banco atual antes de restaurar o backup por cima." \
      "nada foi alterado. Confira o espaco em disco e rode de novo, ou chame o suporte NCommerce."
  fi
  echo "Restaurando o banco de dados da loja. Pode levar alguns minutos..."
  compose exec -T mysql sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "CREATE DATABASE IF NOT EXISTS ncommerce_api_production CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"' \
    < /dev/null \
    || fail "o banco de dados nao aceitou o comando de restauracao."
  compose exec -T mysql sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" ncommerce_api_production' < "$work/backup.sql" \
    || fail "a restauracao do banco de dados parou no meio." \
      "rode o instalador de novo: ele restaura o backup desde o inicio."
  if [ -f "$work/docs.zip" ]; then
    unzip -o "$work/docs.zip" -d "$work" >/dev/null
  fi
  if [ -d "$work/business_docs" ]; then
    copy_into_api "os documentos da empresa" "$work/business_docs" api:/app/ncommerce_api/
  fi
  if [ -f "$work/nfce.zip" ]; then
    unzip -o "$work/nfce.zip" -d "$work" >/dev/null
  fi
  # backup/ guarda os XML dos meses anteriores, que o relatorio de impostos le.
  for part in essentials notas_output backup notas_compra notas_input notas_log; do
    if [ -d "$work/$part" ]; then
      copy_into_api "os arquivos da nota fiscal ($part)" "$work/$part" api:/data/nfce/
    fi
  done
  # Segundo CNPJ: a pasta inteira, com o .last_id que numera as notas dele.
  if [ -f "$work/nfce_ext.zip" ]; then
    mkdir -p "$work/nfce_ext"
    unzip -o "$work/nfce_ext.zip" -d "$work/nfce_ext" >/dev/null
    compose exec -T api mkdir -p /data/nfce/externo < /dev/null || true
    copy_into_api "os arquivos da nota fiscal do segundo CNPJ" "$work/nfce_ext/." api:/data/nfce/externo/
  fi
  restore_printers "$work"
  # Plugins voltam para Documentos/ncommerce/plugins; a API so carrega ao subir.
  if [ -f "$work/plugins.zip" ]; then
    unzip -o "$work/plugins.zip" -d "$PLUGINS_DIR" >/dev/null
    echo "Plugins restaurados em ${PLUGINS_DIR}."
    compose restart api
    wait_api_up 240 || warn "a API demorou para voltar depois de carregar os plugins."
  fi
  rm -rf "$work"
  sudo touch "$marker"
  state_set backup_restaurado "${BACKUP_ZIP:-servidor}"
  echo "Backup restaurado."
}

post_token() {
  local setup_body payload post_body post_http setup_http
  if token_already_on_volume 3; then
    echo "O token desta maquina ja esta gravado."
    return 0
  fi
  setup_body="$WORK/setup.json"
  setup_http="$(api_setup "$setup_body")"
  if [ "$setup_http" = "200" ] && grep -Eq '"setup_required":[[:space:]]*false' "$setup_body"; then
    echo "O token desta maquina ja esta gravado."
    return 0
  fi
  payload="$WORK/token.json"
  post_body="$WORK/token-answer.json"
  ( umask 077; : > "$payload"; : > "$post_body" )
  # O token vai pelo ambiente, nao pela linha de comando (que aparece no ps).
  NC_TOKEN="$NCOMMERCE_TOKEN" python3 - "$payload" <<'PY'
import json, os, sys
open(sys.argv[1], "w").write(json.dumps({"token": os.environ["NC_TOKEN"]}))
PY
  # 502: a API nao conseguiu conferir o token com o mestre. Tenta de novo.
  local i
  for i in 1 2 3 4; do
    post_http="$(curl -sS -o "$post_body" -w "%{http_code}" -m 40 \
      -H "Host: localhost" \
      -H "Content-Type: application/json" \
      --data-binary "@${payload}" \
      "http://127.0.0.1:3000/api/v1/docker_setup" 2>/dev/null || true)"
    case "$post_http" in
      ""|000|502|503) [ "$i" -lt 4 ] && sleep $((10 * i)) ;;
      *) break ;;
    esac
  done
  rm -f "$payload"
  if [ "$post_http" != "200" ] || ! grep -Eq '"ok":[[:space:]]*true' "$post_body"; then
    echo "Detalhe: HTTP ${post_http:-000} $(head -c 300 "$post_body" 2>/dev/null)"
    fail "o NCommerce nao aceitou a identificacao desta empresa (token)." \
      "rode o instalador de novo. Se repetir, mande o log para o suporte NCommerce."
  fi
  if ! token_already_on_volume; then
    fail "o NCommerce respondeu que gravou o token, mas ele nao esta no disco." \
      "rode o instalador de novo. Se repetir, mande o log para o suporte NCommerce."
  fi
  echo "Token gravado."
}

load_store_data() {
  cd "$INSTALL_DIR"
  if [ "$MODE" = "reparo" ]; then
    echo "Loja ja instalada: os dados ficam como estao."
    return 0
  fi
  if [ -n "$BACKUP_ZIP" ]; then
    use_backup_zip
    restore_backup_into_docker
  elif [ "$STORE_ALREADY_LIVE" = "1" ]; then
    # O backup do servidor e mais velho que o banco de uma loja que ja funciona:
    # restaurar por cima apagaria as vendas feitas depois dele.
    echo "Esta loja ja estava funcionando neste computador: o backup do servidor NAO e restaurado por cima."
    echo "(Para restaurar um backup de proposito, rode com --backup /caminho/arquivo.zip.)"
    sudo touch "$INSTALL_DIR/.backup-restored"
  elif [ -f "$INSTALL_DIR/.backup-restored" ]; then
    echo "O backup ja foi restaurado numa execucao anterior."
  else
    download_backup
    restore_backup_into_docker
  fi
  post_token
}

# ============================================================ etapa 10

write_update_shortcut() {
  local wrapper tmp dir xdg seen
  wrapper="$INSTALL_DIR/atualizar-terminal.sh"
  cat > "$WORK/atualizar-terminal.sh" <<EOF
#!/bin/bash
cd "$INSTALL_DIR" || exit 1
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
  install_atomic "$WORK/atualizar-terminal.sh" "$wrapper" 755

  tmp="$WORK/atualizar.desktop"
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
  if [ -n "$xdg" ] && [ "$xdg" != "$HOME" ]; then
    mkdir -p "$xdg"
  else
    xdg=""
  fi
  seen=" "
  for dir in "$xdg" "${HOME}/Desktop" "${HOME}/Área de Trabalho" "${HOME}/Área de trabalho"; do
    [ -n "$dir" ] && [ -d "$dir" ] || continue
    case "$seen" in
      *" $dir "*) continue ;;
    esac
    seen="$seen$dir "
    cp "$tmp" "$dir/.Atualizar NCommerce.desktop.novo"
    chmod +x "$dir/.Atualizar NCommerce.desktop.novo"
    mv -f "$dir/.Atualizar NCommerce.desktop.novo" "$dir/Atualizar NCommerce.desktop"
    gio set "$dir/Atualizar NCommerce.desktop" metadata::trusted true 2>/dev/null || true
    echo "Atalho: $dir/Atualizar NCommerce.desktop"
  done
}

# So declara sucesso depois de ver a loja funcionando de verdade e o inicio
# automatico configurado.
verify_install() {
  local svc running down="" http i policy cid body ok
  cd "$INSTALL_DIR"
  running="$(compose ps --status running --services 2>/dev/null || true)"
  for svc in mysql redis api web guard; do
    if ! printf '%s\n' "$running" | grep -qx "$svc"; then down="$down $svc"; fi
  done
  if [ -n "$down" ]; then
    # Um container pode estar reiniciando logo depois do restore: mais uma chance.
    sleep 15
    compose up -d >/dev/null 2>&1 || true
    sleep 10
    running="$(compose ps --status running --services 2>/dev/null || true)"
    down=""
    for svc in mysql redis api web guard; do
      if ! printf '%s\n' "$running" | grep -qx "$svc"; then down="$down $svc"; fi
    done
  fi
  if [ -n "$down" ]; then
    compose ps || true
    fail "estas partes do NCommerce nao ficaram ligadas:$down." \
      "reinicie o computador e rode o instalador de novo. Se repetir, mande o log para o suporte NCommerce."
  fi
  echo "Containers ligados: mysql, redis, api, web e guard."

  body="$WORK/verify.json"
  ok=0
  for i in $(seq 1 36); do
    http="$(api_setup "$body")"
    if [ "$http" = "200" ] && grep -Eq '"setup_required":[[:space:]]*false' "$body"; then ok=1; break; fi
    sleep 5
  done
  if [ "$ok" -ne 1 ]; then
    if [ "$http" = "200" ]; then
      fail "o NCommerce esta no ar mas ainda sem a identificacao da empresa (token)." \
        "rode o instalador de novo. Se repetir, mande o log para o suporte NCommerce."
    fi
    compose logs --tail 40 api || true
    fail "a API do NCommerce nao respondeu na conferencia final (HTTP ${http:-000})." \
      "espere 5 minutos e rode o instalador de novo. Se repetir, mande o log para o suporte NCommerce."
  fi
  echo "API respondendo e identificada."

  ok=0
  for i in $(seq 1 24); do
    http="$(curl -sS -o /dev/null -w '%{http_code}' -m 5 http://127.0.0.1:4200/ 2>/dev/null || true)"
    case "$http" in 2??|3??) ok=1; break ;; esac
    sleep 5
  done
  if [ "$ok" -ne 1 ]; then
    compose logs --tail 40 web || true
    fail "a tela do NCommerce (porta 4200) nao abriu na conferencia final (HTTP ${http:-000})." \
      "rode o instalador de novo. Se repetir, mande o log para o suporte NCommerce."
  fi
  echo "Tela do sistema abrindo na porta 4200."

  # Inicio automatico: o Docker liga com o computador e religa os containers.
  if [ "$(systemctl is-enabled docker 2>/dev/null || true)" != "enabled" ]; then
    sudo systemctl enable docker >/dev/null 2>&1 || true
  fi
  if [ "$(systemctl is-enabled docker 2>/dev/null || true)" != "enabled" ]; then
    warn "o Docker nao ficou marcado para ligar junto com o computador. Depois de reiniciar, a loja pode nao subir sozinha: chame o suporte."
  fi
  for svc in mysql redis api web guard; do
    cid="$(compose ps -q "$svc" 2>/dev/null | head -n 1)"
    policy="$(sudo docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$cid" 2>/dev/null || true)"
    case "$policy" in
      unless-stopped|always) ;;
      *) warn "o container $svc nao esta marcado para religar sozinho (politica: ${policy:-nenhuma})." ;;
    esac
  done
  echo "Inicio automatico com o computador: conferido."
}

print_success() {
  local ip_addr
  ip_addr="$(host_lan_ips | cut -d, -f1)"
  ip_addr="${ip_addr:-127.0.0.1}"
  echo
  echo "=================================================================="
  if [ "${#NC_WARNINGS[@]}" -eq 0 ]; then
    echo "  INSTALACAO CONCLUIDA COM SUCESSO. O NCOMMERCE ESTA NO AR."
  else
    echo "  INSTALACAO CONCLUIDA. O NCOMMERCE ESTA NO AR, COM AVISOS."
  fi
  echo "=================================================================="
  echo "  Site:  http://${ip_addr}:4200"
  echo "  API:   http://${ip_addr}:3000"
  echo "  CUPS:  http://127.0.0.1:${CUPS_PORT}"
  echo "  SSH:   ${USER}@${ip_addr} porta 22"
  echo "Atualizar: atalho Atualizar NCommerce na area de trabalho."
  echo "O NCommerce liga sozinho quando o computador liga. Pode fechar esta janela."
  if [ "${#NC_WARNINGS[@]}" -gt 0 ]; then
    echo
    echo "Avisos (a loja funciona; avise o suporte NCommerce destes pontos):"
    printf '  - %s\n' "${NC_WARNINGS[@]}"
  fi
  if [ -n "$NC_LOG_FILE" ]; then
    echo "Log desta instalacao: $NC_LOG_FILE"
  fi
}

# ============================================================ roteiro

if [ "$RETOMADA" = "1" ]; then
  resumes="$(( $(state_get retomadas || echo 0) + 1 ))"
  state_set retomadas "$resumes"
  if [ "$resumes" -ge "$MAX_AUTO_RESUMES" ]; then
    # Nao abre sozinho para sempre: depois disso, so quando alguem rodar.
    rm -f "$AUTOSTART_FILE"
  fi
fi

step 1 "Conferindo o computador"
check_computer
state_done conferir

step 2 "Programas basicos"
ensure_base_packages
check_clock_and_master
state_done basicos

step 3 "Codigo de instalacao"
get_install_code
# Daqui em diante ninguem precisa digitar nada.
if [ "$MODE" = "instalacao" ]; then
  register_resume_trigger || true
fi
echo
echo "Agora e so esperar. Nao precisa digitar mais nada."
state_done codigo

step 4 "Acesso do suporte (SSH e AnyDesk)"
setup_support_access
state_done suporte

step 5 "Docker"
ensure_docker
state_done docker

step 6 "Arquivos e servicos do NCommerce"
install_store_files
state_done arquivos

step 7 "Baixando o NCommerce"
pull_images
state_done download

step 8 "Ligando o NCommerce"
start_stack
state_done ligar

step 9 "Dados da loja"
load_store_data
NCOMMERCE_TOKEN=""
state_done dados

step 10 "Conferencia final"
write_update_shortcut
verify_install
# A loja Docker esta no ar: a nativa desligada nesta execucao fica desligada.
NATIVE_STOPPED_NOW=0
state_done conferencia_final
state_set concluida "$(date +%s)"
state_unset codigo || true
state_unset backup_escolha || true
clear_resume_trigger

print_success
NC_VERDICT="ok"
exit 0
