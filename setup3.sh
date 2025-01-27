
if test -n "${1-}"; then
  echo "linux user present. Proceeding..."
else
  echo "FAILED: linux user is not set! use './setup2.sh <username here>"
  exit 1
fi

# Agora que o SSH foi adicionado no bitbucket, vamos copiar o codigo
ssh-keyscan bitbucket.org >> ~/.ssh/known_hosts
cd ~ && mkdir NCommerce && cd NCommerce && \
git clone git@bitbucket.org:Aleksandrus/ncommerce_api.git && \
git clone git@bitbucket.org:Aleksandrus/ncommerce.git && \
git clone git@bitbucket.org:Aleksandrus/sefaz-chrome-extension.git && \
git clone git@bitbucket.org:Aleksandrus/nfce.git

# Install Ruby and Rails
rbenv install 2.6.6 && rbenv global 2.6.6
echo "gem: --no-document" > ~/.gemrc
gem install bundler -v 2.4.22
gem install rails -v 6
gem env home
rbenv rehash

# Setup Rails project
cd ~/NCommerce/ncommerce_api && bundle install

# Setup MYSQL
sudo mysql < ~/NCommerce/ncommerce_api/essentials/setup_scripts/mysql-setup.sql

# Install 80mm-roll printer libs
sudo cp -r ~/NCommerce/ncommerce_api/essentials/libmp2032_4.4.0.5_Debian8_x64/install/usr/* /usr/

cd ~/NCommerce/ncommerce_api/essentials && unzip Driver_CUPS_Ubuntu_18e20.zip && \
sudo dpkg -i bematech-driver_2.0.0.6-1_amd64.deb

# Install ngrok (OBSOLETE)
cd ~/NCommerce/ncommerce_api/essentials && unzip ngrok-stable-linux-amd64.zip && sudo mv ngrok /usr/bin/

# Install phantomjs to calculate page height for printing
cd ~/NCommerce/ncommerce_api/essentials && unzip phantomjs-2.1.1-linux-x86_64.zip && \
sudo cp phantomjs-2.1.1-linux-x86_64/bin/phantomjs /usr/bin/

# Install printer and teamviewer
cd ~/NCommerce/ncommerce_api/essentials && \
sudo dpkg -i prince_11.4-1_ubuntu18.04_amd64.deb
sudo dpkg -i teamviewer_15.13.6_amd64.deb
sudo apt install --fix-broken -y

# Add Dropbox to startup
mkdir -p ~/.config/autostart
cd ~/NCommerce/ncommerce_api/essentials && \
sed -i "s/COMPUTERUSER/$1/g" dropboxd.desktop && \
cp dropboxd.desktop ~/.config/autostart/dropboxd.desktop && \
sed -i "s/$1/COMPUTERUSER/g" dropboxd.desktop

# Add Restauracao (backup restoration script) to Desktop
cd ~/NCommerce/ncommerce_api/essentials && \
sed -i "s/COMPUTERUSER/$1/g" restauracao.desktop && \
cp restauracao.desktop ~/Desktop/Restauracao.desktop && \
sed -i "s/$1/COMPUTERUSER/g" restauracao.desktop && \
gio set ~/Desktop/Restauracao.desktop metadata::trusted true && \
chmod a+x ~/Desktop/Restauracao.desktop


# Install AnyDesk
wget -qO - https://keys.anydesk.com/repos/DEB-GPG-KEY | sudo apt-key add -
echo "deb http://deb.anydesk.com/ all main" | sudo tee -a /etc/apt/sources.list.d/anydesk-stable.list
sudo apt update
sudo apt install -y anydesk

# Install passenger
sudo apt-key adv --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys 561F9B9CAC40B2F7
sudo apt-get install -y apt-transport-https ca-certificates
sudo sh -c 'echo deb https://oss-binaries.phusionpassenger.com/apt/passenger focal main > /etc/apt/sources.list.d/passenger.list'
sudo apt-get update
sudo apt-get install -y passenger passenger-dev
sudo apt-get install -y libnginx-mod-http-passenger
sudo cp ~/.rbenv/shims/ruby /usr/bin/ruby

# Configurar passenger
echo -e "passenger_ruby /home/$1/.rbenv/shims/ruby;\npassenger_root /usr/lib/ruby/vendor_ruby/phusion_passenger/locations.ini;" | sudo tee /etc/nginx/conf.d/mod-http-passenger.conf
