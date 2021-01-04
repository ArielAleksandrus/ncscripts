Depois do Ubuntu 20 instalado, deixar o password salvo para comando sudo:

sudo ls

Colocar o password, e então:

./setup1.sh

Após isto, fechar o terminal e abrir um novo, adicionar chave SSH no bitbucket e executar:

./setup2.sh

Após isto, usar o comando "ngrok authtoken <token do ngrok>"
Então, pode-se usar o comando

./setup3.sh <token do ncommerce aqui>

O ubuntu deverá reiniciar. Confira o arquivo ~/.ngrok2/ngrok.yml e o ~/NCommerce/ncommerce_api/.env.production

Agora, resta criar o banco de dados e as tarefas cron

./setup4.sh