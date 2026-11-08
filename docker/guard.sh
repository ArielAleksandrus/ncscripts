#!/bin/sh
# Guarda das versoes do NCommerce. Roda no servico "guard" do compose (imagem
# docker:cli, com o socket do Docker), igual no Linux e no Windows.
#
# - Guarda cada versao (api + web) que sobe, com a tag keep-<versao>, e mantem
#   as NCOMMERCE_KEEP_VERSIONS (3) mais recentes. A versao em uso nunca sai.
# - Uma versao que respondeu por 5 minutos sem reiniciar fica "boa".
# - Volta sozinho para a ultima versao boa quando a api reinicia 3 vezes em
#   15 minutos, ou nao responde em 10 minutos, numa versao nova (menos de 24 h)
#   ou ja marcada como ruim. Uma versao boa e antiga que reinicia sem parar e
#   problema do computador ou do banco: so avisa, nao volta.
# - Troca de versao pedida pela tela (Configuracoes > Empresa) ou pelo terminal
#   (rollback.sh / rollback.bat), com o arquivo control/request.
# - Avisa o mestre de cada troca. O mestre manda no maximo um WhatsApp por loja por dia.
#
# Arquivos em control/ (a api le em /control):
#   versions.txt   nome|api_id|web_id|visto_em|estado(new/good/bad)|ultima_migration
#   versions.json  o que a tela mostra
#   request        id|nome|origem         (pedido de troca; vazio = versao boa anterior)
#   request.result id|ok ou erro|mensagem
#   events.txt     epoch|tipo|de|para|motivo   (ultimos 20)
#   alert-pending  aviso ainda nao entregue ao mestre
#
# Uso dentro do container (o rollback.sh do host chama estes):
#   guard.sh            laco da guarda
#   guard.sh lista      versoes guardadas
#   guard.sh trocar [versao] [origem]
set -u

D=/ncommerce
C="$D/control"
KEEP="${NCOMMERCE_KEEP_VERSIONS:-3}"
# Os tempos podem mudar por variavel de ambiente (testes).
LOOP_S="${GUARD_LOOP_S:-20}"
HEALTHY_S="${GUARD_HEALTHY_S:-300}"
NEW_WINDOW_S="${GUARD_NEW_WINDOW_S:-86400}"
CRASH_N="${GUARD_CRASH_N:-3}"
CRASH_WINDOW_S="${GUARD_CRASH_WINDOW_S:-900}"
NO_ANSWER_S="${GUARD_NO_ANSWER_S:-600}"
DB="$C/versions.txt"

mkdir -p "$C"
touch "$DB" "$C/events.txt"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*"; }
now() { date +%s; }

env_get() { sed -n "s/^$1=//p" "$2" 2>/dev/null | tail -n 1 | tr -d '\r' | sed "s/^[\"']//; s/[\"']\$//"; }
env_set() {
  if grep -q "^$1=" "$D/.env"; then
    sed -i "s|^$1=.*|$1=$2|" "$D/.env"
  else
    printf '%s=%s\n' "$1" "$2" >> "$D/.env"
  fi
}

# "2026-11-06T15:21:24.809152556Z" -> epoch
to_epoch() { date -u -D '%Y-%m-%dT%H:%M:%S' -d "$(echo "$1" | cut -c1-19)" +%s 2>/dev/null || echo 0; }

# O compose roda daqui de dentro, mas os caminhos relativos do docker-compose.yml
# (./bin/ip, ./host) sao lidos pelo Docker do host. Por isso a pasta e aberta
# no mesmo caminho que o host ve (/opt/ncommerce, ou /run/desktop/mnt/host/c/NCommerce
# no Docker Desktop), com um link para /ncommerce.
setup_compose() {
  SELF="$(hostname)"
  PROJECT="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$SELF" 2>/dev/null)"
  [ -n "$PROJECT" ] || PROJECT=ncommerce
  HOSTDIR="$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/ncommerce"}}{{.Source}}{{end}}{{end}}' "$SELF" 2>/dev/null)"
  case "$HOSTDIR" in
    [A-Za-z]:\\*|[A-Za-z]:/*)
      drive="$(echo "$HOSTDIR" | cut -c1 | tr 'A-Z' 'a-z')"
      HOSTDIR="/run/desktop/mnt/host/$drive$(echo "$HOSTDIR" | cut -c3- | tr '\\' '/')"
      ;;
  esac
  [ -n "$HOSTDIR" ] || HOSTDIR="$D"
  if [ "$HOSTDIR" != "$D" ] && [ ! -e "$HOSTDIR" ]; then
    mkdir -p "$(dirname "$HOSTDIR")"
    ln -s "$D" "$HOSTDIR"
  fi
  REG="$(env_get NCOMMERCE_REGISTRY "$D/.env")"
  REG="${REG:-ncommerce.app:5050}"
}

dc() {
  # A pasta de plugins no .env do Windows e C:/Users/...: aqui vale a que o host montou.
  plug=""
  cid="$(service_cid api)"
  if [ -n "$cid" ]; then
    plug="$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/app/ncommerce_api/app/lib/plugins"}}{{.Source}}{{end}}{{end}}' "$cid" 2>/dev/null)"
  fi
  (
    cd "$HOSTDIR" || exit 1
    [ -n "$plug" ] && export NCOMMERCE_PLUGINS_DIR="$plug"
    docker compose --project-directory "$HOSTDIR" -p "$PROJECT" "$@"
  )
}

service_cid() {
  docker ps -aq --filter "label=com.docker.compose.project=$PROJECT" \
    --filter "label=com.docker.compose.service=$1" | head -n 1
}

image_of() { docker inspect -f '{{.Image}}' "$1" 2>/dev/null; }

# Nome da versao: o rotulo que o release.sh grava, a tag de release, ou a data da imagem.
version_name() {
  v="$(docker image inspect -f '{{index .Config.Labels "ncommerce.version"}}' "$1" 2>/dev/null)"
  case "$v" in ""|"<no value>"|dev)
    v="$(docker image inspect -f '{{range .RepoTags}}{{println .}}{{end}}' "$1" 2>/dev/null \
      | sed -n 's/.*:\([0-9]\{4\}\.[0-9][0-9]\.[0-9][0-9]-[0-9a-f]\{7,\}\(-[0-9a-f]\{7,\}\)\{0,1\}\)$/\1/p' | head -n 1)"
    ;;
  esac
  if [ -z "$v" ]; then
    v="$(docker image inspect -f '{{.Created}}' "$1" 2>/dev/null | cut -c1-16 | sed 's/-/./g; s/T/-/; s/://')"
  fi
  echo "$v" | tr -cd 'A-Za-z0-9_.-'
}

last_migration() {
  docker run --rm --entrypoint sh "$1" -c 'ls /app/ncommerce_api/db/migrate 2>/dev/null | sort | tail -n 1 | cut -c1-14' 2>/dev/null
}

field() { echo "$1" | cut -d'|' -f"$2"; }
line_by_api() { grep "^[^|]*|$1|" "$DB" | head -n 1; }
line_by_name() { grep "^$1|" "$DB" | head -n 1; }

set_state() {
  awk -F'|' -v OFS='|' -v n="$1" -v s="$2" '$1 == n { $5 = s } { print }' "$DB" > "$DB.tmp" && mv "$DB.tmp" "$DB"
}

tag_version() {
  docker tag "$2" "$REG/ncommerce/api:keep-$1" 2>/dev/null
  [ -n "$3" ] && docker tag "$3" "$REG/ncommerce/web:keep-$1" 2>/dev/null
}

register() {
  api_img="$1"
  web_cid="$(service_cid web)"
  web_img=""
  [ -n "$web_cid" ] && web_img="$(image_of "$web_cid")"
  name="$(version_name "$api_img")"
  if [ -n "$(line_by_name "$name")" ]; then
    name="$name-$(echo "$api_img" | sed 's/^sha256://' | cut -c1-7)"
  fi
  mig="$(last_migration "$api_img")"
  printf '%s|%s|%s|%s|new|%s\n' "$name" "$api_img" "$web_img" "$(now)" "$mig" >> "$DB"
  tag_version "$name" "$api_img" "$web_img"
  log "Versao nova em uso: $name"
  prune
}

# O web sobe junto com a api; se a guarda viu a api antes, acerta o web aqui.
refresh_web() {
  web_cid="$(service_cid web)"
  [ -n "$web_cid" ] || return 0
  web_img="$(image_of "$web_cid")"
  line="$(line_by_name "$1")"
  [ "$(field "$line" 5)" = "new" ] || return 0
  [ "$(field "$line" 3)" != "$web_img" ] || return 0
  awk -F'|' -v OFS='|' -v n="$1" -v w="$web_img" '$1 == n { $3 = w } { print }' "$DB" > "$DB.tmp" && mv "$DB.tmp" "$DB"
  docker tag "$web_img" "$REG/ncommerce/web:keep-$1" 2>/dev/null
}

# Mantem KEEP versoes. Saem primeiro as ruins, depois as mais antigas. A em uso fica.
prune() {
  current="${1:-}"
  [ -n "$current" ] || current="$(current_name)"
  while [ "$(wc -l < "$DB")" -gt "$KEEP" ]; do
    victim="$(awk -F'|' -v cur="$current" '$1 != cur { print ($5 == "bad" ? 0 : 1) "|" $4 "|" $1 }' "$DB" \
      | sort -t'|' -k1,1n -k2,2n | head -n 1 | cut -d'|' -f3)"
    [ -n "$victim" ] || break
    docker rmi "$REG/ncommerce/api:keep-$victim" >/dev/null 2>&1
    docker rmi "$REG/ncommerce/web:keep-$victim" >/dev/null 2>&1
    grep -v "^$victim|" "$DB" > "$DB.tmp"; mv "$DB.tmp" "$DB"
    log "Versao $victim apagada (ficam $KEEP)."
  done
}

current_name() {
  cid="$(service_cid api)"
  [ -n "$cid" ] || return 0
  field "$(line_by_api "$(image_of "$cid")")" 1
}

# A versao boa mais recente, mais antiga que a atual. Sem nenhuma, qualquer outra boa.
rollback_target() {
  cur_seen="$(field "$(line_by_name "$1")" 4)"
  t="$(awk -F'|' -v cur="$1" -v s="${cur_seen:-0}" '$1 != cur && $5 == "good" && $4 < s' "$DB" | sort -t'|' -k4,4n | tail -n 1 | cut -d'|' -f1)"
  [ -n "$t" ] || t="$(awk -F'|' -v cur="$1" '$1 != cur && $5 == "good"' "$DB" | sort -t'|' -k4,4n | tail -n 1 | cut -d'|' -f1)"
  echo "$t"
}

event() {
  printf '%s|%s|%s|%s|%s\n' "$(now)" "$1" "$2" "$3" "$4" >> "$C/events.txt"
  tail -n 20 "$C/events.txt" > "$C/events.tmp" && mv "$C/events.tmp" "$C/events.txt"
}

# kind: rollback (troca automatica), switch (pedida), crash_loop (reinicia sem voltar)
alert() {
  printf '%s|%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" "$(now)" > "$C/alert-pending"
  send_alert
}

send_alert() {
  [ -s "$C/alert-pending" ] || return 0
  url="$(env_get NCOMMERCE_SERVER_URL /env/.env.production)"
  token="$(env_get NCOMMERCE_SERVER_TOKEN /env/.env.production)"
  [ -n "$url" ] && [ -n "$token" ] || return 0
  a="$(cat "$C/alert-pending")"
  body="token=$token&kind=$(field "$a" 1)&from=$(field "$a" 2)&to=$(field "$a" 3)&reason=$(field "$a" 4)&at=$(field "$a" 5)"
  if wget -q -T 20 -O /dev/null --post-data "$body" "$url/companies/rollback_alert" 2>/dev/null; then
    rm -f "$C/alert-pending"
  fi
}

# Troca api e web para a versao guardada. O .env fica com a tag dela: um
# reinicio do computador sobe a mesma versao. update.sh volta o .env para latest.
switch_to() {
  to="$1"; kind="$2"; reason="$3"
  from="$(current_name)"
  line="$(line_by_name "$to")"
  if [ -z "$line" ]; then
    echo "Versao $to nao esta guardada."
    return 1
  fi
  if ! docker image inspect "$REG/ncommerce/api:keep-$to" >/dev/null 2>&1; then
    echo "A imagem da versao $to sumiu deste computador."
    return 1
  fi
  if [ -n "$(field "$line" 3)" ] && ! docker image inspect "$REG/ncommerce/web:keep-$to" >/dev/null 2>&1; then
    docker tag "$(field "$line" 3)" "$REG/ncommerce/web:keep-$to" 2>/dev/null
  fi
  log "Trocando de ${from:-?} para $to ($kind, $reason)."
  env_set NCOMMERCE_TAG "keep-$to"
  if ! dc up -d --no-deps api web; then
    echo "O docker compose nao conseguiu subir a versao $to."
    return 1
  fi
  rm -f "$C/restarts.txt" "$C/answered"
  [ "$kind" = "rollback" ] && [ -n "$from" ] && set_state "$from" bad
  event "$kind" "${from:-?}" "$to" "$reason"
  alert "$kind" "${from:-?}" "$to" "$reason"
  echo "Versao $to em uso."
}

process_request() {
  [ -s "$C/request" ] || return 0
  req="$(cat "$C/request")"
  rm -f "$C/request"
  id="$(field "$req" 1)"; to="$(field "$req" 2)"; origin="$(field "$req" 3)"
  case "$origin" in tela|terminal) ;; *) origin=terminal ;; esac
  cur="$(current_name)"
  [ -n "$to" ] || to="$(rollback_target "$cur")"
  if [ -z "$to" ]; then
    printf '%s|erro|%s\n' "$id" "Nao ha versao anterior boa guardada." > "$C/request.result"
    return 0
  fi
  if [ "$to" = "$cur" ]; then
    printf '%s|erro|%s\n' "$id" "A versao $to ja esta em uso." > "$C/request.result"
    return 0
  fi
  if msg="$(switch_to "$to" switch "$origin" 2>&1)"; then
    printf '%s|ok|%s\n' "$id" "$(echo "$msg" | tail -n 1)" > "$C/request.result"
  else
    printf '%s|erro|%s\n' "$id" "$(echo "$msg" | tail -n 1)" > "$C/request.result"
  fi
}

# Qualquer resposta HTTP abaixo de 500 serve: de fora do localhost a api responde 403.
api_answers() {
  wget -S -T 10 -O /dev/null http://api:3000/ 2>&1 | grep -q '^ *HTTP/[0-9.]* [1-4][0-9][0-9]'
}

# Reinicios da api nos ultimos 15 minutos, pelo RestartCount do container.
restarts_in_window() {
  cid="$1"; count="$2"; t="$(now)"
  touch "$C/restarts.txt"
  awk -v c="$cid" -v min=$((t - CRASH_WINDOW_S)) '$2 == c && $1 >= min' "$C/restarts.txt" > "$C/restarts.tmp"
  echo "$t $cid $count" >> "$C/restarts.tmp"
  mv "$C/restarts.tmp" "$C/restarts.txt"
  first="$(head -n 1 "$C/restarts.txt" | cut -d' ' -f3)"
  echo $((count - first))
}

crash_alerted_today() {
  [ "$(cat "$C/crash-alert-day" 2>/dev/null)" = "$(date +%Y-%m-%d)" ]
}

tick() {
  process_request
  send_alert
  cid="$(service_cid api)"
  [ -n "$cid" ] || return 0
  img="$(image_of "$cid")"
  [ -n "$img" ] || return 0
  line="$(line_by_api "$img")"
  if [ -z "$line" ]; then
    register "$img"
    line="$(line_by_api "$img")"
  fi
  name="$(field "$line" 1)"; seen="$(field "$line" 4)"; state="$(field "$line" 5)"
  refresh_web "$name"

  t="$(now)"
  restart_count="$(docker inspect -f '{{.RestartCount}}' "$cid" 2>/dev/null || echo 0)"
  started="$(to_epoch "$(docker inspect -f '{{.State.StartedAt}}' "$cid")")"
  created="$(to_epoch "$(docker inspect -f '{{.Created}}' "$cid")")"
  running="$(docker inspect -f '{{.State.Running}}' "$cid")"
  crashes="$(restarts_in_window "$cid" "$restart_count")"

  answers=0
  if [ "$running" = "true" ] && api_answers; then
    answers=1
    echo "$cid" > "$C/answered"
  fi

  if [ "$state" = "new" ] && [ "$answers" = 1 ] && [ $((t - started)) -ge "$HEALTHY_S" ] && [ "$crashes" -eq 0 ]; then
    set_state "$name" good
    state=good
    log "Versao $name boa: respondeu por $((HEALTHY_S / 60)) minutos sem reiniciar."
  fi

  reason=""
  if [ "$crashes" -ge "$CRASH_N" ]; then
    reason=reinicios
  elif [ "$state" != "good" ] && [ "$(cat "$C/answered" 2>/dev/null)" != "$cid" ] && [ $((t - created)) -ge "$NO_ANSWER_S" ]; then
    reason=sem_resposta
  fi
  [ -n "$reason" ] || return 0

  if [ "$state" != "good" ] || [ $((t - seen)) -lt "$NEW_WINDOW_S" ]; then
    to="$(rollback_target "$name")"
    if [ -n "$to" ]; then
      switch_to "$to" rollback "$reason"
      return 0
    fi
  fi
  if ! crash_alerted_today; then
    date +%Y-%m-%d > "$C/crash-alert-day"
    log "A versao $name esta com problema ($reason) e nao ha para onde voltar sozinho."
    event crash_loop "$name" "" "$reason"
    alert crash_loop "$name" "" "$reason"
  fi
}

json_str() { printf '"%s"' "$(echo "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"; }

write_json() {
  cur="$(current_name)"
  {
    printf '{"updated_at":%s,"keep":%s,"current":%s,"versions":[' "$(now)" "$KEEP" "$(json_str "$cur")"
    sep=""
    sort -t'|' -k4,4nr "$DB" | while IFS='|' read -r n a w s st m; do
      printf '%s{"name":%s,"seen_at":%s,"state":%s,"migration":%s,"current":%s}' "$sep" \
        "$(json_str "$n")" "${s:-0}" "$(json_str "$st")" "$(json_str "$m")" "$([ "$n" = "$cur" ] && echo true || echo false)"
      sep=","
    done
    printf '],"events":['
    sep=""
    tail -n 10 "$C/events.txt" | while IFS='|' read -r at k f to r; do
      printf '%s{"at":%s,"kind":%s,"from":%s,"to":%s,"reason":%s}' "$sep" "${at:-0}" \
        "$(json_str "$k")" "$(json_str "$f")" "$(json_str "$to")" "$(json_str "$r")"
      sep=","
    done
    printf '],"result":%s}\n' "$(json_str "$(cat "$C/request.result" 2>/dev/null)")"
  } > "$C/versions.json.tmp" && mv "$C/versions.json.tmp" "$C/versions.json"
}

cmd_list() {
  cur="$(current_name)"
  echo "Versoes guardadas (mais nova primeiro):"
  sort -t'|' -k4,4nr "$DB" | while IFS='|' read -r n a w s st m; do
    mark=" "; [ "$n" = "$cur" ] && mark="*"
    case "$st" in good) st="boa" ;; new) st="em teste" ;; bad) st="ruim" ;; esac
    printf ' %s %-28s %-9s desde %s\n' "$mark" "$n" "$st" "$(date -d "@$s" '+%d/%m %H:%M')"
  done
  echo "(* em uso)"
}

# Pede a troca ao laco da guarda e espera o resultado.
cmd_switch() {
  id="$(now)-$$"
  printf '%s|%s|%s\n' "$id" "${1:-}" "${2:-terminal}" > "$C/request"
  i=0
  while [ $i -lt 90 ]; do
    if [ -f "$C/request.result" ] && [ "$(cut -d'|' -f1 "$C/request.result")" = "$id" ]; then
      res="$(cat "$C/request.result")"
      echo "$(field "$res" 3)"
      [ "$(field "$res" 2)" = "ok" ]
      return
    fi
    sleep 2
    i=$((i + 1))
  done
  echo "A guarda nao respondeu em 3 minutos. Veja: docker compose logs guard"
  return 1
}

setup_compose

case "${1:-}" in
  lista|list) cmd_list; exit 0 ;;
  trocar|rollback) cmd_switch "${2:-}" "${3:-terminal}"; exit $? ;;
  "") ;;
  *) echo "Uso: guard.sh [lista | trocar [versao]]"; exit 2 ;;
esac

log "Guarda do NCommerce: projeto $PROJECT em $HOSTDIR, mantendo $KEEP versoes."
while true; do
  tick
  write_json
  sleep "$LOOP_S"
done
