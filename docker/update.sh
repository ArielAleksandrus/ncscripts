#!/bin/bash
# Baixa a versao publicada no registry e recria o que mudou.
# Os volumes (banco, notas, certificado, fotos, .env) ficam.
set -euo pipefail

INSTALL_DIR="${NCOMMERCE_INSTALL_DIR:-/opt/ncommerce}"

if [ "$(id -u)" -eq 0 ]; then
  echo "Rode sem sudo: $INSTALL_DIR/update.sh"
  exit 1
fi

if [ ! -f "$INSTALL_DIR/docker-compose.yml" ]; then
  echo "Nao achei $INSTALL_DIR/docker-compose.yml. Rode instalador_docker.sh antes."
  exit 1
fi

cd "$INSTALL_DIR"
if [ -f "$INSTALL_DIR/host-ips.sh" ]; then
  # shellcheck disable=SC1091
  . "$INSTALL_DIR/host-ips.sh"
  write_host_ip_files "$INSTALL_DIR"
fi
if [ -x "$INSTALL_DIR/anydesk-id.sh" ]; then
  sudo "$INSTALL_DIR/anydesk-id.sh" "$INSTALL_DIR" || true
fi
sudo docker compose pull
sudo docker compose up -d
sudo docker compose ps
