#!/bin/bash
# Aponta so o tunnel.nlabs.live para a interface que chega ate ele.
# A rota padrao nao muda, e nenhuma conexao do NetworkManager e religada:
# isso derrubaria a rede da loja.
#
#   tunnel-route.sh                 avalia uma vez
#   tunnel-route.sh --dry-run       mostra a decisao, sem trocar nada
#   tunnel-route.sh --install [dir] instala o timer (a cada 30s)
#
# Orcamento: no maximo um ping na interface em uso. So se ela falhar e que
# a outra e testada, com um ping. Nao ha varredura da LAN.
#
# Se a interface em uso chega, a rodada acaba. Uma qualidade um pouco melhor
# na outra nao troca: cabo e wifi oscilariam o dia inteiro.
# Duas falhas seguidas, e outra placa que chega, trocam a /32. Uma perda de
# um unico ping nao troca. A placa deixada fica de fora por 3 minutos.
# Se nenhuma chega, a rota fica como esta e as proximas rodadas nao pingam
# por 5 minutos. As duas caidas nao viram um laco.
set -uo pipefail

HOST="tunnel.nlabs.live"
BAN_SECONDS=180
HOLD_SECONDS=300
PING_WAIT=2
STATE_DIR="${TUNNEL_ROUTE_STATE_DIR:-/run/ncommerce}"
STATE="$STATE_DIR/tunnel-route.state"
DRY=0

if [ "${1:-}" = "--install" ]; then
  DIR="${2:-/opt/ncommerce}"
  if [ "$(id -u)" -ne 0 ]; then
    echo "Rode com sudo: sudo $0 --install $DIR"
    exit 1
  fi
  cat > /etc/systemd/system/ncommerce-tunnel-route.service <<EOF
[Unit]
Description=Escolhe a interface que alcanca o tunnel.nlabs.live
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$DIR/tunnel-route.sh
TimeoutStartSec=15
Nice=19
EOF
  cat > /etc/systemd/system/ncommerce-tunnel-route.timer <<EOF
[Unit]
Description=Confere o caminho do tunnel.nlabs.live a cada 30 segundos

[Timer]
OnBootSec=45s
OnUnitActiveSec=30s
AccuracySec=5s

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now ncommerce-tunnel-route.timer >/dev/null 2>&1 || true
  exit 0
fi

if [ "${1:-}" = "--dry-run" ]; then
  DRY=1
fi

mkdir -p "$STATE_DIR"
exec 9>"$STATE_DIR/tunnel-route.lock"
if command -v flock >/dev/null 2>&1; then
  flock -n 9 || exit 0
fi

now=$(date +%s)

state_get() {
  [ -f "$STATE" ] || return 0
  awk -F= -v k="$1" '$1 == k { print substr($0, index($0, "=") + 1); exit }' "$STATE"
}

state_set() {
  [ "$DRY" = 1 ] && return 0
  local key="$1" value="$2" tmp
  tmp="$(mktemp "$STATE_DIR/tunnel-route.XXXXXX")"
  if [ -f "$STATE" ]; then
    awk -F= -v k="$key" '$1 != k { print }' "$STATE" > "$tmp"
  fi
  printf '%s=%s\n' "$key" "$value" >> "$tmp"
  mv -f "$tmp" "$STATE"
}

is_public_ip() {
  case "$1" in
    ""|*[!0-9.]*) return 1 ;;
    0.*|10.*|127.*|169.254.*|192.168.*|255.*) return 1 ;;
    172.1[6-9].*|172.2[0-9].*|172.3[0-1].*) return 1 ;;
  esac
  return 0
}

# Nao instala rota para IP da propria loja. Um DNS errado nao pode
# desviar o caixa, a impressora ou o roteador.
resolve_dest() {
  local found cached
  found="$(timeout 2 getent ahostsv4 "$HOST" 2>/dev/null | awk 'NR == 1 { print $1; exit }')"
  if is_public_ip "$found"; then
    printf '%s\n' "$found"
    return 0
  fi
  cached="$(state_get dest)"
  if is_public_ip "$cached"; then
    printf '%s\n' "$cached"
    return 0
  fi
  return 1
}

iface_up() {
  local carrier oper
  carrier="$(cat "/sys/class/net/$1/carrier" 2>/dev/null || true)"
  [ "$carrier" = "1" ] && return 0
  oper="$(cat "/sys/class/net/$1/operstate" 2>/dev/null || true)"
  [ "$oper" = "up" ] && [ "$carrier" != "0" ]
}

iface_src() {
  ip -4 -o addr show dev "$1" scope global 2>/dev/null \
    | awk '{ split($4, a, "/"); print a[1]; exit }'
}

iface_gw() {
  ip -4 route show default dev "$1" 2>/dev/null \
    | awk '{ for (i = 1; i <= NF; i++) if ($i == "via") { print $(i + 1); exit } }'
}

# Um ping, preso a esta placa. Devolve 0 e o tempo em ms.
probe_iface() {
  local out rtt
  out="$(LC_ALL=C ping -I "$1" -n -c 1 -W "$PING_WAIT" "$2" 2>/dev/null)" || return 1
  rtt="$(printf '%s\n' "$out" | sed -n 's/.*[Tt]ime=\([0-9.][0-9.]*\).*/\1/p' | head -1)"
  printf '%s\n' "${rtt:-9999}"
}

eligible_ifaces() {
  ip -4 -o addr show scope global up 2>/dev/null \
    | awk '$2 !~ /^(lo|docker|br-|veth|vmnet|virbr|tun|tap|wg|tailscale|zt|nordlynx)/ { print $2 }' \
    | sort -u
}

route_dev() {
  ip -4 route get "$1" 2>/dev/null \
    | awk '{ for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit } }'
}

banned() {
  local until
  until="$(state_get "bad_$1")"
  [ -n "$until" ] && [ "$now" -lt "$until" ]
}

# Tira a /32 deste destino e devolve a lista que sobra, separada por virgula.
routes_without() {
  printf '%s\n' "$1" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' \
    | awk -v dest="$2" 'NF && $1 != dest "/32" { print }' \
    | paste -sd',' -
}

remember_nm() {
  local chosen="$1" dest="$2" gw="$3" src="$4" iface conn routes kept spec
  command -v nmcli >/dev/null 2>&1 || return 0
  spec="${dest}/32 ${gw} src=${src}"
  while read -r iface; do
    [ -n "$iface" ] || continue
    conn="$(nmcli -g GENERAL.CONNECTION device show "$iface" 2>/dev/null || true)"
    [ -n "$conn" ] && [ "$conn" != "--" ] || continue
    routes="$(nmcli -g ipv4.routes connection show "$conn" 2>/dev/null || true)"
    kept="$(routes_without "$routes" "$dest")"
    if [ "$iface" = "$chosen" ]; then
      if [ -n "$kept" ]; then
        spec="${kept}, ${spec}"
      fi
      nmcli connection modify "$conn" ipv4.routes "$spec" >/dev/null 2>&1 || true
    elif printf '%s' "$routes" | grep -q "${dest}/32"; then
      nmcli connection modify "$conn" ipv4.routes "$kept" >/dev/null 2>&1 || true
    fi
  done < <(eligible_ifaces)
}

apply_switch() {
  local iface="$1" dest="$2" gw="$3" src="$4" old="$5"
  if [ "$DRY" = 1 ]; then
    echo "trocaria para $iface via $gw src $src"
    return 0
  fi
  ip route replace "${dest}/32" via "$gw" dev "$iface" src "$src"
  if [ -n "$old" ] && [ "$old" != "$dest" ]; then
    ip route del "${old}/32" >/dev/null 2>&1 || true
  fi
  remember_nm "$iface" "$dest" "$gw" "$src"
  echo "tunnel.nlabs.live ${dest} sai por ${iface}"
}

hold_active() {
  local until
  until="$(state_get hold_until)"
  [ -n "$until" ] && [ "$now" -lt "$until" ]
}

if hold_active; then
  exit 0
fi

dest="$(resolve_dest)" || exit 0
state_set dest "$dest"

current="$(route_dev "$dest")"
streak="$(state_get fail_streak)"
streak="${streak:-0}"

if [ -n "$current" ] && iface_up "$current" && rtt="$(probe_iface "$current" "$dest")"; then
  [ "$streak" = "0" ] || state_set fail_streak 0
  hold="$(state_get hold_until)"
  [ -z "$hold" ] || [ "$hold" = "0" ] || state_set hold_until 0
  if [ "$DRY" = 1 ]; then
    echo "atual $current ok ${rtt}ms"
    echo "sem troca"
  fi
  exit 0
fi

streak=$((streak + 1))
state_set fail_streak "$streak"

# Uma falha sozinha nao troca e nao pinge as outras placas.
if [ "$streak" -lt 2 ]; then
  if [ "$DRY" = 1 ]; then
    echo "atual ${current:-nenhuma} falhou (${streak}/2)"
  fi
  exit 0
fi

best_iface=""
best_rtt=""
best_gw=""
best_src=""
saw_other=0
tried_other=0
while read -r iface; do
  [ -n "$iface" ] || continue
  [ "$iface" = "$current" ] && continue
  saw_other=$((saw_other + 1))
  [ "$saw_other" -le 3 ] || break
  iface_up "$iface" || continue
  # A placa que largamos agora ha pouco nao entra de novo.
  # Sem isso as duas oscilando trocariam a rota a cada minuto.
  if banned "$iface"; then
    continue
  fi
  gw="$(iface_gw "$iface")"
  src="$(iface_src "$iface")"
  [ -n "$gw" ] && [ -n "$src" ] || continue
  tried_other=$((tried_other + 1))
  if rtt="$(probe_iface "$iface" "$dest")"; then
    if [ -z "$best_rtt" ] || awk -v a="$rtt" -v b="$best_rtt" 'BEGIN { exit !(a + 0 < b + 0) }'; then
      best_iface="$iface"
      best_rtt="$rtt"
      best_gw="$gw"
      best_src="$src"
    fi
  fi
done < <(eligible_ifaces)

if [ -n "$best_iface" ]; then
  # A que falhou duas vezes fica de fora por 3 minutos.
  if [ -n "$current" ]; then
    state_set "bad_$current" $((now + BAN_SECONDS))
  fi
  apply_switch "$best_iface" "$dest" "$best_gw" "$best_src" "$(state_get routed)"
  state_set routed "$dest"
  state_set fail_streak 0
  state_set hold_until 0
  if [ "$DRY" = 1 ]; then
    echo "alternativa $best_iface ok ${best_rtt}ms"
  fi
  exit 0
fi

# Outra placa foi testada e tambem nao chegou: para de pingar por 5 minutos.
# Se a outra so esta de castigo, nao entra nesse silencio. Um ping a cada
# 30s na placa atual basta ate o castigo acabar.
if [ "$tried_other" -gt 0 ] || [ "$saw_other" -eq 0 ]; then
  state_set hold_until $((now + HOLD_SECONDS))
  state_set fail_streak 0
  echo "nenhuma interface alcanca ${HOST}; sem troca por ${HOLD_SECONDS}s"
else
  [ "$DRY" = 1 ] && echo "atual falhou; alternativa de castigo, sem troca"
fi
exit 0
