#!/bin/bash
# Desinstalador da versao Docker do NCommerce no Linux (a do instalador_linux.sh).
# Nao use sudo neste arquivo. Ele chama sudo so onde precisa.
#
# Antes de remover, guarda (padrao) uma copia do banco da loja (dump), das
# configuracoes e dos volumes (certificado e notas, impressoras, imagens,
# documentos, .env) numa pasta FORA da instalacao, e diz onde ficou.
# Remove so o que o instalador criou: containers, volumes e imagens do
# NCommerce, servicos ncommerce-*, /opt/ncommerce, atalhos e ajustes do sistema.
# Docker, AnyDesk, SSH e o resto ficam, numa lista no fim.
#   --simular          so mostra o que faria. Nao muda nada e nao pede confirmacao.
#   --sem-backup       NAO guarda a copia antes de remover (os dados da loja se perdem).
#   --backup-em PASTA  onde criar a pasta da copia (padrao: a pasta pessoal, ~).
#
# Pede para digitar DESINSTALAR. Pode ser interrompido e rodado de novo: continua
# de onde parou (o progresso fica em ~/.ncommerce-desinstalacao) e nao refaz a copia.
set -Eeuo pipefail

UN_SIMULAR=0
SEM_BACKUP=0
BACKUP_BASE=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --simular|--dry-run) UN_SIMULAR=1 ;;
    --sem-backup) SEM_BACKUP=1 ;;
    --backup-em)
      [ "$#" -ge 2 ] || { echo "Use: --backup-em /caminho/da/pasta"; exit 1; }
      BACKUP_BASE="$2"
      shift
      ;;
    --backup-em=*) BACKUP_BASE="${1#--backup-em=}" ;;
    -h|--help|--ajuda) sed -n '2,17p' "$0"; exit 0 ;;
    *) echo "Opcao desconhecida: $1"; exit 1 ;;
  esac
  shift
done

ROOT="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="${NCOMMERCE_INSTALL_DIR:-/opt/ncommerce}"
INSTALLER_STATE_DIR="$HOME/.ncommerce-docker"
UN_DIR="$HOME/.ncommerce-desinstalacao"
LOG_DIR="$HOME/ncommerce-logs"
AUTOSTART_FILE="$HOME/.config/autostart/ncommerce-instalador.desktop"
DEFAULT_REGISTRY="registry.ncommerce.app:5050"
OLD_REGISTRY="ncommerce.app:5050"
PROJECT="$(basename "$INSTALL_DIR" | tr '[:upper:]' '[:lower:]')"
BACKUP_BASE="${BACKUP_BASE:-$HOME}"
# Volumes que nao vao para a copia: o banco vai pelo dump; log e arquivos de impressao sao descartaveis.
SKIP_VOLUMES=" mysql_data api_log api_print "
TUNNEL_HOST="tunnel.nlabs.live"

if [ "$(id -u)" -eq 0 ]; then
  echo "Rode sem sudo. Exemplo: ./desinstalador_linux.sh"
  exit 1
fi
for needed in lib/instalador.sh lib/desinstalador.sh lib/loja_docker.sh; do
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

if path_inside "$BACKUP_BASE" "$INSTALL_DIR"; then
  echo "A copia nao pode ficar dentro de $INSTALL_DIR (essa pasta sera apagada). Escolha outra com --backup-em."
  exit 1
fi

NC_VERDICT=""
NC_FAIL_MSG=""
NC_SIGNAL=""
DOCKER_OK=0
BACKUP_DIR=""
UN_DAEMON_RELOAD=0

fail() {
  NC_FAIL_MSG="$1"
  exit 1
}

on_exit() {
  local rc=$?
  trap - EXIT ERR INT TERM HUP
  set +e
  if [ "$NC_VERDICT" != "ok" ] && [ "$UN_SIMULAR" != "1" ]; then
    [ "$rc" -ne 0 ] || rc=1
    echo
    echo "=================================================================="
    if [ -n "$NC_SIGNAL" ]; then
      echo "  A DESINSTALACAO FOI INTERROMPIDA (janela fechada ou Ctrl+C)."
    else
      echo "  A DESINSTALACAO NAO TERMINOU."
    fi
    echo "=================================================================="
    [ -z "$NC_FAIL_MSG" ] || echo "O que aconteceu: $NC_FAIL_MSG"
    if [ -n "$BACKUP_DIR" ]; then
      echo "A copia da loja ja esta em: $BACKUP_DIR"
    fi
    echo "O que fazer: rode o desinstalador de novo. Ele continua de onde parou."
    [ -z "$NC_LOG_FILE" ] || echo "Log: $NC_LOG_FILE"
  fi
  lock_release
  log_stop
  exit "$rc"
}

# ---------------------------------------------------------------- consultas

# Imagens api e web do NCommerce, de qualquer registry e etiqueta (latest, keep-*, versoes).
ncommerce_images() {
  [ "$DOCKER_OK" = "1" ] || return 0
  sudo docker image ls --format '{{.Repository}}:{{.Tag}}' 2>/dev/null \
    | grep -E '/ncommerce/(api|web):' | grep -v ':<none>$' | sort -u || true
}

# Registries em que este computador entrou com o token da empresa.
registries() {
  local r seen=" "
  for r in "$(state_get registro)" "$DEFAULT_REGISTRY" "$OLD_REGISTRY"; do
    [ -n "$r" ] || continue
    case "$seen" in *" $r "*) continue ;; esac
    seen="$seen$r "
    printf '%s\n' "$r"
  done
}

# ---------------------------------------------------------------- copia

backup_store() {
  local saved volumes volume name plugins
  if [ "$SEM_BACKUP" = "1" ]; then
    echo "SEM COPIA (--sem-backup): o banco e os arquivos da loja serao apagados sem copia."
    return 0
  fi
  saved="$(state_get backup_dir)"
  if [ -n "$saved" ] && [ -f "$saved/banco-ncommerce_api_production.sql.gz" ] && [ ! -e "$saved/INCOMPLETO" ]; then
    BACKUP_DIR="$saved"
    echo "A copia ja foi feita numa execucao anterior: $saved"
    return 0
  fi
  volumes="$(docker_volumes)"
  if ! has_compose && [ -z "$volumes" ]; then
    echo "Nao ha banco nem volumes do NCommerce neste computador: nada para copiar."
    return 0
  fi
  if [ "$DOCKER_OK" != "1" ]; then
    fail "o Docker nao esta respondendo, e a copia do banco precisa dele. Ligue o Docker (sudo systemctl start docker) e rode de novo, ou use --sem-backup para apagar sem copia."
  fi
  if [ "$UN_SIMULAR" = "1" ]; then
    echo "  [simular] criar a pasta da copia em $(abs_path "$BACKUP_BASE")/ncommerce-backup-desinstalacao-<data>"
    echo "  [simular] copia do banco ncommerce_api_production (mysqldump) -> banco-ncommerce_api_production.sql.gz"
    if has_compose; then
      echo "  [simular] copia da pasta $INSTALL_DIR (.env, compose, versoes) -> instalacao/"
    fi
    while IFS= read -r volume; do
      [ -n "$volume" ] || continue
      name="${volume#"${PROJECT}"_}"
      case "$SKIP_VOLUMES" in *" $name "*) continue ;; esac
      echo "  [simular] copia do volume $volume -> volumes/$name.tar.gz"
    done <<< "$volumes"
    return 0
  fi
  if ! has_compose; then
    fail "a pasta $INSTALL_DIR nao tem o docker-compose.yml, e sem ele nao consigo ligar o banco para copiar. Chame o suporte NCommerce, ou use --sem-backup para apagar sem copia."
  fi

  BACKUP_DIR="$(new_backup_dir "$BACKUP_BASE")" || fail "nao consegui criar a pasta da copia em $BACKUP_BASE."
  : > "$BACKUP_DIR/INCOMPLETO"
  echo "Guardando a copia da loja em $BACKUP_DIR ..."
  if ! mysql_running; then
    echo "  - ligando o banco de dados para copiar"
    compose up -d mysql >/dev/null 2>&1 || fail "nao consegui ligar o banco de dados para a copia. Nada foi removido."
  fi
  wait_mysql || fail "o banco de dados nao respondeu para a copia. Nada foi removido."
  echo "  - banco de dados (pode levar alguns minutos)"
  dump_to "$BACKUP_DIR/banco-ncommerce_api_production.sql.gz" \
    || fail "a copia do banco de dados nao ficou completa. Nada foi removido."
  echo "  - configuracoes ($INSTALL_DIR)"
  sudo cp -a "$INSTALL_DIR" "$BACKUP_DIR/instalacao" || fail "nao consegui copiar $INSTALL_DIR. Nada foi removido."
  plugins="$(env_read "$INSTALL_DIR/.env" NCOMMERCE_PLUGINS_DIR)"
  if [ -n "$plugins" ] && [ -d "$plugins" ]; then
    cp -a "$plugins" "$BACKUP_DIR/plugins" || fail "nao consegui copiar os plugins ($plugins). Nada foi removido."
  fi
  mkdir -p "$BACKUP_DIR/volumes"
  while IFS= read -r volume; do
    [ -n "$volume" ] || continue
    name="${volume#"${PROJECT}"_}"
    case "$SKIP_VOLUMES" in *" $name "*) continue ;; esac
    echo "  - volume $name"
    archive_volume "$volume" "$BACKUP_DIR/volumes" || fail "a copia do volume $volume falhou. Nada foi removido."
  done <<< "$volumes"
  sudo chown -R "$(id -u):$(id -g)" "$BACKUP_DIR" 2>/dev/null || true
  chmod -R go-rwx "$BACKUP_DIR" 2>/dev/null || true
  cat > "$BACKUP_DIR/LEIA-ME.txt" <<EOF
Copia do NCommerce feita pelo desinstalador em $(date '+%d/%m/%Y %H:%M').

banco-ncommerce_api_production.sql.gz  banco de dados da loja (mysqldump)
instalacao/                             a pasta $INSTALL_DIR (.env, compose, versoes guardadas)
volumes/*.tar.gz                        arquivos da loja: nfce_data (certificado e notas),
                                        cups_data (impressoras), api_env (.env.production da API),
                                        api_uploads (imagens), api_docs (documentos), api_backups
plugins/                                os plugins da loja (se havia)

Tem senhas e o certificado digital: guarde em lugar seguro e nao compartilhe.
Para restaurar numa instalacao nova, chame o suporte NCommerce.
EOF
  rm -f "$BACKUP_DIR/INCOMPLETO"
  state_set backup_dir "$BACKUP_DIR"
  echo "Copia completa e conferida: $BACKUP_DIR"
}

# ---------------------------------------------------------------- remocao

remove_services() {
  local unit
  for unit in ncommerce-anydesk-id.service ncommerce-net-check.timer ncommerce-net-check.service \
              ncommerce-tunnel-route.timer ncommerce-tunnel-route.service; do
    remove_unit "$unit"
  done
  if [ "$UN_DAEMON_RELOAD" = "1" ] && [ "$UN_SIMULAR" != "1" ]; then
    sudo systemctl daemon-reload >/dev/null 2>&1 || true
  fi
  if [ -e "$AUTOSTART_FILE" ] || [ -e "$INSTALLER_STATE_DIR/retomar-instalacao.sh" ]; then
    act "apagar a retomada automatica do instalador ($AUTOSTART_FILE)" \
      rm -f "$AUTOSTART_FILE" "$INSTALLER_STATE_DIR/retomar-instalacao.sh"
  fi
}

remove_containers_and_volumes() {
  local containers volumes
  [ "$DOCKER_OK" = "1" ] || return 0
  if has_compose && { [ -n "$(docker_containers)" ] || [ -n "$(docker_volumes)" ]; }; then
    act "desligar e apagar os containers, a rede e os volumes do NCommerce (docker compose down --volumes)" \
      quiet compose down --volumes --remove-orphans || fail "o docker compose down falhou."
  fi
  # Sobras sem o compose (pasta apagada numa execucao anterior, nome de projeto antigo).
  containers="$(docker_containers | tr '\n' ' ')"
  if [ -n "${containers// /}" ] && { [ "$UN_SIMULAR" != "1" ] || ! has_compose; }; then
    # shellcheck disable=SC2086
    act "apagar os containers do NCommerce que sobraram: $containers" sudo docker rm -f $containers
  fi
  volumes="$(docker_volumes | tr '\n' ' ')"
  if [ -n "${volumes// /}" ] && { [ "$UN_SIMULAR" != "1" ] || ! has_compose; }; then
    # shellcheck disable=SC2086
    act "apagar os volumes do NCommerce que sobraram: $volumes" sudo docker volume rm $volumes
  fi
}

remove_images() {
  local image reg
  [ "$DOCKER_OK" = "1" ] || return 0
  while IFS= read -r image; do
    [ -n "$image" ] || continue
    act "apagar a imagem $image" quiet sudo docker rmi "$image" || warn "nao consegui apagar a imagem $image."
  done < <(ncommerce_images)
  while IFS= read -r reg; do
    if sudo test -f /root/.docker/config.json && sudo grep -qF "\"$reg\"" /root/.docker/config.json 2>/dev/null; then
      act "sair do registry $reg (login com o token da empresa)" quiet sudo docker logout "$reg" || true
    fi
  done < <(registries)
  for image in mysql:8.0 redis:7-alpine docker:27.5.1-cli; do
    if sudo docker image inspect "$image" >/dev/null 2>&1; then
      manual "imagem Docker $image (generica; usada pelo NCommerce, pode servir a outro programa): sudo docker rmi $image"
    fi
  done
}

# A rota /32 do tunel que o tunnel-route.sh grava no NetworkManager.
remove_tunnel_route() {
  local ip conn routes kept
  ip="$(getent ahostsv4 "$TUNNEL_HOST" 2>/dev/null | awk 'NR == 1 { print $1 }' || true)"
  if [ -z "$ip" ]; then
    ip="$(sed -n 's/^dest=//p' /run/ncommerce/tunnel-route.state 2>/dev/null | head -n 1 || true)"
  fi
  if [ -z "$ip" ]; then
    if command -v nmcli >/dev/null 2>&1; then
      manual "rota fixa do $TUNNEL_HOST (/32) no NetworkManager, se houver: confira com nmcli -g ipv4.routes connection show <conexao>"
    fi
    return 0
  fi
  if ip route show "$ip/32" 2>/dev/null | grep -q .; then
    act "apagar a rota do tunel ($ip/32)" sudo ip route del "$ip/32" || true
  fi
  command -v nmcli >/dev/null 2>&1 || return 0
  while IFS= read -r conn; do
    [ -n "$conn" ] || continue
    routes="$(nmcli -g ipv4.routes connection show "$conn" 2>/dev/null || true)"
    printf '%s' "$routes" | grep -q "$ip/32" || continue
    kept="$(printf '%s' "$routes" | tr ',' '\n' | sed 's/^ *//' | grep -v "^$ip/32" | paste -sd, - | sed 's/,/, /g')"
    act "tirar a rota do tunel ($ip/32) da conexao $conn" sudo nmcli connection modify "$conn" ipv4.routes "$kept" || true
  done < <(nmcli -g NAME connection show 2>/dev/null || true)
}

remove_system_tweaks() {
  remove_tunnel_route
  # O instalador anula a regra do CUPS do Ubuntu (a impressora USB e do container).
  if [ -L /etc/udev/rules.d/70-printers.rules ] && [ "$(readlink /etc/udev/rules.d/70-printers.rules)" = "/dev/null" ]; then
    act "devolver a impressora USB ao CUPS do Ubuntu (/etc/udev/rules.d/70-printers.rules)" sh -c '
      sudo rm -f /etc/udev/rules.d/70-printers.rules
      sudo udevadm control --reload >/dev/null 2>&1 || true'
  fi
  remove_ssh_keepalive
  if command -v ufw >/dev/null 2>&1; then
    local port
    for port in 3000 4200; do
      if sudo ufw status 2>/dev/null | grep -qE "^$port/tcp[[:space:]]"; then
        act "fechar a porta $port no firewall (ufw)" quiet sudo ufw delete allow "$port/tcp" || true
      fi
    done
    manual "porta 22 (SSH) liberada no firewall (ufw): sudo ufw delete allow 22/tcp"
  fi
}

remove_files() {
  if [ -e "$INSTALL_DIR" ]; then
    act "apagar a pasta $INSTALL_DIR" sudo rm -rf "$INSTALL_DIR"
  fi
  remove_desktop_shortcut "Atualizar NCommerce.desktop"
  remove_plugins_dir
  if [ -e "$INSTALLER_STATE_DIR" ]; then
    act "apagar o progresso do instalador ($INSTALLER_STATE_DIR)" rm -rf "$INSTALLER_STATE_DIR"
  fi
}

# Documentos/ncommerce/plugins, a pasta que o instalador cria (ja esta na copia).
# Igual ao desinstalador do Windows: sai a pasta, o LEIA-ME.txt ao lado e a
# pasta de cima se ficar vazia. Uma pasta que o suporte pos em outro lugar fica.
remove_plugins_dir() {
  local plugins parent
  plugins="$(state_get plugins_dir)"
  if [ -z "$plugins" ] && [ -f "$INSTALL_DIR/.env" ]; then
    plugins="$(env_read "$INSTALL_DIR/.env" NCOMMERCE_PLUGINS_DIR)"
  fi
  [ -n "$plugins" ] || return 0
  case "${plugins%/}" in
    */ncommerce/plugins) ;;
    *)
      [ ! -d "$plugins" ] || manual "a pasta de plugins $plugins (fora do lugar padrao, pode ter outras coisas; ja esta na copia)"
      return 0
      ;;
  esac
  plugins="${plugins%/}"
  parent="$(dirname "$plugins")"
  if [ -e "$plugins" ]; then
    act "apagar a pasta de plugins $plugins (ja esta na copia)" rm -rf "$plugins"
  fi
  if [ -e "$parent/LEIA-ME.txt" ]; then
    act "apagar $parent/LEIA-ME.txt" rm -f "$parent/LEIA-ME.txt"
  fi
  if [ "$UN_SIMULAR" != "1" ] && [ -d "$parent" ] && [ -z "$(ls -A "$parent" 2>/dev/null)" ]; then
    rmdir "$parent" 2>/dev/null || true
  fi
}

list_leftovers() {
  manual "Docker (o instalador pode ter instalado; outros programas podem usar): sudo apt remove docker.io docker-compose-v2"
  manual "o usuario $USER no grupo docker: sudo gpasswd -d $USER docker"
  if command -v anydesk >/dev/null 2>&1; then
    manual "AnyDesk e a fonte de pacotes dele: sudo apt remove anydesk; sudo rm /etc/apt/sources.list.d/anydesk-stable.list /etc/apt/trusted.gpg.d/anydesk.gpg"
  fi
  manual "servidor SSH (openssh-server): o suporte entra por ele; sudo apt remove openssh-server"
  if command -v arp-scan >/dev/null 2>&1; then
    manual "arp-scan (verificador de conflito de IP): sudo apt remove arp-scan"
  fi
  if [ -d "$LOG_DIR" ]; then
    manual "os logs da instalacao e desta desinstalacao: $LOG_DIR"
  fi
  if [ -d /var/lib/ncommerce-nativo ] || [ -d "$HOME/NCommerce/ncommerce_api" ]; then
    manual "uma instalacao NATIVA antiga (sem Docker) do NCommerce: use advanced/desinstalador_nativo.sh"
  fi
}

run_all() {
  echo
  echo "1. Copia da loja"
  backup_store
  echo
  echo "2. Servicos do NCommerce"
  remove_services
  echo
  echo "3. Containers e volumes"
  remove_containers_and_volumes
  echo
  echo "4. Imagens do NCommerce"
  remove_images
  echo
  echo "5. Ajustes do sistema"
  remove_system_tweaks
  echo
  echo "6. Arquivos e atalhos"
  remove_files
  list_leftovers
}

# ================================================================ inicio

if [ "$UN_SIMULAR" != "1" ]; then
  mkdir -p "$UN_DIR"
  chmod 700 "$UN_DIR" 2>/dev/null || true
  if ! lock_acquire "$UN_DIR/desinstalador.lock"; then
    echo "O desinstalador do NCommerce ja esta aberto em outra janela."
    exit 2
  fi
fi
if [ -e "$INSTALLER_STATE_DIR/instalador.lock" ] && command -v flock >/dev/null 2>&1 \
   && ! flock -n "$INSTALLER_STATE_DIR/instalador.lock" true 2>/dev/null; then
  echo "O instalador ou uma atualizacao do NCommerce esta rodando agora. Espere terminar e rode de novo."
  lock_release
  exit 2
fi

trap on_exit EXIT
trap 'NC_SIGNAL=INT; exit 130' INT
trap 'NC_SIGNAL=TERM; exit 143' TERM
trap 'NC_SIGNAL=HUP; exit 129' HUP

if [ "$UN_SIMULAR" = "1" ]; then
  NC_STATE_FILE="$UN_DIR/desinstalacao.estado"
else
  log_start "$LOG_DIR" desinstalacao || { echo "Sem log (nao consegui criar $LOG_DIR)."; NC_LOG_FILE=""; }
  state_init "$UN_DIR/desinstalacao.estado"
fi

echo "=================================================================="
if [ "$UN_SIMULAR" = "1" ]; then
  echo "  DESINSTALADOR DO NCOMMERCE (Docker) - SIMULACAO: nada sera mudado"
else
  echo "  DESINSTALADOR DO NCOMMERCE (Docker)"
fi
echo "=================================================================="
echo "A senha do computador pode ser pedida (para ver e remover o que e do NCommerce)."
sudo -v || { echo "Sem a senha do sudo nao consigo continuar."; exit 1; }

if command -v docker >/dev/null 2>&1; then
  if sudo docker info >/dev/null 2>&1; then
    DOCKER_OK=1
  elif [ "$UN_SIMULAR" != "1" ]; then
    fail "o Docker esta instalado mas nao responde. Ligue o Docker (sudo systemctl start docker) e rode de novo."
  else
    echo "AVISO: o Docker nao responde; a simulacao nao consegue listar containers, volumes e imagens."
  fi
fi

# O que vem do .env precisa ser lido antes de a pasta ser apagada (e numa
# segunda execucao ela pode nao existir mais).
if [ "$UN_SIMULAR" != "1" ] && [ -f "$INSTALL_DIR/.env" ]; then
  reg="$(env_read "$INSTALL_DIR/.env" NCOMMERCE_REGISTRY)"
  [ -z "$reg" ] || state_set registro "$reg"
  plugins_dir="$(env_read "$INSTALL_DIR/.env" NCOMMERCE_PLUGINS_DIR)"
  [ -z "$plugins_dir" ] || state_set plugins_dir "$plugins_dir"
fi
# A pasta de plugins tambem e apagada: a copia nao pode ficar dentro dela.
plugins_dir="$(state_get plugins_dir)"
if [ -z "$plugins_dir" ] && [ -f "$INSTALL_DIR/.env" ]; then
  plugins_dir="$(env_read "$INSTALL_DIR/.env" NCOMMERCE_PLUGINS_DIR)"
fi
if [ "$SEM_BACKUP" != "1" ] && [ -n "$plugins_dir" ] && path_inside "$BACKUP_BASE" "$plugins_dir"; then
  echo "A copia nao pode ficar dentro de $plugins_dir (essa pasta sera apagada). Escolha outra com --backup-em."
  NC_VERDICT="ok"
  exit 1
fi
if [ -n "$(state_get backup_dir)" ] || [ -n "$(state_get inicio)" ]; then
  echo "Continuando a desinstalacao comecada em $(date -d "@$(state_get inicio)" '+%d/%m/%Y %H:%M' 2>/dev/null || echo 'outra execucao')."
fi

if ! has_compose && [ ! -e "$INSTALL_DIR" ] && [ -z "$(docker_volumes)" ] && [ -z "$(ncommerce_images)" ] \
   && [ ! -e /etc/systemd/system/ncommerce-anydesk-id.service ] && [ ! -e /etc/systemd/system/ncommerce-net-check.timer ]; then
  echo
  echo "Nao achei a versao Docker do NCommerce neste computador ($INSTALL_DIR, volumes, imagens e servicos)."
fi

# Primeiro mostra tudo o que vai acontecer (como no --simular).
REAL_MODE="$UN_SIMULAR"
UN_SIMULAR=1
echo
echo "O que sera feito:"
run_all
if [ "$SEM_BACKUP" = "1" ]; then
  echo
  echo "!!! ATENCAO: --sem-backup. O banco de dados, as notas, o certificado e as configuracoes da loja"
  echo "!!! serao APAGADOS SEM COPIA. Nao ha como recuperar depois."
else
  echo
  echo "A copia fica numa pasta fora da instalacao, em $(abs_path "$BACKUP_BASE"). Se ela falhar, nada e removido."
fi
print_manual
UN_MANUAL=()
UN_SIMULAR="$REAL_MODE"

if [ "$UN_SIMULAR" = "1" ]; then
  echo
  echo "SIMULACAO: nada foi mudado. Para desinstalar de verdade, rode sem --simular."
  NC_VERDICT="ok"
  exit 0
fi

if ! confirm_uninstall; then
  echo "Cancelado. Nada foi removido."
  NC_VERDICT="ok"
  if [ -z "$(state_get inicio)" ]; then
    lock_release
    rm -rf "$UN_DIR"
  fi
  exit 1
fi
[ -n "$(state_get inicio)" ] || state_set inicio "$(date +%s)"

run_all
[ "$UN_DAEMON_RELOAD" = "0" ] || sudo systemctl daemon-reload >/dev/null 2>&1 || true

echo
echo "=================================================================="
echo "  DESINSTALACAO CONCLUIDA. O NCOMMERCE (Docker) FOI REMOVIDO."
echo "=================================================================="
if [ -n "$BACKUP_DIR" ]; then
  echo "Copia da loja (banco, configuracoes e arquivos): $BACKUP_DIR"
  echo "Ela tem senhas e o certificado digital: guarde em lugar seguro."
elif [ "$SEM_BACKUP" = "1" ]; then
  echo "Sem copia (--sem-backup)."
fi
if [ "${#NC_WARNINGS[@]}" -gt 0 ]; then
  echo
  echo "Avisos:"
  printf '  - %s\n' "${NC_WARNINGS[@]}"
fi
print_manual
[ -z "$NC_LOG_FILE" ] || echo "Log: $NC_LOG_FILE"
NC_VERDICT="ok"
lock_release
rm -rf "$UN_DIR"
exit 0
