#!/bin/bash
# Backup avulso de uma loja NCommerce nativa no Ubuntu, para migrar a loja.
# Pede o usuario e a senha do MySQL e deixa o zip na pasta onde o comando foi
# rodado, no mesmo formato do backup da loja: backup.sql, docs.zip, nfce.zip,
# env.txt e as impressoras, com a senha dos 6 primeiros caracteres do token.
# O instalador_linux.sh aceita esse zip (arraste para o terminal ou --backup).
#
#   ./backup_ubuntu.sh                      loja em ~/NCommerce
#   ./backup_ubuntu.sh /home/loja/NCommerce loja de outro usuario ou outra pasta
#
# Rode sem sudo, como o usuario da loja. O sudo so e pedido para copiar as
# impressoras do CUPS.
set -euo pipefail

OUT_DIR="$(pwd)"
NC_DIR="${1:-$HOME/NCommerce}"
APP_ROOT="$NC_DIR/ncommerce_api"
NFCE_DIST="$NC_DIR/nfce/dist"
ENV_FILE="$APP_ROOT/.env.production"

if [ "$(id -u)" -eq 0 ]; then
  echo "Rode sem sudo, como o usuario da loja. Exemplo: ./backup_ubuntu.sh"
  exit 1
fi
if [ ! -f "$ENV_FILE" ]; then
  echo "Nao achei $ENV_FILE."
  echo "Passe a pasta NCommerce da loja. Exemplo: ./backup_ubuntu.sh /home/loja/NCommerce"
  exit 1
fi
if [ ! -w "$OUT_DIR" ]; then
  echo "Sem permissao para gravar em $OUT_DIR. Rode o comando de outra pasta."
  exit 1
fi

# Le uma variavel do .env sem executar o arquivo. Tira aspas e \r.
env_value() {
  sed -n "s/^[[:space:]]*\(export[[:space:]]\+\)\?$1=//p" "$ENV_FILE" | tail -1 \
    | tr -d '\r' | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'$/\1/"
}

TOKEN="$(env_value NCOMMERCE_SERVER_TOKEN)"
if [ "${#TOKEN}" -lt 6 ]; then
  echo "O .env da loja nao tem NCOMMERCE_SERVER_TOKEN. Sem ele o zip nao teria a senha que o instalador espera."
  exit 1
fi
RAILS_ENV_NAME="$(env_value RAILS_ENV)"
DB_NAME="ncommerce_api_${RAILS_ENV_NAME:-production}"
DB_HOST="$(env_value DBHOST)"
DB_PORT="$(env_value DBPORT)"
DEFAULT_DB_USER="$(env_value NCOMMERCE_API_DATABASE_USER)"

missing=()
for cmd in mysql mysqldump zip unzip; do
  command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
done
if [ "${#missing[@]}" -gt 0 ]; then
  echo "Instalando o que falta: ${missing[*]}..."
  pkgs=(zip unzip)
  if ! command -v mysqldump >/dev/null 2>&1; then pkgs+=(mysql-client); fi
  sudo apt-get update
  sudo apt-get install -y "${pkgs[@]}"
fi

WORK="$(mktemp -d)"
chmod 700 "$WORK"
# O .sql sai sem senha na pasta temporaria: apaga ao sair, com erro ou nao.
trap 'rm -rf "$WORK"' EXIT
MYSQL_CNF="$WORK/my.cnf"

# Senha num arquivo, nao na linha de comando: nao aparece no ps.
write_mysql_cnf() {
  local esc_pass="${2//\\/\\\\}"
  esc_pass="${esc_pass//\"/\\\"}"
  umask 077
  cat > "$MYSQL_CNF" <<EOF
[client]
user="$1"
password="$esc_pass"
host=${DB_HOST:-localhost}
port=${DB_PORT:-3306}
EOF
}

while true; do
  if [ -n "$DEFAULT_DB_USER" ]; then
    read -r -p "Usuario do MySQL [$DEFAULT_DB_USER]: " db_user
    db_user="${db_user:-$DEFAULT_DB_USER}"
  else
    read -r -p "Usuario do MySQL: " db_user
  fi
  read -r -s -p "Senha do MySQL: " db_pass
  echo
  write_mysql_cnf "$db_user" "$db_pass"
  if mysql --defaults-extra-file="$MYSQL_CNF" -N -e "USE \`$DB_NAME\`" >/dev/null 2>"$WORK/mysql.err"; then
    break
  fi
  echo "Nao entrei no banco $DB_NAME com esse usuario e senha:"
  sed 's/^/  /' "$WORK/mysql.err" | head -3
  echo "Tente de novo (Ctrl+C para sair)."
done
unset db_pass

echo "Gerando o banco ($DB_NAME)..."
mysqldump --defaults-extra-file="$MYSQL_CNF" --single-transaction --quick --routines --no-tablespaces \
  "$DB_NAME" > "$WORK/backup.sql"
rm -f "$MYSQL_CNF"
if ! tail -c 300 "$WORK/backup.sql" | grep -q "Dump completed"; then
  echo "O mysqldump nao terminou o arquivo. Backup cancelado."
  exit 1
fi

echo "Juntando os documentos..."
if [ -d "$APP_ROOT/business_docs" ]; then
  (cd "$APP_ROOT" && zip -qr "$WORK/docs.zip" business_docs)
else
  echo "  (sem pasta business_docs)"
fi

echo "Juntando os arquivos da NFC-e..."
nfce_parts=()
for part in essentials notas_output backup; do
  if [ -e "$NFCE_DIST/$part" ]; then nfce_parts+=("$part"); fi
done
if [ "${#nfce_parts[@]}" -gt 0 ]; then
  (cd "$NFCE_DIST" && zip -qr "$WORK/nfce.zip" "${nfce_parts[@]}")
else
  echo "  (sem arquivos da NFC-e em $NFCE_DIST)"
fi
cp "$ENV_FILE" "$WORK/env.txt"

# Sem documentos ou sem NFC-e, o zip interno fica de fora: o instalador so
# abre docs.zip e nfce.zip quando existem.
ZIP_FILES=(backup.sql env.txt)
for z in docs.zip nfce.zip; do
  if [ -f "$WORK/$z" ]; then ZIP_FILES+=("$z"); fi
done
if [ -f /etc/cups/printers.conf ] || [ -d /etc/cups/ppd ]; then
  echo "Copiando as impressoras (pede a senha do computador)..."
  if [ -f /etc/cups/printers.conf ] && sudo cp /etc/cups/printers.conf "$WORK/printers.conf"; then
    sudo chown "$(id -u):$(id -g)" "$WORK/printers.conf"
    ZIP_FILES+=(printers.conf)
  fi
  if [ -d /etc/cups/ppd ] && sudo tar -C /etc/cups -czf "$WORK/cups_ppd.tar.gz" ppd; then
    sudo chown "$(id -u):$(id -g)" "$WORK/cups_ppd.tar.gz"
    ZIP_FILES+=(cups_ppd.tar.gz)
  fi
fi

company="$(env_value COMPANY_NAME | tr -cd 'A-Za-z0-9._-')"
name="ncommerce-backup${company:+-$company}-$(date +%Y%m%d-%H%M).zip"
(cd "$WORK" && zip -q --password "${TOKEN:0:6}" ncommerce.zip "${ZIP_FILES[@]}")

# Confere como o instalador vai conferir antes de entregar o zip.
if ! unzip -tqq -P "${TOKEN:0:6}" "$WORK/ncommerce.zip" >/dev/null 2>&1 \
   || ! unzip -Z1 "$WORK/ncommerce.zip" | grep -qx backup.sql; then
  echo "O zip gerado nao passou na conferencia. Backup cancelado."
  exit 1
fi
mv "$WORK/ncommerce.zip" "$OUT_DIR/$name"

echo
echo "Backup pronto: $OUT_DIR/$name ($(du -h "$OUT_DIR/$name" | cut -f1))"
echo "Conteudo: ${ZIP_FILES[*]}"
echo "Banco: $(grep -c '^INSERT INTO' "$WORK/backup.sql") blocos de dados de $(grep -c '^CREATE TABLE' "$WORK/backup.sql") tabelas."
echo "Para migrar: no instalador_linux.sh, arraste este arquivo quando ele pedir o zip de backup."
