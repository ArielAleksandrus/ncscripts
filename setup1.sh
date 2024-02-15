# Install package dependencies
sudo apt update \
&& sudo apt upgrade -y \
&& sudo apt install -y git chromium-browser build-essential curl default-jre imagemagick openssh-server \
mysql-server libmysqlclient-dev redis-server \
bison libssl-dev libyaml-dev libreadline-dev zlib1g-dev libncurses5-dev libffi-dev libgdbm6 libgdbm-dev \
nginx dirmngr gnupg samba smbclient libsmbclient python3-smbc htop

