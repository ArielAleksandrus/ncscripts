# Agora que as dependências foram instaladas, vamos configurar o NCommerce
NGROK_FILE=~/.ngrok2/ngrok.yml

if test -f "$NGROK_FILE" ; then
  echo "ngrok file present. Proceeding..."
else
  echo "FAILED: ngrok file is not set! use 'ngrok authtoken < ngrok token here>'"
  exit 1
fi

if test -n "${1-}"; then
  echo "ncommerce token present. Proceeding..."
else
  echo "FAILED: ncommerce token is not set! use './setup3.sh <ncommerce token here>"
  exit 1
fi

# Configurar ngrok
cat ~/NCommerce/ncommerce_api/essentials/ngrok-files/example.yml >> ~/.ngrok2/ngrok.yml

# Configurar ngrok para ncommerce
curl https://ncommerce.app:3001/setup/nginx_back/test?token=$1 > /tmp/ncommerce-api
sudo cp /tmp/ncommerce-api /etc/nginx/sites-available/ncommerce-api
sudo ln -s /etc/nginx/sites-available/ncommerce-api /etc/nginx/sites-enabled/ncommerce-api

curl https://ncommerce.app:3001/setup/nginx_front/test?token=$1 > /tmp/ncommerce
sudo cp /tmp/ncommerce /etc/nginx/sites-available/ncommerce
sudo ln -s /etc/nginx/sites-available/ncommerce /etc/nginx/sites-enabled/ncommerce

# Configurar variaveis de ambiente para ncommerce
curl https://ncommerce.app:3001/setup/env/test?token=$1 > ~/NCommerce/ncommerce_api/.env.production
sudo bash -c 'cat .env.production >> /etc/environment' && sudo reboot
