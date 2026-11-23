#!/bin/bash
# Testes do instalador_linux.sh, do update.sh e da lib, com Docker, sudo, apt e
# o mestre de mentira (tests/fake). Rode por tests/run.sh, nunca direto no seu
# computador: os testes apagam /opt/ncommerce e ~/.ncommerce-docker.
set -uo pipefail
if [ ! -d /fake ] || [ "$(id -un)" != "loja" ]; then
  echo "Rode por tests/run.sh (dentro do container de testes)."
  exit 1
fi
FILTER="${1:-}"
# shellcheck source=tests/helpers.sh
. /repo/tests/helpers.sh

want() { [ -z "$FILTER" ] || [[ "$1" == *"$FILTER"* ]]; }

# ------------------------------------------------------------------ lib

if want lib; then
  t "lib: arquivo de estado atomico"
  reset_all
  # shellcheck source=lib/instalador.sh
  . /repo/lib/instalador.sh
  state_init /tmp/estado-teste
  state_set a 1; state_set b "dois tres"; state_set a 5
  check "state_get devolve o ultimo valor" [ "$(state_get a)" = "5" ]
  check "valor com espaco" [ "$(state_get b)" = "dois tres" ]
  check "chave ausente e vazia" [ -z "$(state_get nada)" ]
  state_done x
  check "etapa marcada" state_is_done x
  check "etapa nao marcada" bash -c '. /repo/lib/instalador.sh; NC_STATE_FILE=/tmp/estado-teste; ! state_is_done y'
  state_unset a
  check "state_unset tira a chave" [ -z "$(state_get a)" ]
  check "sem sobra de temporario" bash -c '! ls /tmp/estado-teste.tmp.* 2>/dev/null | grep -q .'
  printf 'lixo\x01binario\nsem igual\n' > /tmp/estado-teste
  : > /tmp/estado-teste.tmp.999
  state_init /tmp/estado-teste
  check "estado ilegivel e posto de lado" [ -f /tmp/estado-teste.ilegivel ]
  check "estado recomeca vazio" [ ! -s /tmp/estado-teste ]
  check "temporario orfao some" [ ! -e /tmp/estado-teste.tmp.999 ]
  rm -f /tmp/estado-teste*

  t "lib: trava"
  ( . /repo/lib/instalador.sh; lock_acquire /tmp/trava-teste.lock && sleep 3 ) &
  holder=$!
  sleep 0.5
  check "segunda execucao nao pega a trava" bash -c '. /repo/lib/instalador.sh; ! lock_acquire /tmp/trava-teste.lock'
  kill -9 "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
  pkill -f 'sleep 3' 2>/dev/null; sleep 0.3
  check "trava de processo morto e liberada (flock)" bash -c '. /repo/lib/instalador.sh; lock_acquire /tmp/trava-teste.lock'
  # Sem flock: pasta com PID. PID morto = trava orfa.
  mkdir -p /tmp/semflock && for c in bash mkdir rm cat dirname kill; do ln -sf "$(command -v $c)" /tmp/semflock/$c; done
  mkdir -p /tmp/trava2.lock.d && echo 999999 > /tmp/trava2.lock.d/pid
  check "trava orfa (sem flock) e tomada" env PATH=/tmp/semflock bash -c '. /repo/lib/instalador.sh; lock_acquire /tmp/trava2.lock && [ "$(cat /tmp/trava2.lock.d/pid)" = "$$" ]'
  echo $$ > /tmp/trava2.lock.d/pid
  check "trava viva (sem flock) e respeitada" env PATH=/tmp/semflock bash -c '. /repo/lib/instalador.sh; ! lock_acquire /tmp/trava2.lock'
  rm -rf /tmp/trava* /tmp/semflock

  t "lib: env_merge e install_atomic"
  export NC_SUDO=0
  printf 'CUPS_PORT=631\nNCOMMERCE_KEEP_VERSIONS=5\nNCOMMERCE_TAG=keep-x\n' > /tmp/env-teste
  env_merge /tmp/env-teste "NCOMMERCE_TAG=latest" "TZ=America/Bahia"
  check "chave trocada" grep -qx 'NCOMMERCE_TAG=latest' /tmp/env-teste
  check "chave nova" grep -qx 'TZ=America/Bahia' /tmp/env-teste
  check "chave desconhecida fica" grep -qx 'NCOMMERCE_KEEP_VERSIONS=5' /tmp/env-teste
  check "sem linha repetida" [ "$(grep -c '^NCOMMERCE_TAG=' /tmp/env-teste)" = "1" ]
  check "copia do anterior" grep -qx 'NCOMMERCE_TAG=keep-x' /tmp/env-teste.bak
  check "env_read" [ "$(env_read /tmp/env-teste CUPS_PORT)" = "631" ]
  echo novo > /tmp/origem; echo velho > /tmp/destino
  install_atomic /tmp/origem /tmp/destino 755 bak
  check "install_atomic troca" [ "$(cat /tmp/destino)" = "novo" ]
  check "install_atomic guarda o anterior" [ "$(cat /tmp/destino.bak)" = "velho" ]
  check "install_atomic nao deixa .novo" [ ! -e /tmp/destino.novo ]
  check "install_atomic falha sem estragar o destino" bash -c '. /repo/lib/instalador.sh; NC_SUDO=0; ! install_atomic /tmp/nao-existe /tmp/destino 644 2>/dev/null && [ "$(cat /tmp/destino)" = novo ]'
  unset NC_SUDO
  rm -f /tmp/env-teste* /tmp/origem /tmp/destino*

  t "lib: download que continua"
  make_backup /fake/master-backup.zip
  size="$(stat -c %s /fake/master-backup.zip)"
  knob backup_cut 100000
  rm -f /tmp/b.part
  download_resumable "http://127.0.0.1:8088/install/GOODCODE/backup" /tmp/b.part 4
  check "download termina depois do corte" cmp -s /tmp/b.part /fake/master-backup.zip
  check "o corte aconteceu e houve retomada (Range)" [ "$(grep -c 'master GET /install/GOODCODE/backup' /fake/calls.log)" -ge 2 ]
  download_resumable "http://127.0.0.1:8088/install/GOODCODE/backup" /tmp/b.part 2
  check "arquivo completo: servidor responde 416 e nada muda" [ "$NC_HTTP" = "416" ] && cmp -s /tmp/b.part /fake/master-backup.zip
  knob no_range; knob backup_cut 1000; rm -f /tmp/b.part
  download_resumable "http://127.0.0.1:8088/install/GOODCODE/backup" /tmp/b.part 4
  check "servidor sem Range: recomeca do zero e termina" cmp -s /tmp/b.part /fake/master-backup.zip
  unknob no_range
  knob no_backup
  download_resumable "http://127.0.0.1:8088/install/GOODCODE/backup" /tmp/c.part 2
  check "204 = sem backup" [ "$NC_HTTP" = "204" ]
  unknob no_backup
  check "404 nao insiste e devolve erro" bash -c '. /repo/lib/instalador.sh; ! download_resumable http://127.0.0.1:8088/install/XXXXXXXX/backup /tmp/d.part 3 && [ "$NC_HTTP" = 404 ]'
  check "sem resposta devolve erro" bash -c '. /repo/lib/instalador.sh; sleep() { :; }; ! download_resumable http://127.0.0.1:9/x /tmp/e.part 2'
  skew="$(clock_skew_seconds http://127.0.0.1:8088/)"
  check "relogio: diferenca pequena com o servidor" [ -n "$skew" ] && [ "$skew" -lt 5 ]
  rm -f /tmp/*.part
  : "$size"
fi

# ------------------------------------------------------------ instalador

if want instalar; then
  t "instalar: do zero, com codigo no arquivo e backup do mestre"
  reset_all; code_file; make_backup /fake/master-backup.zip
  run_installer
  check "sai com 0" [ "$RC" = "0" ]
  check "veredito de sucesso" out_has "INSTALACAO CONCLUIDA COM SUCESSO"
  check "mostra as etapas" out_has "Etapa 10 de 10"
  check "nao pede codigo" out_lacks "Codigo de instalacao (8 caracteres)"
  check ".env com registry" env_is "NCOMMERCE_REGISTRY=127.0.0.1:5050"
  check ".env com tag" env_is "NCOMMERCE_TAG=latest"
  check ".env com compose usb" env_is "COMPOSE_FILE=docker-compose.yml:docker-compose.usb.yml"
  check ".env com plugins" grep -q '^NCOMMERCE_PLUGINS_DIR=/home/loja/Documents/ncommerce/plugins$' /opt/ncommerce/.env
  check ".env com IPs" grep -q '^NCOMMERCE_HOST_IPS=' /opt/ncommerce/.env
  check "scripts instalados" [ -x /opt/ncommerce/update.sh ] && [ -x /opt/ncommerce/guard.sh ] && [ -f /opt/ncommerce/docker-compose.yml ]
  check "banco restaurado uma vez" [ "$(imports)" = "1" ]
  check "banco e o do backup" grep -q 'BACKUP-A' /fake/state/db_import.sql
  check "documentos restaurados" [ -f /app/ncommerce_api/business_docs/contrato.txt ]
  check "nfce restaurada" [ -f /data/nfce/essentials/config/dados_emitente.json ]
  check "marca de backup restaurado" [ -f /opt/ncommerce/.backup-restored ]
  check "token gravado pela API" grep -q 'NCOMMERCE_SERVER_TOKEN=tok123456789' /env/.env.production
  check "login no registry" [ "$(cat /fake/state/login)" = "127.0.0.1:5050" ]
  check "senha do AnyDesk configurada" [ -f /fake/state/anydesk_password ]
  check "atalho na area de trabalho" [ -f "$HOME/Desktop/Atualizar NCommerce.desktop" ]
  check "estado: concluida" state_has "concluida="
  check "estado: codigo apagado" bash -c '! grep -q "^codigo=" ~/.ncommerce-docker/instalacao.estado'
  check "log gravado" bash -c 'ls ~/ncommerce-logs/instalacao-*.log >/dev/null && grep -q "INSTALACAO CONCLUIDA" ~/ncommerce-logs/instalacao-*.log'
  check "token nao aparece no log" bash -c '! grep -rq "tok123456789\|segredo-anydesk" ~/ncommerce-logs/'
  check "zip aberto nao fica no /tmp" bash -c '! find /tmp -name backup.sql 2>/dev/null | grep -q .'
  check "trava solta" lock_free
  check "sem processo de apoio sobrando" bash -c '! pgrep -f "[s]leep 3600" >/dev/null'
  cp /opt/ncommerce/.env /tmp/env-antes

  t "instalar: rodar de novo numa loja pronta so confere (sem codigo)"
  : > /fake/calls.log
  rm -f "$SRC/codigo-instalacao.txt"
  run_installer
  check "sai com 0" [ "$RC" = "0" ]
  check "modo conferir" out_has "ja esta instalado neste computador"
  check "sucesso" out_has "INSTALACAO CONCLUIDA COM SUCESSO"
  check "nao pede codigo" out_lacks "Codigo de instalacao (8 caracteres)"
  check "nao fala com o resgate" not_called "master POST /install/redeem"
  check "nao baixa backup" not_called "/backup"
  check "banco nao e restaurado de novo" [ "$(imports)" = "1" ]
  check "nao baixa imagens que ja tem" not_called "compose pull"
  check ".env igual ao de antes" cmp -s /tmp/env-antes /opt/ncommerce/.env

  t "instalar: a porta do CUPS nao troca na segunda execucao"
  check "porta 631 mantida" env_is "CUPS_PORT=631"
  sed -i 's/^CUPS_PORT=.*/CUPS_PORT=6631/' /opt/ncommerce/.env
  run_installer
  check "porta 6631 de uma loja antiga fica" env_is "CUPS_PORT=6631"

  t "instalar: loja que voltou de versao (keep-) continua nela"
  sed -i 's/^NCOMMERCE_TAG=.*/NCOMMERCE_TAG=keep-2026.01.01-abc1234/' /opt/ncommerce/.env
  echo sha256:apiold > "/fake/state/images/127.0.0.1_5050_ncommerce_api_keep-2026.01.01-abc1234"
  echo sha256:webold > "/fake/state/images/127.0.0.1_5050_ncommerce_web_keep-2026.01.01-abc1234"
  : > /fake/calls.log
  run_installer
  check "sai com 0" [ "$RC" = "0" ]
  check "tag guardada fica" env_is "NCOMMERCE_TAG=keep-2026.01.01-abc1234"
  check "nao tenta baixar a tag que so existe aqui" not_called "compose pull"

  t "instalar: loja em uso nao recebe o backup do mestre por cima"
  reset_all; code_file; knob no_backup
  run_installer
  check "primeira instalacao sem backup" [ "$RC" = "0" ] && [ "$(imports)" = "0" ]
  unknob no_backup; make_backup /fake/master-backup.zip BACKUP-VELHO
  rm -f /opt/ncommerce/.backup-restored   # lojas instaladas pelo instalador antigo nao tinham a marca
  run_installer --reinstalar
  check "sai com 0" [ "$RC" = "0" ]
  check "avisa que nao restaura" out_has "NAO e restaurado por cima"
  check "banco intocado" [ "$(imports)" = "0" ]
  check "marca gravada" [ -f /opt/ncommerce/.backup-restored ]

  t "instalar: --backup numa loja em uso guarda copia do banco antes"
  make_backup "/tmp/zip avulso.zip" BACKUP-AVULSO
  run_installer --backup "/tmp/zip avulso.zip"
  check "sai com 0" [ "$RC" = "0" ]
  check "copia antes de restaurar" bash -c 'ls /opt/ncommerce/backups/antes-de-restaurar-*.sql.gz >/dev/null 2>&1'
  check "backup avulso restaurado" grep -q 'BACKUP-AVULSO' /fake/state/db_import.sql
  check "dump antes do import" bash -c '[ "$(grep -n mysqldump /fake/calls.log | head -1 | cut -d: -f1)" -lt "$(grep -n "mysql -uroot" /fake/calls.log | tail -1 | cut -d: -f1)" ]'
  knob dump_fail
  make_backup "/tmp/zip2.zip" BACKUP-DOIS
  run_installer --backup "/tmp/zip2.zip"
  check "sem copia do banco, nao restaura" [ "$RC" != "0" ] && ! grep -q 'BACKUP-DOIS' /fake/state/db_import.sql
  check "explica" out_has "nao consegui guardar uma copia do banco"
  unknob dump_fail

  t "instalar: restauracao que falha e e repetida nao troca a copia de antes"
  installed_store
  : > /fake/state/db_import.sql
  make_backup "/tmp/zip3.zip" BACKUP-TRES
  knob mysql_fail 1
  run_installer --backup "/tmp/zip3.zip"
  first="$(grep -c '^mysqldump' /fake/calls.log)"
  for _ in 2 3 4; do run_installer --backup "/tmp/zip3.zip"; done
  check "falha" [ "$RC" != "0" ]
  check "uma copia so, a da primeira tentativa" [ "$first" -ge 1 ] && [ "$(grep -c '^mysqldump' /fake/calls.log)" = "$first" ] \
    && bash -c 'f="$(sed -n "s/^copia_antes_de_restaurar=//p" ~/.ncommerce-docker/instalacao.estado)"; [ -s "$f" ]'
  check "avisa que a copia ja esta guardada" out_has "copia do banco de antes da restauracao ja esta guardada"
  rm -f /fake/knobs/mysql_fail
  run_installer --backup "/tmp/zip3.zip"
  check "depois restaura" [ "$RC" = "0" ] && grep -q 'BACKUP-TRES' /fake/state/db_import.sql

  t "instalar: codigo recusado, depois digitado"
  reset_all; code_file BADCODE1
  STDIN_TEXT=$'abc\ngood-code\n' run_installer
  check "sai com 0" [ "$RC" = "0" ]
  check "avisa do recusado" out_has "Codigo BADCODE1 recusado"
  check "rejeita formato" out_has "Use 8 letras ou numeros"
  check "sucesso com o digitado" out_has "INSTALACAO CONCLUIDA"

  t "instalar: sem codigo e sem teclado nao fica em laco"
  reset_all
  STDIN_TEXT="" run_installer
  check "falha limpa" [ "$RC" != "0" ] && out_has "precisa do codigo de instalacao"
  check "saida pequena (sem laco)" [ "$(wc -l < "$OUT")" -lt 80 ]

  t "instalar: sem internet"
  reset_all; code_file
  NCOMMERCE_MASTER_URL="https://servidor.que-nao-existe.invalid" run_installer
  check "falha na etapa 1" [ "$RC" != "0" ] && out_has "Parou na etapa 1 de 10"
  check "diz que e a internet" out_has "sem internet"
  check "diz o que fazer" out_has "O que fazer:"
  check "nada instalado" [ ! -e /opt/ncommerce ]

  t "instalar: mestre fora do ar"
  reset_all; code_file; knob master_500
  run_installer
  check "falha na etapa 3" [ "$RC" != "0" ] && out_has "Parou na etapa 3 de 10"
  check "codigo continua valendo" out_has "O codigo continua valendo"
  unknob master_500
  run_installer
  check "rodar de novo termina" [ "$RC" = "0" ]

  t "instalar: abaixo do minimo"
  reset_all; code_file
  mkdir -p /tmp/fakenproc && printf '#!/bin/sh\necho 2\n' > /tmp/fakenproc/nproc && chmod +x /tmp/fakenproc/nproc
  PATH="/tmp/fakenproc:$PATH" run_installer
  check "barra" [ "$RC" != "0" ] && out_has "4 threads (este tem 2)"
  PATH="/tmp/fakenproc:$PATH" run_installer --ignorar-requisitos
  check "bypass segue" [ "$RC" = "0" ] && out_has "Seguindo mesmo assim"
  rm -rf /tmp/fakenproc

  t "instalar: senha do sudo recusada"
  reset_all; code_file; knob sudo_denied
  run_installer
  check "explica" [ "$RC" != "0" ] && out_has "nao e administrador"

  t "instalar: pacote pela metade e apt ocupado"
  reset_all; code_file; knob dpkg_broken
  run_installer
  check "conserta o dpkg e segue" [ "$RC" = "0" ] && out_has "ficou pela metade" && called "dpkg --configure -a"

  t "instalar: download das imagens cai e volta"
  reset_all; code_file; knob pull_fail 2
  run_installer
  check "tenta de novo e termina" [ "$RC" = "0" ] && out_has "tentativa 2 de 4"
  reset_all; code_file; knob pull_fail 9
  run_installer
  check "desiste com explicacao" [ "$RC" != "0" ] && out_has "Parou na etapa 7 de 10" && out_has "download do NCommerce nao terminou"
  check "containers nao foram ligados" not_called "compose up"
  check "estado guarda ate onde foi" state_has "etapa_arquivos=" && ! state_has "etapa_download="
  unknob pull_fail
  : > /fake/calls.log
  run_installer
  check "rodar de novo termina" [ "$RC" = "0" ] && out_has "INSTALACAO CONCLUIDA"

  t "instalar: registry inalcancavel"
  reset_all; code_file
  pkill -f 'server.py registry'; sleep 0.3
  run_installer
  check "explica antes de tentar baixar" [ "$RC" != "0" ] && out_has "nao consegui chegar no servidor de onde o NCommerce e baixado" && not_called "compose pull"

  t "instalar: API nao sobe"
  reset_all; code_file; knob api_never_starts
  run_installer
  check "falha na etapa 8 com explicacao" [ "$RC" != "0" ] && out_has "Parou na etapa 8 de 10" && out_has "nao respondeu"
  unknob api_never_starts
  run_installer
  check "rodar de novo termina" [ "$RC" = "0" ]

  t "instalar: tela (4200) fora na conferencia final"
  reset_all; code_file; knob web_down
  # 24 x 5s de espera na conferencia: encurta o sleep so neste teste.
  mkdir -p /tmp/fastsleep && printf '#!/bin/sh\nexec /usr/bin/sleep 0.05\n' > /tmp/fastsleep/sleep && chmod +x /tmp/fastsleep/sleep
  PATH="/tmp/fastsleep:$PATH" run_installer
  check "nao declara sucesso" [ "$RC" != "0" ] && out_lacks "CONCLUIDA" && out_has "porta 4200"
  unknob web_down
  PATH="/tmp/fastsleep:$PATH" run_installer
  check "rodar de novo confere e termina (sem codigo)" [ "$RC" = "0" ] && out_has "ja esta instalado"
  rm -rf /tmp/fastsleep

  t "instalar: backup do mestre cortado no meio e retomado"
  reset_all; code_file; make_backup /fake/master-backup.zip; knob backup_cut 50000
  run_installer
  check "termina" [ "$RC" = "0" ] && out_has "Backup baixado e conferido"
  check "restaurou" [ "$(imports)" = "1" ]
  check "sem .part sobrando" [ ! -e "$HOME/.ncommerce-docker/ncommerce.zip.part" ]

  t "instalar: pedaco velho de outro backup e descartado"
  reset_all; code_file; make_backup /fake/master-backup.zip
  mkdir -p "$HOME/.ncommerce-docker"; head -c 5000 /dev/urandom > "$HOME/.ncommerce-docker/ncommerce.zip.part"
  run_installer
  check "baixa de novo do inicio e termina" [ "$RC" = "0" ] && out_has "nao passou na conferencia" && [ "$(imports)" = "1" ]

  t "instalar: arquivos do instalador faltando ou danificados"
  reset_all; code_file
  rm -rf "$SRC/lib"
  run_installer
  check "pede para extrair o zip" [ "$RC" != "0" ] && out_has "Extraia o zip do instalador inteiro"
  reset_all; code_file
  head -c 2000 /repo/docker/update.sh > "$SRC/docker/update.sh"; echo 'if [ ' >> "$SRC/docker/update.sh"
  run_installer
  check "script cortado nao e instalado" [ "$RC" != "0" ] && out_has "esta danificado" && [ ! -e /opt/ncommerce/update.sh ]

  t "instalar: estado ilegivel nao trava"
  reset_all; code_file
  mkdir -p "$HOME/.ncommerce-docker"; head -c 300 /dev/urandom > "$HOME/.ncommerce-docker/instalacao.estado"
  run_installer
  check "instala mesmo assim" [ "$RC" = "0" ]

  t "instalar: .env vazio (queda de energia) volta da copia"
  : > /opt/ncommerce/.env
  run_installer
  check "volta a copia" [ "$RC" = "0" ] && out_has "estava vazio" && env_is "NCOMMERCE_REGISTRY=127.0.0.1:5050"

  t "instalar: como root"
  check "recusa" bash -c 'FAKE_ROOT=1 bash "$0/instalador_linux.sh" 2>&1 | grep -q "Rode sem sudo"' "$SRC"
fi

if want interromper; then
  t "interromper: duas janelas ao mesmo tempo"
  reset_all; code_file; knob pull_sleep 6
  start_installer_bg
  wait_call "compose pull"
  cp "$OUT" /tmp/out-primeira.txt
  OUT=/tmp/out2.txt run_installer
  check "a segunda sai avisando" [ "$RC" = "2" ] && grep -q "ja esta aberto em outra janela" /tmp/out2.txt
  check "a segunda nao mexe em nada" [ "$(grep -c '^docker compose pull' /fake/calls.log)" = "1" ]
  wait_bg
  check "a primeira termina normal" [ "$RC" = "0" ] && out_has "INSTALACAO CONCLUIDA"

  t "interromper: Ctrl+C no download das imagens"
  reset_all; code_file; knob pull_sleep 30
  start_installer_bg
  wait_call "compose pull"
  signal_group INT
  wait_bg
  check "sai com 130" [ "$RC" = "130" ]
  check "veredito de interrompida" out_has "A INSTALACAO FOI INTERROMPIDA"
  check "diz a etapa" out_has "Parou na etapa 7 de 10"
  check "diz para rodar de novo" out_has "rode o instalador de novo"
  check "trava solta" lock_free
  check "sem processo de apoio sobrando" bash -c 'sleep 0.5; ! pgrep -f "[s]leep 3600" >/dev/null'
  check "sem arquivo com token no /tmp" bash -c '! grep -rlq tok123456789 /tmp 2>/dev/null'
  unknob pull_sleep
  run_installer
  check "rodar de novo termina" [ "$RC" = "0" ] && out_has "INSTALACAO CONCLUIDA"

  t "interromper: janela fechada (SIGHUP) no download"
  reset_all; code_file; knob pull_sleep 30
  start_installer_bg
  wait_call "compose pull"
  signal_group HUP
  wait_bg
  check "sai com 129" [ "$RC" = "129" ]
  check "o log guarda o veredito" bash -c 'grep -q "A INSTALACAO FOI INTERROMPIDA" ~/ncommerce-logs/instalacao-*.log'
  check "trava solta" lock_free
  unknob pull_sleep
  run_installer
  check "rodar de novo termina" [ "$RC" = "0" ]

  t "interromper: queda de energia (kill -9) em cada ponto"
  for point in "apt-get\|dpkg --audit" "master POST /install/redeem" "docker login" "compose pull" "compose up" "mysql -uroot.*ncommerce_api_production$" "api POST"; do
    reset_all; code_file; make_backup /fake/master-backup.zip
    knob pull_sleep 3; knob up_sleep 3; knob mysql_sleep 3; knob api_post_sleep 3
    start_installer_bg
    if wait_call "$point"; then
      sleep 0.3
      signal_group KILL
      wait_bg
      pkill -f 'sleep 3600' 2>/dev/null
      unknob pull_sleep; unknob up_sleep; unknob mysql_sleep; unknob api_post_sleep
      SHOW_OUT=0 check "[$point] morreu sem veredito" out_lacks "CONCLUIDA"
      check "[$point] trava nao fica orfa" lock_free
      run_installer
      check "[$point] rodar de novo termina" [ "$RC" = "0" ] && out_has "O NCOMMERCE ESTA NO AR"
      check "[$point] token gravado" grep -q 'NCOMMERCE_SERVER_TOKEN=tok123456789' /env/.env.production
      check "[$point] banco restaurado e marcado" [ -f /opt/ncommerce/.backup-restored ] && [ "$(imports)" -ge 1 ]
      check "[$point] ultimo import completo" bash -c 'tail -n 3 /fake/state/db_import.sql | grep -q "CREATE TABLE"'
    else
      bad "[$point] ponto nao alcancado"
      signal_group KILL; wait_bg
    fi
  done

  t "interromper: queda no meio do restore nao restaura duas vezes depois de pronto"
  run_installer
  n="$(imports)"
  run_installer
  check "loja pronta: sem novo import" [ "$(imports)" = "$n" ]

  t "interromper: atalho de retomada depois de queda de energia"
  reset_all; code_file; knob pull_sleep 30
  DISPLAY=:0 start_installer_bg
  wait_call "compose pull"
  check "atalho de retomada criado" [ -f "$HOME/.config/autostart/ncommerce-instalador.desktop" ] && [ -x "$HOME/.ncommerce-docker/retomar-instalacao.sh" ]
  check "aponta para o instalador (pasta com espaco e acento)" bash -n "$HOME/.ncommerce-docker/retomar-instalacao.sh"
  signal_group KILL; wait_bg; pkill -f 'sleep 3600' 2>/dev/null
  unknob pull_sleep
  RC=0; printf '\n' | DISPLAY=:0 bash "$HOME/.ncommerce-docker/retomar-instalacao.sh" > "$OUT" 2>&1 || RC=$?
  check "a retomada termina a instalacao" out_has "INSTALACAO CONCLUIDA"
  check "atalho de retomada removido" [ ! -e "$HOME/.config/autostart/ncommerce-instalador.desktop" ] && [ ! -e "$HOME/.ncommerce-docker/retomar-instalacao.sh" ]
  # Pasta do instalador apagada: o atalho se remove sozinho.
  reset_all; code_file; knob pull_sleep 30
  DISPLAY=:0 start_installer_bg; wait_call "compose pull"; signal_group KILL; wait_bg; pkill -f 'sleep 3600' 2>/dev/null
  mv "$SRC" "$SRC.apagado"
  bash "$HOME/.ncommerce-docker/retomar-instalacao.sh" > "$OUT" 2>&1 < /dev/null
  check "sem a pasta, o atalho some" [ ! -e "$HOME/.config/autostart/ncommerce-instalador.desktop" ]
  mv "$SRC.apagado" "$SRC"
fi

if want nativo; then
  # desligar/religar de verdade mexem em nginx, cron e systemd: aqui entram
  # versoes de mentira que so anotam a chamada.
  fake_native_tools() {
    cat > "$SRC/tools/desligar_nativo.sh" <<'EOS'
#!/bin/bash
echo "desligar_nativo" >> /fake/calls.log
rm -f /etc/nginx/sites-enabled/ncommerce
EOS
    cat > "$SRC/tools/religar_nativo.sh" <<'EOS'
#!/bin/bash
echo "religar_nativo" >> /fake/calls.log
touch /etc/nginx/sites-enabled/ncommerce
EOS
  }
  t "nativo: so desliga a loja antiga depois de baixar tudo"
  reset_all; code_file; fake_native_tools; touch /etc/nginx/sites-enabled/ncommerce; knob pull_fail 9
  run_installer
  check "download falhou e a loja antiga nem foi tocada" [ "$RC" != "0" ] && not_called "desligar_nativo" && [ -e /etc/nginx/sites-enabled/ncommerce ]
  unknob pull_fail

  t "nativo: Docker nao assume -> religa a loja antiga sozinho"
  knob up_fail 9
  run_installer
  check "falhou" [ "$RC" != "0" ]
  check "desligou e religou" called "desligar_nativo" && called "religar_nativo"
  check "avisa" out_has "A loja antiga esta no ar de novo"
  check "pull antes de desligar" bash -c '[ "$(grep -n "compose pull" /fake/calls.log | tail -1 | cut -d: -f1)" -lt "$(grep -n desligar_nativo /fake/calls.log | head -1 | cut -d: -f1)" ]'
  unknob up_fail

  t "nativo: migracao que da certo nao religa"
  : > /fake/calls.log
  run_installer
  check "termina" [ "$RC" = "0" ] && called "desligar_nativo" && not_called "religar_nativo"
fi

# ---------------------------------------------------------------- update

# Loja instalada, com a versao api1/web1 rodando e marcada boa pelo guard.
installed_store() {
  reset_all; code_file; knob no_backup
  run_installer
  [ "$RC" = "0" ] || { bad "preparo: a instalacao falhou"; return 1; }
  unknob no_backup
  printf 'v1|sha256:api1|sha256:web1|1|good|20260101\n' > /tmp/versions.txt
  cp /tmp/versions.txt /opt/ncommerce/control/versions.txt
  # pacote de scripts publicado = os deste repositorio
  rm -rf /tmp/pkg && mkdir -p /tmp/pkg/ncscripts-master && cp -r /repo/docker /tmp/pkg/ncscripts-master/
  tar -czf /fake/ncscripts.tar.gz -C /tmp/pkg ncscripts-master
  : > /fake/calls.log
}

run_update() {
  RC=0
  bash /opt/ncommerce/update.sh > "$OUT" 2>&1 < /dev/null || RC=$?
}

start_update_bg() {
  setsid env --default-signal=INT,HUP,TERM bash /opt/ncommerce/update.sh > "$OUT" 2>&1 < /dev/null &
  BG_PID=$!
}

api_latest() { cat /fake/state/images/127.0.0.1_5050_ncommerce_api_latest; }
web_latest() { cat /fake/state/images/127.0.0.1_5050_ncommerce_web_latest; }
running_api() { cat /fake/state/containers/api; }

if want atualizar; then
  t "atualizar: versao nova publicada"
  installed_store
  knob published_api sha256:api2; knob published_web sha256:web2
  knob migration_sha256_api1 20260101000000; knob migration_sha256_api2 20260101000000
  printf 'v2|sha256:api2|sha256:web2|2|good|20260101\n' >> /opt/ncommerce/control/versions.txt
  run_update
  check "sai com 0" [ "$RC" = "0" ]
  check "veredito" out_has "ATUALIZACAO CONCLUIDA. VERSAO v2 FUNCIONANDO"
  check "api nova rodando" [ "$(running_api)" = "sha256:api2" ]
  check "sem estado de atualizacao sobrando" [ ! -e /opt/ncommerce/control/update.state ]
  check "log da atualizacao" bash -c 'grep -q "ATUALIZACAO CONCLUIDA" ~/ncommerce-logs/atualizacao-*.log'
  check "migration igual: sem copia do banco" not_called mysqldump
  check "pull antes do up" bash -c '[ "$(grep -n "compose pull" /fake/calls.log | head -1 | cut -d: -f1)" -lt "$(grep -n "compose up" /fake/calls.log | head -1 | cut -d: -f1)" ]'

  t "atualizar: versao que muda o banco guarda copia antes"
  installed_store
  knob published_api sha256:api3; knob migration_sha256_api1 20260101000000; knob migration_sha256_api3 20260202000000
  run_update
  check "sai com 0" [ "$RC" = "0" ]
  check "copia guardada" bash -c 'ls /opt/ncommerce/backups/antes-de-atualizar-*.sql.gz >/dev/null 2>&1'
  check "copia antes da troca" bash -c '[ "$(grep -n mysqldump /fake/calls.log | head -1 | cut -d: -f1)" -lt "$(grep -n "compose up" /fake/calls.log | head -1 | cut -d: -f1)" ]'
  installed_store
  knob published_api sha256:api3; knob migration_sha256_api1 20260101000000; knob migration_sha256_api3 20260202000000; knob dump_fail
  run_update
  check "sem copia nao atualiza" [ "$RC" != "0" ] && [ "$(running_api)" = "sha256:api1" ] && not_called "compose up"
  check "etiqueta latest volta para a versao em uso" [ "$(api_latest)" = "sha256:api1" ]
  check "veredito" out_has "A ATUALIZACAO NAO FOI FEITA. A LOJA CONTINUA NA VERSAO EM QUE ESTAVA"

  t "atualizar: internet cai no meio do download (api baixou, web nao)"
  installed_store
  knob published_api sha256:api2; knob published_web sha256:web2; knob pull_partial 9
  run_update
  check "sai com erro" [ "$RC" != "0" ]
  check "veredito" out_has "A LOJA CONTINUA NA VERSAO EM QUE ESTAVA"
  check "nada foi recriado" not_called "compose up" && [ "$(running_api)" = "sha256:api1" ]
  check "api:latest volta para a versao em uso" [ "$(api_latest)" = "sha256:api1" ]
  check "web:latest fica na versao em uso" [ "$(web_latest)" = "sha256:web1" ]
  check ".env intocado" env_is "NCOMMERCE_TAG=latest"
  check "sem estado sobrando" [ ! -e /opt/ncommerce/control/update.state ]

  t "atualizar: loja numa versao guardada so muda de tag depois do download"
  installed_store
  sed -i 's/^NCOMMERCE_TAG=.*/NCOMMERCE_TAG=keep-v1/' /opt/ncommerce/.env
  knob pull_fail 9
  run_update
  check "download falhou: tag guardada fica" [ "$RC" != "0" ] && env_is "NCOMMERCE_TAG=keep-v1"
  unknob pull_fail
  run_update
  check "download ok: volta para a publicada" [ "$RC" = "0" ] && env_is "NCOMMERCE_TAG=latest"

  t "atualizar: Ctrl+C no download"
  installed_store
  knob published_api sha256:api2; knob pull_sleep 30
  start_update_bg
  wait_call "compose pull"
  check "estado: baixando" grep -q '^pull|' /opt/ncommerce/control/update.state
  signal_group INT; wait_bg
  check "sai com 130" [ "$RC" = "130" ]
  check "veredito" out_has "A LOJA CONTINUA NA VERSAO EM QUE ESTAVA" && out_has "interrompida"
  check "loja intocada" [ "$(running_api)" = "sha256:api1" ] && not_called "compose up"
  check "estado limpo" [ ! -e /opt/ncommerce/control/update.state ]
  check "trava solta" lock_free

  t "atualizar: Ctrl+C no meio da troca religa a loja"
  installed_store
  knob published_api sha256:api2; knob up_sleep 30
  start_update_bg
  wait_call "compose up"
  check "estado: trocando" grep -q '^up|' /opt/ncommerce/control/update.state
  unknob up_sleep
  signal_group INT; wait_bg
  check "religa" out_has "Ligando o NCommerce de novo" && [ "$(grep -c 'compose up' /fake/calls.log)" -ge 2 ]
  check "veredito" out_has "INTERROMPIDA NO MEIO DA TROCA"
  check "estado limpo depois de religar" [ ! -e /opt/ncommerce/control/update.state ]

  t "atualizar: Ctrl+C na conferencia diz que a versao nova ja esta no lugar"
  installed_store
  knob published_api sha256:api2
  NCOMMERCE_UPDATE_WAIT_S=60 start_update_bg
  for _ in $(seq 1 150); do grep -q "Conferindo a versao nova" "$OUT" 2>/dev/null && break; sleep 0.1; done
  signal_group INT; wait_bg
  check "veredito certo" out_has "ATUALIZACAO FEITA. A CONFERENCIA DA VERSAO NOVA CONTINUA SOZINHA" \
    && out_lacks "NAO FOI FEITA" && [ "$(running_api)" = "sha256:api2" ]

  t "atualizar: queda de energia no meio da troca deixa o aviso para a guarda"
  installed_store
  knob published_api sha256:api2; knob up_sleep 30
  start_update_bg
  wait_call "compose up"
  signal_group KILL; wait_bg; unknob up_sleep
  check "estado 'up' fica para a guarda terminar" grep -q '^up|' /opt/ncommerce/control/update.state
  run_update
  check "atualizar de novo termina e limpa" [ "$RC" = "0" ] && [ ! -e /opt/ncommerce/control/update.state ] && [ "$(running_api)" = "sha256:api2" ]

  t "atualizar: versao nova nao liga -> volta para a anterior"
  installed_store
  knob published_api sha256:api2; knob published_web sha256:web2; knob up_fail 2
  run_update
  check "sai com erro e avisa" [ "$RC" != "0" ] && out_has "VOLTOU PARA A VERSAO ANTERIOR"
  check "anterior rodando" [ "$(running_api)" = "sha256:api1" ] && [ "$(api_latest)" = "sha256:api1" ]

  t "atualizar: a guarda voltou a versao sozinha"
  installed_store
  knob published_api sha256:api2
  ( sleep 1.5; echo sha256:api1 > /fake/state/containers/api ) &
  NCOMMERCE_UPDATE_WAIT_S=30 run_update
  check "avisa que voltou" [ "$RC" = "1" ] && out_has "VOLTOU SOZINHO PARA A VERSAO v1"

  t "atualizar: dois cliques no atalho"
  installed_store
  knob pull_sleep 5
  start_update_bg
  wait_call "compose pull"
  OUT=/tmp/out2.txt run_update
  check "o segundo sai avisando" [ "$RC" = "2" ] && grep -q "ja esta rodando em outra janela" /tmp/out2.txt
  wait_bg
  check "o primeiro termina" [ "$RC" = "0" ]
  check "um download so" [ "$(grep -c '^docker compose pull' /fake/calls.log)" = "1" ]

  t "atualizar: disco quase cheio"
  installed_store
  mkdir -p /tmp/fakedf && printf '#!/bin/sh\necho "Filesystem 1024-blocks Used Available Capacity Mounted on"\necho "/dev/sda1 100000000 99000000 1000000 99%% /"\n' > /tmp/fakedf/df && chmod +x /tmp/fakedf/df
  PATH="/tmp/fakedf:$PATH" run_update
  check "nao comeca" [ "$RC" != "0" ] && out_has "quase cheio" && not_called "compose pull"
  rm -rf /tmp/fakedf

  t "atualizar: scripts novos do pacote publicado"
  installed_store
  echo '# marca-nova' >> /tmp/pkg/ncscripts-master/docker/rollback.sh
  echo '# marca-nova' >> /tmp/pkg/ncscripts-master/docker/update.sh
  tar -czf /fake/ncscripts.tar.gz -C /tmp/pkg ncscripts-master
  run_update
  check "termina" [ "$RC" = "0" ]
  check "scripts trocados" grep -q marca-nova /opt/ncommerce/rollback.sh && grep -q marca-nova /opt/ncommerce/update.sh
  check "seguiu com o update.sh novo, um log so" [ "$(ls ~/ncommerce-logs/atualizacao-*.log | wc -l)" = "1" ]
  check "um download so das imagens" [ "$(grep -c '^docker compose pull' /fake/calls.log)" = "1" ]

  t "atualizar: pacote com script danificado nao troca nenhum"
  installed_store
  echo '# marca-boa' >> /tmp/pkg/ncscripts-master/docker/rollback.sh
  printf 'if [ ; then\n' >> /tmp/pkg/ncscripts-master/docker/tunnel-route.sh
  tar -czf /fake/ncscripts.tar.gz -C /tmp/pkg ncscripts-master
  run_update
  check "atualizacao das imagens segue" [ "$RC" = "0" ] && out_has "Nao troquei nenhum script"
  check "nem o script bom entrou" bash -c '! grep -q marca-boa /opt/ncommerce/rollback.sh'
  head -c 3000 /fake/ncscripts.tar.gz > /fake/cortado && mv /fake/cortado /fake/ncscripts.tar.gz
  run_update
  check "pacote cortado e ignorado" [ "$RC" = "0" ] && out_has "Nao consegui atualizar os scripts"

  t "atualizar: loja com os scripts ANTIGOS (master) recebe os novos e termina"
  installed_store
  # Scripts do master atual, como estao hoje nas lojas.
  for f in update.sh update-host.sh guard.sh rollback.sh host-ips.sh; do
    cp "/master-scripts/$f" "/opt/ncommerce/$f"
    chmod 755 "/opt/ncommerce/$f"
  done
  # O update-host.sh antigo so baixa do GitHub: um curl de mentira entrega o pacote local.
  mkdir -p /tmp/fakecurl
  cat > /tmp/fakecurl/curl <<'EOS'
#!/bin/sh
case "$*" in
  *github.com*ncscripts*)
    out=""; prev=""
    for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
    if [ -n "$out" ]; then cp /fake/ncscripts.tar.gz "$out"; else cat /fake/ncscripts.tar.gz; fi
    exit 0 ;;
esac
exec /usr/bin/curl "$@"
EOS
  chmod +x /tmp/fakecurl/curl
  knob published_api sha256:api2
  RC=0; PATH="/tmp/fakecurl:$PATH" bash /opt/ncommerce/update.sh > "$OUT" 2>&1 < /dev/null || RC=$?
  check "termina" [ "$RC" = "0" ]
  check "passou para o update.sh novo" out_has "ATUALIZACAO" && cmp -s /repo/docker/update.sh /opt/ncommerce/update.sh
  check "guard.sh novo no lugar" cmp -s /repo/docker/guard.sh /opt/ncommerce/guard.sh
  check "api nova rodando" [ "$(running_api)" = "sha256:api2" ]
  rm -rf /tmp/fakecurl
fi

# ------------------------------------------------- volta ao estado anterior

if want volta; then
  t "volta: reparo com compose novo que nao liga volta os arquivos e religa"
  installed_store
  cp /opt/ncommerce/docker-compose.yml /tmp/compose-antes.yml
  echo "# compose-novo" >> "$SRC/docker/docker-compose.yml"
  knob up_fail 2; knob api_down; knob up_heals_api
  NCOMMERCE_ROLLBACK_WAIT_S=10 run_installer
  check "falha" [ "$RC" != "0" ]
  check "avisa e volta" out_has "Voltando os arquivos e a versao de antes" && out_has "A LOJA VOLTOU PARA COMO ESTAVA"
  check "compose de antes no lugar" cmp -s /tmp/compose-antes.yml /opt/ncommerce/docker-compose.yml
  check "religou depois de voltar" [ "$(grep -c '^docker compose up' /fake/calls.log)" -ge 3 ]
  check "copia de antes apagada" [ ! -e /opt/ncommerce/control/antes-da-instalacao ]
  unknob up_heals_api

  t "volta: loja que segue respondendo nao e desfeita"
  installed_store
  echo "# compose-novo" >> "$SRC/docker/docker-compose.yml"
  knob up_fail 2
  run_installer
  check "falha sem voltar" [ "$RC" != "0" ] && out_lacks "Voltando os arquivos"
  check "copia de antes fica para a proxima" [ -s /opt/ncommerce/control/antes-da-instalacao/imagens ]
  run_installer
  check "rodar de novo termina e apaga a copia" [ "$RC" = "0" ] && [ ! -e /opt/ncommerce/control/antes-da-instalacao ]

  t "volta: --reinstalar com versao nova que nao liga volta a versao em uso"
  installed_store
  code_file
  knob published_api sha256:api2; knob published_web sha256:web2
  knob migration_sha256_api1 20260101000000; knob migration_sha256_api2 20260101000000
  knob up_fail 2; knob api_down; knob up_heals_api; knob no_backup
  NCOMMERCE_ROLLBACK_WAIT_S=10 run_installer --reinstalar
  check "falha e volta" [ "$RC" != "0" ] && out_has "A LOJA VOLTOU PARA COMO ESTAVA"
  check "latest volta para a versao de antes" [ "$(api_latest)" = "sha256:api1" ] && [ "$(web_latest)" = "sha256:web1" ]
  check "versao de antes rodando" [ "$(running_api)" = "sha256:api1" ]
  unknob up_heals_api

  t "volta: --reinstalar com download cortado nao mexe na loja"
  installed_store
  code_file
  knob published_api sha256:api2; knob published_web sha256:web2; knob pull_partial 9; knob no_backup
  run_installer --reinstalar
  check "falha" [ "$RC" != "0" ]
  check "latest volta para a versao em uso" [ "$(api_latest)" = "sha256:api1" ]
  check "nada recriado" [ "$(running_api)" = "sha256:api1" ]

  t "volta: --reinstalar com versao que muda o banco guarda copia antes"
  installed_store
  code_file
  knob published_api sha256:api3; knob migration_sha256_api1 20260101000000; knob migration_sha256_api3 20260202000000; knob no_backup
  run_installer --reinstalar
  check "termina" [ "$RC" = "0" ]
  check "copia guardada antes do up" bash -c 'ls /opt/ncommerce/backups/antes-de-atualizar-*.sql.gz >/dev/null 2>&1'

  t "volta: atualizacao morta no download e desfeita pelo instalador"
  installed_store
  printf 'pull|1|sha256:api1|sha256:web1|latest\n' > /opt/ncommerce/control/update.state
  echo sha256:api2 > /fake/state/images/127.0.0.1_5050_ncommerce_api_latest
  run_installer
  check "termina" [ "$RC" = "0" ] && out_has "interrompida durante o download"
  check "latest de volta" [ "$(api_latest)" = "sha256:api1" ] && [ "$(running_api)" = "sha256:api1" ]
  check "estado limpo" [ ! -e /opt/ncommerce/control/update.state ]
fi


# ---------------------------------------------------------- desinstalar

# Loja instalada com volumes de mentira (banco, certificado, .env da API, log).
store_to_uninstall() {
  installed_store || return 1
  local v=/fake/state/volumes
  mkdir -p "$v/ncommerce_mysql_data" "$v/ncommerce_nfce_data" "$v/ncommerce_api_env" "$v/ncommerce_api_log" \
    "$v/ncommerce_cups_data" "$v/outro_dados"
  echo "certificado" > "$v/ncommerce_nfce_data/certificado.pfx"
  echo "NCOMMERCE_SERVER_TOKEN=tok123" > "$v/ncommerce_api_env/.env.production"
  echo "log" > "$v/ncommerce_api_log/production.log"
  echo "<Printer x>" > "$v/ncommerce_cups_data/printers.conf"
  echo "nao e do ncommerce" > "$v/outro_dados/arquivo"
  # Coisas que nao sao do NCommerce e devem ficar.
  echo sha256:nginx > /fake/state/images/nginx_latest
  echo sha256:kx > /fake/state/images/127.0.0.1_5050_ncommerce_api_keep-v0
  printf '[Unit]\n' > /etc/systemd/system/outro.service
  printf '[Desktop Entry]\n' > "$HOME/Desktop/Outro.desktop"
  : > /fake/calls.log
}

backup_dir() { find "$HOME" -maxdepth 1 -name 'ncommerce-backup-desinstalacao-*' | head -n 1; }
nothing_removed() {
  [ -f /opt/ncommerce/docker-compose.yml ] && [ -d /fake/state/volumes/ncommerce_mysql_data ] \
    && [ -f /fake/state/containers/api ] && [ -f /etc/systemd/system/ncommerce-anydesk-id.service ] \
    && [ -f /fake/state/images/127.0.0.1_5050_ncommerce_api_latest ]
}
gz_dump_ok() { gzip -dc "$1" | tail -c 300 | grep -q "Dump completed"; }

if want desinstalar; then
  t "desinstalar: --simular lista e nao muda nada"
  store_to_uninstall
  run_uninstaller --simular
  check "termina" [ "$RC" = "0" ]
  check "mostra a copia, o compose down, as imagens e a pasta" \
    bash -c 'grep -q "\[simular\] copia do banco" /tmp/out.txt && grep -q "\[simular\] copia do volume ncommerce_nfce_data" /tmp/out.txt && grep -q "\[simular\] desligar e apagar os containers" /tmp/out.txt && grep -q "\[simular\] apagar a imagem 127.0.0.1:5050/ncommerce/api:latest" /tmp/out.txt && grep -q "\[simular\] apagar a pasta /opt/ncommerce" /tmp/out.txt'
  check "nao copia o banco cru nem o log" bash -c '! grep -q "volume ncommerce_mysql_data\|volume ncommerce_api_log" /tmp/out.txt'
  check "nao lista o que nao e do NCommerce" bash -c '! grep -q "outro_dados\|nginx\|outro.service\|Outro.desktop" /tmp/out.txt'
  check "mostra a pasta de plugins" out_has "[simular] apagar a pasta de plugins $HOME/Documents/ncommerce/plugins"
  check "lista o que fica para remover a mao" out_has "remova a mao se quiser"
  check "diz que nada mudou" out_has "SIMULACAO: nada foi mudado"
  check "nada removido" nothing_removed
  check "sem pasta de copia e sem estado" bash -c '[ -z "$(find "$HOME" -maxdepth 1 -name "ncommerce-backup-desinstalacao-*")" ] && [ ! -e "$HOME/.ncommerce-desinstalacao" ]'
  check "nenhum comando que muda" bash -c '! grep -qE "compose down|docker rmi|docker volume rm|mysqldump|systemctl disable|rm -rf" /fake/calls.log'

  t "desinstalar: resposta diferente de DESINSTALAR cancela"
  STDIN_TEXT=$'desinstalar\n' run_uninstaller
  check "sai com erro" [ "$RC" != "0" ]
  check "avisa" out_has "Cancelado. Nada foi removido."
  check "nada removido" nothing_removed
  check "sem copia" [ -z "$(backup_dir)" ]

  t "desinstalar: copia falha -> para sem remover; de novo, termina"
  knob dump_fail
  STDIN_TEXT=$'DESINSTALAR\n' run_uninstaller
  check "falha" [ "$RC" != "0" ]
  check "explica" out_has "Nada foi removido."
  check "nada removido" nothing_removed
  check "copia marcada incompleta" [ -e "$(backup_dir)/INCOMPLETO" ]
  unknob dump_fail
  rm -rf "$(backup_dir)"
  STDIN_TEXT=$'DESINSTALAR\n' run_uninstaller
  check "termina" [ "$RC" = "0" ] && out_has "DESINSTALACAO CONCLUIDA"

  t "desinstalar: desinstala com copia"
  store_to_uninstall
  STDIN_TEXT=$'DESINSTALAR\n' run_uninstaller
  b="$(backup_dir)"
  check "termina" [ "$RC" = "0" ] && out_has "DESINSTALACAO CONCLUIDA"
  check "diz onde ficou a copia" out_has "Copia da loja (banco, configuracoes e arquivos): $b"
  check "dump completo" gz_dump_ok "$b/banco-ncommerce_api_production.sql.gz"
  check "certificado na copia" bash -c "tar xzf '$b/volumes/nfce_data.tar.gz' -O ./certificado.pfx | grep -q certificado"
  check ".env da API na copia" bash -c "tar xzf '$b/volumes/api_env.tar.gz' -O ./.env.production | grep -q tok123"
  check "impressoras na copia" [ -f "$b/volumes/cups_data.tar.gz" ]
  check "sem banco cru, log nem volume alheio" bash -c "[ ! -e '$b/volumes/mysql_data.tar.gz' ] && [ ! -e '$b/volumes/api_log.tar.gz' ] && [ ! -e '$b/volumes/outro_dados.tar.gz' ]"
  check "configuracoes na copia" bash -c "grep -q '^NCOMMERCE_REGISTRY=' '$b/instalacao/.env' && [ -f '$b/instalacao/docker-compose.yml' ] && [ -f '$b/LEIA-ME.txt' ] && [ ! -e '$b/INCOMPLETO' ]"
  check "copia so do usuario" [ "$(stat -c %a "$b")" = "700" ]
  check "containers e volumes do NCommerce apagados" bash -c '[ -z "$(ls /fake/state/containers)" ] && [ ! -e /fake/state/volumes/ncommerce_mysql_data ] && [ ! -e /fake/state/volumes/ncommerce_nfce_data ]'
  check "imagens do NCommerce apagadas, inclusive keep-" bash -c '! ls /fake/state/images | grep -q ncommerce_'
  check "servicos apagados" bash -c '! ls /etc/systemd/system | grep -q "^ncommerce-"'
  check "pasta, atalho e progresso apagados" bash -c "[ ! -e /opt/ncommerce ] && [ ! -e '$HOME/Desktop/Atualizar NCommerce.desktop' ] && [ ! -e '$HOME/.ncommerce-docker' ] && [ ! -e '$HOME/.ncommerce-desinstalacao' ]"
  check "regra do CUPS e keepalive do SSH desfeitos" bash -c '[ ! -e /etc/udev/rules.d/70-printers.rules ] && [ ! -e /etc/ssh/sshd_config.d/ncommerce-keepalive.conf ]'
  check "o que nao e do NCommerce ficou" bash -c "[ -d /fake/state/volumes/outro_dados ] && [ -f /fake/state/images/nginx_latest ] && [ -f /fake/state/images/mysql_8.0 ] && [ -f /etc/systemd/system/outro.service ] && [ -f '$HOME/Desktop/Outro.desktop' ] && [ -f /etc/ssh/sshd_config ]"
  check "plugins saem, como no Windows (e estao na copia)" bash -c "[ ! -e '$HOME/Documents/ncommerce/plugins' ] && [ -d '$b/plugins' ]"
  check "lista a mao: Docker e imagem generica" bash -c 'grep -q "Docker (o instalador" /tmp/out.txt && grep -q "imagem Docker mysql:8.0" /tmp/out.txt'
  check "log da desinstalacao fica" bash -c 'ls "$HOME"/ncommerce-logs/desinstalacao-*.log >/dev/null 2>&1'
  run_uninstaller --simular
  check "rodar de novo: nada a fazer" out_has "Nao achei a versao Docker"

  t "desinstalar: interrompida depois da copia continua sem copiar de novo"
  store_to_uninstall
  knob down_fail 1
  STDIN_TEXT=$'DESINSTALAR\n' run_uninstaller
  check "falha no compose down" [ "$RC" != "0" ] && out_has "A copia da loja ja esta em:"
  check "volumes ainda existem" [ -d /fake/state/volumes/ncommerce_mysql_data ]
  STDIN_TEXT=$'DESINSTALAR\n' run_uninstaller
  check "termina" [ "$RC" = "0" ] && out_has "DESINSTALACAO CONCLUIDA"
  check "avisa que a copia ja existia" out_has "A copia ja foi feita numa execucao anterior"
  check "uma copia so" [ "$(grep -c '^mysqldump' /fake/calls.log)" = "1" ] && [ "$(find "$HOME" -maxdepth 1 -name 'ncommerce-backup-desinstalacao-*' | wc -l)" = "1" ]
  check "volumes apagados" [ ! -e /fake/state/volumes/ncommerce_mysql_data ]

  t "desinstalar: --sem-backup apaga sem copia, com aviso"
  store_to_uninstall
  STDIN_TEXT=$'DESINSTALAR\n' run_uninstaller --sem-backup
  check "termina" [ "$RC" = "0" ]
  check "avisa" out_has "SEM COPIA (--sem-backup)" && out_has "APAGADOS SEM COPIA"
  check "sem dump e sem pasta de copia" bash -c '! grep -q mysqldump /fake/calls.log' && [ -z "$(backup_dir)" ]
  check "removido" [ ! -e /opt/ncommerce ]

  t "desinstalar: --backup-em dentro da instalacao e recusado; fora, a copia vai para la"
  store_to_uninstall
  run_uninstaller --backup-em /opt/ncommerce/x
  check "recusa" [ "$RC" != "0" ] && out_has "nao pode ficar dentro de /opt/ncommerce"
  mkdir -p /tmp/backups-teste
  STDIN_TEXT=$'DESINSTALAR\n' run_uninstaller --backup-em /tmp/backups-teste
  check "copia na pasta pedida" bash -c 'ls /tmp/backups-teste/ncommerce-backup-desinstalacao-*/banco-ncommerce_api_production.sql.gz >/dev/null 2>&1'
  store_to_uninstall
  plug="$(sed -n 's/^NCOMMERCE_PLUGINS_DIR=//p' /opt/ncommerce/.env | tail -n 1)"
  STDIN_TEXT=$'DESINSTALAR\n' run_uninstaller --backup-em "$plug/copia"
  check "dentro da pasta de plugins (que e apagada) e recusado" [ -n "$plug" ] && [ "$RC" != "0" ] \
    && out_has "nao pode ficar dentro de $plug" && nothing_removed

  t "desinstalar: nao roda com o instalador ou uma atualizacao aberta"
  store_to_uninstall
  ( exec 9>>"$HOME/.ncommerce-docker/instalador.lock"; flock 9; sleep 3 ) &
  holder=$!
  sleep 0.5
  STDIN_TEXT=$'DESINSTALAR\n' run_uninstaller
  check "recusa" [ "$RC" = "2" ] && out_has "esta rodando agora"
  check "nada removido" nothing_removed
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
fi


# Instalacao nativa de mentira: ~/NCommerce, banco, nginx, cron e /etc/environment (num arquivo de teste).
native_store() {
  reset_all
  rm -rf "$HOME/NCommerce" "$HOME/.ncommerce-progress" "$HOME/.ncommerce-desinstalacao-nativo" /etc/nginx/sites-available
  local api="$HOME/NCommerce/ncommerce_api"
  mkdir -p "$api/essentials/config" "$api/node_modules/x" "$api/log" "$HOME/.ncommerce-progress" /etc/nginx/sites-available
  printf 'NCOMMERCE_SERVER_TOKEN=tok123\nSECRET_KEY_BASE=abc\n' > "$api/.env.production"
  echo "certificado" > "$api/essentials/config/dados_emitente.json"
  echo "lixo" > "$api/node_modules/x/a.js"
  echo "log" > "$api/log/production.log"
  touch "$HOME/.ncommerce-progress/step7.done"
  printf 'PATH=/usr/bin\nNCOMMERCE_SERVER_TOKEN=tok123\nSECRET_KEY_BASE=abc\nOUTRA=1\n' > /tmp/environment-teste
  for site in ncommerce ncommerce-api outro; do
    echo "server {}" > "/etc/nginx/sites-available/$site"
    ln -sf "/etc/nginx/sites-available/$site" "/etc/nginx/sites-enabled/$site"
  done
  printf '* * * * * %s/vendor/scripts/chown_files.sh %s\n0 1 * * * /usr/bin/outro\n' "$api" "$api" > /fake/state/crontab-user
  touch /fake/state/native_db /fake/state/native_db_user
  printf '[Desktop Entry]\n' > "$HOME/Desktop/Restauracao.desktop"
  : > /fake/calls.log
}

run_native_uninstaller() {
  RC=0
  printf '%s' "${STDIN_TEXT:-}" | NCOMMERCE_ENVIRONMENT_FILE=/tmp/environment-teste \
    bash "$SRC/advanced/desinstalador_nativo.sh" "$@" > "$OUT" 2>&1 || RC=$?
}

native_untouched() {
  [ -f "$HOME/NCommerce/ncommerce_api/.env.production" ] && [ -e /fake/state/native_db ] \
    && grep -q tok123 /tmp/environment-teste && grep -q chown_files /fake/state/crontab-user \
    && [ -e /etc/nginx/sites-enabled/ncommerce-api ]
}

if want desinstalar_nativo; then
  t "desinstalar_nativo: --simular lista e nao muda nada"
  native_store
  run_native_uninstaller --simular
  check "termina" [ "$RC" = "0" ] && out_has "SIMULACAO: nada foi mudado"
  check "lista copia, nginx, cron, banco, environment e pasta" bash -c 'grep -q "\[simular\] copia do banco ncommerce_api_production" /tmp/out.txt && grep -q "\[simular\] tirar o site ncommerce-api do nginx" /tmp/out.txt && grep -q "\[simular\] tirar do cron do loja" /tmp/out.txt && grep -q "\[simular\] apagar o banco" /tmp/out.txt && grep -q "\[simular\] tirar do /tmp/environment-teste" /tmp/out.txt && grep -q "\[simular\] apagar a pasta /home/loja/NCommerce" /tmp/out.txt'
  check "nao lista o site alheio" bash -c '! grep -q "site outro" /tmp/out.txt'
  check "lista o que fica (Ruby)" out_has "Ruby (rbenv"
  check "nada mudou" native_untouched
  check "sem copia, sem estado e sem DROP" bash -c '[ -z "$(find "$HOME" -maxdepth 1 -name "ncommerce-backup-desinstalacao-*")" ] && [ ! -e "$HOME/.ncommerce-desinstalacao-nativo" ] && ! grep -qE "DROP|^mysqldump" /fake/calls.log'

  t "desinstalar_nativo: cancelar nao muda nada"
  STDIN_TEXT=$'nao\n' run_native_uninstaller
  check "cancela" [ "$RC" != "0" ] && out_has "Cancelado. Nada foi removido."
  check "nada mudou e nada sobrou" bash -c '[ ! -e "$HOME/.ncommerce-desinstalacao-nativo" ]' && native_untouched

  t "desinstalar_nativo: copia falha -> nada removido; de novo, termina"
  knob dump_fail
  STDIN_TEXT=$'DESINSTALAR\n' run_native_uninstaller
  check "falha e explica" [ "$RC" != "0" ] && out_has "Nada foi removido."
  check "nada mudou" native_untouched
  unknob dump_fail
  STDIN_TEXT=$'DESINSTALAR\n' run_native_uninstaller
  check "termina" [ "$RC" = "0" ] && out_has "DESINSTALACAO CONCLUIDA"

  t "desinstalar_nativo: desinstala com copia"
  native_store
  STDIN_TEXT=$'DESINSTALAR\n' run_native_uninstaller
  b="$(backup_dir)"
  check "termina" [ "$RC" = "0" ] && out_has "DESINSTALACAO CONCLUIDA" && out_has "$b"
  check "dump completo" gz_dump_ok "$b/banco-ncommerce_api_production.sql.gz"
  check "arquivos na copia, sem node_modules e log" bash -c "tar tzf '$b/arquivos-NCommerce.tar.gz' > /tmp/lista && grep -q 'essentials/config/dados_emitente.json' /tmp/lista && ! grep -q node_modules /tmp/lista && ! grep -q 'log/production.log' /tmp/lista"
  check "configuracoes na copia" bash -c "grep -q tok123 '$b/config/env.production' && grep -q OUTRA '$b/config/environment' && [ -f '$b/config/nginx/ncommerce-api' ] && grep -q chown_files '$b/config/cron.txt'"
  check "pasta, progresso e atalho apagados" bash -c "[ ! -e '$HOME/NCommerce' ] && [ ! -e '$HOME/.ncommerce-progress' ] && [ ! -e '$HOME/Desktop/Restauracao.desktop' ] && [ ! -e '$HOME/.ncommerce-desinstalacao-nativo' ]"
  check "banco e usuario do MySQL apagados" bash -c '[ ! -e /fake/state/native_db ] && [ ! -e /fake/state/native_db_user ]'
  check "cron: so a linha do NCommerce saiu" bash -c '! grep -q chown_files /fake/state/crontab-user && grep -q /usr/bin/outro /fake/state/crontab-user'
  check "environment: so as linhas do .env sairam" bash -c '! grep -q tok123 /tmp/environment-teste && grep -qx PATH=/usr/bin /tmp/environment-teste && grep -qx OUTRA=1 /tmp/environment-teste'
  check "nginx: so os sites do NCommerce sairam" bash -c '[ ! -e /etc/nginx/sites-enabled/ncommerce-api ] && [ ! -e /etc/nginx/sites-available/ncommerce ] && [ -e /etc/nginx/sites-enabled/outro ]'

  t "desinstalar_nativo: --sem-backup"
  native_store
  STDIN_TEXT=$'DESINSTALAR\n' run_native_uninstaller --sem-backup
  check "termina sem copia" [ "$RC" = "0" ] && out_has "APAGADOS SEM COPIA" && [ -z "$(backup_dir)" ]
  check "removido" bash -c '[ ! -e "$HOME/NCommerce" ] && [ ! -e /fake/state/native_db ] && ! grep -q tok123 /tmp/environment-teste'
fi

# ---------------------------------------------------------- trocar o tipo da loja

# Loja Docker instalada, com volumes e o .env da API (o rake de mentira e tests/fake/troca_rake.sh).
store_to_change() {
  store_to_uninstall || return 1
  rm -rf "$HOME/.ncommerce-troca-tipo" "$HOME"/ncommerce-backup-troca-tipo-* /fake/state/loja /fake/state/mysql
  mkdir -p /fake/state/loja
  echo restaurant > /fake/state/loja/tipo
  printf 'NCOMMERCE_SERVER_TOKEN=tok123\nNCOMMERCE_COMMERCE_TYPE=restaurant\n' > /env/.env.production
  : > /fake/calls.log
}

run_changer() {
  RC=0
  printf '%s' "${STDIN_TEXT:-}" | TT_RETRY_WAIT_S=0 bash "$SRC/manutencao/trocar_tipo_linux.sh" "$@" > "$OUT" 2>&1 || RC=$?
}

change_backup() { find "$HOME" -maxdepth 1 -name 'ncommerce-backup-troca-tipo-*' | head -n 1; }
change_backups() { find "$HOME" -maxdepth 1 -name 'ncommerce-backup-troca-tipo-*' | wc -l; }
loja_tipo() { cat /fake/state/loja/tipo; }
nothing_changed() {
  [ "$(loja_tipo)" = "restaurant" ] && ! grep -qE "rake store:commerce_type:(prepare|reset)|mysqldump|compose stop" /fake/calls.log
}
line_of() { grep -n -- "$1" /fake/calls.log | head -n 1 | cut -d: -f1; }

if want trocar_tipo; then
  t "trocar_tipo: --simular mostra o aviso, a conferencia e o plano, sem mudar nada"
  store_to_change
  run_changer --simular --tipo comercio
  check "termina" [ "$RC" = "0" ] && out_has "SIMULACAO: nada foi mudado"
  check "aviso claro do que some e do que fica" bash -c 'grep -q "APAGA TODO O BANCO DE DADOS" /tmp/out.txt && grep -q "MESMA SENHA" /tmp/out.txt && grep -q "NUMERACAO" /tmp/out.txt'
  check "mostra o resumo da loja" out_has "Sai: 12 produtos"
  check "confere o mestre sem mudar (dry run)" called "notify_master TO=general DRY_RUN=1"
  check "mostra o plano" out_has "APAGAR e recriar o banco"
  check "nada mudou, sem copia nem estado" bash -c '[ -z "$(find "$HOME" -maxdepth 1 -name "ncommerce-backup-troca-tipo-*")" ] && [ ! -e "$HOME/.ncommerce-troca-tipo" ]' && nothing_changed

  t "trocar_tipo: caixa ou comanda aberta -> recusa e diz quais"
  store_to_change
  printf 'Caixa #3 aberto por Maria desde 23/11/2026 08:00\nComanda Mesa 4 (#88) aberta desde 23/11/2026 12:10\n' > /fake/state/loja/bloqueios
  STDIN_TEXT=$'APAGAR TUDO\n' run_changer --tipo industria
  check "recusa com 3" [ "$RC" = "3" ]
  check "diz quais" out_has "Caixa #3 aberto por Maria" && out_has "Comanda Mesa 4"
  check "nada mudou" nothing_changed
  check "sem copia e sem estado" bash -c '[ -z "$(find "$HOME" -maxdepth 1 -name "ncommerce-backup-troca-tipo-*")" ] && [ ! -e "$HOME/.ncommerce-troca-tipo/troca.estado" ]'

  t "trocar_tipo: mesmo tipo e recusado"
  store_to_change
  STDIN_TEXT=$'APAGAR TUDO\n' run_changer --tipo restaurante
  check "recusa com 4" [ "$RC" = "4" ] && out_has "ja e do tipo Restaurante" && nothing_changed

  t "trocar_tipo: resposta diferente de APAGAR TUDO cancela"
  store_to_change
  STDIN_TEXT=$'apagar tudo\n' run_changer --tipo comercio
  check "cancela" [ "$RC" = "1" ] && out_has "Cancelado. Nada foi apagado."
  check "nada mudou" nothing_changed

  t "trocar_tipo: API antiga (sem a tarefa) pede para atualizar"
  store_to_change
  knob rake_antiga
  STDIN_TEXT=$'APAGAR TUDO\n' run_changer --tipo comercio
  check "para e explica" [ "$RC" != "0" ] && out_has "Atualize o NCommerce"
  check "nada mudou" nothing_changed
  unknob rake_antiga

  t "trocar_tipo: mestre fora do ar antes de comecar -> nada muda"
  store_to_change
  knob master_dry_fail
  STDIN_TEXT=$'APAGAR TUDO\n' run_changer --tipo comercio
  check "para" [ "$RC" != "0" ] && out_has "Nada foi apagado"
  check "nada mudou" nothing_changed
  unknob master_dry_fail

  t "trocar_tipo: troca completa pelo menu (2 = comercio)"
  store_to_change
  STDIN_TEXT=$'2\nAPAGAR TUDO\n' run_changer
  b="$(change_backup)"
  check "termina" [ "$RC" = "0" ] && out_has "TIPO DA LOJA TROCADO: agora e Comercio em geral"
  check "mensagem final: copia, senha, o que configurar" bash -c "grep -q 'Copia de seguranca (banco conferido e configuracao): $b' /tmp/out.txt && grep -q 'MESMA senha' /tmp/out.txt && grep -q 'Configure de novo' /tmp/out.txt && grep -q 'Nao ha usuarios de exemplo' /tmp/out.txt && ! grep -q 'cashier123' /tmp/out.txt"
  check "loja trocada e mestre avisado" [ "$(loja_tipo)" = "general" ] && [ "$(cat /fake/state/loja/mestre)" = "general" ]
  check ".env da API com o tipo novo" grep -qx NCOMMERCE_COMMERCE_TYPE=general /env/.env.production
  check "dump completo" gz_dump_ok "$b/banco-ncommerce_api_production.sql.gz"
  check "conferencia: restaurado e contado" bash -c "cmp -s '$b/conferencia-banco-da-loja.txt' '$b/conferencia-copia-restaurada.txt' && grep -q bills '$b/conferencia-copia-restaurada.txt'"
  check "banco temporario apagado" [ ! -e /fake/state/mysql/ncommerce_troca_conferencia.counts ]
  check "o que fica, a lista das notas e o LEIA-ME na copia" bash -c "[ -s '$b/manter.json' ] && [ -f '$b/notas-fiscais.csv' ] && [ -f '$b/LEIA-ME.txt' ] && [ ! -e '$b/INCOMPLETO' ] && [ -f '$b/reset.txt' ]"
  check "configuracao e volumes na copia" bash -c "[ -f '$b/instalacao/docker-compose.yml' ] && [ -f '$b/volumes/nfce_data.tar.gz' ] && [ -f '$b/volumes/api_env.tar.gz' ] && [ ! -e '$b/volumes/mysql_data.tar.gz' ]"
  check "copia so do usuario" [ "$(stat -c %a "$b")" = "700" ]
  check "o rake recebe a copia montada em /troca" called "-v $b:/troca"
  check "ordem: parar, copiar, guardar, resetar, avisar, ligar" bash -c '
    s=$(grep -n "compose stop guard web api" /fake/calls.log | head -1 | cut -d: -f1)
    d=$(grep -n "^mysqldump" /fake/calls.log | head -1 | cut -d: -f1)
    p=$(grep -n "rake store:commerce_type:prepare" /fake/calls.log | head -1 | cut -d: -f1)
    r=$(grep -n "rake store:commerce_type:reset" /fake/calls.log | head -1 | cut -d: -f1)
    m=$(grep -n "rake store:commerce_type:notify_master KEEP_FILE" /fake/calls.log | head -1 | cut -d: -f1)
    u=$(grep -n "compose up -d$" /fake/calls.log | tail -1 | cut -d: -f1)
    [ "$s" -lt "$d" ] && [ "$d" -lt "$p" ] && [ "$p" -lt "$r" ] && [ "$r" -lt "$m" ] && [ "$m" -lt "$u" ]'
  check "pausa da guarda tirada, estado apagado, trava livre" bash -c "[ ! -e /opt/ncommerce/control/pausa ] && [ ! -e '$HOME/.ncommerce-troca-tipo' ]" && lock_free
  check "log da troca" bash -c 'ls "$HOME"/ncommerce-logs/troca-tipo-*.log >/dev/null 2>&1'

  t "trocar_tipo: copia que nao bate na conferencia -> nada apagado; de novo, termina"
  store_to_change
  knob restore_mismatch
  STDIN_TEXT=$'APAGAR TUDO\n' run_changer --tipo industria
  check "para" [ "$RC" != "0" ] && out_has "nao passou na conferencia" && out_has "Nada foi apagado"
  check "nao guardou nem resetou" bash -c '! grep -qE "rake store:commerce_type:(prepare|reset)" /fake/calls.log'
  check "loja religada" bash -c '[ "$(grep -n "compose up -d$" /fake/calls.log | tail -1 | cut -d: -f1)" -gt "$(grep -n "compose stop guard web api" /fake/calls.log | head -1 | cut -d: -f1)" ]' && [ "$(loja_tipo)" = "restaurant" ]
  unknob restore_mismatch
  STDIN_TEXT=$'APAGAR TUDO\n' run_changer --tipo industria
  check "termina" [ "$RC" = "0" ] && [ "$(loja_tipo)" = "industry" ]
  check "a copia cortada saiu: uma copia so, completa" bash -c "[ \"\$(find '$HOME' -maxdepth 1 -name 'ncommerce-backup-troca-tipo-*' | wc -l)\" = 1 ] && [ ! -e \"\$(find '$HOME' -maxdepth 1 -name 'ncommerce-backup-troca-tipo-*')/INCOMPLETO\" ]"

  t "trocar_tipo: falha depois da copia religa a loja -> a copia velha nao serve mais; de novo, copia nova"
  store_to_change
  knob prepare_fail
  STDIN_TEXT=$'APAGAR TUDO\n' run_changer --tipo comercio
  check "para sem apagar e religa" [ "$RC" != "0" ] && out_has "Nada foi apagado" && [ "$(loja_tipo)" = "restaurant" ] \
    && [ ! -e /opt/ncommerce/control/pausa ]
  unknob prepare_fail
  : > /fake/calls.log
  STDIN_TEXT=$'APAGAR TUDO\n' run_changer --tipo comercio
  check "termina com uma copia nova (a loja vendeu depois da primeira)" [ "$RC" = "0" ] && [ "$(loja_tipo)" = "general" ] \
    && [ "$(grep -c '^mysqldump' /fake/calls.log)" = "1" ] && [ "$(change_backups)" = "2" ]

  t "trocar_tipo: loja que ficou parada depois da copia -> pede de novo e nao refaz a copia"
  store_to_change
  knob prepare_fail; knob up_fail 1
  STDIN_TEXT=$'APAGAR TUDO\n' run_changer --tipo comercio
  check "para sem apagar; nao religou e diz como religar" [ "$RC" != "0" ] && out_has "Nada foi apagado" \
    && out_has "ela religa a loja sem apagar nada" && [ -e /opt/ncommerce/control/pausa ]
  unknob prepare_fail; unknob up_fail
  STDIN_TEXT=$'nao\n' run_changer
  check "ainda da para desistir" [ "$RC" = "1" ] && out_has "Cancelado. Nada foi apagado; a copia ficou em" && [ "$(loja_tipo)" = "restaurant" ]
  check "desistiu: religada e estado limpo" [ ! -e /opt/ncommerce/control/pausa ] && [ ! -e "$HOME/.ncommerce-troca-tipo/troca.estado" ]
  knob prepare_fail; knob up_fail 1
  STDIN_TEXT=$'APAGAR TUDO\n' run_changer --tipo comercio
  unknob prepare_fail; unknob up_fail
  : > /fake/calls.log
  STDIN_TEXT=$'APAGAR TUDO\n' run_changer
  check "continua e termina" [ "$RC" = "0" ] && out_has "Continuando a troca para Comercio em geral" && [ "$(loja_tipo)" = "general" ]
  check "sem copia nova" bash -c '! grep -q "^mysqldump" /fake/calls.log' && out_has "nao sera refeita"
  check "parou a loja de novo antes de guardar e apagar" bash -c '[ "$(grep -n "compose stop guard web api" /fake/calls.log | head -1 | cut -d: -f1)" -lt "$(grep -n "rake store:commerce_type:prepare" /fake/calls.log | head -1 | cut -d: -f1)" ]'

  t "trocar_tipo: banco mudou depois da copia (loja ligada por fora) -> copia nova antes de apagar"
  store_to_change
  knob prepare_fail; knob up_fail 1
  STDIN_TEXT=$'APAGAR TUDO\n' run_changer --tipo comercio
  unknob prepare_fail; unknob up_fail
  printf 'bills\t31\nproducts\t12\nusers\t5\n' > /fake/state/mysql/ncommerce_api_production.counts
  : > /fake/calls.log
  STDIN_TEXT=$'APAGAR TUDO\n' run_changer
  check "percebe e copia de novo" [ "$RC" = "0" ] && out_has "O banco mudou depois da copia" \
    && [ "$(grep -c '^mysqldump' /fake/calls.log)" = "1" ] && [ "$(change_backups)" = "2" ] && [ "$(loja_tipo)" = "general" ]

  t "trocar_tipo: reset interrompido no meio -> loja fica parada; de novo, termina sem refazer a copia"
  store_to_change
  knob reset_fail 1
  STDIN_TEXT=$'APAGAR TUDO\n' run_changer --tipo industria
  check "falha" [ "$RC" != "0" ] && out_has "ja comecou a ser apagado"
  check "banco no meio, loja parada (pausa)" bash -c '[ "$(cat /fake/state/loja/banco)" = meio ] && [ -e /opt/ncommerce/control/pausa ]'
  check "nao religou a loja com o banco pela metade" bash -c 'r=$(grep -n "rake store:commerce_type:reset" /fake/calls.log | tail -1 | cut -d: -f1); ! sed -n "$r,\$p" /fake/calls.log | grep -q "compose up -d$"'
  run_changer --tipo restaurante
  check "outro tipo com troca em andamento e recusado" [ "$RC" = "2" ] && out_has "ja esta em andamento"
  STDIN_TEXT="" run_changer
  check "continua sem pedir de novo e termina" [ "$RC" = "0" ] && out_has "parou no meio do reset" && [ "$(loja_tipo)" = "industry" ] && [ "$(cat /fake/state/loja/banco)" = ok ]
  check "uma copia so, dois resets" [ "$(grep -c '^mysqldump' /fake/calls.log)" = "1" ] && [ "$(wc -l < /fake/state/loja/resets)" = "2" ] && [ "$(change_backups)" = "1" ]
  check "religada" [ ! -e /opt/ncommerce/control/pausa ]

  t "trocar_tipo: mestre fora do ar depois do reset -> troca vale; rodar de novo avisa"
  store_to_change
  knob master_fail 3
  STDIN_TEXT=$'APAGAR TUDO\n' run_changer --tipo comercio
  check "termina com aviso" [ "$RC" = "0" ] && out_has "FALTA avisar o NCommerce (mestre)" && [ "$(loja_tipo)" = "general" ]
  check "loja ligada, estado guardado" bash -c "[ ! -e /opt/ncommerce/control/pausa ] && [ -f '$HOME/.ncommerce-troca-tipo/troca.estado' ] && [ ! -e /fake/state/loja/mestre ]"
  STDIN_TEXT="" run_changer
  check "de novo: avisa e limpa" [ "$RC" = "0" ] && [ "$(cat /fake/state/loja/mestre)" = "general" ] && [ ! -e "$HOME/.ncommerce-troca-tipo" ]
  check "sem reset nem copia nova" [ "$(wc -l < /fake/state/loja/resets)" = "1" ] && [ "$(grep -c '^mysqldump' /fake/calls.log)" = "1" ]

  t "trocar_tipo: nao roda com o instalador ou uma atualizacao aberta; copia dentro da instalacao recusada"
  store_to_change
  ( exec 9>>"$HOME/.ncommerce-docker/instalador.lock"; flock 9; sleep 3 ) &
  holder=$!
  sleep 0.5
  STDIN_TEXT=$'APAGAR TUDO\n' run_changer --tipo comercio
  check "recusa" [ "$RC" = "2" ] && out_has "esta rodando agora" && nothing_changed
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
  run_changer --tipo comercio --backup-em /opt/ncommerce/x
  check "copia dentro da instalacao" [ "$RC" != "0" ] && out_has "nao pode ficar dentro de /opt/ncommerce"
fi

# Instalacao nativa com o Rakefile da API (o bundle de mentira chama o rake de mentira).
native_store_to_change() {
  native_store
  rm -rf "$HOME/.ncommerce-troca-tipo" "$HOME"/ncommerce-backup-troca-tipo-* /fake/state/loja /fake/state/mysql
  mkdir -p /fake/state/loja
  echo restaurant > /fake/state/loja/tipo
  touch "$HOME/NCommerce/ncommerce_api/Rakefile"
  echo NCOMMERCE_COMMERCE_TYPE=restaurant >> "$HOME/NCommerce/ncommerce_api/.env.production"
  echo NCOMMERCE_COMMERCE_TYPE=restaurant >> /tmp/environment-teste
  : > /fake/calls.log
}

run_native_changer() {
  RC=0
  printf '%s' "${STDIN_TEXT:-}" | TT_RETRY_WAIT_S=0 NCOMMERCE_ENVIRONMENT_FILE=/tmp/environment-teste \
    bash "$SRC/manutencao/trocar_tipo_nativo.sh" "$@" > "$OUT" 2>&1 || RC=$?
}

if want trocar_tipo_nativo; then
  t "trocar_tipo_nativo: --simular nao muda nada"
  native_store_to_change
  run_native_changer --simular --tipo industria
  check "termina" [ "$RC" = "0" ] && out_has "SIMULACAO: nada foi mudado" && out_has "Sai: 12 produtos"
  check "nada mudou" bash -c '! grep -qE "rake store:commerce_type:(prepare|reset)|mysqldump|systemctl stop" /fake/calls.log' && [ "$(loja_tipo)" = restaurant ]

  t "trocar_tipo_nativo: troca completa"
  native_store_to_change
  STDIN_TEXT=$'APAGAR TUDO\n' run_native_changer --tipo industria
  b="$(change_backup)"
  check "termina" [ "$RC" = "0" ] && out_has "TIPO DA LOJA TROCADO: agora e Industria" && [ "$(loja_tipo)" = industry ]
  check "rake na pasta da API, com o manter.json na copia" bash -c "grep -q 'bundle exec rake store:commerce_type:reset KEEP_FILE=$b/manter.json' /fake/calls.log && grep -q 'em $HOME/NCommerce/ncommerce_api' /fake/calls.log"
  check "dump e conferencia" bash -c "gzip -dc '$b/banco-ncommerce_api_production.sql.gz' | grep -q 'Dump completed' && cmp -s '$b/conferencia-banco-da-loja.txt' '$b/conferencia-copia-restaurada.txt'"
  check "configuracao na copia" bash -c "grep -q tok123 '$b/config/env.production' && grep -q OUTRA '$b/config/environment'"
  check ".env.production e /etc/environment com o tipo novo" bash -c "grep -qx NCOMMERCE_COMMERCE_TYPE=industry '$HOME/NCommerce/ncommerce_api/.env.production' && grep -qx NCOMMERCE_COMMERCE_TYPE=industry /tmp/environment-teste && grep -qx OUTRA=1 /tmp/environment-teste"
  check "nginx parado antes da copia e ligado no fim" bash -c '[ "$(grep -n "systemctl stop nginx" /fake/calls.log | head -1 | cut -d: -f1)" -lt "$(grep -n "^mysqldump" /fake/calls.log | head -1 | cut -d: -f1)" ] && [ "$(grep -n "systemctl start nginx" /fake/calls.log | tail -1 | cut -d: -f1)" -gt "$(grep -n "rake store:commerce_type:reset" /fake/calls.log | head -1 | cut -d: -f1)" ]'
  check "estado apagado" [ ! -e "$HOME/.ncommerce-troca-tipo" ]

  t "trocar_tipo_nativo: reset interrompido continua"
  native_store_to_change
  knob reset_fail 1
  STDIN_TEXT=$'APAGAR TUDO\n' run_native_changer --tipo comercio
  check "falha no meio" [ "$RC" != "0" ] && out_has "ja comecou a ser apagado"
  STDIN_TEXT="" run_native_changer
  check "termina sem copia nova" [ "$RC" = "0" ] && [ "$(loja_tipo)" = general ] && [ "$(grep -c '^mysqldump' /fake/calls.log)" = "1" ]
fi

summary
