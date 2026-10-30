#!/bin/bash
# IPs da maquina onde o Docker roda. O container nao enxerga a rede da loja.
# NCOMMERCE_HOST_IPS vale para a imagem nova. bin/ip vale para a imagem que
# ainda executa `ip a`.

host_lan_ips() {
  local raw
  if command -v ip >/dev/null 2>&1; then
    raw="$(ip -4 -o addr show scope global 2>/dev/null | awk '$2 !~ /^(docker|br-|veth)/ { split($4, a, "/"); print a[1] }')"
  else
    raw="$(hostname -I 2>/dev/null | tr ' ' '\n')"
  fi
  printf '%s\n' "$raw" | grep -E '^[0-9]+(\.[0-9]+){3}$' | grep -vE '^(127\.|169\.254\.)' | sort -u | paste -sd, - || true
}

write_host_ip_files() {
  local dir="$1" ips shim ip envf
  ips="$(host_lan_ips)"
  shim="$(mktemp)"
  {
    printf '%s\n' '#!/bin/sh' '# IPs do servidor, no formato de `ip a`.'
    if [ -n "$ips" ]; then
      local IFS=','
      for ip in $ips; do
        case "$ip" in
          ""|*[!0-9.]*) continue ;;
        esac
        printf "printf 'inet %s/24\\\\n'\n" "$ip"
      done
    fi
  } > "$shim"
  chmod 755 "$shim"
  sudo mkdir -p "$dir/bin"
  if [ -d "$dir/bin/ip" ]; then
    sudo rm -rf "$dir/bin/ip"
  fi
  sudo cp "$shim" "$dir/bin/ip"
  sudo chmod 755 "$dir/bin/ip"
  rm -f "$shim"

  envf="$dir/.env"
  if [ -f "$envf" ]; then
    sudo sed -i '/^NCOMMERCE_HOST_IPS=/d' "$envf"
    printf 'NCOMMERCE_HOST_IPS=%s\n' "$ips" | sudo tee -a "$envf" >/dev/null
  fi
  if [ -n "$ips" ]; then
    echo "IPs do servidor: ${ips//,/, }"
  else
    echo "Nao achei um IP de rede nesta maquina."
  fi
}
