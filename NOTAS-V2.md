# ncscripts - NCommerce 2.0 (branch v2)

Objetivo: instaladores e atualizacoes que aguentam interrupcao (janela fechada,
PC desligado, queda de rede): idempotentes, retomaveis, com trava, log e
veredito, sem deixar a loja pior que antes (baixa e confere tudo antes de
trocar; volta ao estado anterior quando a troca falha).

Nada aqui foi publicado: o GitHub `master` (de onde as lojas puxam scripts) nao
mudou. Nomes de arquivos, servicos, tarefas e a conversa com o mestre sao os
mesmos de antes.

## Como testar

    tests/run.sh             Linux: instalador, update.sh, lib e guarda (container sem rede)
    tests/run.sh volta       so um grupo (lib, codigo, interromper, nativo, atualizar, volta, guard...)
    tests/run-windows.sh     Windows: PSScriptAnalyzer (sintaxe/comandos do PowerShell 5.1,
                             so ASCII) + Pester no PowerShell 7 do Linux, com docker/curl de mentira
    tests/run-windows.sh update

A primeira execucao do run-windows.sh precisa de internet (monta a imagem com
Pester e PSScriptAnalyzer). Os testes nunca usam o Docker de verdade da maquina
(o docker dentro do container e o de mentira de tests/fake/bin).

Ultima rodada (2026-11-20, noite): Linux 259 conferencias + guarda 29, 0 erradas;
Windows: analise 11 arquivos 0 problemas, Pester 77 testes, 0 falhas.

## Feito

Linux
- Instalador interrompivel e retomavel (trava flock, estado em
  ~/.ncommerce-docker/instalacao.estado, log em ~/ncommerce-logs, veredito final,
  atalho de retomada no login).
- update.sh so troca depois de baixar tudo; copia do banco quando a versao muda
  migrations; volta para a anterior se nao liga; Ctrl+C e queda tratados.
- update-host.sh: pacote inteiro conferido (bash -n, sh -n, compose config) antes de trocar.
- guard.sh: religa container parado, termina troca interrompida, recarrega a si mesmo.
- Volta ao estado anterior no instalador (nova nesta rodada): numa loja que ja
  funcionava, o instalador guarda compose, .env e imagens em uso em
  /opt/ncommerce/control/antes-da-instalacao. Se a execucao falhar e a API nao
  responder, volta tudo, religa e diz o resultado. Download cortado no
  --reinstalar devolve a etiqueta latest. Versao nova que muda o banco no
  --reinstalar guarda copia antes. Atualizacao morta no download (update.state
  "pull") e desfeita pelo instalador. Copia com mais de 2 dias e descartada; o
  update.sh apaga a copia quando atualiza.
- Bug corrigido: a primeira atualizacao de uma loja (sem nenhum
  atualizacao-*.log) parava em silencio no `ls | tail` com pipefail.

Windows
- instalador-lib.ps1: log, trava (Mutex Global\NCommerceInstalador, o Windows
  solta se o processo morrer), estado em C:\ProgramData\NCommerce\instalacao.estado,
  escrita atomica, .env UTF-8 sem BOM, download que continua, conferencia do zip
  de backup (ZipCrypto) e ajudantes de docker/compose/dump/update.state.
- instalador_windows.ps1 (trabalho do agente anterior, validado e commitado):
  10 etapas retomaveis, tarefa "NCommerce Instalador Retomar" no logon, aviso por
  WhatsApp depois do reinicio, modo reparo sem codigo. Nesta rodada: volta ao
  estado anterior igual ao Linux, compose conferido (docker compose config)
  antes de entrar no lugar, copia do banco no -Reinstalar, atualizacao
  interrompida desfeita antes do compose up, instalador-lib.ps1 copiado para C:\NCommerce.
- ncommerce-update.ps1 (novo): porta do update.sh (trava, log em
  C:\NCommerce\logs\atualizacao-*.log, scripts novos primeiro e segue com o
  atualizador novo, download inteiro antes de trocar com NCOMMERCE_TAG=latest so
  no processo, copia do banco, volta para a anterior se nao liga, espera o
  veredito da guarda, control\update.state no formato do Linux).
  -Recuperar: chamado no logon pelo ncommerce-docker-startup.bat; desfaz
  download pela metade (etiqueta latest), conserta .env vazio e tag keep- que sumiu.
- ncommerce-docker-update.bat: chama o ncommerce-update.ps1; sem ele, o jeito antigo.
- ncommerce-docker-startup.bat: -Recuperar antes do compose up; com "pull"
  (atalho antigo) busca o ncommerce-update.ps1 e passa a atualizacao para ele.
- update-host.ps1: zip inteiro, cada .ps1 pelo parser e o compose pelo
  `docker compose config` antes de trocar qualquer arquivo; troca atomica; nao
  depende da lib (loja antiga ainda nao tem).
- rollback.bat: instrucoes de troca manual quando a guarda esta parada.

Passagem das lojas antigas (Windows): o update.bat antigo roda o update-host.ps1
antigo (copia o update-host.ps1 novo, o startup.bat novo e o update.bat.new),
depois chama o startup.bat NOVO com "pull", que roda o update-host.ps1 novo
(traz ncommerce-update.ps1 e instalador-lib.ps1) e entrega a atualizacao ao
ncommerce-update.ps1 -SemScripts. O bloco do "pull" e um bloco so do cmd, para o
arquivo poder ser trocado enquanto roda. Isso NAO foi rodado num Windows.

## Nao verificado (precisa de maquina de teste)

- Nada do Windows rodou num Windows: os .bat nao foram executados; WSL, Docker
  Desktop, tarefas agendadas, firewall, SSH, AnyDesk, assinatura Authenticode,
  QuickEdit/botao X, Ctrl+C real no console, Mutex Global entre sessoes.
  O que foi testado roda no PowerShell 7 do Linux; o alvo e o 5.1 (so a analise
  estatica cobre a compatibilidade).
- Ctrl+C no meio do ncommerce-update.ps1 (o finally) so foi lido, nao testado;
  o processo morto (janela fechada) foi testado.
- A volta ao estado anterior nao desfaz o banco: uma versao nova que ja migrou
  o banco e voltou fica com o banco migrado (a copia antes-de-atualizar fica em
  backups/ para o suporte).
- Linux: so no container com docker/sudo/apt de mentira.

## Roteiro de teste manual (maquina de teste, nunca uma loja)

Preparar o pacote do v2 (no PC de desenvolvimento):

    git -C ncscripts archive --format=zip --prefix=ncscripts-master/ -o ncscripts-v2.zip v2
    git -C ncscripts archive --format=tar.gz --prefix=ncscripts-master/ -o ncscripts-v2.tar.gz v2

Para forcar um download grande sem publicar versao nova, tire so a etiqueta da
imagem em uso (o container continua rodando): `docker image rm
registry.ncommerce.app:5050/ncommerce/api:latest`. O proximo pull baixa ~1 GB.

Linux (Ubuntu 22.04/24.04, codigo de instalacao de uma empresa de teste)
1. Extrair o zip, `./instalador_linux.sh`. Na etapa 7 (download) fechar o
   terminal. Rodar de novo: continua; `~/.ncommerce-docker/instalacao.estado`
   tem as etapas; `~/ncommerce-logs/instalacao-*.log` tem as duas execucoes.
2. Abrir duas vezes ao mesmo tempo: a segunda diz que ja esta aberto.
3. Desligar a maquina (botao) na etapa 9 (restauracao). Ligar e entrar: o
   atalho de retomada abre o instalador e termina; o banco e restaurado uma vez.
4. Atualizar com o v2: servir o tar.gz (`python3 -m http.server` na pasta) e
   rodar `NCOMMERCE_SCRIPTS_URL=http://IP:8000/ncscripts-v2.tar.gz /opt/ncommerce/update.sh`.
   Com a etiqueta api:latest tirada, puxar o cabo de rede no meio do download:
   veredito "A LOJA CONTINUA NA VERSAO EM QUE ESTAVA"; `docker image inspect -f
   {{.Id}} .../api:latest` igual ao `docker inspect -f {{.Image}}` do container
   da api; sem /opt/ncommerce/control/update.state. Religar a rede e atualizar de
   novo: "ATUALIZACAO CONCLUIDA".
5. Mesma coisa com Ctrl+C no download, e com kill -9 no meio do "Trocando para
   a versao nova" (a guarda religa em ate ~1 min; atualizar de novo termina).
6. Volta do instalador: na pasta extraida, trocar em docker/docker-compose.yml
   `"3000:3000"` por `"22:3000"` (a 22 e do SSH) e rodar o instalador na loja
   instalada: deve aparecer "A LOJA VOLTOU PARA COMO ESTAVA ANTES DESTA
   INSTALACAO" e o sistema abrir. Desfazer a troca e rodar de novo: termina ok e
   some /opt/ncommerce/control/antes-da-instalacao.
7. Loja com os scripts antigos (instalada pelo master): trocar a linha URL= do
   /opt/ncommerce/update-host.sh pelo endereco do tar.gz do v2 e usar o atalho
   Atualizar: os scripts novos entram e a atualizacao termina.
8. `./rollback.sh lista` e `./rollback.sh` (volta para a anterior boa).

Windows (10 22H2 ou 11; VM serve se tiver virtualizacao aninhada)
1. Extrair o zip do v2 (com codigo-instalacao.txt) e abrir InstaladorWindows.bat.
   No Windows recem-formatado ele pede reinicio para o WSL2: depois de entrar,
   a tarefa "NCommerce Instalador Retomar" abre o instalador sozinha.
2. Na etapa 7, encerrar o powershell.exe pelo Gerenciador de Tarefas (equivale
   ao X). Abrir de novo: continua. Conferir C:\ProgramData\NCommerce\instalacao.estado
   e C:\NCommerce\logs\instalacao-*.log.
3. Clicar dentro da janela durante o download: nao pode congelar (QuickEdit
   desligado). O X da janela some no console classico (no Windows Terminal nao).
4. Reset da VM na etapa 9: ao entrar, retoma e termina; restaura uma vez.
5. Duas janelas do instalador: a segunda espera ~30 s e diz que ja esta aberto.
6. Atualizar com o v2: num cmd, `set NCOMMERCE_SCRIPTS_ZIP_URL=file:///C:/teste/ncscripts-v2.zip`
   e `C:\NCommerce\ncommerce-docker-update.bat`. Com a etiqueta api:latest tirada,
   encerrar o powershell no meio do download. Sair e entrar no Windows (a tarefa
   de logon roda o -Recuperar): a loja sobe na versao de antes, a etiqueta
   api:latest volta para a imagem do container e some C:\NCommerce\control\update.state.
   Atualizar de novo: "ATUALIZACAO CONCLUIDA", log em C:\NCommerce\logs\atualizacao-*.log.
7. Passagem de loja antiga: numa loja instalada pelo master, trocar o $ZipUrl do
   C:\NCommerce\update-host.ps1 pelo file:///C:/teste/ncscripts-v2.zip e usar o
   atalho Atualizar NCommerce (o .bat antigo). Esperado: scripts novos copiados,
   C:\NCommerce\ncommerce-update.ps1 e instalador-lib.ps1 presentes, a atualizacao
   termina com veredito, e na proxima vez o ncommerce-docker-update.bat ja e o novo.
8. Volta do instalador: trocar `"3000:3000"` por `"22:3000"` no
   docker\docker-compose.yml da pasta extraida e rodar o instalador na loja
   instalada: "A LOJA VOLTOU PARA COMO ESTAVA". Desfazer e rodar de novo: ok.
9. rollback.bat lista / rollback.bat; parar o guard (`docker compose stop guard`)
   e rodar de novo: mostra a troca manual.

## Falta / ideias

- Rodar o roteiro acima numa maquina de teste antes de publicar no master.
- Publicar = merge no master do GitHub (decisao do Ariel).
