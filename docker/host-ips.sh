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

# Um .env vazio (queda de energia no meio de uma gravacao antiga) faria o compose
# subir com os padroes: sem a pasta de plugins e sem a porta do CUPS da loja.
# A copia .env.bak, gravada a cada troca, volta no lugar.
repair_env_file() {
  local envf="$1"
  if sudo test -f "$envf" && ! sudo test -s "$envf" && sudo test -s "$envf.bak"; then
    sudo cp -p "$envf.bak" "$envf.novo" && sudo mv -f "$envf.novo" "$envf"
    echo "O arquivo $envf estava vazio. Voltei a copia anterior."
  fi
}

write_host_ip_files() {
  local dir="$1" ips shim ip envf tmp
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
  # bin/ip e montado como arquivo no container: trocar com mv mudaria o inode e
  # o container continuaria vendo o antigo. Por isso e gravado por cima, e so
  # quando mudou.
  if ! sudo cmp -s "$shim" "$dir/bin/ip" 2>/dev/null; then
    sudo cp "$shim" "$dir/bin/ip"
    sudo chmod 755 "$dir/bin/ip"
  fi
  rm -f "$shim"

  # O .env e trocado inteiro com mv: uma queda de energia deixa o antigo ou o novo.
  envf="$dir/.env"
  repair_env_file "$envf"
  if sudo test -f "$envf"; then
    tmp="$(mktemp)"
    { sudo cat "$envf" | grep -v '^NCOMMERCE_HOST_IPS=' || true; printf 'NCOMMERCE_HOST_IPS=%s\n' "$ips"; } > "$tmp"
    if ! sudo cmp -s "$tmp" "$envf"; then
      sudo install -m 644 "$tmp" "$envf.novo" && sudo mv -f "$envf.novo" "$envf"
    fi
    rm -f "$tmp"
  fi
  if [ -n "$ips" ]; then
    echo "IPs do servidor: ${ips//,/, }"
  else
    echo "Nao achei um IP de rede nesta maquina."
  fi
}
