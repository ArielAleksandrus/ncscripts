#!/usr/bin/env bash
# Uso: sudo ls && ./setup1.sh   (NUNCA "sudo ./setup1.sh")
set -eo pipefail

if [ "$(id -u)" -eq 0 ]; then
  echo "FAILED: não rode com sudo. Use 'sudo ls' antes e depois './setup1.sh'"
  exit 1
fi

APT="sudo DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold"

# ---------------------------------------------------------------
# Dependências do sistema
# ---------------------------------------------------------------
$APT update
$APT upgrade -y
$APT install -y \
  git build-essential pkg-config curl wget imagemagick openssh-server \
  mysql-server libmysqlclient-dev redis-server \
  bison libssl-dev libyaml-dev libreadline-dev zlib1g-dev libncurses5-dev libffi-dev libgdbm6 libgdbm-dev \
  nginx dirmngr gnupg apt-transport-https ca-certificates \
  samba smbclient libsmbclient python3-smbc htop \
  zenity zip unzip cups

if ! sudo systemctl enable --now ssh; then
  sudo systemctl enable --now ssh.socket
fi
if command -v ufw >/dev/null 2>&1; then
  sudo ufw allow 22/tcp >/dev/null || true
  sudo ufw allow 80/tcp >/dev/null || true
  sudo ufw allow 443/tcp >/dev/null || true
fi
echo "SSH na porta 22."

# ---------------------------------------------------------------
# Google Chrome (.deb, sem snap)
# ---------------------------------------------------------------
echo "Instalando Google Chrome (.deb, sem snap)..."
curl -fsSL -o /tmp/google-chrome-stable_current_amd64.deb \
  https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
sudo dpkg -i /tmp/google-chrome-stable_current_amd64.deb || $APT install -f -y
rm -f /tmp/google-chrome-stable_current_amd64.deb
xdg-settings set default-web-browser google-chrome.desktop 2>/dev/null || true

# ---------------------------------------------------------------
# Java 17
# ---------------------------------------------------------------
$APT install -y openjdk-17-jre openjdk-17-jdk
sudo update-java-alternatives --set java-1.17.0-openjdk-amd64

# ---------------------------------------------------------------
# Redis 7.2 (Sidekiq 8 exige Redis 7+; o pacote do focal é Redis 5)
# Compila do fonte e faz o serviço redis-server do apt usar o binário novo,
# mantendo config (/etc/redis/redis.conf), usuário e dados do pacote.
# ---------------------------------------------------------------
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
sleep 1
redis-cli INFO server | grep redis_version

echo "Setup 1 concluído. Feche este terminal, abra outro, rode 'sudo ls' e depois './setup2.sh'."