#!/bin/bash
# Funcoes da loja Docker no Linux usadas pelo desinstalador_linux.sh e pelo
# manutencao/trocar_tipo_linux.sh: docker compose na pasta da loja, banco
# (esperar, copiar com mysqldump) e copia dos volumes. Quem usa define
# INSTALL_DIR, PROJECT e DOCKER_OK e faz `. lib/instalador.sh` e
# `. lib/desinstalador.sh` (dump_ok) antes deste arquivo.

compose() { (cd "$INSTALL_DIR" && sudo docker compose "$@"); }

has_compose() { [ -f "$INSTALL_DIR/docker-compose.yml" ]; }

docker_volumes() {
  [ "$DOCKER_OK" = "1" ] || return 0
  sudo docker volume ls -q --filter "label=com.docker.compose.project=$PROJECT" 2>/dev/null || true
}

docker_containers() {
  [ "$DOCKER_OK" = "1" ] || return 0
  sudo docker ps -aq --filter "label=com.docker.compose.project=$PROJECT" 2>/dev/null || true
}

mysql_running() {
  [ -n "$(compose ps -q mysql 2>/dev/null)" ]
}

wait_mysql() {
  local i
  for i in $(seq 1 60); do
    if compose exec -T mysql sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SELECT 1"' >/dev/null 2>&1 < /dev/null; then
      return 0
    fi
    sleep 2
  done
  return 1
}

dump_to() {
  local dest="$1"
  compose exec -T mysql sh -c 'rm -f /tmp/ncommerce-dump.sql /tmp/ncommerce-dump.sql.gz
      mysqldump -uroot -p"$MYSQL_ROOT_PASSWORD" --single-transaction --quick --routines --no-tablespaces \
        --result-file=/tmp/ncommerce-dump.sql ncommerce_api_production 2>/dev/null \
      && tail -c 300 /tmp/ncommerce-dump.sql | grep -q "Dump completed" \
      && gzip -f /tmp/ncommerce-dump.sql' < /dev/null || return 1
  compose cp "mysql:/tmp/ncommerce-dump.sql.gz" "$dest" >/dev/null || return 1
  compose exec -T mysql rm -f /tmp/ncommerce-dump.sql.gz < /dev/null || true
  sudo chown "$(id -u):$(id -g)" "$dest" 2>/dev/null || true
  dump_ok "$dest"
}

# Uma imagem que ja esta no computador e tem sh e tar.
helper_image() {
  local image
  for image in docker:27.5.1-cli redis:7-alpine mysql:8.0; do
    if sudo docker image inspect "$image" >/dev/null 2>&1; then
      printf '%s\n' "$image"
      return 0
    fi
  done
  return 1
}

archive_volume() {
  local volume="$1" dest_dir="$2" image name
  name="${volume#"${PROJECT}"_}"
  image="$(helper_image)" || return 1
  sudo docker run --rm --network none -v "$volume:/v:ro" -v "$dest_dir:/b" --entrypoint sh "$image" \
    -c "tar czf /b/$name.tar.gz -C /v ." < /dev/null >/dev/null || return 1
  sudo chown "$(id -u):$(id -g)" "$dest_dir/$name.tar.gz" 2>/dev/null || true
  gzip -t "$dest_dir/$name.tar.gz"
}
