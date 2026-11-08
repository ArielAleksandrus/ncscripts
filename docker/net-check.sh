#!/bin/bash
# Procura conflito de IP na rede da loja e grava o resultado em <dir>/host/net_check.
# O chat de suporte (SupportContext na API) le esse arquivo para responder
# "a impressora nao imprime", "o monitor nao funciona", "o celular do garcom nao conecta".
#
# O container nao enxerga o ARP da loja (a rede do Docker e outra), por isso roda aqui,
# como root, pelo timer ncommerce-net-check (a cada 2 minutos).
#   net-check.sh [/opt/ncommerce]            grava host/net_check
#   net-check.sh --install [/opt/ncommerce]  instala o arp-scan e o timer, e roda uma vez
#
# Formato (uma linha por item, campos separados por TAB):
#   checked_at  <hora ISO>
#   server      <interface> <ip> ok|conflict <MACs que tambem responderam por esse IP>
#   neighbor    <ip> <mac> <fabricante>     (uma linha por resposta: dois MACs no mesmo IP = conflito)
# A deteccao: o arp-scan pergunta "quem tem este IP?" como um aparelho sem IP (--arpspa 0.0.0.0).
# Para o IP do proprio servidor, qualquer resposta e de outro aparelho.
set -u

if [ "${1:-}" = "--install" ]; then
  DIR="${2:-/opt/ncommerce}"
  if [ "$(id -u)" -ne 0 ]; then
    echo "Rode com sudo: sudo $0 --install $DIR"
    exit 1
  fi
  if ! command -v arp-scan >/dev/null 2>&1 && command -v apt-get >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get install -y arp-scan >/dev/null 2>&1 \
      || { DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get update >/dev/null 2>&1 \
           && DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get install -y arp-scan >/dev/null 2>&1; }
  fi
  if ! command -v arp-scan >/dev/null 2>&1; then
    echo "Nao consegui instalar o arp-scan. O chat de suporte fica sem a verificacao de conflito de IP."
  fi
  cat > /etc/systemd/system/ncommerce-net-check.service <<EOF
[Unit]
Description=Procura conflito de IP na rede da loja para o NCommerce
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$DIR/net-check.sh $DIR
TimeoutStartSec=60
EOF
  cat > /etc/systemd/system/ncommerce-net-check.timer <<EOF
[Unit]
Description=Procura conflito de IP na rede da loja a cada 2 minutos

[Timer]
OnBootSec=1min
OnUnitActiveSec=2min

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now ncommerce-net-check.timer >/dev/null 2>&1 || true
  "$0" "$DIR" || true
  exit 0
fi

DIR="${1:-/opt/ncommerce}"
command -v arp-scan >/dev/null 2>&1 || exit 0
command -v ip >/dev/null 2>&1 || exit 0

out="$(mktemp)"
trap 'rm -f "$out"' EXIT
printf 'checked_at\t%s\n' "$(date -Iseconds)" > "$out"

# Interfaces da loja: com IPv4 global, ligadas e fisicas (sem Docker, VMware, VPN).
ip -4 -o addr show scope global 2>/dev/null \
  | awk '$2 !~ /^(docker|br-|veth|vmnet|virbr|tun|tap|wg|tailscale|zt)/ { split($4, a, "/"); print $2, a[1] }' \
  | sort -u \
  | while read -r iface addr; do
      [ -n "$addr" ] || continue
      # Outro aparelho respondendo pelo IP deste servidor.
      others="$(timeout 15 arp-scan -I "$iface" --arpspa=0.0.0.0 --retry=3 --plain "$addr" 2>/dev/null \
        | awk -F'\t' -v ip="$addr" '$1 == ip { print $2 }' | sort -u | paste -sd, -)"
      if [ -n "$others" ]; then
        printf 'server\t%s\t%s\tconflict\t%s\n' "$iface" "$addr" "$others" >> "$out"
      else
        printf 'server\t%s\t%s\tok\t\n' "$iface" "$addr" >> "$out"
      fi
      # A rede inteira: cada resposta vira uma linha. arp-scan ja diz o fabricante pelo MAC.
      timeout 40 arp-scan -I "$iface" --localnet --retry=2 --plain 2>/dev/null \
        | awk -F'\t' '$1 ~ /^[0-9]+(\.[0-9]+){3}$/ && $2 ~ /:/ { printf "neighbor\t%s\t%s\t%s\n", $1, tolower($2), $3 }' \
        | sort -u >> "$out"
    done

mkdir -p "$DIR/host"
install -m 644 "$out" "$DIR/host/.net_check.tmp" && mv -f "$DIR/host/.net_check.tmp" "$DIR/host/net_check"
