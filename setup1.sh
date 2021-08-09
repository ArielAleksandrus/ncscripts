# Install package dependencies
sudo apt update \
&& sudo apt upgrade -y \
&& sudo apt install -y git chromium-browser build-essential curl default-jre imagemagick openssh-server \
mysql-server libmysqlclient-dev redis-server \
bison libssl-dev libyaml-dev libreadline-dev zlib1g-dev libncurses5-dev libffi-dev libgdbm6 libgdbm-dev \
nginx dirmngr gnupg samba smbclient libsmbclient python3-smbc

# Install NVM and Node
curl -o- https://raw.githubusercontent.com/creationix/nvm/v0.33.11/install.sh | bash
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"
nvm install v12.8.1

# Install Rbenv
git clone https://github.com/rbenv/rbenv.git ~/.rbenv
echo 'export PATH="$HOME/.rbenv/bin:$PATH"' >> ~/.bashrc
echo 'eval "$(rbenv init -)"' >> ~/.bashrc
source ~/.bashrc && git clone https://github.com/rbenv/ruby-build.git ~/.rbenv/plugins/ruby-build

sudo apt autoremove -y

# Install Dropbox
cd ~ && wget -O - "https://www.dropbox.com/download?plat=lnx.x86_64" | tar xzf -

# Generate SSH key-pair
SSH_FILE=~/.ssh/id_rsa

if test -f "$SSH_FILE" ; then
  echo "id_rsa file present. Proceeding..."
else
	yes "" | yes "" | ssh-keygen
fi

