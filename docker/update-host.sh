#!/bin/bash
# Atualiza os scripts desta instalacao (/opt/ncommerce) com o ncscripts publicado
# no GitHub, como o update-host.ps1 do Windows. O update.sh chama este antes do pull.
# Sem internet ou com o GitHub fora, so avisa: a atualizacao das imagens segue.
# Cada arquivo e trocado por mv (inode novo): o update.sh que esta rodando nao se embaralha.
# Nada e trocado se algum arquivo do pacote vier danificado: cada script passa
# por uma conferencia de sintaxe antes, e ou entram todos ou nenhum.
set -uo pipefail

INSTALL_DIR="${1:-/opt/ncommerce}"
URL="${NCOMMERCE_SCRIPTS_URL:-https://github.com/ArielAleksandrus/ncscripts/archive/refs/heads/master.tar.gz}"
FILES="docker-compose.yml docker-compose.usb.yml update.sh update-host.sh host-ips.sh anydesk-id.sh guard.sh rollback.sh net-check.sh tunnel-route.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

keep_going() {
  echo "$1 Sigo com a atualizacao do sistema."
  exit 0
}

# O pacote e baixado inteiro para um arquivo e so depois aberto: download
# cortado no meio nao chega a ser extraido.
if ! curl -fsSL --retry 2 --connect-timeout 15 --max-time 180 -o "$work/ncscripts.tar.gz" "$URL" 2>/dev/null \
   || ! gzip -t "$work/ncscripts.tar.gz" 2>/dev/null \
   || ! tar -xzf "$work/ncscripts.tar.gz" -C "$work" 2>/dev/null; then
  keep_going "Nao consegui atualizar os scripts do NCommerce."
fi
src="$(find "$work" -mindepth 2 -maxdepth 2 -type d -name docker | sed -n '1p')"
if [ -z "$src" ] || [ ! -f "$src/docker-compose.yml" ]; then
  keep_going "O pacote do GitHub veio sem docker/docker-compose.yml."
fi

# Conferencia antes de trocar qualquer coisa.
for f in $FILES; do
  [ -f "$src/$f" ] || continue
  if [ ! -s "$src/$f" ]; then
    keep_going "O pacote do GitHub trouxe $f vazio. Nao troquei nenhum script."
  fi
  case "$f" in
    guard.sh) sh -n "$src/$f" 2>/dev/null || keep_going "O pacote do GitHub trouxe $f com erro. Nao troquei nenhum script." ;;
    *.sh) bash -n "$src/$f" 2>/dev/null || keep_going "O pacote do GitHub trouxe $f com erro. Nao troquei nenhum script." ;;
  esac
done
if [ -f "$src/docker-compose.usb.yml" ] && sudo docker compose version >/dev/null 2>&1; then
  if ! (cd "$src" && sudo docker compose -f docker-compose.yml -f docker-compose.usb.yml config -q) >/dev/null 2>&1; then
    keep_going "O docker-compose.yml do pacote do GitHub nao passou na conferencia. Nao troquei nenhum script."
  fi
fi

changed=""
for f in $FILES; do
  [ -f "$src/$f" ] || continue
  if [ -f "$INSTALL_DIR/$f" ] && cmp -s "$src/$f" "$INSTALL_DIR/$f"; then
    continue
  fi
  mode=644
  case "$f" in *.sh) mode=755 ;; esac
  # host-ips.sh e lido com ".", nao executado: fica 644 como o instalador grava.
  case "$f" in host-ips.sh) mode=644 ;; esac
  sudo install -m "$mode" "$src/$f" "$INSTALL_DIR/.$f.new" && sudo mv -f "$INSTALL_DIR/.$f.new" "$INSTALL_DIR/$f" \
    && changed="$changed $f"
done

if [ -n "$changed" ]; then
  echo "Scripts do NCommerce atualizados:$changed"
else
  echo "Scripts do NCommerce ja estao na versao publicada."
fi
exit 0
