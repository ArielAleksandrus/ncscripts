#!/bin/bash
# Grava o ID do AnyDesk deste computador em <dir>/host/anydesk_id.
# O container le esse arquivo e a API manda o ID para o mestre, que leva ao cadastro no manager.
# O systemd chama no boot (ncommerce-anydesk-id.service). Uso: anydesk-id.sh [/opt/ncommerce]
set -u

DIR="${1:-/opt/ncommerce}"

command -v anydesk >/dev/null 2>&1 || exit 0

# Logo depois do boot o servico do AnyDesk ainda nao tem ID e responde 0.
id=""
for _ in $(seq 1 24); do
  id="$(anydesk --get-id 2>/dev/null | tr -cd '0-9')"
  if [ -n "$id" ] && [ "$id" != "0" ]; then
    break
  fi
  id=""
  sleep 5
done

if [ -z "$id" ]; then
  echo "O AnyDesk nao informou o ID."
  exit 0
fi

mkdir -p "$DIR/host"
printf '%s\n' "$id" > "$DIR/host/anydesk_id.tmp"
mv "$DIR/host/anydesk_id.tmp" "$DIR/host/anydesk_id"
echo "AnyDesk ID: $id"
