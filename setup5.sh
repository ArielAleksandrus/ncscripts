#!/usr/bin/env bash
# Uso: ./setup5.sh <usuario_linux>   (se omitido, usa $COMPUTER_USER ou o usuário atual)
set -eo pipefail

USERNAME="${1:-${COMPUTER_USER:-$USER}}"
APP_DIR="/home/${USERNAME}/NCommerce/ncommerce_api"
SCRIPTS="${APP_DIR}/vendor/scripts"
SECRET_FILE="/home/${USERNAME}/.ncommerce_secret_key_base"

if [ ! -d "$APP_DIR" ]; then
  echo "FAILED: $APP_DIR não existe. Usuário correto? use './setup5.sh <username>'"
  exit 1
fi

# ---------------------------------------------------------------
# SECRET_KEY_BASE (gerada uma vez e reaproveitada nas próximas execuções)
# ---------------------------------------------------------------
if [ ! -s "$SECRET_FILE" ]; then
  openssl rand -hex 64 > "$SECRET_FILE"
fi
chmod 600 "$SECRET_FILE"
SECRET_KEY_BASE="$(cat "$SECRET_FILE")"
export SECRET_KEY_BASE

# Passenger/Nginx: entrega a chave ao app
printf 'passenger_env_var SECRET_KEY_BASE %s;\n' "$SECRET_KEY_BASE" \
  | sudo tee /etc/nginx/conf.d/ncommerce-env.conf >/dev/null
sudo chmod 640 /etc/nginx/conf.d/ncommerce-env.conf

# ---------------------------------------------------------------
# Banco: create, migrate e seed
# ---------------------------------------------------------------
cd "$APP_DIR"
bundle exec rake db:create db:migrate db:seed

sudo nginx -t
sudo systemctl reload nginx

# ---------------------------------------------------------------
# Cron jobs
# Remove entradas antigas do NCommerce antes de adicionar (não duplica ao rodar de novo)
# ---------------------------------------------------------------
# Uso do NGROK está DEPRECATED:
# @reboot ${SCRIPTS}/start_ngrok.sh ${APP_DIR} | at now + 2 minutes
# @monthly ${SCRIPTS}/backup_nfce.sh

{
  crontab -l 2>/dev/null \
    | grep -v "${SCRIPTS}/" \
    | grep -v '^SECRET_KEY_BASE=' \
    || true
  echo "SECRET_KEY_BASE=${SECRET_KEY_BASE}"
  echo "* * * * * ${SCRIPTS}/chown_files.sh ${APP_DIR}"
  echo "* * * * * ( sleep 30; ${SCRIPTS}/chown_files.sh ${APP_DIR} )"
  echo "30 18 * * 2 ${SCRIPTS}/backup.sh ${APP_DIR}"
  echo "30 17 * * 4 ${SCRIPTS}/backup.sh ${APP_DIR}"
  echo "30 18 * * 6 ${SCRIPTS}/backup.sh ${APP_DIR}"
} | crontab -

echo "Crontab atual:"
crontab -l

echo "Setup 5 concluído."