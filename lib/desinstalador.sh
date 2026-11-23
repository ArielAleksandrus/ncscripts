#!/bin/bash
# Funcoes comuns dos desinstaladores Linux (desinstalador_linux.sh e
# advanced/desinstalador_nativo.sh). Usa a lib do instalador (trava, estado,
# log); quem usa faz `. lib/instalador.sh` antes de `. lib/desinstalador.sh`.
#
# Modo simular (UN_SIMULAR=1): nada e mudado. `act` so mostra o que faria, e
# as consultas (listar containers, volumes, arquivos) rodam normalmente.

UN_SIMULAR="${UN_SIMULAR:-0}"
UN_MANUAL=()
UN_DONE=()

# act "o que e" comando...  Faz (ou, no simular, so mostra) e devolve o codigo do comando.
act() {
  local what="$1"
  shift
  if [ "$UN_SIMULAR" = "1" ]; then
    printf '  [simular] %s\n' "$what"
    return 0
  fi
  printf '  - %s\n' "$what"
  "$@"
}

# Roda sem mostrar a saida do comando (o que importa e o codigo de saida).
quiet() { "$@" >/dev/null 2>&1; }

# Alguma coisa que este desinstalador nao remove: volta na lista do fim.
manual() { UN_MANUAL+=("$*"); }

print_manual() {
  [ "${#UN_MANUAL[@]}" -gt 0 ] || return 0
  echo
  echo "Ficou no computador (remova a mao se quiser; o instalador do NCommerce nao"
  echo "registra se estes ja existiam antes dele, entao nao foram removidos):"
  printf '  - %s\n' "${UN_MANUAL[@]}"
}

# confirm_uninstall "texto do que sera removido"
# Devolve 0 so quando a pessoa digita DESINSTALAR.
confirm_uninstall() {
  local answer=""
  echo
  echo "Para confirmar, digite DESINSTALAR (em maiusculas) e tecle Enter."
  echo "Qualquer outra resposta cancela sem mudar nada."
  read -r -p "> " answer || answer=""
  [ "$answer" = "DESINSTALAR" ]
}

# Caminho absoluto, mesmo de pasta que ainda nao existe.
abs_path() {
  local p="$1"
  case "$p" in
    /*) ;;
    *) p="$PWD/$p" ;;
  esac
  realpath -m -- "$p" 2>/dev/null || printf '%s\n' "$p"
}

# path_inside FILHO PAI: o FILHO e o PAI ou esta dentro dele.
path_inside() {
  local child parent
  child="$(abs_path "$1")"
  parent="$(abs_path "$2")"
  [ "$child" = "$parent" ] || [ "${child#"$parent"/}" != "$child" ]
}

# Pasta nova para o backup: BASE/ncommerce-backup-desinstalacao-AAAAMMDD-HHMMSS.
new_backup_dir() {
  local base="$1" dir
  dir="$(abs_path "$base")/ncommerce-backup-desinstalacao-$(date '+%Y%m%d-%H%M%S')"
  mkdir -p "$dir" || return 1
  chmod 700 "$dir" 2>/dev/null || true
  printf '%s\n' "$dir"
}

# O dump comprimido termina com "Dump completed" e o gzip esta inteiro.
dump_ok() {
  local file="$1"
  [ -s "$file" ] && gzip -t "$file" 2>/dev/null && gzip -dc "$file" 2>/dev/null | tail -c 300 | grep -q "Dump completed"
}

# Linhas do crontab (do usuario, ou do root com "root") que rodam algo do NCommerce.
# Linhas de variavel (CHAVE=valor) nao rodam nada e ficam de fora.
cron_ncommerce_lines() {
  local who="$1" current
  if [ "$who" = root ]; then
    current="$(sudo crontab -l 2>/dev/null || true)"
  else
    current="$(crontab -l 2>/dev/null || true)"
  fi
  printf '%s\n' "$current" | grep -iE 'ncommerce|nfce' | grep -vE '^[[:space:]]*#|^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=' || true
}

# Tira do crontab as linhas de cron_ncommerce_lines.
strip_cron_lines() {
  local who="$1" current removed kept
  removed="$(cron_ncommerce_lines "$who")"
  [ -n "$removed" ] || return 0
  if [ "$who" = root ]; then
    current="$(sudo crontab -l 2>/dev/null || true)"
  else
    current="$(crontab -l 2>/dev/null || true)"
  fi
  kept="$(printf '%s\n' "$current" | grep -vxF -f <(printf '%s\n' "$removed") || true)"
  if [ "$who" = root ]; then
    printf '%s\n' "$kept" | sudo crontab -
  else
    printf '%s\n' "$kept" | crontab -
  fi
}

# Unidade do systemd criada pelo NCommerce: para, desabilita e apaga o arquivo.
remove_unit() {
  local unit="$1" file="/etc/systemd/system/$1"
  [ -e "$file" ] || return 0
  act "parar e apagar o servico $unit" sh -c '
    sudo systemctl disable --now "$1" >/dev/null 2>&1 || true
    sudo rm -f "$2"' _ "$unit" "$file"
  UN_DAEMON_RELOAD=1
}

# O ajuste de keepalive do SSH que os instaladores gravam. O SSH continua ligado.
remove_ssh_keepalive() {
  local conf=/etc/ssh/sshd_config.d/ncommerce-keepalive.conf
  [ -e "$conf" ] || return 0
  act "apagar o ajuste de keepalive do SSH ($conf)" sh -c '
    sudo rm -f "$1"
    if sudo sshd -t >/dev/null 2>&1; then
      sudo systemctl reload ssh >/dev/null 2>&1 || sudo systemctl reload ssh.service >/dev/null 2>&1 || true
    fi' _ "$conf"
}

# Atalhos .desktop com este nome nas pastas de area de trabalho do usuario.
desktop_dirs() {
  local xdg="" dir seen=" "
  if command -v xdg-user-dir >/dev/null 2>&1; then
    xdg="$(xdg-user-dir DESKTOP 2>/dev/null || true)"
    [ "$xdg" != "$HOME" ] || xdg=""
  fi
  for dir in "$xdg" "$HOME/Desktop" "$HOME/Área de Trabalho" "$HOME/Área de trabalho"; do
    [ -n "$dir" ] && [ -d "$dir" ] || continue
    case "$seen" in *" $dir "*) continue ;; esac
    seen="$seen$dir "
    printf '%s\n' "$dir"
  done
}

remove_desktop_shortcut() {
  local name="$1" dir
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    if [ -e "$dir/$name" ]; then
      act "apagar o atalho $dir/$name" rm -f "$dir/$name"
    fi
  done < <(desktop_dirs)
}
