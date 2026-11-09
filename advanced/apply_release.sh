#!/bin/bash
# COPIA de ncommerce_api/vendor/scripts/apply_release.sh, so para o PASSO 4 do
# instalador_nativo.sh (a maquina ainda nao tem o NCommerce). As atualizacoes
# usam a versao que vem no pacote. Mudou la, copie para ca.
#
# Atualiza uma loja nativa (sem Docker) com o pacote ncommerce/native do
# registry, no lugar do git pull. Publicado por docker/native-package.sh.
#
#   apply_release.sh <~/NCommerce>              baixa e aplica
#   apply_release.sh <~/NCommerce> <pasta>      aplica um pacote ja extraido
#
# O login no registry e "store" + NCOMMERCE_SERVER_TOKEN do .env.production
# (ou NCOMMERCE_TOKEN no ambiente, como no instalador). NCOMMERCE_TAG escolhe
# a versao (padrao latest); voltar de versao e rodar de novo com a tag antiga.
#
# Cada pasta (ncommerce_api, ncommerce, nfce, sefaz-chrome-extension) recebe os
# arquivos do pacote por cima. O que estava na lista da versao anterior e saiu
# da nova e apagado; o resto (.env, certificado, notas, uploads, log) fica.
# Na primeira vez a lista anterior e o git ls-files, e depois o .git e apagado.
#
# Saida 3: nao conseguiu baixar. Nada foi alterado.

set -euo pipefail

NC_ROOT="${1:?uso: apply_release.sh <pasta NCommerce> [pacote extraido]}"
STAGE="${2:-}"
COMPONENTS="ncommerce_api ncommerce nfce sefaz-chrome-extension"
ENV_FILE="$NC_ROOT/ncommerce_api/.env.production"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

say() {
  printf '[%s] %s\n' "$(date +'%d/%m/%Y %H:%M:%S')" "$*"
}

env_value() {
  [ -f "$ENV_FILE" ] || return 0
  sed -n "s/^$1=//p" "$ENV_FILE" | tail -n 1 | tr -d '"'"'"'\r'
}

fetch() {
  local registry token tag manifest layer digest media blob
  registry="${NCOMMERCE_REGISTRY:-$(env_value NCOMMERCE_REGISTRY)}"
  registry="${registry:-registry.ncommerce.app:5050}"
  token="${NCOMMERCE_TOKEN:-$(env_value NCOMMERCE_SERVER_TOKEN)}"
  tag="${NCOMMERCE_TAG:-latest}"
  if [ -z "$token" ]; then
    say "Sem NCOMMERCE_SERVER_TOKEN em $ENV_FILE."
    return 3
  fi

  # O token vai num arquivo de config do curl, nao na linha de comando (ps).
  printf 'user = "store:%s"\n' "$token" > "$TMP/curlrc"
  chmod 600 "$TMP/curlrc"
  # Sem esquema e https. http://host:porta so para testar com um registry local.
  case "$registry" in
    *://*) ;;
    *) registry="https://$registry" ;;
  esac
  local base="$registry/v2/ncommerce/native"
  local accept="application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json"

  say "Baixando a versao $tag de $registry..."
  if ! curl -fsS --retry 3 -K "$TMP/curlrc" -H "Accept: $accept" "$base/manifests/$tag" -o "$TMP/manifest.json"; then
    say "O registry recusou ou nao respondeu."
    return 3
  fi

  # Um index (lista de plataformas) aponta para o manifest de verdade.
  manifest="$(python3 -I - "$TMP/manifest.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
for entry in m.get("manifests") or []:
    platform = entry.get("platform") or {}
    if platform.get("os") in (None, "linux"):
        print(entry["digest"])
        break
PY
)"
  if [ -n "$manifest" ]; then
    curl -fsS --retry 3 -K "$TMP/curlrc" -H "Accept: $accept" "$base/manifests/$manifest" -o "$TMP/manifest.json" || return 3
  fi

  layer="$(python3 -I - "$TMP/manifest.json" <<'PY'
import json, sys
layers = json.load(open(sys.argv[1])).get("layers") or []
if len(layers) == 1:
    print(layers[0]["digest"], layers[0].get("mediaType", ""))
PY
)"
  if [ -z "$layer" ]; then
    say "O manifest nao tem uma camada so. Pacote invalido."
    return 3
  fi
  digest="${layer%% *}"
  media="${layer#* }"

  blob="$TMP/package"
  if ! curl -fsSL --retry 3 -K "$TMP/curlrc" "$base/blobs/$digest" -o "$blob"; then
    say "Nao consegui baixar o pacote."
    return 3
  fi
  if [ "sha256:$(sha256sum "$blob" | cut -d' ' -f1)" != "$digest" ]; then
    say "O pacote baixado nao confere com o digest $digest."
    return 3
  fi

  STAGE="$TMP/stage"
  mkdir -p "$STAGE"
  case "$media" in
    *zstd*) zstd -dc "$blob" | tar -x -C "$STAGE" ;;
    *) tar -xzf "$blob" -C "$STAGE" ;;
  esac
  rm -f "$blob"
}

old_list() {
  local comp="$1" dest="$NC_ROOT/$1"
  if [ -f "$NC_ROOT/.release/$comp.files" ]; then
    cat "$NC_ROOT/.release/$comp.files"
  elif [ -d "$dest/.git" ]; then
    git -C "$dest" ls-files
  fi
}

apply_component() {
  local comp="$1" dest="$NC_ROOT/$1" new="$STAGE/.release/$1.files" f
  mkdir -p "$dest"
  old_list "$comp" | LC_ALL=C sort -u > "$TMP/$comp.old"

  (cd "$STAGE/$comp" && tar -cf - .) | tar -xpf - -C "$dest"

  # Apaga so o que a versao anterior trazia e a nova nao traz.
  LC_ALL=C comm -23 "$TMP/$comp.old" "$new" > "$TMP/$comp.gone"
  while IFS= read -r f; do
    case "$f" in ''|/*|..|../*|*/../*|*/..) continue ;; esac
    rm -f -- "$dest/$f"
    (cd "$dest" && rmdir -p --ignore-fail-on-non-empty -- "$(dirname -- "$f")" 2>/dev/null) || true
  done < "$TMP/$comp.gone"
  say "$comp: $(wc -l < "$new") arquivos, $(wc -l < "$TMP/$comp.gone") removidos."
}

if [ -z "$STAGE" ]; then
  fetch || exit 3
fi

for comp in $COMPONENTS; do
  if [ ! -d "$STAGE/$comp" ] || [ ! -f "$STAGE/.release/$comp.files" ]; then
    say "Pacote incompleto: falta $comp."
    exit 3
  fi
done

say "Aplicando a versao $(cat "$STAGE/.release/VERSION")..."
for comp in $COMPONENTS; do
  apply_component "$comp"
done

mkdir -p "$NC_ROOT/.release"
cp "$STAGE/.release/"* "$NC_ROOT/.release/"
# Sem codigo-fonte nem historico na loja.
for comp in $COMPONENTS; do
  rm -rf "$NC_ROOT/$comp/.git"
done
say "Versao $(cat "$NC_ROOT/.release/VERSION") aplicada."
