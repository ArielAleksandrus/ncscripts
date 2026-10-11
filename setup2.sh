#!/usr/bin/env bash
# Uso: sudo ls && ./setup2.sh   (NUNCA "sudo ./setup2.sh")
set -eo pipefail

if [ "$(id -u)" -eq 0 ]; then
  echo "FAILED: não rode com sudo. Use 'sudo ls' antes e depois './setup2.sh'"
  exit 1
fi

# ---------------------------------------------------------------
# NVM e Node
# ---------------------------------------------------------------
NVM_VERSION="v0.40.3"
NODE_VERSION="v24.13.0"

curl -fsSL "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh" | bash

export NVM_DIR="$HOME/.nvm"
# O nvm.sh não funciona bem com "set -e"; desliga só neste trecho
set +e
# shellcheck disable=SC1091
\. "$NVM_DIR/nvm.sh"
nvm install "$NODE_VERSION"
NVM_STATUS=$?
nvm alias default "$NODE_VERSION" >/dev/null
set -e
if [ "$NVM_STATUS" -ne 0 ]; then
  echo "FAILED: nvm install $NODE_VERSION falhou"
  exit 1
fi

# ---------------------------------------------------------------
# TunnelMole (antigo Expose.sh)
# ---------------------------------------------------------------
curl -fsSL https://tunnelmole.com/sh/install-linux.sh | sudo bash

# ---------------------------------------------------------------
# rbenv + ruby-build
# ---------------------------------------------------------------
if [ -d ~/.rbenv/.git ]; then
  git -C ~/.rbenv pull --ff-only
else
  git clone https://github.com/rbenv/rbenv.git ~/.rbenv
fi

# ruby-build precisa estar atualizado para conhecer o Ruby 3.4.9
if [ -d ~/.rbenv/plugins/ruby-build/.git ]; then
  git -C ~/.rbenv/plugins/ruby-build pull --ff-only
else
  git clone https://github.com/rbenv/ruby-build.git ~/.rbenv/plugins/ruby-build
fi

# Só adiciona ao .bashrc se ainda não estiver lá
grep -qF 'export PATH="$HOME/.rbenv/bin:$PATH"' ~/.bashrc \
  || echo 'export PATH="$HOME/.rbenv/bin:$PATH"' >> ~/.bashrc
grep -qF 'eval "$(rbenv init - bash)"' ~/.bashrc \
  || echo 'eval "$(rbenv init - bash)"' >> ~/.bashrc

sudo apt-get autoremove -y

# ---------------------------------------------------------------
# Dropbox
# ---------------------------------------------------------------
cd ~
wget -qO- "https://www.dropbox.com/download?plat=lnx.x86_64" | tar xzf -

# ---------------------------------------------------------------
# Chave SSH (adicionar no Bitbucket e no servidor Nlabs antes do setup3)
# ---------------------------------------------------------------
SSH_FILE=~/.ssh/id_rsa
mkdir -p ~/.ssh
chmod 700 ~/.ssh

if [ -f "$SSH_FILE" ]; then
  echo "id_rsa já existe, mantendo a chave atual."
else
  ssh-keygen -t rsa -b 4096 -N "" -f "$SSH_FILE" -C "${USER}@$(hostname)"
fi

echo
echo "================ CHAVE SSH PÚBLICA ================"
cat "${SSH_FILE}.pub"
echo "==================================================="
echo
echo "Setup 2 concluído. Próximos passos:"
echo "  1. Configure o Dropbox: ~/.dropbox-dist/dropboxd"
echo "     (DESMARCAR pastas de terceiros: Preferences > Sync > Select Folders)"
echo "  2. Adicione a chave SSH acima no Bitbucket e no servidor Nlabs"
echo "  3. Feche o terminal, abra outro, rode 'sudo ls' e depois './setup3.sh <usuario>'"