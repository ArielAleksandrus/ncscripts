#!/bin/bash
# Troca a versao do NCommerce pelo terminal. Quem troca e o servico guard.
#   ./rollback.sh            volta para a versao boa anterior
#   ./rollback.sh lista      mostra as versoes guardadas
#   ./rollback.sh <versao>   troca para essa versao (pode ser mais nova que a atual)
# A tela tambem troca: Configuracoes > Empresa > Versoes.
set -uo pipefail

INSTALL_DIR="${NCOMMERCE_INSTALL_DIR:-/opt/ncommerce}"
cd "$INSTALL_DIR" || exit 1

guard() { sudo docker compose exec -T guard sh /ncommerce/guard.sh "$@"; }

if [ -z "$(sudo docker compose ps -q --status running guard 2>/dev/null)" ]; then
  echo "O servico guard nao esta rodando. Para trocar a mao:"
  echo "  sudo docker image ls | grep keep-"
  echo "  sudo sed -i 's/^NCOMMERCE_TAG=.*/NCOMMERCE_TAG=keep-<versao>/' $INSTALL_DIR/.env"
  echo "  sudo docker compose up -d --no-deps api web"
  exit 1
fi

case "${1:-}" in
  lista|list|-l) guard lista; exit $? ;;
  -h|--help) sed -n 2,6p "$0"; exit 0 ;;
esac

guard lista
echo
read -r -p "Trocar para ${1:-a versao boa anterior}? O sistema fica fora do ar por cerca de um minuto. [s/N] " ok
case "$ok" in
  s|S|sim|SIM) ;;
  *) echo "Nada mudou."; exit 1 ;;
esac
guard trocar "${1:-}" terminal
