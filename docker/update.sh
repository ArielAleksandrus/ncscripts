#!/bin/bash
# Baixa a versao publicada no registry e recria o que mudou.
# Os volumes (banco, notas, certificado, fotos, .env) ficam.
# Antes, atualiza os scripts desta pasta com o ncscripts do GitHub (update-host.sh).
# Depois, espera o servico guard dizer se a versao nova funciona. Se ela nao
# funcionar, o guard ja voltou para a anterior: veja ./rollback.sh lista.
set -euo pipefail

INSTALL_DIR="${NCOMMERCE_INSTALL_DIR:-/opt/ncommerce}"
WAIT_S="${NCOMMERCE_UPDATE_WAIT_S:-390}"

if [ "$(id -u)" -eq 0 ]; then
  echo "Rode sem sudo: $INSTALL_DIR/update.sh"
  exit 1
fi

if [ ! -f "$INSTALL_DIR/docker-compose.yml" ]; then
  echo "Nao achei $INSTALL_DIR/docker-compose.yml. Rode instalador_linux.sh antes."
  exit 1
fi

cd "$INSTALL_DIR"

# Scripts novos primeiro. Se este update.sh mudou, segue com o novo.
if [ "${NCOMMERCE_SCRIPTS_UPDATED:-}" != "1" ] && [ -x "$INSTALL_DIR/update-host.sh" ]; then
  before="$(sha256sum "$INSTALL_DIR/update.sh")"
  "$INSTALL_DIR/update-host.sh" "$INSTALL_DIR" || true
  if [ "$(sha256sum "$INSTALL_DIR/update.sh")" != "$before" ]; then
    NCOMMERCE_SCRIPTS_UPDATED=1 exec "$INSTALL_DIR/update.sh" "$@"
  fi
fi

# Instaladores antigos clonavam o codigo-fonte em src/. Nada usa essa pasta.
if [ -d "$INSTALL_DIR/src" ]; then
  sudo rm -rf "$INSTALL_DIR/src"
fi
if [ -f "$INSTALL_DIR/host-ips.sh" ]; then
  # shellcheck disable=SC1091
  . "$INSTALL_DIR/host-ips.sh"
  write_host_ip_files "$INSTALL_DIR"
fi
if [ -x "$INSTALL_DIR/anydesk-id.sh" ]; then
  sudo "$INSTALL_DIR/anydesk-id.sh" "$INSTALL_DIR" || true
fi
# Lojas antigas ganham aqui o timer que procura conflito de IP (host/net_check).
if [ -x "$INSTALL_DIR/net-check.sh" ] && [ ! -f /etc/systemd/system/ncommerce-net-check.timer ]; then
  sudo "$INSTALL_DIR/net-check.sh" --install "$INSTALL_DIR" || true
fi
# Lojas antigas ganham o timer que troca a rota do tunel se a interface cair.
if [ -x "$INSTALL_DIR/tunnel-route.sh" ] && [ ! -f /etc/systemd/system/ncommerce-tunnel-route.timer ]; then
  sudo "$INSTALL_DIR/tunnel-route.sh" --install "$INSTALL_DIR" || true
fi

# Uma troca de versao (guard) deixa NCOMMERCE_TAG=keep-<versao>. Atualizar volta para a publicada.
sudo sed -i 's/^NCOMMERCE_TAG=keep-.*/NCOMMERCE_TAG=latest/' "$INSTALL_DIR/.env"
sudo mkdir -p "$INSTALL_DIR/control"

# O mestre e o registry ganharam nomes proprios: api.ncommerce.app e
# registry.ncommerce.app:5050. Com o proxy da Cloudflare ligado em ncommerce.app,
# as portas 3001 e 5050 desse nome param de responder.
OLD_REGISTRY=ncommerce.app:5050
NEW_REGISTRY=registry.ncommerce.app:5050

# Usuario e senha do registry antigo, do jeito que o docker login gravou.
registry_credentials() {
  sudo python3 - "$1" <<'PY'
import base64, json, subprocess, sys
host = sys.argv[1]
try:
    conf = json.load(open("/root/.docker/config.json"))
except Exception:
    sys.exit(1)
for key, value in conf.get("auths", {}).items():
    if key.split("://")[-1].rstrip("/") == host and value.get("auth"):
        print(base64.b64decode(value["auth"]).decode())
        sys.exit(0)
store = conf.get("credHelpers", {}).get(host) or conf.get("credsStore")
if store:
    out = subprocess.run(["docker-credential-" + store, "get"], input=host, capture_output=True, text=True)
    if out.returncode == 0:
        data = json.loads(out.stdout)
        print(data["Username"] + ":" + data["Secret"])
        sys.exit(0)
sys.exit(1)
PY
}

migrate_registry() {
  local creds
  grep -qx "NCOMMERCE_REGISTRY=$OLD_REGISTRY" .env || return 0
  if ! creds="$(registry_credentials "$OLD_REGISTRY")" || [ -z "$creds" ]; then
    echo "Nao achei o login de $OLD_REGISTRY. Sigo com ele."
    return 0
  fi
  if printf '%s' "${creds#*:}" | sudo docker login "$NEW_REGISTRY" --username "${creds%%:*}" --password-stdin >/dev/null 2>&1; then
    sudo sed -i "s/^NCOMMERCE_REGISTRY=$OLD_REGISTRY\$/NCOMMERCE_REGISTRY=$NEW_REGISTRY/" .env
    echo "Registry trocado para $NEW_REGISTRY."
    # A guarda le o registry so ao ligar, e ao ligar renomeia as versoes guardadas.
    sudo docker compose restart guard >/dev/null 2>&1 || true
  else
    echo "Nao consegui entrar em $NEW_REGISTRY. Sigo com $OLD_REGISTRY."
  fi
}

# O endereco do mestre fica no volume api_env (/env/.env.production). Vale a partir
# do proximo reinicio da api; o endereco antigo segue no ar enquanto isso.
migrate_master_url() {
  [ -n "$(sudo docker compose ps -q api 2>/dev/null)" ] || return 0
  sudo docker compose exec -T api sh -c \
    "grep -q '^NCOMMERCE_SERVER_URL=.*ncommerce\.app:3001' /env/.env.production 2>/dev/null || exit 0
     sed -i '/^NCOMMERCE_SERVER_URL=/s#https://ncommerce\.app:3001#https://api.ncommerce.app#' /env/.env.production
     echo 'Mestre trocado para https://api.ncommerce.app.'" || true
}

migrate_registry
migrate_master_url

sudo docker compose pull
sudo docker compose up -d

# Espera o guard: a versao fica "good" depois de 5 minutos respondendo.
wait_verdict() {
  local reg tag new_img cid img line name state i
  [ -n "$(sudo docker compose ps -q guard 2>/dev/null)" ] || return 0
  reg="$(sed -n 's/^NCOMMERCE_REGISTRY=//p' .env | tail -n 1)"
  tag="$(sed -n 's/^NCOMMERCE_TAG=//p' .env | tail -n 1)"
  new_img="$(sudo docker image inspect -f '{{.Id}}' "${reg:-registry.ncommerce.app:5050}/ncommerce/api:${tag:-latest}" 2>/dev/null || true)"
  name=""
  echo
  echo "Conferindo a versao nova (ate $((WAIT_S / 60)) minutos). Pode fechar: a conferencia continua sozinha."
  for ((i = 0; i < WAIT_S; i += 10)); do
    cid="$(sudo docker compose ps -aq api 2>/dev/null | head -n 1)"
    img="$(sudo docker inspect -f '{{.Image}}' "$cid" 2>/dev/null || true)"
    line="$(grep "^[^|]*|$img|" control/versions.txt 2>/dev/null | head -n 1 || true)"
    name="$(echo "$line" | cut -d'|' -f1)"
    state="$(echo "$line" | cut -d'|' -f5)"
    if [ -n "$new_img" ] && [ -n "$img" ] && [ "$img" != "$new_img" ]; then
      echo "A versao nova nao funcionou. O NCommerce voltou para a versao ${name:-anterior}."
      return 1
    fi
    if [ "$state" = "good" ]; then
      echo "Versao $name funcionando."
      return 0
    fi
    sleep 10
  done
  echo "A versao ${name:-nova} ainda esta em teste. Se ela falhar, o NCommerce volta sozinho para a anterior."
  return 0
}

status=0
wait_verdict || status=$?
sudo docker compose ps
exit "$status"
