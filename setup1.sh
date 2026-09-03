# Install package dependencies
sudo apt update \
&& sudo apt upgrade -y \
&& sudo apt install -y git build-essential curl wget default-jre imagemagick openssh-server \
mysql-server libmysqlclient-dev redis-server \
bison libssl-dev libyaml-dev libreadline-dev zlib1g-dev libncurses5-dev libffi-dev libgdbm6 libgdbm-dev \
nginx dirmngr gnupg samba smbclient libsmbclient python3-smbc htop \
zenity zip unzip cups

echo "Instalando Google Chrome (.deb, sem snap)..."
curl -fsSL -o /tmp/google-chrome-stable_current_amd64.deb \
  https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
sudo dpkg -i /tmp/google-chrome-stable_current_amd64.deb || sudo apt-get install -f -y
rm -f /tmp/google-chrome-stable_current_amd64.deb
xdg-settings set default-web-browser google-chrome.desktop 2>/dev/null || true

# Use JAVA 17
sudo apt install -y openjdk-17-jre openjdk-17-jdk
sudo update-java-alternatives --set "/usr/lib/jvm/java-1.17.0-openjdk-amd64"