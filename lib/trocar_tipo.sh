#!/bin/bash
# Roteiro comum da troca do tipo da loja no Linux (manutencao/trocar_tipo_linux.sh,
# Docker, e manutencao/trocar_tipo_nativo.sh, sem Docker). Quem usa faz
# `. lib/instalador.sh`, `. lib/desinstalador.sh` e este arquivo, define as
# variaveis abaixo e as funcoes de cada sistema, e chama tt_main.
#
# Variaveis: TT_DIR (estado e trava), TT_SCRIPT (nome para as mensagens),
# TT_BACKUP_BASE, TT_TIPO_PEDIDO, UN_SIMULAR, LOG_DIR.
# Funcoes de cada sistema:
#   tt_preparar              confere o que precisa (Docker ligado, pasta da loja...)
#   tt_rake ARGS...          roda `rake ARGS` da API da loja (TT_KEEP_IN: o manter.json visto por ela)
#   tt_mysql_root ARGS...    o cliente mysql como root (stdin repassado)
#   tt_banco_pronto          espera o banco responder
#   tt_dump DESTINO.sql.gz   copia o banco (conferida: dump_ok)
#   tt_copiar_resto PASTA    o resto da copia (configuracao, volumes)
#   tt_parar_loja / tt_ligar_loja
#   tt_depois_do_reset       ajustes do sistema depois do reset (opcional)
#   tt_env_file_dentro       o ENV_FILE do ponto de vista do rake
#
# Etapas (estado em $TT_DIR/troca.estado; rodar de novo continua):
#   backup   copia do banco + configuracao, conferida num banco temporario
#   prepare  o rake guarda o que fica (manter.json na pasta da copia)
#   reset    o rake apaga e recria o banco do tipo novo e repoe o que fica
#   mestre   avisa o mestre (se falhar, a troca vale; rodar de novo tenta outra vez)
#   ligar    liga a loja

TT_CONFIRM_WORD="APAGAR TUDO"
TT_DB="ncommerce_api_production"
TT_DB_CONF="ncommerce_troca_conferencia"
TT_KEEP_NAME="manter.json"
TT_TIPO=""
TT_BACKUP_DIR=""
TT_LOJA_PARADA=0
NC_VERDICT=""
NC_FAIL_MSG=""
NC_SIGNAL=""

# O manter.json do ponto de vista do rake (Docker: a pasta da copia montada em /troca).
tt_keep_in() { printf '%s\n' "${TT_KEEP_IN:-$TT_BACKUP_DIR/$TT_KEEP_NAME}"; }

tt_label() {
  case "$1" in
    restaurant) echo "Restaurante" ;;
    general) echo "Comercio em geral" ;;
    industry) echo "Industria" ;;
    *) echo "$1" ;;
  esac
}

# restaurante|restaurant|1 -> restaurant (vazio se nao reconhece).
tt_normalizar_tipo() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -d ' ')" in
    1|restaurante|restaurant) echo restaurant ;;
    2|comercio|comercioemgeral|general|geral) echo general ;;
    3|industria|industry) echo industry ;;
    *) echo "" ;;
  esac
}

tt_fail() {
  NC_FAIL_MSG="$1"
  exit 1
}

tt_on_exit() {
  local rc=$?
  trap - EXIT ERR INT TERM HUP
  set +e
  if [ "$NC_VERDICT" != "ok" ] && [ "$UN_SIMULAR" = "1" ] && [ -n "$NC_FAIL_MSG" ]; then
    echo
    echo "SIMULACAO interrompida: $NC_FAIL_MSG"
  fi
  if [ "$NC_VERDICT" != "ok" ] && [ "$UN_SIMULAR" != "1" ]; then
    [ "$rc" -ne 0 ] || rc=1
    echo
    echo "=================================================================="
    if [ -n "$NC_SIGNAL" ]; then
      echo "  A TROCA DE TIPO FOI INTERROMPIDA (janela fechada ou Ctrl+C)."
    else
      echo "  A TROCA DE TIPO NAO TERMINOU."
    fi
    echo "=================================================================="
    [ -z "$NC_FAIL_MSG" ] || echo "O que aconteceu: $NC_FAIL_MSG"
    if [ -n "$(state_get reset_iniciado)" ] && ! state_is_done reset; then
      echo "O banco da loja ja comecou a ser apagado e ainda nao esta pronto: a loja fica"
      echo "desligada ate a troca terminar. Rode $TT_SCRIPT de novo: ela continua daqui."
      echo "(Para voltar como estava, chame o suporte NCommerce com a copia abaixo.)"
    elif ! state_is_done reset; then
      tt_ligar_se_parada
      echo "Nada foi apagado. Rode $TT_SCRIPT de novo quando quiser: continua de onde parou."
    else
      echo "Rode $TT_SCRIPT de novo: continua de onde parou."
    fi
    [ -z "$TT_BACKUP_DIR" ] || ! state_is_done backup || echo "Copia de seguranca conferida: $TT_BACKUP_DIR"
    [ -z "${NC_LOG_FILE:-}" ] || echo "Log: $NC_LOG_FILE"
  fi
  lock_release
  log_stop
  exit "$rc"
}

# Liga a loja de novo quando esta execucao (ou uma anterior) a desligou e o banco nao foi tocado.
tt_ligar_se_parada() {
  if [ "$TT_LOJA_PARADA" = "1" ] || [ -n "$(state_get loja_parada)" ]; then
    echo "Religando a loja como estava..."
    if tt_ligar_loja; then
      state_unset loja_parada 2>/dev/null || true
      TT_LOJA_PARADA=0
    else
      echo "Nao consegui religar a loja. Reinicie o computador: ela liga sozinha."
    fi
  fi
}

tt_parar_loja_marcando() {
  [ -z "$(state_get loja_parada)" ] || return 0
  echo "Desligando a loja (nenhuma venda entra depois da copia)..."
  state_set loja_parada 1
  TT_LOJA_PARADA=1
  tt_parar_loja || tt_fail "nao consegui desligar a loja para a copia."
}

tt_aviso() {
  cat <<'EOF'

ATENCAO: trocar o tipo APAGA TODO O BANCO DE DADOS da loja e comeca de novo,
como uma instalacao nova do tipo escolhido.

Sera APAGADO: todos os produtos e categorias, comandas, pedidos, vendas,
caixas, clientes, fornecedores, estoque, reservas, cardapios, usuarios que
nao sao administradores e todas as opcoes e configuracoes da loja (taxas,
formas de pagamento, qual impressora imprime o que...).

FICA:
  - os dados da empresa (nome, razao social, CNPJ, endereco, contatos, logo),
    ja com o tipo novo, e os responsaveis;
  - os ADMINISTRADORES, com o mesmo login e a MESMA SENHA;
  - a configuracao da NFC-e (CSC, serie, ambiente, certificado) e a NUMERACAO:
    a proxima nota continua de onde parou (numero repetido a SEFAZ recusa);
  - as notas fiscais (XML) guardadas no computador (guarda de 5 anos);
  - a conexao com o NCommerce (mestre), o tunel, o iFood conectado e as
    impressoras instaladas.

Antes de apagar e feita uma COPIA DE SEGURANCA do banco, fora da instalacao,
conferida (restaurada num banco temporario e comparada tabela por tabela).
Se a copia falhar, nada e apagado. Precisa: nenhum caixa aberto e nenhuma
comanda aberta (feche antes).
EOF
}

tt_pedir_tipo() {
  local answer="" tipo
  if [ -n "$TT_TIPO_PEDIDO" ]; then
    tipo="$(tt_normalizar_tipo "$TT_TIPO_PEDIDO")"
    [ -n "$tipo" ] || { echo "Tipo desconhecido: $TT_TIPO_PEDIDO (use restaurante, comercio ou industria)."; exit 2; }
    TT_TIPO="$tipo"
    return 0
  fi
  echo
  echo "Para qual tipo a loja vai passar?"
  echo "  1) Restaurante"
  echo "  2) Comercio em geral"
  echo "  3) Industria"
  read -r -p "Digite 1, 2 ou 3 e tecle Enter: " answer || answer=""
  tipo="$(tt_normalizar_tipo "$answer")"
  if [ -z "$tipo" ]; then
    echo "Resposta nao reconhecida. Nada foi mudado."
    NC_VERDICT="ok"
    exit 1
  fi
  TT_TIPO="$tipo"
}

# Roda o rake e mostra a saida. Devolve o codigo dele. Uma API antiga (sem as
# tarefas) vira uma mensagem para atualizar antes.
TT_RAKE_OUT=""
tt_rake_show() {
  local rc=0
  TT_RAKE_OUT="$(mktemp)"
  tt_rake "$@" > "$TT_RAKE_OUT" 2>&1 || rc=$?
  grep -v '^\(PREPARE_OK\|RESET_OK\|MASTER_OK\)' "$TT_RAKE_OUT" | sed 's/^/  /' || true
  if [ "$rc" -ne 0 ] && grep -q "Don't know how to build task" "$TT_RAKE_OUT"; then
    rm -f "$TT_RAKE_OUT"
    tt_fail "esta versao do NCommerce ainda nao tem a troca de tipo. Atualize o NCommerce (atalho Atualizar NCommerce) e rode de novo. Nada foi apagado."
  fi
  rm -f "$TT_RAKE_OUT"
  return "$rc"
}

tt_conferir_loja() {
  local rc=0
  echo
  echo "Conferindo a loja (caixas e comandas abertos, o que fica e o que sai)..."
  tt_rake_show store:commerce_type:check "TO=$TT_TIPO" || rc=$?
  case "$rc" in
    0) ;;
    3)
      NC_VERDICT="ok"
      echo
      echo "Feche os caixas e as comandas acima (e espere as notas serem transmitidas) e rode de novo."
      echo "Nada foi mudado."
      tt_ligar_se_parada
      tt_encerrar_estado_sem_reset
      exit 3
      ;;
    4)
      NC_VERDICT="ok"
      echo
      echo "A loja ja e do tipo $(tt_label "$TT_TIPO"). Nada foi mudado."
      tt_ligar_se_parada
      tt_encerrar_estado_sem_reset
      exit 4
      ;;
    *) tt_fail "nao consegui conferir a loja (codigo $rc). Nada foi apagado." ;;
  esac
}

tt_conferir_mestre() {
  echo
  echo "Conferindo a conexao com o NCommerce (mestre)..."
  if ! tt_rake_show store:commerce_type:notify_master "TO=$TT_TIPO" DRY_RUN=1; then
    tt_fail "o NCommerce (mestre) nao respondeu ou recusou. A troca precisa avisar o mestre: confira a internet e rode de novo. Nada foi apagado."
  fi
}

# Cancelado/recusado antes do reset: o estado some (a copia, se feita, fica).
tt_encerrar_estado_sem_reset() {
  [ "$UN_SIMULAR" != "1" ] || return 0
  if [ -z "$(state_get reset_iniciado)" ]; then
    lock_release
    rm -f "$TT_DIR/troca.estado"
  fi
}

tt_confirmar() {
  local answer=""
  echo
  echo "Para APAGAR TODO O BANCO e trocar a loja para $(tt_label "$TT_TIPO"),"
  echo "digite $TT_CONFIRM_WORD (em maiusculas) e tecle Enter."
  echo "Qualquer outra resposta cancela sem mudar nada."
  read -r -p "> " answer || answer=""
  [ "$answer" = "$TT_CONFIRM_WORD" ]
}

tt_plano() {
  echo
  echo "O que sera feito:"
  echo "  1. desligar a loja (api, web e guarda; o banco fica ligado)"
  echo "  2. copia de seguranca em $(abs_path "$TT_BACKUP_BASE")/ncommerce-backup-troca-tipo-<data>:"
  echo "     banco (mysqldump) conferido num banco temporario ($TT_DB_CONF) e a configuracao"
  echo "  3. guardar o que fica (dados da empresa, administradores, NFC-e) em $TT_KEEP_NAME, na copia"
  echo "  4. APAGAR e recriar o banco $TT_DB como uma loja nova do tipo $(tt_label "$TT_TIPO")"
  echo "     e repor o que fica"
  echo "  5. avisar o NCommerce (mestre) da troca"
  echo "  6. ligar a loja"
}

# Conta as linhas de cada tabela de um banco: "tabela<TAB>linhas", em ordem.
tt_contar_tabelas() {
  local db="$1" sql
  sql="$(tt_mysql_root -N -e "SET SESSION group_concat_max_len = 4194304; SELECT GROUP_CONCAT(CONCAT('SELECT ''', table_name, ''', COUNT(*) FROM \`', table_schema, '\`.\`', table_name, '\`') ORDER BY table_name SEPARATOR ' UNION ALL ') FROM information_schema.tables WHERE table_schema = '$db' AND table_type = 'BASE TABLE'" < /dev/null)" || return 1
  [ -n "$sql" ] && [ "$sql" != "NULL" ] || return 1
  printf '%s;\n' "$sql" | tt_mysql_root -N
}

# Restaura a copia num banco temporario e compara tabela por tabela com o banco da loja.
tt_conferir_copia() {
  local dump="$1" dir="$2" rc=0
  echo "  - conferindo a copia: restaurando num banco temporario ($TT_DB_CONF)"
  tt_mysql_root -e "DROP DATABASE IF EXISTS \`$TT_DB_CONF\`; CREATE DATABASE \`$TT_DB_CONF\`" < /dev/null || return 1
  if ! gzip -dc "$dump" | tt_mysql_root "$TT_DB_CONF"; then
    rc=1
  fi
  if [ "$rc" = "0" ]; then
    tt_contar_tabelas "$TT_DB" > "$dir/conferencia-banco-da-loja.txt" || rc=1
    tt_contar_tabelas "$TT_DB_CONF" > "$dir/conferencia-copia-restaurada.txt" || rc=1
  fi
  tt_mysql_root -e "DROP DATABASE IF EXISTS \`$TT_DB_CONF\`" < /dev/null || true
  [ "$rc" = "0" ] || return 1
  if [ ! -s "$dir/conferencia-banco-da-loja.txt" ]; then
    echo "    a contagem do banco da loja veio vazia"
    return 1
  fi
  if ! cmp -s "$dir/conferencia-banco-da-loja.txt" "$dir/conferencia-copia-restaurada.txt"; then
    echo "    a copia restaurada nao bate com o banco da loja:"
    diff "$dir/conferencia-banco-da-loja.txt" "$dir/conferencia-copia-restaurada.txt" | head -n 10 | sed 's/^/      /'
    return 1
  fi
  echo "  - copia conferida: $(wc -l < "$dir/conferencia-banco-da-loja.txt" | tr -d ' ') tabelas, linhas iguais em todas"
}

tt_backup() {
  local saved dump
  saved="$(state_get backup_dir)"
  if state_is_done backup && [ -n "$saved" ] && [ -f "$saved/banco-$TT_DB.sql.gz" ] && [ ! -e "$saved/INCOMPLETO" ]; then
    TT_BACKUP_DIR="$saved"
    echo "A copia ja foi feita e conferida numa execucao anterior: $saved"
    return 0
  fi
  # Uma copia cortada por uma execucao anterior nao serve: comeca de novo.
  if [ -n "$saved" ] && [ -e "$saved/INCOMPLETO" ]; then
    rm -rf -- "$saved"
    state_unset backup_dir
  fi
  tt_parar_loja_marcando
  TT_BACKUP_DIR="$(abs_path "$TT_BACKUP_BASE")/ncommerce-backup-troca-tipo-$(date '+%Y%m%d-%H%M%S')"
  mkdir -p "$TT_BACKUP_DIR" || tt_fail "nao consegui criar a pasta da copia em $TT_BACKUP_BASE. Nada foi apagado."
  chmod 700 "$TT_BACKUP_DIR" 2>/dev/null || true
  : > "$TT_BACKUP_DIR/INCOMPLETO"
  state_set backup_dir "$TT_BACKUP_DIR"
  echo "Guardando a copia da loja em $TT_BACKUP_DIR ..."
  tt_banco_pronto || tt_fail "o banco de dados nao respondeu para a copia. Nada foi apagado."
  echo "  - banco de dados (pode levar alguns minutos)"
  dump="$TT_BACKUP_DIR/banco-$TT_DB.sql.gz"
  tt_dump "$dump" || tt_fail "a copia do banco de dados nao ficou completa. Nada foi apagado."
  tt_conferir_copia "$dump" "$TT_BACKUP_DIR" \
    || tt_fail "a copia do banco nao passou na conferencia (restaurada num banco temporario). Nada foi apagado."
  tt_copiar_resto "$TT_BACKUP_DIR" || tt_fail "nao consegui copiar a configuracao da loja. Nada foi apagado."
  chmod -R go-rwx "$TT_BACKUP_DIR" 2>/dev/null || true
  cat > "$TT_BACKUP_DIR/LEIA-ME.txt" <<EOF
Copia do NCommerce feita pela troca de tipo da loja em $(date '+%d/%m/%Y %H:%M'),
antes de apagar o banco (tipo novo: $(tt_label "$TT_TIPO")).

banco-$TT_DB.sql.gz   banco de dados da loja (mysqldump), conferido: restaurado num banco
                                         temporario, mesmas tabelas e mesmo numero de linhas
conferencia-*.txt                        a contagem de linhas de cada tabela (loja e copia)
$TT_KEEP_NAME                              o que a troca repoe (empresa, administradores, NFC-e)
notas-fiscais.csv                        a lista das notas fiscais que estavam no banco
o resto                                  a configuracao da loja (.env e o que mais houver)

Tem senhas: guarde em lugar seguro, fora de pastas sincronizadas (OneDrive, Google Drive).
Para voltar a loja como estava, chame o suporte NCommerce com esta pasta.
EOF
  rm -f "$TT_BACKUP_DIR/INCOMPLETO"
  state_done backup
  echo "Copia completa e conferida: $TT_BACKUP_DIR"
}

tt_prepare() {
  local rc=0
  if state_is_done prepare; then
    echo "O que fica ja foi guardado numa execucao anterior."
    return 0
  fi
  # Gravado de uma vez (arquivo temporario + rename): se existe, esta completo.
  if [ -s "$TT_BACKUP_DIR/$TT_KEEP_NAME" ]; then
    state_done prepare
    echo "O que fica ja foi guardado: $TT_BACKUP_DIR/$TT_KEEP_NAME"
    return 0
  fi
  tt_rake_show store:commerce_type:prepare "TO=$TT_TIPO" "KEEP_FILE=$(tt_keep_in)" "CHANGED_BY=$TT_CHANGED_BY" || rc=$?
  case "$rc" in
    0) ;;
    3|4)
      NC_VERDICT="ok"
      echo
      echo "A troca foi recusada (acima). Nada foi apagado; a copia ficou em $TT_BACKUP_DIR."
      tt_ligar_se_parada
      tt_encerrar_estado_sem_reset
      exit "$rc"
      ;;
    *) tt_fail "nao consegui guardar o que fica (codigo $rc). Nada foi apagado." ;;
  esac
  [ -s "$TT_BACKUP_DIR/$TT_KEEP_NAME" ] || tt_fail "o arquivo $TT_KEEP_NAME nao apareceu na copia. Nada foi apagado."
  chmod 600 "$TT_BACKUP_DIR/$TT_KEEP_NAME" 2>/dev/null || true
  state_done prepare
}

tt_reset() {
  local rc=0
  if state_is_done reset; then
    echo "O banco ja foi recriado como $(tt_label "$TT_TIPO") numa execucao anterior."
    return 0
  fi
  if [ -n "$(state_get reset_iniciado)" ]; then
    echo "Uma execucao anterior parou no meio do reset. Recomecando o reset a partir do que foi guardado."
  fi
  state_set reset_iniciado "$(date +%s)"
  echo "Apagando e recriando o banco (pode levar alguns minutos)..."
  TT_RESET_LOG="$TT_BACKUP_DIR/reset.txt"
  tt_rake store:commerce_type:reset "KEEP_FILE=$(tt_keep_in)" CONFIRM=APAGAR_TUDO "ENV_FILE=$(tt_env_file_dentro)" \
    > "$TT_RESET_LOG" 2>&1 || rc=$?
  grep -v '^RESET_OK' "$TT_RESET_LOG" | sed 's/^/  /' || true
  if [ "$rc" -ne 0 ] || ! grep -q '^RESET_OK' "$TT_RESET_LOG"; then
    tt_fail "o reset do banco nao terminou (codigo $rc)."
  fi
  if declare -F tt_depois_do_reset >/dev/null; then
    tt_depois_do_reset || warn "o ajuste do sistema depois do reset falhou (veja acima)."
  fi
  state_done reset
}

tt_avisar_mestre() {
  if state_is_done mestre; then
    return 0
  fi
  echo "Avisando o NCommerce (mestre) da troca..."
  local i
  for i in 1 2 3; do
    if tt_rake_show store:commerce_type:notify_master "KEEP_FILE=$(tt_keep_in)"; then
      state_done mestre
      return 0
    fi
    [ "$i" = 3 ] || sleep "${TT_RETRY_WAIT_S:-5}"
  done
  TT_MESTRE_PENDENTE=1
  warn "o NCommerce (mestre) nao foi avisado. A troca na loja valeu; rode $TT_SCRIPT de novo com internet para avisar."
}

tt_ligar() {
  if state_is_done ligar; then return 0; fi
  echo "Ligando a loja..."
  tt_ligar_loja || tt_fail "nao consegui ligar a loja. Reinicie o computador (ela liga sozinha) ou rode $TT_SCRIPT de novo."
  state_unset loja_parada
  TT_LOJA_PARADA=0
  state_done ligar
}

tt_mensagem_final() {
  echo
  echo "=================================================================="
  echo "  TIPO DA LOJA TROCADO: agora e $(tt_label "$TT_TIPO")."
  echo "=================================================================="
  echo "Copia de seguranca (banco conferido e configuracao): $TT_BACKUP_DIR"
  echo "  Tem senhas: guarde em lugar seguro, fora de pastas sincronizadas."
  echo
  echo "Os administradores entram com o MESMO login e a MESMA senha de antes."
  echo "A NFC-e continua com a mesma configuracao e a numeracao continua de onde parou."
  echo "As notas (XML) continuam no computador; a lista delas esta em notas-fiscais.csv na copia."
  echo
  echo "Configure de novo, como numa instalacao nova:"
  echo "  - produtos, categorias e cardapios;"
  echo "  - usuarios (caixas, vendedores$( [ "$TT_TIPO" = restaurant ] && echo ', garcons, cozinha')) e as permissoes;"
  echo "  - impressoras: qual imprime o que (Configuracoes > Impressoras);"
  echo "  - taxas, formas de pagamento, entrega e as opcoes da loja (Configuracoes);"
  echo "  - clientes e fornecedores (se quiser, o suporte importa da copia)."
  echo "Nao ha usuarios de exemplo: ficam so os administradores (e o usuario interno do iFood)."
  if [ "${TT_MESTRE_PENDENTE:-0}" = "1" ]; then
    echo
    echo "FALTA avisar o NCommerce (mestre): rode $TT_SCRIPT de novo com internet."
  fi
  if [ "${#NC_WARNINGS[@]}" -gt 0 ]; then
    echo
    echo "Avisos:"
    printf '  - %s\n' "${NC_WARNINGS[@]}"
  fi
  [ -z "${NC_LOG_FILE:-}" ] || echo "Log: $NC_LOG_FILE"
}

tt_main() {
  local resuming=0 saved_tipo
  if [ "$UN_SIMULAR" = "1" ]; then
    NC_STATE_FILE="$TT_DIR/troca.estado"
  else
    mkdir -p "$TT_DIR"
    chmod 700 "$TT_DIR" 2>/dev/null || true
    log_start "$LOG_DIR" troca-tipo || { echo "Sem log (nao consegui criar $LOG_DIR)."; NC_LOG_FILE=""; }
    state_init "$TT_DIR/troca.estado"
  fi

  echo "=================================================================="
  if [ "$UN_SIMULAR" = "1" ]; then
    echo "  TROCAR O TIPO DA LOJA - SIMULACAO: nada sera mudado"
  else
    echo "  TROCAR O TIPO DA LOJA (restaurante / comercio em geral / industria)"
  fi
  echo "=================================================================="

  saved_tipo="$(state_get tipo)"
  if [ -n "$saved_tipo" ] && state_is_done backup; then
    resuming=1
    if [ -n "$TT_TIPO_PEDIDO" ] && [ "$(tt_normalizar_tipo "$TT_TIPO_PEDIDO")" != "$saved_tipo" ]; then
      echo "Uma troca para $(tt_label "$saved_tipo") ja esta em andamento. Ela precisa terminar antes de outra."
      NC_VERDICT="ok"
      exit 2
    fi
    TT_TIPO="$saved_tipo"
    TT_BACKUP_DIR="$(state_get backup_dir)"
  fi

  tt_preparar

  if [ "$resuming" = "1" ]; then
    echo "Continuando a troca para $(tt_label "$TT_TIPO") comecada em $(date -d "@$(state_get inicio)" '+%d/%m/%Y %H:%M' 2>/dev/null || echo 'outra execucao')."
    echo "A copia conferida ja esta em $TT_BACKUP_DIR (nao sera refeita)."
    if [ "$UN_SIMULAR" = "1" ]; then
      echo "  [simular] continuar: guardar o que fica, recriar o banco, avisar o mestre e ligar a loja"
      echo
      echo "SIMULACAO: nada foi mudado."
      NC_VERDICT="ok"
      exit 0
    fi
    if [ -z "$(state_get reset_iniciado)" ]; then
      # Nada apagado ainda: a pessoa ainda pode desistir.
      tt_aviso
      if ! tt_confirmar; then
        echo "Cancelado. Nada foi apagado; a copia ficou em $TT_BACKUP_DIR."
        NC_VERDICT="ok"
        tt_ligar_se_parada
        tt_encerrar_estado_sem_reset
        exit 1
      fi
    fi
  else
    tt_aviso
    tt_pedir_tipo
    tt_conferir_loja
    tt_conferir_mestre
    tt_plano
    if [ "$UN_SIMULAR" = "1" ]; then
      echo
      echo "SIMULACAO: nada foi mudado. Para trocar de verdade, rode sem --simular."
      NC_VERDICT="ok"
      exit 0
    fi
    if ! tt_confirmar; then
      echo "Cancelado. Nada foi apagado."
      NC_VERDICT="ok"
      tt_ligar_se_parada
      tt_encerrar_estado_sem_reset
      exit 1
    fi
    state_set tipo "$TT_TIPO"
    [ -n "$(state_get inicio)" ] || state_set inicio "$(date +%s)"
  fi

  echo
  echo "1. Copia de seguranca"
  tt_backup
  echo
  echo "2. Guardar o que fica"
  tt_prepare
  echo
  echo "3. Apagar e recriar o banco como $(tt_label "$TT_TIPO")"
  tt_reset
  echo
  echo "4. Avisar o NCommerce (mestre)"
  tt_avisar_mestre
  echo
  echo "5. Ligar a loja"
  tt_ligar

  tt_mensagem_final
  NC_VERDICT="ok"
  if [ "${TT_MESTRE_PENDENTE:-0}" != "1" ]; then
    lock_release
    rm -rf "$TT_DIR"
  fi
  exit 0
}
