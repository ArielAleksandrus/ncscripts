#!/bin/bash
# Desliga a instalacao nativa do NCommerce no Ubuntu (nginx + Passenger em
# ~/NCommerce), para a loja migrar para o Docker. Nao apaga nada: o que for
# desligado fica anotado em /var/lib/ncommerce-nativo, e o religar_nativo.sh
# volta tudo como estava.
#
# Desliga:
#   - os sites ncommerce e ncommerce-api do nginx (portas 3000 e 4200);
#   - as linhas do NCommerce no cron do usuario e do root;
#   - o Sidekiq e o tunel SSH nativos (os do container ficam);
#   - os servicos Redis e MySQL nativos, que o Docker nao usa.
# Os dados do MySQL nativo ficam no disco. Faca o backup antes
# (tools/backup_ubuntu.sh): com o MySQL parado ele nao conecta.
#
# Rode sem sudo. A senha do sudo e pedida uma vez.
#   --sem-banco   deixa o MySQL nativo ligado
set -euo pipefail

KEEP_DB=0
for arg in "$@"; do
  case "$arg" in
    --sem-banco) KEEP_DB=1 ;;
    *) echo "Opcao desconhecida: $arg"; exit 1 ;;
  esac
done

if [ "$(id -u)" -eq 0 ]; then
  echo "Rode sem sudo. Exemplo: ./desligar_nativo.sh"
  exit 1
fi
echo "Desligando o NCommerce nativo. Digite a senha do computador se for pedida."
sudo -v

STATE=/var/lib/ncommerce-nativo
sudo mkdir -p "$STATE"
sudo chmod 700 "$STATE"
SITES=(ncommerce ncommerce-api)
SIDEKIQ_PATTERN='^sidekiq [0-9]'
TUNNEL_PATTERN='^ssh .*-R .*tunnel[.]nlabs[.]live'
# Linhas de cron do NCommerce. Variaveis (SECRET_KEY_BASE=...) ficam: nao rodam nada.
CRON_PATTERN='ncommerce|nfce'

# Guarda uma linha no arquivo de estado, sem repetir (desligar duas vezes
# nao pode perder o que a primeira vez anotou).
remember() {
  local file="$STATE/$1" line="$2"
  sudo touch "$file"
  if ! sudo grep -qxF -- "$line" "$file"; then
    printf '%s\n' "$line" | sudo tee -a "$file" >/dev/null
  fi
}

# Processos fora de container (os do Docker ficam num cgroup docker), de qualquer usuario.
native_pids() {
  local pid
  for pid in $(pgrep -f "$1" 2>/dev/null || true); do
    if ! grep -qE 'docker|containerd' "/proc/$pid/cgroup" 2>/dev/null; then
      echo "$pid"
    fi
  done
}

# Tira do crontab (do usuario, ou do root com sudo) as linhas do NCommerce e
# guarda cada uma para o religar.
strip_cron() {
  local who="$1" state_file="$2" current removed kept
  if [ "$who" = root ]; then
    current="$(sudo crontab -l 2>/dev/null || true)"
  else
    current="$(crontab -l 2>/dev/null || true)"
  fi
  removed="$(printf '%s\n' "$current" | grep -iE "$CRON_PATTERN" | grep -vE '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=' || true)"
  [ -n "$removed" ] || return 0
  kept="$(printf '%s\n' "$current" | grep -vxF -f <(printf '%s\n' "$removed") || true)"
  while IFS= read -r line; do
    remember "$state_file" "$line"
  done <<< "$removed"
  if [ "$who" = root ]; then
    printf '%s\n' "$kept" | sudo crontab -
  else
    printf '%s\n' "$kept" | crontab -
  fi
  echo "  - cron do $who: $(printf '%s\n' "$removed" | wc -l) linha(s) do NCommerce tirada(s)"
}

# Para e desabilita um servico, anotando se estava habilitado e no ar.
stop_service() {
  local svc="$1" enabled active
  systemctl list-unit-files "${svc}.service" --no-legend 2>/dev/null | grep -q . || return 0
  enabled="$(systemctl is-enabled "$svc" 2>/dev/null || true)"
  active="$(systemctl is-active "$svc" 2>/dev/null || true)"
  if [ "$enabled" != enabled ] && [ "$active" != active ]; then
    return 0
  fi
  if ! sudo grep -q "^${svc} " "$STATE/services" 2>/dev/null; then
    remember services "$svc $enabled $active"
  fi
  sudo systemctl disable --now "$svc" >/dev/null 2>&1 || sudo systemctl stop "$svc" || true
  echo "  - servico $svc parado e desabilitado"
}

changed=0
for site in "${SITES[@]}"; do
  if [ -L "/etc/nginx/sites-enabled/$site" ] || [ -e "/etc/nginx/sites-enabled/$site" ]; then
    target="$(readlink -f "/etc/nginx/sites-enabled/$site")"
    remember nginx_sites "$site $target"
    sudo rm -f "/etc/nginx/sites-enabled/$site"
    echo "  - site $site tirado do nginx"
    changed=1
  fi
done
if [ "$changed" -eq 1 ] && command -v nginx >/dev/null 2>&1; then
  # Reiniciar derruba o Passenger e o Rails nativo.
  sudo systemctl restart nginx 2>/dev/null || sudo service nginx restart 2>/dev/null || true
fi

strip_cron "$USER" cron_user
strip_cron root cron_root

for pattern in "$SIDEKIQ_PATTERN" "$TUNNEL_PATTERN"; do
  pids="$(native_pids "$pattern")"
  if [ -n "$pids" ]; then
    # shellcheck disable=SC2086
    sudo kill $pids 2>/dev/null || true
    if [ "$pattern" = "$SIDEKIQ_PATTERN" ]; then
      echo "  - Sidekiq nativo parado"
    else
      echo "  - tunel nativo fechado"
    fi
  fi
done

stop_service redis-server
if [ "$KEEP_DB" -eq 0 ]; then
  stop_service mysql
fi

sleep 2
left=""
for port in 3000 4200; do
  if sudo ss -ltnp 2>/dev/null | grep -E ":${port}[[:space:]]" | grep -qE 'nginx|Passenger|ruby'; then
    left="$left $port"
  fi
done
if [ -n "$(native_pids "$SIDEKIQ_PATTERN")" ]; then
  left="$left sidekiq"
fi
if [ -n "$left" ]; then
  echo "Ainda ficou no ar:$left. Confira antes de instalar o Docker."
  exit 1
fi

echo "NCommerce nativo desligado. Para voltar: tools/religar_nativo.sh"
