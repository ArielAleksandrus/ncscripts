#!/usr/bin/env bash
# Uso: sudo ls && ./setup4.sh <token do ncommerce> <usuario_linux>
# (ngrok não é mais usado)
set -eo pipefail

if [ "$(id -u)" -eq 0 ]; then
  echo "FAILED: não rode com sudo. Use 'sudo ls' antes e depois './setup4.sh <token> <usuario>'"
  exit 1
fi

if [ -n "${1-}" ]; then
  NC_TOKEN="$1"
  echo "ncommerce token present. Proceeding..."
else
  echo "FAILED: ncommerce token is not set! use './setup4.sh <ncommerce token here> <username here>'"
  exit 1
fi

if [ -n "${2-}" ]; then
  LINUX_USER="$2"
  echo "linux user present. Proceeding..."
else
  echo "FAILED: linux user is not set! use './setup4.sh <ncommerce token here> <username here>'"
  exit 1
fi

APP_DIR=~/NCommerce/ncommerce_api
ENV_FILE="$APP_DIR/.env.production"
SECRET_FILE=~/.ncommerce_secret_key_base
SETUP_URL="https://ncommerce.app:3001/setup"

# ---------------------------------------------------------------
# Senha do computador (vai para COMPUTER_PASSWORD)
# Pergunta logo no início para o resto rodar sem interrupção.
# ---------------------------------------------------------------
while true; do
  read -rsp "Senha sudo DESTE computador (COMPUTER_PASSWORD): " COMPUTER_PASSWORD; echo
  read -rsp "Repita a senha: " COMPUTER_PASSWORD_2; echo
  if [ -z "$COMPUTER_PASSWORD" ]; then
    echo "Senha vazia, tente de novo."
  elif [ "$COMPUTER_PASSWORD" != "$COMPUTER_PASSWORD_2" ]; then
    echo "As senhas não conferem, tente de novo."
  else
    break
  fi
done
unset COMPUTER_PASSWORD_2

# Baixa uma URL para um arquivo temporário; falha se der erro HTTP ou vier vazio
# (sem isso, uma página de erro do servidor viraria config do nginx ou .env)
download() {
  local url="$1" out
  out="$(mktemp)"
  if ! curl -fsS "$url" -o "$out" || [ ! -s "$out" ]; then
    rm -f "$out"
    echo "FAILED: não consegui baixar ${url%%\?*}. Token e usuário estão corretos?" >&2
    exit 1
  fi
  echo "$out"
}

# ---------------------------------------------------------------
# SSH: known_hosts do Nlabs e keep alive do tunnel
# ---------------------------------------------------------------
mkdir -p ~/.ssh
chmod 700 ~/.ssh
for HOST in nlabs.live tunnel.nlabs.live; do
  ssh-keygen -F "$HOST" >/dev/null || ssh-keyscan -H "$HOST" >> ~/.ssh/known_hosts
done

touch ~/.ssh/config
if ! grep -qF "# BEGIN NCOMMERCE" ~/.ssh/config; then
  {
    echo "# BEGIN NCOMMERCE"
    cat "$APP_DIR/essentials/ssh_config.txt"
    echo "# END NCOMMERCE"
  } >> ~/.ssh/config
fi
chmod 600 ~/.ssh/config

# ---------------------------------------------------------------
# Nginx: back end e front end
# ---------------------------------------------------------------
BACK_TMP="$(download "${SETUP_URL}/nginx_back/${LINUX_USER}?token=${NC_TOKEN}")"
FRONT_TMP="$(download "${SETUP_URL}/nginx_front/${LINUX_USER}?token=${NC_TOKEN}")"

sudo install -m 644 "$BACK_TMP"  /etc/nginx/sites-available/ncommerce-api
sudo install -m 644 "$FRONT_TMP" /etc/nginx/sites-available/ncommerce
rm -f "$BACK_TMP" "$FRONT_TMP"

sudo ln -sfn /etc/nginx/sites-available/ncommerce-api /etc/nginx/sites-enabled/ncommerce-api
sudo ln -sfn /etc/nginx/sites-available/ncommerce     /etc/nginx/sites-enabled/ncommerce

# ---------------------------------------------------------------
# .env.production
# ---------------------------------------------------------------
ENV_TMP="$(download "${SETUP_URL}/env/${LINUX_USER}?token=${NC_TOKEN}")"

# SECRET_KEY_BASE: gerada uma vez por máquina e reaproveitada
if [ ! -s "$SECRET_FILE" ]; then
  openssl rand -hex 64 > "$SECRET_FILE"
fi
chmod 600 "$SECRET_FILE"

# Remove do arquivo baixado as variáveis que o script define, e acrescenta as daqui
grep -vE '^(export )?(SECRET_KEY_BASE|COMPUTER_PASSWORD)=' "$ENV_TMP" > "$ENV_FILE" || true
rm -f "$ENV_TMP"
{
  echo "SECRET_KEY_BASE=$(cat "$SECRET_FILE")"
  echo "COMPUTER_PASSWORD=\"${COMPUTER_PASSWORD//\"/\\\"}\""
} >> "$ENV_FILE"
chmod 600 "$ENV_FILE"

# ---------------------------------------------------------------
# /etc/environment: substitui o bloco do NCommerce (não duplica ao rodar de novo)
# ---------------------------------------------------------------
ETC_TMP="$(mktemp)"
sed '/^# BEGIN NCOMMERCE$/,/^# END NCOMMERCE$/d' /etc/environment > "$ETC_TMP"
{
  echo "# BEGIN NCOMMERCE"
  sed -E 's/^export //' "$ENV_FILE"
  echo "# END NCOMMERCE"
} >> "$ETC_TMP"
sudo install -m 644 "$ETC_TMP" /etc/environment
rm -f "$ETC_TMP"

# ---------------------------------------------------------------
# Valida o nginx antes de reiniciar
# ---------------------------------------------------------------
sudo nginx -t

echo
echo "Setup 4 concluído. O computador vai reiniciar em 10 segundos (Ctrl+C para cancelar)."
echo "Depois: 'sudo ls' e './setup5.sh ${LINUX_USER}'"
sleep 10
sudo reboot