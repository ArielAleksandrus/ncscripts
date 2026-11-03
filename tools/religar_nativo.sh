#!/bin/bash
# Volta a instalacao nativa do NCommerce que o desligar_nativo.sh desligou,
# com o que ficou anotado em /var/lib/ncommerce-nativo: sites do nginx, linhas
# do cron (usuario e root), Redis e MySQL. O Sidekiq e o tunel voltam sozinhos
# quando o Rails nativo sobe.
#
# Se a loja Docker estiver nesta maquina, ela e parada antes: as duas juntas
# brigariam pelas portas 3000 e 4200 e buscariam os mesmos pedidos do iFood.
# Os dados do Docker ficam nos volumes.
#
# Rode sem sudo. A senha do sudo e pedida uma vez.
set -euo pipefail

if [ "$(id -u)" -eq 0 ]; then
  echo "Rode sem sudo. Exemplo: ./religar_nativo.sh"
  exit 1
fi
echo "Religando o NCommerce nativo. Digite a senha do computador se for pedida."
sudo -v

STATE=/var/lib/ncommerce-nativo
if ! sudo test -d "$STATE"; then
  echo "Nao achei $STATE: o desligar_nativo.sh nao rodou nesta maquina. Nada para religar."
  exit 1
fi
DOCKER_DIR="${NCOMMERCE_INSTALL_DIR:-/opt/ncommerce}"

if [ -f "$DOCKER_DIR/docker-compose.yml" ] && command -v docker >/dev/null 2>&1; then
  echo "  - parando a loja Docker de $DOCKER_DIR"
  # stop: com restart unless-stopped, os containers continuam parados depois de reiniciar o PC.
  (cd "$DOCKER_DIR" && sudo docker compose stop) || true
fi

# Devolve ao crontab as linhas anotadas que nao estao la.
restore_cron() {
  local who="$1" state_file="$STATE/$2" current added=0 line
  sudo test -s "$state_file" || return 0
  if [ "$who" = root ]; then
    current="$(sudo crontab -l 2>/dev/null || true)"
  else
    current="$(crontab -l 2>/dev/null || true)"
  fi
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if ! printf '%s\n' "$current" | grep -qxF -- "$line"; then
      current="$(printf '%s\n%s' "$current" "$line")"
      added=$((added + 1))
    fi
  done < <(sudo cat "$state_file")
  current="$(printf '%s\n' "$current" | sed '/./,$!d')"
  if [ "$who" = root ]; then
    printf '%s\n' "$current" | sudo crontab -
  else
    printf '%s\n' "$current" | crontab -
  fi
  echo "  - cron do $who: $added linha(s) devolvida(s)"
}

if sudo test -s "$STATE/services"; then
  while read -r svc enabled active; do
    [ -n "$svc" ] || continue
    if [ "$enabled" = enabled ]; then
      sudo systemctl enable "$svc" >/dev/null 2>&1 || true
    fi
    if [ "$active" = active ]; then
      sudo systemctl start "$svc"
    fi
    echo "  - servico $svc religado"
  done < <(sudo cat "$STATE/services")
fi

restore_cron "$USER" cron_user
restore_cron root cron_root

restarted=0
if sudo test -s "$STATE/nginx_sites"; then
  while read -r site target; do
    [ -n "$site" ] || continue
    if [ ! -e "$target" ]; then
      echo "  - site $site: $target nao existe mais, ficou de fora"
      continue
    fi
    sudo ln -sfn "$target" "/etc/nginx/sites-enabled/$site"
    echo "  - site $site de volta no nginx"
    restarted=1
  done < <(sudo cat "$STATE/nginx_sites")
fi
if [ "$restarted" -eq 1 ]; then
  if ! sudo nginx -t >/dev/null 2>&1; then
    echo "O nginx recusou a configuracao. Veja: sudo nginx -t"
    exit 1
  fi
  sudo systemctl restart nginx 2>/dev/null || sudo service nginx restart
fi

# O Passenger so sobe o Rails no primeiro acesso, e o Rails sobe o Sidekiq e o tunel.
echo "Subindo o Rails nativo (pode levar um minuto)..."
ok=0
for _ in $(seq 1 30); do
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 http://localhost:3000/ || true)"
  if [ -n "$code" ] && [ "$code" != 000 ] && [ "$code" -lt 500 ]; then
    ok=1
    break
  fi
  sleep 3
done
if [ "$ok" -ne 1 ]; then
  echo "A API nativa nao respondeu na porta 3000. Veja o log do nginx e do Rails."
  exit 1
fi

sudo rm -rf "$STATE"
echo "NCommerce nativo religado (API respondendo na porta 3000)."
