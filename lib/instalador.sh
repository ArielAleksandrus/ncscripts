#!/bin/bash
# Funcoes do instalador_linux.sh que nao dependem da loja: trava contra duas
# execucoes, registro de progresso em disco, log, escrita atomica de arquivos e
# download que continua de onde parou. Este arquivo so define funcoes; quem usa
# faz `. lib/instalador.sh`. Os testes ficam em tests/.
#
# Tudo que grava em disco escreve num arquivo temporario na mesma pasta e troca
# com mv: uma queda de energia deixa o arquivo antigo ou o novo, nunca a metade.

# ---------------------------------------------------------------- mensagens

NC_LOG_FILE=""
NC_STEP_NOW=0
NC_STEP_TOTAL=0
NC_STEP_TITLE=""
NC_WARNINGS=()

say() { printf '%s\n' "$*"; }

# Aviso que nao para a instalacao. Volta no resumo do fim.
warn() {
  NC_WARNINGS+=("$*")
  printf 'AVISO: %s\n' "$*"
}

# step 3 "Docker": cabecalho "Etapa 3 de 10" e ponto de retomada no log.
step() {
  NC_STEP_NOW="$1"
  NC_STEP_TITLE="$2"
  printf '\n=== Etapa %s de %s: %s ===\n' "$NC_STEP_NOW" "$NC_STEP_TOTAL" "$NC_STEP_TITLE"
  if [ -n "$NC_LOG_FILE" ]; then
    printf '[%s] etapa %s/%s: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$NC_STEP_NOW" "$NC_STEP_TOTAL" "$NC_STEP_TITLE" >> "$NC_LOG_FILE" 2>/dev/null || true
  fi
}

# Tudo que aparece na tela vai tambem para o arquivo de log. O tee ignora
# Ctrl+C e o fechamento da janela, para gravar as ultimas linhas.
# log_start /pasta prefixo  -> define NC_LOG_FILE
log_start() {
  local dir="$1" prefix="$2"
  mkdir -p "$dir" || return 1
  NC_LOG_FILE="$dir/$prefix-$(date '+%Y%m%d-%H%M%S').log"
  : > "$NC_LOG_FILE" || return 1
  chmod 600 "$NC_LOG_FILE" 2>/dev/null || true
  # Ficam os 10 logs mais recentes.
  # shellcheck disable=SC2012
  ls -1t "$dir/$prefix"-*.log 2>/dev/null | tail -n +11 | while IFS= read -r old; do rm -f -- "$old"; done
  exec 3>&1 4>&2
  exec > >(trap '' INT HUP TERM; exec tee -a "$NC_LOG_FILE") 2>&1
  NC_TEE_PID=$!
}

# Fecha o tee e espera ele gravar o que falta.
log_stop() {
  [ -n "${NC_TEE_PID:-}" ] || return 0
  exec 1>&3 2>&4 3>&- 4>&-
  wait "$NC_TEE_PID" 2>/dev/null || true
  NC_TEE_PID=""
}

# --------------------------------------------------------------------- trava

NC_LOCK_FILE=""
NC_LOCK_DIR=""

# lock_acquire /caminho/arquivo.lock
# Devolve 1 se outra execucao esta viva. Com flock o kernel solta a trava
# quando o processo morre (queda, kill -9): nao existe trava orfa. Sem flock,
# a trava e uma pasta com o PID de quem pegou; PID que nao existe mais e trava
# orfa e e tomada.
lock_acquire() {
  local file="$1" pid
  mkdir -p "$(dirname "$file")" || return 1
  if command -v flock >/dev/null 2>&1; then
    exec 8>>"$file" || return 1
    if ! flock -n 8; then
      exec 8>&-
      return 1
    fi
    NC_LOCK_FILE="$file"
    printf '%s\n' "$$" > "$file.pid" 2>/dev/null || true
    return 0
  fi
  if ! mkdir "$file.d" 2>/dev/null; then
    pid="$(cat "$file.d/pid" 2>/dev/null || true)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      return 1
    fi
    rm -rf "$file.d"
    mkdir "$file.d" 2>/dev/null || return 1
  fi
  printf '%s\n' "$$" > "$file.d/pid"
  NC_LOCK_DIR="$file.d"
  return 0
}

lock_release() {
  if [ -n "$NC_LOCK_FILE" ]; then
    rm -f "$NC_LOCK_FILE.pid"
    exec 8>&- 2>/dev/null || true
    NC_LOCK_FILE=""
  fi
  if [ -n "$NC_LOCK_DIR" ]; then
    rm -rf "$NC_LOCK_DIR"
    NC_LOCK_DIR=""
  fi
}

# -------------------------------------------------------- arquivo de estado

# Linhas chave=valor. Cada gravacao troca o arquivo inteiro com mv.
NC_STATE_FILE=""

state_init() {
  NC_STATE_FILE="$1"
  mkdir -p "$(dirname "$NC_STATE_FILE")" || return 1
  # Sobra de uma gravacao interrompida.
  rm -f "$NC_STATE_FILE".tmp.* 2>/dev/null || true
  # Arquivo ilegivel (disco cheio, queda no meio de outra coisa) nao pode
  # travar o instalador: comeca de novo. As etapas conferem o que ja existe.
  if [ -e "$NC_STATE_FILE" ] && grep -qvE '^[A-Za-z0-9_]+=[^[:cntrl:]]*$' "$NC_STATE_FILE" 2>/dev/null; then
    mv -f "$NC_STATE_FILE" "$NC_STATE_FILE.ilegivel" 2>/dev/null || rm -f "$NC_STATE_FILE"
  fi
  [ -e "$NC_STATE_FILE" ] || : > "$NC_STATE_FILE"
}

state_get() {
  [ -f "$NC_STATE_FILE" ] || return 0
  awk -v k="$1" 'index($0, k "=") == 1 { v = substr($0, length(k) + 2) } END { printf "%s", v }' "$NC_STATE_FILE"
}

state_set() {
  local key="$1" value="${2:-}" tmp
  tmp="$NC_STATE_FILE.tmp.$$"
  {
    if [ -f "$NC_STATE_FILE" ]; then
      awk -v k="$key" 'index($0, k "=") != 1' "$NC_STATE_FILE"
    fi
    printf '%s=%s\n' "$key" "$value"
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  sync "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$NC_STATE_FILE"
}

state_unset() {
  local key="$1" tmp
  [ -f "$NC_STATE_FILE" ] || return 0
  tmp="$NC_STATE_FILE.tmp.$$"
  awk -v k="$key" 'index($0, k "=") != 1' "$NC_STATE_FILE" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$NC_STATE_FILE"
}

state_done() { state_set "etapa_$1" "$(date +%s)"; }
state_is_done() { [ -n "$(state_get "etapa_$1")" ]; }

# ---------------------------------------------------------- escrita atomica

# install_atomic ORIGEM DESTINO MODO [bak]
# Copia para DESTINO.novo, confere o tamanho e troca com mv. Com "bak", o
# arquivo anterior, se era diferente, fica em DESTINO.bak. Usa sudo quando
# NC_SUDO=1 (padrao).
install_atomic() {
  local src="$1" dst="$2" mode="$3" keep="${4:-}" tmp
  tmp="$dst.novo"
  if _root test -f "$dst" && _root cmp -s "$src" "$dst"; then
    _root chmod "$mode" "$dst"
    return 0
  fi
  _root install -m "$mode" "$src" "$tmp" || { _root rm -f "$tmp"; return 1; }
  if ! _root cmp -s "$src" "$tmp"; then
    _root rm -f "$tmp"
    return 1
  fi
  if [ "$keep" = "bak" ] && _root test -f "$dst"; then
    _root cp -p "$dst" "$dst.bak" || true
  fi
  _root mv -f "$tmp" "$dst"
}

_root() {
  if [ "${NC_SUDO:-1}" = "1" ]; then sudo "$@"; else "$@"; fi
}

# env_merge ARQUIVO CHAVE=valor [CHAVE=valor ...]
# Troca ou acrescenta as chaves dadas e mantem as outras linhas do arquivo
# (NCOMMERCE_KEEP_VERSIONS, senha do banco trocada a mao etc.). O anterior
# fica em ARQUIVO.bak.
env_merge() {
  local file="$1" tmp pair key keys="" rc
  shift
  tmp="$(mktemp)" || return 1
  for pair in "$@"; do
    key="${pair%%=*}"
    keys="$keys $key"
  done
  {
    if _root test -f "$file"; then
      _root cat "$file" | awk -v keys="$keys" '
        BEGIN { n = split(keys, a, " "); for (i = 1; i <= n; i++) drop[a[i]] = 1 }
        { k = $0; sub(/=.*/, "", k); if (!(k in drop)) print }'
    fi
    for pair in "$@"; do
      printf '%s\n' "$pair"
    done
  } > "$tmp"
  install_atomic "$tmp" "$file" 644 bak
  rc=$?
  rm -f "$tmp"
  return "$rc"
}

# Ultimo valor de uma chave num .env (sem aspas em volta).
env_read() {
  local file="$1" key="$2"
  _root test -f "$file" || return 0
  _root cat "$file" | awk -v k="$key" 'index($0, k "=") == 1 { v = substr($0, length(k) + 2) } END { printf "%s", v }' | tr -d '\r'
}

# ------------------------------------------------------------------ download

# retry N ESPERA comando...   tenta ate N vezes, esperando ESPERA*tentativa segundos.
retry() {
  local n="$1" wait_s="$2" i
  shift 2
  for ((i = 1; i <= n; i++)); do
    if "$@"; then return 0; fi
    if [ "$i" -lt "$n" ]; then
      say "Nao deu certo (tentativa $i de $n). Tentando de novo em $((wait_s * i)) segundos..."
      sleep $((wait_s * i))
    fi
  done
  return 1
}

# download_resumable URL ARQUIVO.part [tentativas]
# Baixa continuando do ponto em que ARQUIVO.part parou. Escreve o codigo HTTP
# final em NC_HTTP. Devolve 0 quando o servidor entregou tudo (200/206), quando
# nao ha o que baixar (204) ou quando o .part ja estava completo (416): quem
# chama confere o arquivo antes de usar. Devolve 1 nos outros casos.
# Sem tempo maximo: um arquivo grande numa internet lenta termina. A conexao
# so e largada se ficar 60 segundos abaixo de 1 KB/s.
NC_HTTP=""
download_resumable() {
  local url="$1" part="$2" tries="${3:-5}" i rc
  for ((i = 1; i <= tries; i++)); do
    rc=0
    NC_HTTP="$(curl -sS -f -L -C - --connect-timeout 20 --speed-limit 1024 --speed-time 60 \
      -o "$part" -w '%{http_code}' "$url" 2>/dev/null)" || rc=$?
    NC_HTTP="${NC_HTTP:-000}"
    case "$rc:$NC_HTTP" in
      0:200|0:206|0:204) return 0 ;;
      22:416) return 0 ;;
      # O servidor nao aceita continuar: recomeca do zero.
      33:*) rm -f "$part" ;;
      # 4xx nao melhora tentando de novo. 408 e 429 sim.
      22:408|22:429) ;;
      22:4*) return 1 ;;
    esac
    if [ "$i" -lt "$tries" ]; then
      sleep $((5 * i))
    fi
  done
  return 1
}

# Diferenca, em segundos, entre o relogio deste computador e a hora de um
# servidor (cabecalho Date). -k: so a data e lida, e com o relogio errado o
# certificado nao confere. Escreve o numero sem sinal; nada se nao conseguir.
clock_skew_seconds() {
  local url="$1" header remote now
  header="$(curl -skI --max-time 15 "$url" 2>/dev/null | tr -d '\r' | awk 'tolower($1) == "date:" { $1 = ""; print; exit }')"
  [ -n "$header" ] || return 0
  remote="$(date -u -d "$header" +%s 2>/dev/null)" || return 0
  now="$(date -u +%s)"
  if [ "$now" -ge "$remote" ]; then echo $((now - remote)); else echo $((remote - now)); fi
}
