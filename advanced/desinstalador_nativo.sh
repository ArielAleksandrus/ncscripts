#!/bin/bash
# Desinstalador da instalacao NATIVA do NCommerce (sem Docker: a do
# advanced/instalador_nativo.sh, num Ubuntu ou dentro do WSL do Windows).
# Rode da raiz do ncscripts, sem sudo: ./advanced/desinstalador_nativo.sh
#
# Antes de remover, guarda (padrao) o banco da loja (dump), o .env.production,
# o /etc/environment, os sites do nginx, o cron e os arquivos de ~/NCommerce
# (sem node_modules, .git, logs e temporarios) numa pasta FORA da instalacao.
# Remove so o que e claramente do NCommerce: sites do nginx, linhas do cron,
# Sidekiq e tunel nativos, banco ncommerce_api_production e usuario 'ncommerce'
# do MySQL, as linhas do .env que o instalador pos no /etc/environment, a pasta
# ~/NCommerce, o atalho Restauracao e o progresso do instalador. Ruby, MySQL,
# nginx, Redis, Chrome, Java, AnyDesk, Dropbox e o resto ficam, numa lista no fim.
#   --simular          so mostra o que faria. Nao muda nada e nao pede confirmacao.
#   --sem-backup       NAO guarda a copia antes de remover (os dados da loja se perdem).
#   --backup-em PASTA  onde criar a pasta da copia (padrao: a pasta pessoal, ~).
#
# Pede para digitar DESINSTALAR. Pode ser interrompido e rodado de novo: continua
# de onde parou (progresso em ~/.ncommerce-desinstalacao) e nao refaz a copia.
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
UN_DIR="$HOME/.ncommerce-desinstalacao-nativo"
LOG_DIR="$HOME/ncommerce-logs"
DB_NAME="ncommerce_api_production"
SITES=(ncommerce ncommerce-api)
SIDEKIQ_PATTERN='^sidekiq [0-9]'
TUNNEL_PATTERN='^ssh .*-R .*tunnel[.]nlabs[.]live'
BACKUP_BASE="${BACKUP_BASE:-$HOME}"
IS_WSL=0
if [ -n "${WSL_DISTRO_NAME:-}" ] || grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null; then
  IS_WSL=1
fi

if [ "$(id -u)" -eq 0 ]; then
  echo "Rode sem sudo. Exemplo: ./advanced/desinstalador_nativo.sh"
  exit 1
fi
for needed in lib/instalador.sh lib/desinstalador.sh; do
  if [ ! -f "$ROOT/$needed" ]; then
    echo "Nao achei $ROOT/$needed. Rode de dentro da pasta do ncscripts inteira."
    exit 1
  fi
done
# shellcheck source=lib/instalador.sh
. "$ROOT/lib/instalador.sh"
# shellcheck source=lib/desinstalador.sh
. "$ROOT/lib/desinstalador.sh"

if path_inside "$BACKUP_BASE" "$NC_HOME"; then
  echo "A copia nao pode ficar dentro de $NC_HOME (essa pasta sera apagada). Escolha outra com --backup-em."
  exit 1
fi

NC_VERDICT=""
NC_FAIL_MSG=""
NC_SIGNAL=""
BACKUP_DIR=""
UN_DAEMON_RELOAD=0
MYSQL_OK=0

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
    [ -z "$BACKUP_DIR" ] || echo "A copia da loja ja esta em: $BACKUP_DIR"
    echo "O que fazer: rode o desinstalador de novo. Ele continua de onde parou."
    [ -z "$NC_LOG_FILE" ] || echo "Log: $NC_LOG_FILE"
  fi
  lock_release
  log_stop
  exit "$rc"
}

# ---------------------------------------------------------------- consultas

db_exists() {
  [ "$MYSQL_OK" = "1" ] || return 1
  [ -n "$(sudo mysql -N -e "SHOW DATABASES LIKE '$DB_NAME'" 2>/dev/null || true)" ]
}

db_user_exists() {
  [ "$MYSQL_OK" = "1" ] || return 1
  [ -n "$(sudo mysql -N -e "SELECT 1 FROM mysql.user WHERE user='ncommerce' AND host='localhost'" 2>/dev/null || true)" ]
}

# Processos fora de container (os do Docker ficam num cgroup docker).
native_pids() {
  local pid
  for pid in $(pgrep -f "$1" 2>/dev/null || true); do
    if ! grep -qE 'docker|containerd' "/proc/$pid/cgroup" 2>/dev/null; then
      echo "$pid"
    fi
  done
}

# As linhas do .env.production que o instalador acrescentou ao /etc/environment.
# Guardadas em $UN_DIR (so o usuario le) enquanto a desinstalacao nao termina:
# depois que ~/NCommerce some, sem elas nao da para saber quais linhas tirar.
environment_lines_file() { printf '%s\n' "$UN_DIR/linhas-environment"; }

remember_environment_lines() {
  local file
  file="$(environment_lines_file)"
  [ -f "$ENV_FILE" ] || return 0
  [ "$UN_SIMULAR" != "1" ] || return 0
  grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$ENV_FILE" > "$file.tmp" 2>/dev/null || true
  chmod 600 "$file.tmp"
  mv -f "$file.tmp" "$file"
}

environment_lines_present() {
  local file="$1"
  [ -s "$file" ] && [ -f "$ENVIRONMENT_FILE" ] && grep -qxF -f "$file" "$ENVIRONMENT_FILE"
}

# ---------------------------------------------------------------- copia

backup_store() {
  local saved
  if [ "$SEM_BACKUP" = "1" ]; then
    echo "SEM COPIA (--sem-backup): o banco e os arquivos da loja serao apagados sem copia."
    return 0
  fi
  saved="$(state_get backup_dir)"
  if [ -n "$saved" ] && [ -f "$saved/LEIA-ME.txt" ] && [ ! -e "$saved/INCOMPLETO" ]; then
    BACKUP_DIR="$saved"
    echo "A copia ja foi feita numa execucao anterior: $saved"
    return 0
  fi
  if ! db_exists && [ ! -d "$NC_HOME" ]; then
    echo "Nao ha banco nem pasta do NCommerce neste computador: nada para copiar."
    return 0
  fi
  if [ "$UN_SIMULAR" = "1" ]; then
    echo "  [simular] criar a pasta da copia em $(abs_path "$BACKUP_BASE")/ncommerce-backup-desinstalacao-<data>"
    if db_exists; then
      echo "  [simular] copia do banco $DB_NAME (mysqldump) -> banco-$DB_NAME.sql.gz"
    elif [ "$MYSQL_OK" != "1" ]; then
      echo "  [simular] o MySQL nao responde: a copia do banco vai falhar ate ele ser ligado (sudo systemctl start mysql)"
    fi
    [ ! -d "$NC_HOME" ] || echo "  [simular] copia de $NC_HOME (sem node_modules, .git, logs e temporarios) -> arquivos-NCommerce.tar.gz"
    echo "  [simular] copia do .env.production, /etc/environment, sites do nginx e cron -> config/"
    return 0
  fi
  if [ "$MYSQL_OK" != "1" ] && [ -d "$API_DIR" ]; then
    fail "o MySQL nao responde, e a copia do banco precisa dele. Ligue o MySQL (sudo systemctl start mysql) e rode de novo, ou use --sem-backup para apagar sem copia."
  fi

  BACKUP_DIR="$(new_backup_dir "$BACKUP_BASE")" || fail "nao consegui criar a pasta da copia em $BACKUP_BASE."
  : > "$BACKUP_DIR/INCOMPLETO"
  echo "Guardando a copia da loja em $BACKUP_DIR ..."
  if db_exists; then
    echo "  - banco de dados (pode levar alguns minutos)"
    rm -f "$BACKUP_DIR/banco.sql"
    sudo mysqldump --single-transaction --quick --routines --no-tablespaces \
      --result-file="$BACKUP_DIR/banco.sql" "$DB_NAME" < /dev/null \
      || fail "a copia do banco de dados falhou. Nada foi removido."
    sudo chown "$(id -u):$(id -g)" "$BACKUP_DIR/banco.sql" 2>/dev/null || true
    tail -c 300 "$BACKUP_DIR/banco.sql" | grep -q "Dump completed" \
      || fail "a copia do banco de dados nao ficou completa. Nada foi removido."
    gzip -f "$BACKUP_DIR/banco.sql"
    mv -f "$BACKUP_DIR/banco.sql.gz" "$BACKUP_DIR/banco-$DB_NAME.sql.gz"
    dump_ok "$BACKUP_DIR/banco-$DB_NAME.sql.gz" || fail "a copia do banco de dados nao ficou completa. Nada foi removido."
  fi
  mkdir -p "$BACKUP_DIR/config"
  if [ -f "$ENV_FILE" ]; then
    cp -p "$ENV_FILE" "$BACKUP_DIR/config/env.production" || fail "nao consegui copiar o $ENV_FILE. Nada foi removido."
  fi
  if [ -f "$ENVIRONMENT_FILE" ]; then
    sudo cat "$ENVIRONMENT_FILE" > "$BACKUP_DIR/config/environment" || fail "nao consegui copiar o $ENVIRONMENT_FILE. Nada foi removido."
  fi
  local site
  for site in "${SITES[@]}"; do
    if [ -f "$NGINX_DIR/sites-available/$site" ]; then
      mkdir -p "$BACKUP_DIR/config/nginx"
      sudo cat "$NGINX_DIR/sites-available/$site" > "$BACKUP_DIR/config/nginx/$site" || true
    fi
  done
  { cron_ncommerce_lines "$USER"; cron_ncommerce_lines root; } > "$BACKUP_DIR/config/cron.txt" 2>/dev/null || true
  if [ -d "$NC_HOME" ]; then
    echo "  - arquivos de $NC_HOME (notas, certificado, imagens, documentos)"
    tar czf "$BACKUP_DIR/arquivos-NCommerce.tar.gz" -C "$HOME" \
      --exclude=node_modules --exclude=.git --exclude=tmp --exclude=log --exclude=dist \
      --exclude='vendor/bundle' --exclude='.angular' --warning=no-file-changed NCommerce \
      || fail "a copia de $NC_HOME falhou. Nada foi removido."
    gzip -t "$BACKUP_DIR/arquivos-NCommerce.tar.gz" || fail "a copia de $NC_HOME nao ficou inteira. Nada foi removido."
  fi
  chmod -R go-rwx "$BACKUP_DIR" 2>/dev/null || true
  cat > "$BACKUP_DIR/LEIA-ME.txt" <<EOF
Copia do NCommerce (instalacao nativa) feita pelo desinstalador em $(date '+%d/%m/%Y %H:%M').

banco-$DB_NAME.sql.gz   banco de dados da loja (mysqldump), se havia
arquivos-NCommerce.tar.gz          a pasta ~/NCommerce, sem node_modules, .git, logs e temporarios
config/env.production              o .env.production da API
config/environment                 o /etc/environment como estava
config/nginx/                      os sites ncommerce e ncommerce-api do nginx
config/cron.txt                    as linhas do NCommerce no cron

Tem senhas e o certificado digital: guarde em lugar seguro e nao compartilhe.
Para restaurar numa instalacao nova, chame o suporte NCommerce.
EOF
  rm -f "$BACKUP_DIR/INCOMPLETO"
  state_set backup_dir "$BACKUP_DIR"
  echo "Copia completa e conferida: $BACKUP_DIR"
}

# ---------------------------------------------------------------- remocao

stop_store() {
  local site changed=0 pids who unit
  for site in "${SITES[@]}"; do
    if [ -e "$NGINX_DIR/sites-enabled/$site" ] || [ -L "$NGINX_DIR/sites-enabled/$site" ] \
       || [ -e "$NGINX_DIR/sites-available/$site" ]; then
      act "tirar o site $site do nginx" sudo rm -f "$NGINX_DIR/sites-enabled/$site" "$NGINX_DIR/sites-available/$site"
      changed=1
    fi
  done
  if [ "$changed" = "1" ] && command -v nginx >/dev/null 2>&1; then
    act "reiniciar o nginx (para o Passenger e a API nativa)" quiet sh -c \
      'sudo systemctl restart nginx 2>/dev/null || sudo service nginx restart'  || true
  fi
  for who in "$USER" root; do
    if [ -n "$(cron_ncommerce_lines "$who")" ]; then
      act "tirar do cron do $who as linhas do NCommerce (backup, chown_files)" strip_cron_lines "$who"
    fi
  done
  for pattern in "$SIDEKIQ_PATTERN" "$TUNNEL_PATTERN"; do
    pids="$(native_pids "$pattern" | tr '\n' ' ')"
    if [ -n "${pids// /}" ]; then
      # shellcheck disable=SC2086
      act "parar o processo nativo ($pattern): $pids" quiet sudo kill $pids || true
    fi
  done
  # Lojas antigas com o sidekiq.service do ncommerce_api.
  unit=/etc/systemd/system/sidekiq.service
  if [ -f "$unit" ] && grep -qi ncommerce "$unit" 2>/dev/null; then
    remove_unit sidekiq.service
  fi
  if [ "$UN_DAEMON_RELOAD" = "1" ] && [ "$UN_SIMULAR" != "1" ]; then
    sudo systemctl daemon-reload >/dev/null 2>&1 || true
  fi
}

drop_database() {
  if db_exists; then
    act "apagar o banco $DB_NAME do MySQL" sudo mysql -e "DROP DATABASE IF EXISTS \`$DB_NAME\`" \
      || fail "nao consegui apagar o banco $DB_NAME."
  fi
  if db_user_exists; then
    act "apagar o usuario 'ncommerce'@'localhost' do MySQL" sudo mysql -e "DROP USER IF EXISTS 'ncommerce'@'localhost'" || true
  fi
  if [ "$MYSQL_OK" != "1" ] && [ -d "$API_DIR" ]; then
    manual "o banco $DB_NAME e o usuario 'ncommerce' do MySQL (o MySQL nao respondia): sudo mysql -e \"DROP DATABASE $DB_NAME; DROP USER 'ncommerce'@'localhost'\""
  fi
}

clean_environment() {
  local lines tmp
  lines="$(environment_lines_file)"
  if [ ! -s "$lines" ] && [ "$UN_SIMULAR" = "1" ] && [ -f "$ENV_FILE" ]; then
    lines="$ENV_FILE"
  fi
  environment_lines_present "$lines" || return 0
  act "tirar do $ENVIRONMENT_FILE as linhas do .env do NCommerce (senhas e token)" sh -c '
    tmp="$(mktemp)" && grep -vxF -f "$1" "$2" > "$tmp"
    sudo install -m 644 "$tmp" "$2.novo" && sudo mv -f "$2.novo" "$2"
    rc=$?; rm -f "$tmp"; exit $rc' _ "$lines" "$ENVIRONMENT_FILE" \
    || fail "nao consegui limpar o $ENVIRONMENT_FILE."
}

remove_files() {
  if [ -e "$NC_HOME" ]; then
    act "apagar a pasta $NC_HOME" rm -rf "$NC_HOME"
  fi
  remove_desktop_shortcut "Restauracao.desktop"
  if [ -e "$HOME/.ncommerce-progress" ]; then
    act "apagar o progresso do instalador nativo ($HOME/.ncommerce-progress)" rm -rf "$HOME/.ncommerce-progress"
  fi
  if [ -e /var/lib/ncommerce-nativo ]; then
    act "apagar as anotacoes do desligar_nativo.sh (/var/lib/ncommerce-nativo)" sudo rm -rf /var/lib/ncommerce-nativo
  fi
  remove_ssh_keepalive
}

list_leftovers() {
  manual "Ruby (rbenv em ~/.rbenv e as duas linhas do rbenv no ~/.bashrc)"
  command -v nginx >/dev/null 2>&1 && manual "nginx e Passenger (/etc/nginx/conf.d/mod-http-passenger.conf, /etc/apt/sources.list.d/passenger.list): sudo apt remove nginx passenger"
  command -v mysql >/dev/null 2>&1 && manual "o servidor MySQL: sudo apt remove mysql-server"
  [ -e /usr/local/bin/redis-server ] && manual "Redis compilado em /usr/local/bin e /etc/systemd/system/redis-server.service.d/override.conf"
  command -v google-chrome >/dev/null 2>&1 && manual "Google Chrome: sudo apt remove google-chrome-stable"
  [ -e /usr/bin/phantomjs ] && manual "phantomjs (/usr/bin/phantomjs e /usr/local/lib/phantomjs)"
  command -v prince >/dev/null 2>&1 && manual "Prince (PDF): sudo apt remove prince"
  manual "Java (openjdk), ImageMagick e os drivers de impressora (Elgin, Bematech)"
  command -v anydesk >/dev/null 2>&1 && manual "AnyDesk: sudo apt remove anydesk"
  command -v teamviewer >/dev/null 2>&1 && manual "TeamViewer: sudo apt remove teamviewer"
  { [ -d "$HOME/.dropbox-dist" ] || [ -f "$HOME/.config/autostart/dropboxd.desktop" ]; } \
    && manual "Dropbox (~/.dropbox-dist e ~/.config/autostart/dropboxd.desktop)"
  [ -f "$HOME/.ssh/config" ] && grep -qs nlabs "$HOME/.ssh/config" && manual "o bloco nlabs do ~/.ssh/config (tunel de suporte)"
  manual "servidor SSH (openssh-server) e as portas 22, 80 e 443 no firewall (ufw)"
  if [ -d /opt/ncommerce ] || [ -f /etc/systemd/system/ncommerce-anydesk-id.service ]; then
    manual "a versao Docker do NCommerce tambem esta neste computador: use ./desinstalador_linux.sh"
  fi
  if [ "$IS_WSL" = "1" ]; then
    manual "no Windows (PowerShell como administrador): a tarefa agendada \"NCommerce WSL Startup\" (schtasks /delete /tn \"NCommerce WSL Startup\" /f), a pasta C:\\NCommerce\\wsl, as regras de firewall \"NCommerce WSL port 3000/4200\", o netsh portproxy das portas 3000 e 4200 e a distro Ubuntu do WSL"
  fi
  [ -d "$LOG_DIR" ] && manual "os logs desta desinstalacao: $LOG_DIR"
  return 0
}

run_all() {
  echo
  echo "1. Copia da loja"
  backup_store
  echo
  echo "2. Desligar o NCommerce nativo"
  stop_store
  echo
  echo "3. Banco de dados"
  drop_database
  echo
  echo "4. /etc/environment"
  clean_environment
  echo
  echo "5. Arquivos e atalhos"
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

trap on_exit EXIT
trap 'NC_SIGNAL=INT; exit 130' INT
trap 'NC_SIGNAL=TERM; exit 143' TERM
trap 'NC_SIGNAL=HUP; exit 129' HUP

if [ "$UN_SIMULAR" = "1" ]; then
  NC_STATE_FILE="$UN_DIR/desinstalacao.estado"
else
  log_start "$LOG_DIR" desinstalacao-nativo || { echo "Sem log (nao consegui criar $LOG_DIR)."; NC_LOG_FILE=""; }
  state_init "$UN_DIR/desinstalacao.estado"
fi

echo "=================================================================="
if [ "$UN_SIMULAR" = "1" ]; then
  echo "  DESINSTALADOR DO NCOMMERCE NATIVO (sem Docker) - SIMULACAO: nada sera mudado"
else
  echo "  DESINSTALADOR DO NCOMMERCE NATIVO (sem Docker)"
fi
echo "=================================================================="
echo "A senha do computador pode ser pedida (para ver e remover o que e do NCommerce)."
sudo -v || { echo "Sem a senha do sudo nao consigo continuar."; exit 1; }

if command -v mysql >/dev/null 2>&1 && sudo mysql -N -e "SELECT 1" >/dev/null 2>&1; then
  MYSQL_OK=1
fi
if [ -n "$(state_get inicio)" ]; then
  echo "Continuando a desinstalacao comecada em $(date -d "@$(state_get inicio)" '+%d/%m/%Y %H:%M' 2>/dev/null || echo 'outra execucao')."
fi
if [ ! -d "$NC_HOME" ] && ! db_exists && [ ! -e "$NGINX_DIR/sites-enabled/ncommerce-api" ]; then
  echo
  echo "Nao achei a instalacao nativa do NCommerce neste computador (~/NCommerce, banco e nginx)."
fi

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
remember_environment_lines

run_all

echo
echo "=================================================================="
echo "  DESINSTALACAO CONCLUIDA. O NCOMMERCE NATIVO FOI REMOVIDO."
echo "=================================================================="
if [ -n "$BACKUP_DIR" ]; then
  echo "Copia da loja (banco, configuracoes e arquivos): $BACKUP_DIR"
  echo "Ela tem senhas e o certificado digital: guarde em lugar seguro."
elif [ "$SEM_BACKUP" = "1" ]; then
  echo "Sem copia (--sem-backup)."
fi
print_manual
[ -z "$NC_LOG_FILE" ] || echo "Log: $NC_LOG_FILE"
NC_VERDICT="ok"
lock_release
rm -rf "$UN_DIR"
exit 0
