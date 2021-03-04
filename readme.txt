Depois do Ubuntu 20 instalado, deixar o password salvo para comando sudo:

sudo ls

Colocar o password, e então:

./setup1.sh

Em seguida, configurar o Dropbox:
~/.dropbox-dist/dropboxd

Iniciar o dropbox quando o sistema iniciar:
https://askubuntu.com/a/557818/323337

Após isto, fechar o terminal e abrir um novo, deixar o sudo ativo com "sudo ls" novamente, adicionar chave SSH no bitbucket e executar:

./setup2.sh

Após isto, usar o comando "ngrok authtoken <token do ngrok>"
Então, pode-se usar o comando

./setup3.sh <token do ncommerce aqui> <username do linux aqui>

O ubuntu deverá reiniciar. Confira o arquivo ~/.ngrok2/ngrok.yml e o ~/NCommerce/ncommerce_api/.env.production

Agora, resta criar o banco de dados e as tarefas cron

./setup4.sh
