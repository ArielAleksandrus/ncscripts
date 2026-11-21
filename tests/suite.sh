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

summary
