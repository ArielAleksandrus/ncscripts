#!/bin/bash
# =====================================================
# INSTALADOR ÚNICO NCOMMERCE - Ubuntu 20.04 / 22.04 / 24.04 / 26.04 e WSL (RESUMÍVEL + ROBUSTO)
# ✅ Não duplica rbenv • ✅ Pula clones já feitos • ✅ Corrige dependências
# =====================================================

set -e

IS_WSL=0
if [ -n "${WSL_DISTRO_NAME:-}" ] || grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null; then
  IS_WSL=1
fi

# Os caminhos /home/<usuario> precisam ser os do usuário que roda o script.
LINUX_USER="$(id -un)"
if [ "$LINUX_USER" = "root" ]; then
  echo "❌ Não rode como root (nem com sudo). Entre com o usuário Linux normal e rode ./instalador_unico.sh"
  exit 1
fi

# ====================== VERSÃO DO UBUNTU ======================
# O que muda entre versões (nomes de pacotes, Java, Prince) é decidido a partir daqui.
. /etc/os-release
UBUNTU_VERSION="${VERSION_ID:-}"
case "${ID:-}:$UBUNTU_VERSION" in
  ubuntu:20.04|ubuntu:22.04|ubuntu:24.04|ubuntu:26.04) ;;
  *)
    echo "⚠️  Este instalador suporta Ubuntu 20.04, 22.04, 24.04 e 26.04 (detectado: ${PRETTY_NAME:-desconhecido})."
    read -r -p "Continuar mesmo assim? [s/N] " CONTINUE_ANYWAY
    case "$CONTINUE_ANYWAY" in s|S) ;; *) exit 1 ;; esac
    ;;
esac

PROGRESS_DIR="$HOME/.ncommerce-progress"
mkdir -p "$PROGRESS_DIR"

is_step_done() { [ -f "$PROGRESS_DIR/step$1.done" ]; }
mark_step_done() { touch "$PROGRESS_DIR/step$1.done"; echo "✅ PASSO $1/7 marcado como concluído"; }

echo "=== INSTALADOR COMPLETO NCOMMERCE (${PRETTY_NAME:-Ubuntu} - RESUMÍVEL) ==="
echo

# ====================== SUDO KEEP-ALIVE ======================
echo "🔑 Digite sua senha sudo (será usada apenas uma vez):"
sudo -v
sudo_keep_alive() {
  while true; do sudo -n true 2>/dev/null || break; sleep 60; done
}
sudo_keep_alive &
KEEP_ALIVE_PID=$!

# Ubuntu recem-instalado nao escuta SSH. Abre antes dos passos longos.
enable_ssh() {
  echo "Abrindo o SSH na porta 22..."
  if ! dpkg -s openssh-server >/dev/null 2>&1; then
    sudo DEBIAN_FRONTEND=noninteractive apt-get update
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y openssh-server
  fi
  if ! sudo systemctl enable --now ssh; then
    sudo systemctl enable --now ssh.socket
  fi
  if command -v ufw >/dev/null 2>&1; then
    sudo ufw allow 22/tcp >/dev/null || true
    sudo ufw allow 80/tcp >/dev/null || true
    sudo ufw allow 443/tcp >/dev/null || true
  fi
  echo "SSH na porta 22. Usuario: ${LINUX_USER}."
}
enable_ssh
trap 'kill $KEEP_ALIVE_PID 2>/dev/null || true' EXIT

# ====================== DADOS ======================
# O tecnico digita o codigo de 8 caracteres. O mestre devolve o token e a
# access key do Bitbucket. O token fica neste arquivo para o passo 7 e para
# uma instalacao retomada.
INSTALL_CODE_FILE="$PROGRESS_DIR/install-code"
TOKEN_FILE="$PROGRESS_DIR/token"
MACHINE_FILE="$PROGRESS_DIR/machine-id"
KEY_FILE="$PROGRESS_DIR/git-read-key"
MASTER_URL="${NCOMMERCE_MASTER_URL:-https://ncommerce.app:3001}"

read_install_code() {
  local raw code
  while true; do
    read -r -p "Codigo de instalacao (8 caracteres): " raw
    code="$(printf '%s' "$raw" | tr -d '[:space:]-' | tr '[:lower:]' '[:upper:]')"
    if printf '%s' "$code" | grep -Eq '^[A-Z0-9]{8}$'; then
      printf '%s' "$code" > "$INSTALL_CODE_FILE"
      chmod 600 "$INSTALL_CODE_FILE"
      return 0
    fi
    echo "Use 8 letras ou numeros."
  done
}

if [ ! -s "$TOKEN_FILE" ] && [ ! -s "$INSTALL_CODE_FILE" ]; then
  read_install_code
fi
echo "Usuário Linux: $LINUX_USER"

redeem_install_code() {
  if [ -s "$TOKEN_FILE" ] && { is_step_done 4 || [ -s "$KEY_FILE" ]; }; then
    TOKEN="$(tr -d '[:space:]' < "$TOKEN_FILE")"
    return 0
  fi
  if [ ! -s "$INSTALL_CODE_FILE" ]; then
    echo "❌ Codigo de instalacao ausente. Rode de novo e informe o codigo de 8 caracteres."
    exit 1
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    sudo apt-get update
    sudo apt-get install -y python3
  fi
  if [ ! -s "$MACHINE_FILE" ]; then
    if [ -r /proc/sys/kernel/random/uuid ]; then
      tr -d '[:space:]' < /proc/sys/kernel/random/uuid > "$MACHINE_FILE"
    else
      openssl rand -hex 16 > "$MACHINE_FILE"
    fi
    chmod 600 "$MACHINE_FILE"
  fi
  python3 - "$MASTER_URL" "$INSTALL_CODE_FILE" "$MACHINE_FILE" "$TOKEN_FILE" "$KEY_FILE" <<'PY'
import json, socket, sys, urllib.error, urllib.request
master, code_path, machine_path, token_path, key_path = sys.argv[1:]
code = open(code_path).read().strip()
machine = open(machine_path).read().strip()
host = "".join(ch for ch in socket.gethostname() if ch.isalnum() or ch in ".-")[:100]
payload = json.dumps({"code": code, "machine_id": machine, "hostname": host}).encode()
req = urllib.request.Request(
    master.rstrip("/") + "/install/redeem",
    data=payload,
    headers={"Content-Type": "application/json"},
    method="POST",
)
try:
    with urllib.request.urlopen(req, timeout=30) as resp:
        raw = resp.read()
except urllib.error.HTTPError as exc:
    sys.stderr.write("Codigo recusado (HTTP %s). %s\n" % (exc.code, exc.read().decode("utf-8", "replace")))
    sys.exit(1)
except Exception as exc:
    sys.stderr.write("Nao consegui falar com o mestre: %s\n" % exc)
    sys.exit(1)
try:
    data = json.loads(raw.decode())
except Exception:
    sys.stderr.write("Resposta do mestre nao e JSON.\n")
    sys.exit(1)
token = data.get("token") or data.get("ncommerce_token") or ""
key = data.get("git_private_key") or ""
if not isinstance(token, str):
    token = ""
if not isinstance(key, str):
    key = ""
key = key.replace("\r\n", "\n").replace("\r", "\n")
if key and not key.endswith("\n"):
    key += "\n"
if not token or "PRIVATE KEY" not in key:
    sys.stderr.write("A resposta do mestre nao trouxe o token e a chave de leitura.\n")
    sys.exit(1)
open(token_path, "w").write(token + "\n")
open(key_path, "w").write(key)
PY
  chmod 600 "$TOKEN_FILE" "$KEY_FILE"
  if is_step_done 4; then
    shred -u "$KEY_FILE" 2>/dev/null || rm -f "$KEY_FILE"
  fi
  TOKEN="$(tr -d '[:space:]' < "$TOKEN_FILE")"
}

download_company_backup() {
  BACKUP_ZIP="$PROGRESS_DIR/ncommerce.zip"
  if [ -f "$PROGRESS_DIR/backup-restored" ]; then
    return 0
  fi
  rm -f "$BACKUP_ZIP"
  if [ ! -s "$INSTALL_CODE_FILE" ]; then
    echo "Codigo de instalacao ja foi apagado. Sem download do backup do mestre."
    return 0
  fi
  python3 - "$MASTER_URL" "$INSTALL_CODE_FILE" "$MACHINE_FILE" "$BACKUP_ZIP" <<'PY'
import sys, urllib.error, urllib.request
master, code_path, machine_path, dest = sys.argv[1:]
code = open(code_path).read().strip()
machine = open(machine_path).read().strip()
url = "%s/install/%s/backup?machine_id=%s" % (master.rstrip("/"), code, machine)
req = urllib.request.Request(url)
try:
    with urllib.request.urlopen(req, timeout=600) as resp:
        if resp.status == 204:
            sys.exit(0)
        open(dest, "wb").write(resp.read())
except urllib.error.HTTPError as exc:
    if exc.code == 204:
        sys.exit(0)
    sys.stderr.write("Nao consegui baixar o backup (HTTP %s).\n" % exc.code)
    sys.exit(1)
PY
  if [ -s "$BACKUP_ZIP" ]; then
    echo "Backup baixado em ${BACKUP_ZIP}."
  else
    echo "Esta empresa nao tem backup no mestre. A instalacao segue vazia."
    rm -f "$BACKUP_ZIP"
  fi
}

echo "🚀 Iniciando instalação (resumível)..."
echo

# ====================== PASSO 1/7 ======================
if is_step_done 1; then
  echo "PASSO 1/7 já concluído anteriormente. Pulando..."
else
  echo "PASSO 1/7: Atualizando sistema + pacotes + JDK"
  sudo apt update && sudo apt upgrade -y
  # libgdbm6/libgdbm6t64 e libsmbclient/libsmbclient0 mudam de nome entre versões do Ubuntu;
  # libgdbm-dev e smbclient/python3-smbc já puxam a variante certa como dependência.
  sudo apt install -y git build-essential curl wget python3 default-jre imagemagick openssh-server \
  mysql-server libmysqlclient-dev redis-server bison libssl-dev libyaml-dev libreadline-dev \
  zlib1g-dev libncurses-dev libffi-dev libgdbm-dev nginx dirmngr gnupg \
  samba smbclient python3-smbc htop \
  zenity zip unzip cups cron

  # Sidekiq 8 exige Redis 7+; o apt do 20.04 (5.x) e do 22.04 (6.0) é antigo demais.
  # Igual ao setup1.sh: compila o 7.2 e faz o serviço redis-server do apt usar o binário novo,
  # mantendo config (/etc/redis/redis.conf), usuário e dados do pacote.
  case "$UBUNTU_VERSION" in
    20.04|22.04)
      REDIS_BRANCH="7.2"
      if /usr/local/bin/redis-server --version 2>/dev/null | grep -q "v=${REDIS_BRANCH}"; then
        echo "Redis ${REDIS_BRANCH} já instalado em /usr/local/bin, pulando compilação."
      else
        BUILD_DIR="$(mktemp -d)"
        git clone --depth 1 --branch "$REDIS_BRANCH" https://github.com/redis/redis.git "$BUILD_DIR/redis"
        make -C "$BUILD_DIR/redis" -j"$(nproc)"
        sudo make -C "$BUILD_DIR/redis" install
        rm -rf "$BUILD_DIR"
      fi

      sudo mkdir -p /etc/systemd/system/redis-server.service.d
      printf '[Service]\nExecStart=\nExecStart=/usr/local/bin/redis-server /etc/redis/redis.conf\n' \
        | sudo tee /etc/systemd/system/redis-server.service.d/override.conf >/dev/null
      sudo systemctl daemon-reload
      sudo systemctl enable redis-server
      sudo systemctl restart redis-server
      ;;
  esac

  echo "Instalando Google Chrome (.deb, sem snap)..."
  curl -fsSL -o /tmp/google-chrome-stable_current_amd64.deb \
    https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
  sudo dpkg -i /tmp/google-chrome-stable_current_amd64.deb || sudo apt-get install -f -y
  rm -f /tmp/google-chrome-stable_current_amd64.deb
  xdg-settings set default-web-browser google-chrome.desktop 2>/dev/null || true
  # printer.rb usa "chromium" como fallback do Prince; o .deb do Chrome só cria "google-chrome".
  if ! command -v chromium >/dev/null 2>&1; then
    sudo ln -sf /usr/bin/google-chrome /usr/local/bin/chromium
  fi

  # No 20.04/22.04 o openjdk-21 só vem pelo repositório -updates; sem ele, usa o 17.
  JAVA_VERSION=21
  if ! apt-cache show openjdk-21-jdk >/dev/null 2>&1; then
    echo "⚠️  openjdk-21 não disponível no Ubuntu $UBUNTU_VERSION. Usando openjdk-17."
    JAVA_VERSION=17
  fi
  JAVA_HOME_DIR="/usr/lib/jvm/java-${JAVA_VERSION}-openjdk-amd64"
  sudo apt install -y "openjdk-${JAVA_VERSION}-jre" "openjdk-${JAVA_VERSION}-jdk"

  echo "Configurando Java $JAVA_VERSION como padrão..."
  sudo update-alternatives --install /usr/bin/java java "$JAVA_HOME_DIR/bin/java" "${JAVA_VERSION}00"
  sudo update-alternatives --install /usr/bin/javac javac "$JAVA_HOME_DIR/bin/javac" "${JAVA_VERSION}00"
  sudo update-alternatives --set java "$JAVA_HOME_DIR/bin/java"
  sudo update-alternatives --set javac "$JAVA_HOME_DIR/bin/javac"

  mark_step_done 1
fi
echo

redeem_install_code

# ====================== PASSO 2/7 ======================
if is_step_done 2; then
  echo "PASSO 2/7 já concluído anteriormente. Pulando..."
else
  echo "PASSO 2/7: NVM + Node 24"
  curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.4/install.sh | bash

  export NVM_DIR="$HOME/.nvm"
  [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

  nvm install 24
  nvm use 24
  nvm alias default 24

  curl -s https://tunnelmole.com/sh/install-linux.sh | sudo bash
  mark_step_done 2
fi
echo

# ====================== PASSO 3/7 ======================
if is_step_done 3; then
  echo "PASSO 3/7 já concluído anteriormente. Pulando..."
else
  echo "PASSO 3/7: Rbenv + Dropbox + chave SSH"

  if ! grep -q 'rbenv/bin' ~/.bashrc; then
    echo 'export PATH="$HOME/.rbenv/bin:$PATH"' >> ~/.bashrc
  fi
  if ! grep -q 'rbenv init' ~/.bashrc; then
    echo 'eval "$(rbenv init -)"' >> ~/.bashrc
  fi

  git clone https://github.com/rbenv/rbenv.git ~/.rbenv 2>/dev/null || true
  git clone https://github.com/rbenv/ruby-build.git ~/.rbenv/plugins/ruby-build 2>/dev/null || true

  export PATH="$HOME/.rbenv/bin:$PATH"
  eval "$(rbenv init -)"

  sudo apt autoremove -y

  cd ~ && wget -O - "https://www.dropbox.com/download?plat=lnx.x86_64" | tar xzf -
  mkdir -p ~/.config/autostart
  cat > ~/.config/autostart/dropboxd.desktop <<EOF
[Desktop Entry]
Type=Application
Exec=${HOME}/.dropbox-dist/dropboxd
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
Name=Dropbox
EOF
  "${HOME}/.dropbox-dist/dropboxd" >/tmp/dropboxd.log 2>&1 &
  echo ""
  echo "══════════════════════════════════════════════════════════════"
  echo "Dropbox foi iniciado. Faca login na CONTA DA EMPRESA."
  echo "Depois: preferencias -> Sync -> desmarque pastas de terceiros."
  echo "Se a empresa ja tem backup, o instalador baixa o zip do servidor mestre no final."
  echo "══════════════════════════════════════════════════════════════"
  read -r -p "Pressione ENTER depois de logar no Dropbox (ou ENTER para seguir sem backup)..."

  mkdir -p ~/.ssh
  if [ ! -f ~/.ssh/id_rsa ]; then
    ssh-keygen -t rsa -b 4096 -N "" -f ~/.ssh/id_rsa -q
  fi

  echo ""
  echo "══════════════════════════════════════════════════════════════"
  echo "🔑 COPIE A CHAVE PÚBLICA ABAIXO e adicione no servidor Nlabs (authorized_keys do usuário nlabs em tunnel.nlabs.live):"
  echo ""
  cat ~/.ssh/id_rsa.pub
  echo ""
  echo "══════════════════════════════════════════════════════════════"
  read -r -p "✅ Pressione ENTER quando a chave já estiver adicionada no servidor Nlabs..."
  mark_step_done 3
fi
echo

# Ao retomar depois do PASSO 3, o rbenv não está no PATH (o script não lê o ~/.bashrc);
# sem isso os passos 5 e 7 não acham gem/bundle.
if [ -x "$HOME/.rbenv/bin/rbenv" ]; then
  export PATH="$HOME/.rbenv/bin:$PATH"
  eval "$(rbenv init -)"
fi

# ====================== PASSO 4/7 ======================
if is_step_done 4; then
  echo "PASSO 4/7 já concluído anteriormente. Pulando..."
else
  echo "PASSO 4/7: Clonando repositórios (pula se já existir)"
  cd ~ && mkdir -p NCommerce && cd NCommerce

  # Evita a pergunta "Are you sure you want to continue connecting?" no primeiro clone
  mkdir -p ~/.ssh
  if ! ssh-keygen -F bitbucket.org >/dev/null 2>&1; then
    ssh-keyscan -H bitbucket.org >> ~/.ssh/known_hosts 2>/dev/null
  fi

  if [ ! -s "$KEY_FILE" ]; then
    echo "❌ Chave de leitura do Bitbucket ausente. Rode de novo com o codigo de instalacao."
    exit 1
  fi
  export GIT_SSH_COMMAND="ssh -i ${KEY_FILE} -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes"
  for repo in ncommerce_api ncommerce sefaz-chrome-extension nfce; do
    if [ ! -d "$repo/.git" ]; then
      echo "Clonando $repo..."
      if ! git clone "git@bitbucket.org:Aleksandrus/$repo.git"; then
        echo ""
        echo "❌ Não consegui clonar $repo. A access key de leitura do Bitbucket foi recusada."
        echo "Depois rode ./instalador_unico.sh de novo (ele continua deste passo)."
        exit 1
      fi
    else
      echo "✅ $repo já existe. Pulando clone."
    fi
  done
  unset GIT_SSH_COMMAND
  shred -u "$KEY_FILE" 2>/dev/null || rm -f "$KEY_FILE"

  mark_step_done 4
fi
echo

# ====================== PASSO 5/7 a 7/7 (mantidos iguais) ======================
if is_step_done 5; then
  echo "PASSO 5/7 já concluído anteriormente. Pulando..."
else
  echo "PASSO 5/7: Ruby 3.4.9 + Rails 7 + bundle"
  git -C ~/.rbenv/plugins/ruby-build pull
  rbenv install 3.4.9 --verbose || true
  rbenv global 3.4.9
  rbenv rehash

  echo "gem: --no-document" > ~/.gemrc
  gem install bundler
  gem install rails -v 7.2.3.1

  cd ~/NCommerce/ncommerce_api && bundle install
  mark_step_done 5
fi
echo

if is_step_done 6; then
  echo "PASSO 6/7 já concluído anteriormente. Pulando..."
else
  echo "PASSO 6/7: Impressora, AnyDesk, TeamViewer, Passenger + correção de dependências"
  cd ~/NCommerce/ncommerce_api/essentials

  # ================== NOVO: INSTALAÇÃO DO DRIVER ELGIN ==================
  echo "→ Instalando Driver Elgin..."
  if [ -f "DriverElgin.zip" ]; then
      unzip -o DriverElgin.zip
      # O zip descompacta em Elgin_i9_linux_driver_vX.Y.Z/setup
      ELGIN_SETUP="$(find . -maxdepth 3 -type d -path '*Elgin*/setup' | head -n 1)"
      if [ -n "$ELGIN_SETUP" ]; then
          chmod +x "$ELGIN_SETUP/install"
          echo "→ Executando instalação do Driver Elgin como root..."
          (cd "$ELGIN_SETUP" && sudo ./install)
          echo "✅ Driver Elgin instalado com sucesso!"
      else
          echo "❌ ERRO: Pasta 'setup' não encontrada após descompactar DriverElgin.zip"
      fi
  else
      echo "⚠️  DriverElgin.zip não encontrado (pulando)"
  fi
  # =====================================================================

  sudo cp -r libmp2032_4.4.0.5_Debian8_x64/install/usr/* /usr/ 2>/dev/null || true
  unzip -o Driver_CUPS_Ubuntu_18e20.zip
  sudo dpkg -i bematech-driver_2.0.0.6-1_amd64.deb 2>/dev/null || true
  # phantomjs 2.1.1 aborta com "Auto configuration failed" no OpenSSL 3 (Ubuntu 22+):
  # o binário real fica em /usr/local/lib e /usr/bin/phantomjs roda ele com OPENSSL_CONF=/dev/null.
  unzip -o phantomjs-2.1.1-linux-x86_64.zip
  sudo install -D -m 755 phantomjs-2.1.1-linux-x86_64/bin/phantomjs /usr/local/lib/phantomjs/phantomjs
  printf '#!/bin/sh\nOPENSSL_CONF=/dev/null exec /usr/local/lib/phantomjs/phantomjs "$@"\n' | sudo tee /usr/bin/phantomjs >/dev/null
  sudo chmod 755 /usr/bin/phantomjs

  # O prince_11.4 (Ubuntu 18.04) depende de libssl1.1/libtiff5, que não existem mais.
  echo "Instalando Prince..."
  case "$UBUNTU_VERSION" in
    20.04|22.04|24.04|26.04) PRINCE_UBUNTU="$UBUNTU_VERSION" ;;
    *) PRINCE_UBUNTU="24.04" ;;
  esac
  PRINCE_DEB="/tmp/prince_16.2-1_ubuntu${PRINCE_UBUNTU}_amd64.deb"
  if curl -fsSL -o "$PRINCE_DEB" "https://www.princexml.com/download/prince_16.2-1_ubuntu${PRINCE_UBUNTU}_amd64.deb"; then
    sudo apt install -y "$PRINCE_DEB"
  else
    echo "⚠️  Não consegui baixar o Prince. Instale manualmente: https://www.princexml.com/download/"
  fi
  rm -f "$PRINCE_DEB"

  if [ "$IS_WSL" = "1" ]; then
    echo "WSL: TeamViewer/AnyDesk devem ser instalados no Windows, não no Ubuntu. Pulando."
  else
    echo "Instalando TeamViewer..."
    # Sem "cd /tmp": o resto do passo usa arquivos relativos a essentials/ (dropboxd.desktop etc.).
    wget -q -O /tmp/teamviewer_amd64.deb https://download.teamviewer.com/download/linux/teamviewer_amd64.deb
    sudo apt install -y /tmp/teamviewer_amd64.deb || true
    rm -f /tmp/teamviewer_amd64.deb

    # AnyDesk
    wget -qO - https://keys.anydesk.com/repos/DEB-GPG-KEY | gpg --dearmor | sudo tee /etc/apt/trusted.gpg.d/anydesk.gpg > /dev/null
    echo "deb http://deb.anydesk.com/ all main" | sudo tee /etc/apt/sources.list.d/anydesk-stable.list
    sudo apt update && sudo apt install -y anydesk
  fi

  echo "Corrigindo dependências quebradas..."
  sudo apt install --fix-broken -y

  # Passenger
  curl https://oss-binaries.phusionpassenger.com/auto-software-signing-gpg-key-2025.txt | gpg --dearmor | sudo tee /etc/apt/trusted.gpg.d/phusion.gpg >/dev/null
  sudo sh -c 'echo deb https://oss-binaries.phusionpassenger.com/apt/passenger $(lsb_release -sc) main > /etc/apt/sources.list.d/passenger.list'
  sudo apt update
  sudo apt install -y passenger passenger-dev libnginx-mod-http-passenger

  echo -e "passenger_ruby /home/$LINUX_USER/.rbenv/shims/ruby;\npassenger_root /usr/lib/ruby/vendor_ruby/phusion_passenger/locations.ini;" | \
    sudo tee /etc/nginx/conf.d/mod-http-passenger.conf

  mkdir -p ~/.config/autostart

  # Atalho na área de trabalho: English "Desktop" AND Portuguese "Área de Trabalho"
  sed "s/COMPUTERUSER/$LINUX_USER/g" dropboxd.desktop > ~/.config/autostart/dropboxd.desktop
  RESTORE_TMP="$(mktemp)"
  sed "s/COMPUTERUSER/$LINUX_USER/g" restauracao.desktop > "$RESTORE_TMP"
  chmod +x ~/NCommerce/ncommerce_api/vendor/scripts/restore_backup.sh
  for DESKTOP_DIR in "${HOME}/Desktop" "${HOME}/Área de Trabalho" "$(command -v xdg-user-dir >/dev/null && xdg-user-dir DESKTOP || true)"; do
    [ -n "$DESKTOP_DIR" ] || continue
    mkdir -p "$DESKTOP_DIR"
    cp "$RESTORE_TMP" "$DESKTOP_DIR/Restauracao.desktop"
    chmod +x "$DESKTOP_DIR/Restauracao.desktop"
    gio set "$DESKTOP_DIR/Restauracao.desktop" metadata::trusted true 2>/dev/null || true
  done
  rm -f "$RESTORE_TMP"

  sudo apt install --fix-broken -y
  mark_step_done 6
fi

if is_step_done 7; then
  echo "PASSO 7/7 já concluído anteriormente. Pulando..."
else
  echo "PASSO 7/7: Nginx + .env + banco + cron"
  ssh-keyscan -H nlabs.live >> ~/.ssh/known_hosts 2>/dev/null
  ssh-keyscan -H tunnel.nlabs.live >> ~/.ssh/known_hosts 2>/dev/null
  if ! grep -qs 'nlabs' ~/.ssh/config; then
    cat ~/NCommerce/ncommerce_api/essentials/ssh_config.txt >> ~/.ssh/config 2>/dev/null || true
  fi
  touch ~/.ssh/config
  chmod 600 ~/.ssh/config

  # -f: se o servidor responder erro (token errado etc.), aborta em vez de gravar a página de erro
  # no nginx/.env. Baixa tudo antes de instalar qualquer arquivo.
  SETUP_URL="https://ncommerce.app:3001/setup"
  curl -fsS "$SETUP_URL/nginx_back/$LINUX_USER?token=$TOKEN" -o /tmp/ncommerce-api
  curl -fsS "$SETUP_URL/nginx_front/$LINUX_USER?token=$TOKEN" -o /tmp/ncommerce
  curl -fsS "$SETUP_URL/env/$LINUX_USER?token=$TOKEN" -o /tmp/ncommerce-env

  sudo cp /tmp/ncommerce-api /etc/nginx/sites-available/ncommerce-api
  sudo ln -sf /etc/nginx/sites-available/ncommerce-api /etc/nginx/sites-enabled/ncommerce-api
  sudo cp /tmp/ncommerce /etc/nginx/sites-available/ncommerce
  sudo ln -sf /etc/nginx/sites-available/ncommerce /etc/nginx/sites-enabled/ncommerce
  rm -f /tmp/ncommerce-api /tmp/ncommerce

  mv /tmp/ncommerce-env /home/${LINUX_USER}/NCommerce/ncommerce_api/.env.production
  # O .env do servidor não traz SECRET_KEY_BASE, e o Rails 7.2 não sobe em produção sem ela.
  if ! grep -q '^SECRET_KEY_BASE=.' /home/${LINUX_USER}/NCommerce/ncommerce_api/.env.production; then
    sed -i '/^SECRET_KEY_BASE=/d' /home/${LINUX_USER}/NCommerce/ncommerce_api/.env.production
    echo "SECRET_KEY_BASE=$(openssl rand -hex 64)" >> /home/${LINUX_USER}/NCommerce/ncommerce_api/.env.production
  fi
  # Só acrescenta as linhas que ainda não estão lá, para o passo poder ser repetido.
  (grep -vxF -f /etc/environment /home/${LINUX_USER}/NCommerce/ncommerce_api/.env.production || true) | \
    sudo tee -a /etc/environment >/dev/null

  chmod o+x /home/${LINUX_USER} # newer nginx requires this
  cd ~/NCommerce/ncommerce_api
  if [ -z "$(sudo mysql -N -e "SELECT 1 FROM mysql.user WHERE user='ncommerce' AND host='localhost'")" ]; then
    sudo mysql < ./essentials/setup_scripts/mysql-setup.sql
  fi
  if [ -f "$PROGRESS_DIR/backup-restored" ]; then
    echo "Backup ja restaurado. Pulando o banco vazio."
  else
    download_company_backup
    if [ -s "${BACKUP_ZIP:-}" ]; then
      if ! grep -q NCOMMERCE_ZIP_PASSWORD ./vendor/scripts/restore_backup.sh; then
        echo "❌ O restore_backup.sh clonado ainda nao aceita a senha vinda do instalador."
        echo "O zip ficou em ${BACKUP_ZIP}."
        exit 1
      fi
      echo "Restaurando o backup desta empresa..."
      NCOMMERCE_ZIP_PATH="$BACKUP_ZIP" \
        NCOMMERCE_ZIP_PASSWORD="${TOKEN:0:6}" \
        NCOMMERCE_SKIP_PAUSE=1 \
        bash ./vendor/scripts/restore_backup.sh
      if ! grep -q '^SECRET_KEY_BASE=.' .env.production; then
        echo "SECRET_KEY_BASE=$(openssl rand -hex 64)" >> .env.production
      fi
      touch "$PROGRESS_DIR/backup-restored"
    else
      bundle exec rake db:create db:migrate db:seed RAILS_ENV=production
    fi
  fi
  sudo service nginx restart

  (crontab -l 2>/dev/null | grep -v "ncommerce_api/vendor/scripts" || true) > /tmp/crontab.tmp
  cat >> /tmp/crontab.tmp << EOF
* * * * * /home/${LINUX_USER}/NCommerce/ncommerce_api/vendor/scripts/chown_files.sh /home/${LINUX_USER}/NCommerce/ncommerce_api
* * * * * ( sleep 30; /home/${LINUX_USER}/NCommerce/ncommerce_api/vendor/scripts/chown_files.sh /home/${LINUX_USER}/NCommerce/ncommerce_api )
30 18 * * 2 /home/${LINUX_USER}/NCommerce/ncommerce_api/vendor/scripts/backup.sh /home/${LINUX_USER}/NCommerce/ncommerce_api
30 17 * * 4 /home/${LINUX_USER}/NCommerce/ncommerce_api/vendor/scripts/backup.sh /home/${LINUX_USER}/NCommerce/ncommerce_api
30 18 * * 6 /home/${LINUX_USER}/NCommerce/ncommerce_api/vendor/scripts/backup.sh /home/${LINUX_USER}/NCommerce/ncommerce_api
EOF
  crontab /tmp/crontab.tmp
  rm -f /tmp/crontab.tmp
  sudo service cron reload

  shred -u "$INSTALL_CODE_FILE" 2>/dev/null || rm -f "$INSTALL_CODE_FILE"
  mark_step_done 7
fi
echo

echo "🎉 INSTALAÇÃO CONCLUÍDA COM SUCESSO!"
# No WSL não reinicia, para não derrubar o Windows.
if [ "$IS_WSL" = "1" ]; then
  echo "WSL detectado: NÃO vou reiniciar o Windows."
  echo "Para aplicar systemd/nginx de ponta a ponta:"
  echo "  1. No PowerShell (Admin):  wsl --shutdown"
  echo "  2. Depois rode C:\\NCommerce\\wsl\\ncommerce-wsl-startup.bat"
  echo "  3. Ou só abra o Ubuntu de novo; o agendamento de logon também sobe o WSL."
else
  echo "O computador será reiniciado em 10 segundos..."
  sleep 10
  sudo reboot
fi