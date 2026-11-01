#!/usr/bin/env bash
# Uso: sudo ls && ./setup3.sh <usuario_linux>
set -eo pipefail

if [ -n "${1-}" ]; then
  LINUX_USER="$1"
  echo "linux user present. Proceeding..."
else
  echo "FAILED: linux user is not set! use './setup3.sh <username here>'"
  exit 1
fi

ESSENTIALS=~/NCommerce/ncommerce_api/essentials

# Garante rbenv no PATH mesmo se o terminal não foi reaberto depois do setup2
export PATH="$HOME/.rbenv/bin:$PATH"
eval "$(rbenv init - bash)"

# ---------------------------------------------------------------
# Código (SSH já adicionado no Bitbucket)
# ---------------------------------------------------------------
mkdir -p ~/.ssh
ssh-keygen -F bitbucket.org >/dev/null || ssh-keyscan bitbucket.org >> ~/.ssh/known_hosts

mkdir -p ~/NCommerce
cd ~/NCommerce
for REPO in ncommerce_api ncommerce sefaz-chrome-extension nfce; do
  if [ -d "$REPO" ]; then
    echo "$REPO já existe, pulando clone."
  else
    git clone "git@bitbucket.org:Aleksandrus/$REPO.git"
  fi
done

# ---------------------------------------------------------------
# Ruby e Rails
# ---------------------------------------------------------------
rbenv install --skip-existing 3.4.9
rbenv global 3.4.9
echo "gem: --no-document" > ~/.gemrc
gem install bundler -v 4.0.19
gem install rails -v 7
gem env home
rbenv rehash

cd ~/NCommerce/ncommerce_api
bundle install
rbenv rehash

# ---------------------------------------------------------------
# MySQL
# ---------------------------------------------------------------
sudo mysql < "$ESSENTIALS/setup_scripts/mysql-setup.sql" \
  || echo "AVISO: mysql-setup.sql falhou (talvez já tenha sido executado antes). Verifique."

# ---------------------------------------------------------------
# Impressora térmica 80mm
# ---------------------------------------------------------------
sudo cp -r "$ESSENTIALS"/libmp2032_4.4.0.5_Debian8_x64/install/usr/* /usr/

cd "$ESSENTIALS"
unzip -o Driver_CUPS_Ubuntu_18e20.zip
sudo dpkg -i bematech-driver_2.0.0.6-1_amd64.deb || true

# ---------------------------------------------------------------
# ngrok (OBSOLETO) - descomente se ainda precisar
# ---------------------------------------------------------------
# cd "$ESSENTIALS" && unzip -o ngrok-stable-linux-amd64.zip && sudo mv ngrok /usr/bin/

# ---------------------------------------------------------------
# phantomjs (calcula altura da página para impressão)
# ---------------------------------------------------------------
cd "$ESSENTIALS"
unzip -o phantomjs-2.1.1-linux-x86_64.zip
sudo cp phantomjs-2.1.1-linux-x86_64/bin/phantomjs /usr/bin/

# ---------------------------------------------------------------
# Prince e TeamViewer
# ---------------------------------------------------------------
cd "$ESSENTIALS"
sudo dpkg -i prince_11.4-1_ubuntu18.04_amd64.deb || true
sudo dpkg -i teamviewer_15.13.6_amd64.deb || true
sudo apt-get install --fix-broken -y

# O .deb do TeamViewer cria um repo apt assinado com a chave antiga.
# Importa a chave atual para o `apt update` não quebrar.
curl -fsSL https://linux.teamviewer.com/pubkey/currentkey.asc \
  | gpg --dearmor | sudo tee /etc/apt/trusted.gpg.d/teamviewer.gpg >/dev/null \
  || sudo apt-key adv --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys EF9DBDC73B7D1A07

# ---------------------------------------------------------------
# Autostart do Dropbox + atalho Restauracao (Desktop e "Área de Trabalho")
# ---------------------------------------------------------------
mkdir -p ~/.config/autostart
cd "$ESSENTIALS"
sed "s/COMPUTERUSER/$LINUX_USER/g" dropboxd.desktop > ~/.config/autostart/dropboxd.desktop

RESTORE_TMP="$(mktemp)"
sed "s/COMPUTERUSER/$LINUX_USER/g" restauracao.desktop > "$RESTORE_TMP"
chmod a+x ~/NCommerce/ncommerce_api/vendor/scripts/restore_backup.sh

XDG_DESKTOP="$(command -v xdg-user-dir >/dev/null && xdg-user-dir DESKTOP || true)"
for DESKTOP_DIR in "${HOME}/Desktop" "${HOME}/Área de Trabalho" "$XDG_DESKTOP"; do
  [ -n "$DESKTOP_DIR" ] || continue
  mkdir -p "$DESKTOP_DIR"
  cp "$RESTORE_TMP" "$DESKTOP_DIR/Restauracao.desktop"
  chmod a+x "$DESKTOP_DIR/Restauracao.desktop"
  gio set "$DESKTOP_DIR/Restauracao.desktop" metadata::trusted true 2>/dev/null || true
done
rm -f "$RESTORE_TMP"

# ---------------------------------------------------------------
# AnyDesk
# ---------------------------------------------------------------
curl -fsSL https://keys.anydesk.com/repos/DEB-GPG-KEY \
  | gpg --dearmor | sudo tee /etc/apt/trusted.gpg.d/anydesk.gpg >/dev/null
# tee sem -a: não duplica a linha se o script rodar de novo
echo "deb http://deb.anydesk.com/ all main" | sudo tee /etc/apt/sources.list.d/anydesk-stable.list >/dev/null

# ---------------------------------------------------------------
# Passenger + Nginx
# ---------------------------------------------------------------
sudo apt-get install -y dirmngr gnupg apt-transport-https ca-certificates curl
# Chave nova da Phusion (trocada em jan/2026)
curl -fsSL https://oss-binaries.phusionpassenger.com/auto-software-signing-gpg-key-2025.txt \
  | gpg --dearmor | sudo tee /etc/apt/trusted.gpg.d/phusion.gpg >/dev/null \
  || sudo apt-key adv --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys D870AB033FB45BD1
echo "deb https://oss-binaries.phusionpassenger.com/apt/passenger focal main" \
  | sudo tee /etc/apt/sources.list.d/passenger.list >/dev/null

# Um único update depois de todos os repos configurados
sudo apt-get update
sudo apt-get install -y anydesk
sudo apt-get install -y passenger passenger-dev libnginx-mod-http-passenger

# Configurar Passenger
printf 'passenger_ruby /home/%s/.rbenv/shims/ruby;\npassenger_root /usr/lib/ruby/vendor_ruby/phusion_passenger/locations.ini;\n' "$LINUX_USER" \
  | sudo tee /etc/nginx/conf.d/mod-http-passenger.conf >/dev/null

sudo /usr/bin/passenger-config validate-install || true
sudo nginx -t && sudo systemctl restart nginx

echo "Setup 3 concluído. Rode 'sudo ls' e depois './setup4.sh <token> <usuario>'."