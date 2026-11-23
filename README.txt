INSTALADOR NCOMMERCE
====================

O NCommerce roda em Docker. Ha um instalador para cada sistema:

  - Windows: InstaladorWindows.bat (duplo clique; ele pede administrador)
  - Linux:   ./instalador_linux.sh  (no terminal, SEM sudo)


1. ANTES DE COMECAR
-------------------

Codigo de instalacao
  O instalador pede um codigo de 8 letras e numeros. O suporte gera o codigo no
  ncommerce_manager, na pagina da empresa (botao "Novo codigo").
  Se o instalador foi baixado em ncommerce.app/instalar, o codigo ja vem no
  arquivo codigo-instalacao.txt e nao precisa ser digitado.
  O codigo vale 48 horas e serve para um computador so. Se a instalacao parar no
  meio, rode o instalador de novo no mesmo computador: o codigo continua valendo.
  No Windows, ligar o WSL2 pode reiniciar o computador. Quando o codigo esta no
  codigo-instalacao.txt, ao ligar de novo o mestre manda um WhatsApp pedindo
  para abrir o InstaladorWindows.bat outra vez.

Internet
  O computador precisa de internet durante a instalacao e para atualizar.


2. REQUISITOS MINIMOS
---------------------

                   Windows                         Linux
  Sistema          Windows 10 22H2 ou Windows 11   Ubuntu 20.04 ou mais novo
  Processador      4 threads                       4 threads
  Memoria (RAM)    6 GB                            4 GB

A memoria e a nominal, a que vem escrita na especificacao do computador. O
Windows e o Linux mostram um pouco menos porque o firmware e o video integrado
reservam uma parte; o instalador ja desconta isso.

No Windows a memoria e maior porque o Docker Desktop roda uma maquina virtual.

A velocidade (clock) do processador nao e verificada: um processador com 4
threads raramente e lento demais para o sistema.

O Windows 10 esta sem atualizacoes de seguranca da Microsoft desde outubro de
2025. Ele funciona, mas prefira o Windows 11.


3. INSTALACAO FORA DOS REQUISITOS (BYPASS)
------------------------------------------

!!! O NCommerce NAO da suporte oficial a instalacoes feitas com bypass. !!!
Lentidao, travamentos e falhas de impressao nesses computadores nao sao
atendidos pelo suporte. Use por sua conta e risco.

Windows: abra o Prompt de Comando, entre na pasta do instalador e rode:

  InstaladorWindows.bat -IgnorarRequisitos

Linux: no terminal, na pasta do instalador:

  ./instalador_linux.sh --ignorar-requisitos

O instalador mostra o que falta e segue mesmo assim.

No Linux, Ubuntu abaixo do 20.04 nao tem o Docker Compose v2 nos pacotes, e o
instalador pode nao conseguir instalar o Docker.


4. IMPRESSORAS
--------------

Impressoras suportadas oficialmente:
  - Bematech MP-4200 TH
  - Elgin i9
  - Epson TM-T20

Como podem ser ligadas:
  - USB: apenas UMA impressora USB, ligada no proprio computador onde o
    NCommerce foi instalado (o servidor).
  - Rede: impressoras com cabo de rede ou Wi-Fi proprios, com IP fixo. Pode
    haver varias.

NAO suportado:
  - Impressora compartilhada: impressora USB instalada em OUTRO computador e
    compartilhada pela rede. Se aquele computador desligar, travar ou mudar de
    nome, a impressao para, e o NCommerce nao tem como resolver.
  - Impressoras fora da lista acima. Podem funcionar, mas sem garantia.

Windows: o instalador oferece o driver da impressora USB. Escolha o modelo e a
porta USB na tela do driver. A impressora tem que estar ligada e plugada.
O instalador compartilha essa impressora para o NCommerce sozinho (isso e
interno, no proprio servidor, e nao e o "compartilhamento" nao suportado acima).

Linux: a impressora USB e cadastrada no CUPS do NCommerce, e nao no CUPS do
Ubuntu.

As impressoras (USB e de rede) sao cadastradas no CUPS do NCommerce, aberto pelo
botao "Impressoras SISTEMA" na pagina de impressoras do NCommerce. No Linux o
endereco tambem aparece no fim da instalacao (normalmente http://127.0.0.1:631,
ou :6631 se a 631 estiver ocupada).


5. DEPOIS DA INSTALACAO
-----------------------

Atualizar o NCommerce
  - Windows: C:\NCommerce\ncommerce-docker-update.bat
  - Linux:   /opt/ncommerce/update.sh (ha um atalho na Area de Trabalho)

Acesso remoto
  O instalador configura o AnyDesk e o tunel de suporte. O ID do AnyDesk e a
  chave do tunel vao sozinhos para o ncommerce_manager.

Recomendado
  - IP fixo no computador servidor.
  - Nao desligar o servidor durante o expediente.


6. DESINSTALAR
-------------

Use o desinstalador da mesma pasta do instalador:

  - Windows: DesinstaladorWindows.bat (duplo clique; ele pede administrador)
  - Linux:   ./desinstalador_linux.sh  (no terminal, SEM sudo)
  - Instalacao nativa (sem Docker, Ubuntu ou WSL): ./advanced/desinstalador_nativo.sh

Ele mostra tudo o que vai remover e pede para digitar DESINSTALAR. Qualquer
outra resposta cancela sem mudar nada.

Antes de remover, ele guarda uma COPIA da loja numa pasta fora da instalacao e
diz onde ficou: o banco de dados (dump), o .env e as configuracoes, o
certificado e as notas, as impressoras, as imagens e os documentos. Se a copia
falhar, nada e removido. A copia tem senhas e o certificado digital: guarde em
lugar seguro.
  Linux:   ~/ncommerce-backup-desinstalacao-<data>  (outra pasta: --backup-em PASTA)
  Windows: C:\NCommerce-backup-desinstalacao-<data>  (outra pasta ou pen drive: -PastaBackup E:\)

Remove so o que o instalador criou: containers, volumes e imagens do NCommerce,
servicos e tarefas agendadas do NCommerce, a pasta da instalacao, os atalhos e
os ajustes que ele fez no sistema. Docker, AnyDesk, SSH, WSL e o resto ficam: o
instalador nao registra se ja existiam antes. No fim aparece a lista do que
ficou, para remover a mao se quiser.

Pode ser interrompido e rodado de novo: continua de onde parou e nao refaz a
copia.

Opcoes:
  Linux:   --simular     so mostra o que faria (nao muda nada, nao pede confirmacao)
           --sem-backup  remove SEM a copia (os dados da loja se perdem)
  Windows: -Simular e -SemBackup, do mesmo jeito (ex.: DesinstaladorWindows.bat -Simular)

Antes de desinstalar uma loja em uso, fale com o suporte NCommerce.


7. PASTA advanced/
------------------

Uso do suporte. Tem o instalador sem Docker (instalador_nativo.sh), a
instalacao nativa dentro do WSL do Windows e os scripts antigos (.old). Veja
advanced/readme.txt.

A instalacao nativa (sem Docker, inclusive no WSL) so tem suporte quando a
equipe NCommerce autoriza explicitamente. Ela sera substituida em breve pela
instalacao Docker.
