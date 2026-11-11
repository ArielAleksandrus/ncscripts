#!/bin/bash
# Atualiza os scripts desta instalacao (/opt/ncommerce) com o ncscripts publicado
# no GitHub, como o update-host.ps1 do Windows. O update.sh chama este antes do pull.
# Sem internet ou com o GitHub fora, so avisa: a atualizacao das imagens segue.
# Cada arquivo e trocado por mv (inode novo): o update.sh que esta rodando nao se embaralha.
set -uo pipefail

INSTALL_DIR="${1:-/opt/ncommerce}"
URL="https://github.com/ArielAleksandrus/ncscripts/archive/refs/heads/master.tar.gz"
FILES="docker-compose.yml docker-compose.usb.yml update.sh update-host.sh host-ips.sh anydesk-id.sh guard.sh rollback.sh net-check.sh tunnel-route.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

if ! curl -fsSL --max-time 60 "$URL" | tar -xz -C "$work" 2>/dev/null; then
  echo "Nao consegui atualizar os scripts do NCommerce. Sigo com a atualizacao do sistema."
  exit 0
fi
src="$work/ncscripts-master/docker"
if [ ! -f "$src/docker-compose.yml" ]; then
  echo "O pacote do GitHub veio sem docker/docker-compose.yml. Sigo com a atualizacao do sistema."
  exit 0
fi

changed=""
for f in $FILES; do
  [ -f "$src/$f" ] || continue
  if [ -f "$INSTALL_DIR/$f" ] && cmp -s "$src/$f" "$INSTALL_DIR/$f"; then
    continue
  fi
  mode=644
  case "$f" in *.sh) mode=755 ;; esac
  sudo install -m "$mode" "$src/$f" "$INSTALL_DIR/.$f.new" && sudo mv -f "$INSTALL_DIR/.$f.new" "$INSTALL_DIR/$f" \
    && changed="$changed $f"
done

if [ -n "$changed" ]; then
  echo "Scripts do NCommerce atualizados:$changed"
else
  echo "Scripts do NCommerce ja estao na versao publicada."
fi
exit 0
