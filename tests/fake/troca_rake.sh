#!/bin/sh
# rake de mentira da API da loja: as tarefas store:commerce_type:* da troca de
# tipo (manutencao/trocar_tipo_*), com o mesmo contrato de saida e codigos.
# Loja em /fake/state/loja: tipo, bloqueios (uma linha por caixa/comanda aberta),
# banco (ok | meio), mestre (tipo avisado). Knobs: rake_antiga, prepare_fail,
# reset_fail (quantas vezes falha no meio), master_fail, master_dry_fail.
# TROCA_MAP="/troca=/pasta/no/host" traduz o caminho montado no container.
L=/fake/state/loja
K=/fake/knobs
mkdir -p "$L"
echo "rake $*" >> /fake/calls.log
task="$1"; shift
TO=""; KEEP_FILE=""; CONFIRM=""; ENV_FILE=""; DRY_RUN=""; CHANGED_BY=""
for a in "$@"; do
  case "$a" in
    TO=*) TO="${a#TO=}" ;;
    KEEP_FILE=*) KEEP_FILE="${a#KEEP_FILE=}" ;;
    CONFIRM=*) CONFIRM="${a#CONFIRM=}" ;;
    ENV_FILE=*) ENV_FILE="${a#ENV_FILE=}" ;;
    DRY_RUN=*) DRY_RUN="${a#DRY_RUN=}" ;;
    CHANGED_BY=*) CHANGED_BY="${a#CHANGED_BY=}" ;;
  esac
done
if [ -n "${TROCA_MAP:-}" ] && [ -n "$KEEP_FILE" ]; then
  KEEP_FILE="${TROCA_MAP#*=}${KEEP_FILE#"${TROCA_MAP%%=*}"}"
fi
take() {
  n="$(cat "$K/$1" 2>/dev/null)"
  case "$n" in ""|*[!0-9]*|0) return 1 ;; esac
  echo $((n - 1)) > "$K/$1"
}
if [ -e "$K/rake_antiga" ]; then
  echo "rake aborted!"; echo "Don't know how to build task '$task'"; exit 1
fi
tipo="$(cat "$L/tipo" 2>/dev/null || echo restaurant)"
check() {
  case "$TO" in restaurant|general|industry) ;; *) echo "Tipo invalido: $TO"; exit 2 ;; esac
  [ "$TO" != "$tipo" ] || { echo "A loja ja e do tipo $TO."; exit 4; }
  echo "Tipo atual: $tipo -> novo: $TO"
  echo "Fica: Minha Empresa (CNPJ 11.222.333/4445-66); administradores: admin, dono; proxima NFC-e: 1235"
  echo "Sai: 12 produtos, 30 comandas, 4 caixas, 7 clientes, 3 usuarios"
  if [ -s "$L/bloqueios" ]; then
    echo "Nao da para trocar o tipo agora:"
    sed 's/^/  - /' "$L/bloqueios"
    exit 3
  fi
}
case "$task" in
  store:commerce_type:check) check ;;
  store:commerce_type:prepare)
    check
    [ -n "$KEEP_FILE" ] || exit 2
    [ ! -e "$KEEP_FILE" ] || { echo "KEEP_FILE ja existe"; exit 5; }
    [ ! -e "$K/prepare_fail" ] || { echo "erro no prepare"; exit 1; }
    printf '{"change_id":"c-123","from":"%s","to":"%s","changed_by":"%s"}\n' "$tipo" "$TO" "$CHANGED_BY" > "$KEEP_FILE.tmp"
    mv "$KEEP_FILE.tmp" "$KEEP_FILE"
    echo "nota" > "$(dirname "$KEEP_FILE")/notas-fiscais.csv"
    echo "PREPARE_OK c-123"
    ;;
  store:commerce_type:reset)
    [ "$CONFIRM" = "APAGAR_TUDO" ] || exit 2
    [ -s "$KEEP_FILE" ] || { echo "sem KEEP_FILE"; exit 5; }
    to="$(sed -n 's/.*"to":"\([a-z]*\)".*/\1/p' "$KEEP_FILE")"
    echo meio > "$L/banco"
    echo "reset" >> "$L/resets"
    if take reset_fail; then echo "Lost connection to MySQL"; exit 1; fi
    echo "$to" > "$L/tipo"
    echo ok > "$L/banco"
    if [ -n "$ENV_FILE" ] && [ -f "$ENV_FILE" ]; then
      { grep -v '^NCOMMERCE_COMMERCE_TYPE=' "$ENV_FILE"; echo "NCOMMERCE_COMMERCE_TYPE=$to"; } > "$ENV_FILE.tmp"
      mv "$ENV_FILE.tmp" "$ENV_FILE"
    fi
    echo "Reposto: empresa, 2 administradores, numeracao da NFC-e (proxima 1235)"
    echo "RESET_OK"
    ;;
  store:commerce_type:notify_master)
    if [ "$DRY_RUN" = "1" ]; then
      [ ! -e "$K/master_dry_fail" ] || { echo "Sem resposta do mestre."; exit 6; }
      echo "MASTER_OK"; exit 0
    fi
    if take master_fail; then echo "Sem resposta do mestre."; exit 6; fi
    [ -s "$KEEP_FILE" ] || exit 5
    sed -n 's/.*"to":"\([a-z]*\)".*/\1/p' "$KEEP_FILE" > "$L/mestre"
    echo "MASTER_OK"
    ;;
  *) echo "Don't know how to build task '$task'"; exit 1 ;;
esac
