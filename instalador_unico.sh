#!/bin/bash
# =====================================================
# INSTALADOR ÚNICO NCOMMERCE - Ubuntu 25 (RESUMÍVEL + ROBUSTO)
# ✅ Não duplica rbenv • ✅ Pula clones já feitos • ✅ Corrige dependências
# =====================================================

set -e

PROGRESS_DIR="$HOME/.ncommerce-progress"
mkdir -p "$PROGRESS_DIR"

is_step_done() { [ -f "$PROGRESS_DIR/step$1.done" ]; }
mark_step_done() { touch "$PROGRESS_DIR/step$1.done"; echo "✅ PASSO $1/7 marcado como concluído"; }

echo "=== INSTALADOR COMPLETO NCOMMERCE (Ubuntu 25 - RESUMÍVEL) ==="
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
read -p "Digite seu usuário Linux: " USER

if [ -z "$TOKEN" ] || [ -z "$USER" ]; then
  echo "❌ Token ou usuário não informado!"
  exit 1
fi

echo "🚀 Iniciando instalação (resumível)..."
echo

# ====================== PASSO 1/7 ======================
if is_step_done 1; then
  echo "PASSO 1/7 já concluído anteriormente. Pulando..."
else
  echo "PASSO 1/7: Atualizando sistema + pacotes + JDK 21"
  sudo apt update && sudo apt upgrade -y
  sudo apt install -y git chromium-browser build-essential curl default-jre imagemagick openssh-server \
  mysql-server libmysqlclient-dev redis-server bison libssl-dev libyaml-dev libreadline-dev \
  zlib1g-dev libncurses-dev libffi-dev libgdbm6 libgdbm-dev nginx dirmngr gnupg \
  samba smbclient libsmbclient python3-smbc htop

  sudo apt install -y openjdk-21-jre openjdk-21-jdk

  echo "Configurando Java 21 como padrão..."
  sudo update-alternatives --install /usr/bin/java java /usr/lib/jvm/java-21-openjdk-amd64/bin/java 2100
  sudo update-alternatives --install /usr/bin/javac javac /usr/lib/jvm/java-21-openjdk-amd64/bin/javac 2100
  sudo update-alternatives --set java /usr/lib/jvm/java-21-openjdk-amd64/bin/java
  sudo update-alternatives --set javac /usr/lib/jvm/java-21-openjdk-amd64/bin/javac

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

# ====================== PASSO 4/7 ======================
if is_step_done 4; then
  echo "PASSO 4/7 já concluído anteriormente. Pulando..."
else
  echo "PASSO 4/7: Clonando repositórios (pula se já existir)"
  cd ~ && mkdir -p NCommerce && cd NCommerce

  # Verificação mais robusta
  for repo in ncommerce_api ncommerce sefaz-chrome-extension nfce; do
    if [ ! -d "$repo/.git" ]; then
      echo "Clonando $repo..."
      git clone "git@bitbucket.org:Aleksandrus/$repo.git" || true
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

  sudo cp -r libmp2032_4.4.0.5_Debian8_x64/install/usr/* /usr/ 2>/dev/null || true
  unzip -o Driver_CUPS_Ubuntu_18e20.zip
  sudo dpkg -i bematech-driver_2.0.0.6-1_amd64.deb 2>/dev/null || true

  unzip -o phantomjs-2.1.1-linux-x86_64.zip && sudo cp phantomjs-2.1.1-linux-x86_64/bin/phantomjs /usr/bin/ 2>/dev/null || true
  sudo dpkg -i prince_11.4-1_ubuntu18.04_amd64.deb 2>/dev/null || true

  echo "Instalando TeamViewer..."
  cd /tmp && wget -q https://download.teamviewer.com/download/linux/teamviewer_amd64.deb
  sudo dpkg -i teamviewer_amd64.deb 2>/dev/null || true

  echo "Corrigindo dependências quebradas (Prince, etc.)..."
  sudo apt install --fix-broken -y

  # AnyDesk
  wget -qO - https://keys.anydesk.com/repos/DEB-GPG-KEY | gpg --dearmor | sudo tee /etc/apt/trusted.gpg.d/anydesk.gpg > /dev/null
  echo "deb http://deb.anydesk.com/ all main" | sudo tee /etc/apt/sources.list.d/anydesk-stable.list
  sudo apt update && sudo apt install -y anydesk

  # Passenger
  curl https://oss-binaries.phusionpassenger.com/auto-software-signing-gpg-key-2025.txt | gpg --dearmor | sudo tee /etc/apt/trusted.gpg.d/phusion.gpg >/dev/null
  sudo sh -c 'echo deb https://oss-binaries.phusionpassenger.com/apt/passenger $(lsb_release -sc) main > /etc/apt/sources.list.d/passenger.list'
  sudo apt update
  sudo apt install -y passenger passenger-dev libnginx-mod-http-passenger

  echo -e "passenger_ruby /home/$USER/.rbenv/shims/ruby;\npassenger_root /usr/lib/ruby/vendor_ruby/phusion_passenger/locations.ini;" | \
    sudo tee /etc/nginx/conf.d/mod-http-passenger.conf

  mkdir -p ~/.config/autostart
  cd ~/NCommerce/ncommerce_api/essentials
  sed "s/COMPUTERUSER/$USER/g" dropboxd.desktop > ~/.config/autostart/dropboxd.desktop
  sed "s/COMPUTERUSER/$USER/g" restauracao.desktop > ~/Desktop/Restauracao.desktop
  gio set ~/Desktop/Restauracao.desktop metadata::trusted true
  chmod +x ~/Desktop/Restauracao.desktop

  sudo apt install --fix-broken -y
  mark_step_done 6
fi
echo

if is_step_done 7; then
  echo "PASSO 7/7 já concluído anteriormente. Pulando..."
else
  echo "PASSO 7/7: Nginx + .env + banco + cron"
  ssh-keyscan -H nlabs.live >> ~/.ssh/known_hosts 2>/dev/null
  ssh-keyscan -H tunnel.nlabs.live >> ~/.ssh/known_hosts 2>/dev/null
  cat ~/NCommerce/ncommerce_api/essentials/ssh_config.txt >> ~/.ssh/config 2>/dev/null || true
  chmod 600 ~/.ssh/config

  curl -s "https://ncommerce.app:3001/setup/nginx_back/$USER?token=$TOKEN" > /tmp/ncommerce-api
  sudo cp /tmp/ncommerce-api /etc/nginx/sites-available/ncommerce-api
  sudo ln -sf /etc/nginx/sites-available/ncommerce-api /etc/nginx/sites-enabled/ncommerce-api

  curl -s "https://ncommerce.app:3001/setup/nginx_front/$USER?token=$TOKEN" > /tmp/ncommerce
  sudo cp /tmp/ncommerce /etc/nginx/sites-available/ncommerce
  sudo ln -sf /etc/nginx/sites-available/ncommerce /etc/nginx/sites-enabled/ncommerce

  curl -s "https://ncommerce.app:3001/setup/env/$USER?token=$TOKEN" > /home/${USER}/NCommerce/ncommerce_api/.env.production
  sudo bash -c "cat /home/${USER}/NCommerce/ncommerce_api/.env.production >> /etc/environment"

  cd ~/NCommerce/ncommerce_api
  sudo mysql < ./essentials/setup_scripts/mysql-setup.sql
  bundle exec rake db:create db:migrate db:seed RAILS_ENV=production
  sudo service nginx restart

  (crontab -l 2>/dev/null | grep -v "ncommerce_api/vendor/scripts" || true) > /tmp/crontab.tmp
  cat >> /tmp/crontab.tmp << EOF
* * * * * /home/${USER}/NCommerce/ncommerce_api/vendor/scripts/chown_files.sh /home/${USER}/NCommerce/ncommerce_api
* * * * * ( sleep 30; /home/${USER}/NCommerce/ncommerce_api/vendor/scripts/chown_files.sh /home/${USER}/NCommerce/ncommerce_api )
30 18 * * 2 /home/${USER}/NCommerce/ncommerce_api/vendor/scripts/backup.sh /home/${USER}/NCommerce/ncommerce_api
30 17 * * 4 /home/${USER}/NCommerce/ncommerce_api/vendor/scripts/backup.sh /home/${USER}/NCommerce/ncommerce_api
30 18 * * 6 /home/${USER}/NCommerce/ncommerce_api/vendor/scripts/backup.sh /home/${USER}/NCommerce/ncommerce_api
EOF
  crontab /tmp/crontab.tmp
  rm -f /tmp/crontab.tmp
  sudo service cron reload

  mark_step_done 7
fi
echo

echo "🎉 INSTALAÇÃO CONCLUÍDA COM SUCESSO!"
echo "O computador será reiniciado em 10 segundos..."
sleep 10
sudo reboot