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
sudo docker compose pull
sudo docker compose up -d
sudo docker compose ps
