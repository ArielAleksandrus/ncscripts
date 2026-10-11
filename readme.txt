Depois do Ubuntu 20 instalado, baixe e execute os seguintes scripts:

https://github.com/ArielAleksandrus/ncscripts/archive/refs/heads/master.zip

ATENÇÃO: antes de todos os scripts, dê um "sudo ls" para deixar o "sudo" permitido, mas JAMAIS use o sudo junto com o script
EXEMPLO:
				- errado: "sudo ./script..."
				- CORRETO: "sudo ls"
				           "./script..."

./setup1.sh

Após isto, fechar o terminal e abrir um novo, deixar o sudo ativo com "sudo ls" novamente

./setup2.sh

Em seguida, configurar o Dropbox:
~/.dropbox-dist/dropboxd

!!!DESMARCAR PASTAS DE TERCEIROS NA SINCRONIZACAO!!!
Abrir o app Dropbox, ir em Preferences, Sync, Select Folders

Após isto, fechar o terminal e abrir um novo, deixar o sudo ativo com "sudo ls" novamente.

!!! ADICIONAR CHAVE SSH no bitbucket e no servidor Nlabs !!! e executar:

./setup3.sh <username do linux aqui>

Então, pode-se usar o comando  (requer "sudo ls" antes)

./setup4.sh <token do ncommerce aqui> <username do linux aqui>

O ubuntu deverá reiniciar. Confira o arquivo ~/.ngrok2/ngrok.yml e o ~/NCommerce/ncommerce_api/.env.production

!!!! INSERIR A VARIAVEL COMPUTER_PASSWORD NO .env.production E NO /etc/environment !!!!
Agora, resta criar o banco de dados e as tarefas cron (requer "sudo ls" antes)

./setup5.sh <usuario do linux>

Após isto, realizar os seguintes procedimentos:
  1. colocar ip fixo na máquina do cliente
  2. instalar impressoras (ou restaurar o backup — passo abaixo)
  3. adicionar extensão ncommerce no Google Chrome (extensões -> modo desenvolvedor ON -> carregar sem compactar /home/<usuario>/NCommerce/sefaz-chrome-extension -> Fixar no navegador)
  4. reiniciar o pc e testar o acesso remoto
  5. setar configurações de nota fiscal (exclusivo NCommerce)
  6. instalar certificado no navegador (exclusivo ncommerce)

PARA RESTAURAR UM BACKUP (PC novo / Ubuntu fresco):
  1. Instalar tudo com os scripts acima (Dropbox logado na conta da empresa)
  2. Esperar o Dropbox baixar ncommerce.zip  (ou copiar o zip para ~/Downloads)
  3. Na área de trabalho, abrir o atalho "Restauracao"
  4. Suporte informa a senha do zip (6 primeiros caracteres do token NCommerce)
  5. O técnico informa a senha sudo DESTE computador
  6. O script restaura banco, .env, impressoras, NFC-e e documentos
     (usuario linux, senha sudo e caminhos ficam os desta máquina)

PARA TABLETS DE AUTOATENDIMENTO:
  1. Para cada tablet, habilitar a flag "Insecure origins treated as secure"
  A flag pode ser habilitada neste link em cada tablet:
    chrome://flags/#unsafely-treat-insecure-origin-as-secure

  verificar o link:
    https://medium.com/@Carmichaelize/enabling-the-microphone-camera-in-chrome-for-local-unsecure-origins-9c90c3149339

  2. Adicionar os possíveis IP's do servidor com a devida porta (no caso, 4200). Por exemplo:
    http://192.168.1.172:4200
