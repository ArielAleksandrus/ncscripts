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
trap 'kill $KEEP_ALIVE_PID 2>/dev/null || true' EXIT

# ====================== DADOS ======================
read -p "Digite o TOKEN do NCommerce: " TOKEN

if [ -z "$TOKEN" ]; then
  echo "❌ Token não informado!"
  exit 1
fi
echo "Usuário Linux: $LINUX_USER"

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
  sudo apt install -y git build-essential curl wget default-jre imagemagick openssh-server \
  mysql-server libmysqlclient-dev redis-server bison libssl-dev libyaml-dev libreadline-dev \
  zlib1g-dev libncurses-dev libffi-dev libgdbm-dev nginx dirmngr gnupg \
  samba smbclient python3-smbc htop \
  zenity zip unzip cups cron

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
  echo "O atalho Restauracao na area de trabalho usa o ncommerce.zip do Dropbox."
  echo "══════════════════════════════════════════════════════════════"
  read -r -p "Pressione ENTER depois de logar no Dropbox (ou ENTER para seguir sem backup)..."

  mkdir -p ~/.ssh
  if [ ! -f ~/.ssh/id_rsa ]; then
    ssh-keygen -t rsa -b 4096 -N "" -f ~/.ssh/id_rsa -q
  fi

  echo ""
  echo "══════════════════════════════════════════════════════════════"
  echo "🔑 COPIE A CHAVE PÚBLICA ABAIXO e adicione no Bitbucket:"
  echo ""
  cat ~/.ssh/id_rsa.pub
  echo ""
  echo "══════════════════════════════════════════════════════════════"
  read -r -p "✅ Pressione ENTER quando a chave já estiver adicionada no Bitbucket..."
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

  for repo in ncommerce_api ncommerce sefaz-chrome-extension nfce; do
    if [ ! -d "$repo/.git" ]; then
      echo "Clonando $repo..."
      if ! git clone "git@bitbucket.org:Aleksandrus/$repo.git"; then
        echo ""
        echo "❌ Não consegui clonar $repo. Confira se a chave abaixo está no Bitbucket:"
        cat ~/.ssh/id_rsa.pub
        echo "Depois rode ./instalador_unico.sh de novo (ele continua deste passo)."
        exit 1
      fi
    else
      echo "✅ $repo já existe. Pulando clone."
    fi
  done

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
  # Só acrescenta as linhas que ainda não estão lá, para o passo poder ser repetido.
  (grep -vxF -f /etc/environment /home/${LINUX_USER}/NCommerce/ncommerce_api/.env.production || true) | \
    sudo tee -a /etc/environment >/dev/null

  chmod o+x /home/${LINUX_USER} # newer nginx requires this
  cd ~/NCommerce/ncommerce_api
  if [ -z "$(sudo mysql -N -e "SELECT 1 FROM mysql.user WHERE user='ncommerce' AND host='localhost'")" ]; then
    sudo mysql < ./essentials/setup_scripts/mysql-setup.sql
  fi
  bundle exec rake db:create db:migrate db:seed RAILS_ENV=production
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