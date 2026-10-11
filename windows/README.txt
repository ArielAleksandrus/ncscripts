Instalação NCommerce em um PC Windows (WSL2 + Ubuntu 24.04)
============================================================

O ERP (ncommerce_api, ncommerce, nfce) continua sendo Linux. Estes
scripts só preparam o Windows para parecer um Ubuntu na LAN, e então
chamam o mesmo instalador_unico.sh dos PCs Ubuntu.

O QUE O WINDOWS FAZ SOZINHO
---------------------------
1. Clique com o botão direito em install-ncommerce-wsl.bat -> Executar
   como administrador  (ou dê dois cliques; ele pede admin sozinho).
2. Liga WSL + Virtual Machine Platform (pode pedir um reboot — rode o
   .bat de novo depois).
3. Instala Ubuntu-24.04 NA MESMA JANELA: crie usuário e senha Linux e,
   quando aparecer o prompt ($), digite  exit  para o script continuar.
   Se o Ubuntu ficar sem usuário (entrando como root), o script pede um
   nome e cria o usuário. Liga systemd (nginx/cron/mysql no "boot").
4. No Windows 11 (22H2+): liga networkingMode=mirrored no .wslconfig
   e libera 3000/4200 no firewall do Hyper-V, para tablets na LAN
   falarem com :3000 e :4200 no IP do PC.
5. No Windows 10 / NAT: ncommerce-wsl-startup.bat faz netsh portproxy.
6. Copia ncommerce-wsl-startup.bat para C:\NCommerce\wsl e cria a
   tarefa "NCommerce WSL Startup" no logon do Windows. A tarefa deixa
   um wsl.exe oculto rodando (sleep infinity) para o WSL não desligar
   sozinho. Pode apagar a pasta baixada depois; não apague C:\NCommerce.
7. Copia esta pasta ncscripts para ~/ncscripts dentro do Ubuntu e abre
   um shell lá.

O QUE AINDA É MANUAL (igual Ubuntu físico)
------------------------------------------
  ./instalador_unico.sh
    - token NCommerce
    - usuário Linux
    - colar a chave SSH no Bitbucket
    - login Dropbox da empresa
  Depois, como no readme.txt da raiz:
    - TeamViewer/AnyDesk: instalar NO WINDOWS (o instalador pula no WSL)
    - IP fixo no Windows
    - impressoras (USB no WSL é limitado — ver abaixo)
    - extensão Chrome sefaz
    - certificado NFC-e
    - auto-logon do Windows (netplwiz), senão após queda de energia o
      WSL não sobe até alguém logar

TESTE ANTES DE ENTREGAR
-----------------------
  Reinicie o Windows, faça logon e NÃO abra o Ubuntu. Espere 5 minutos e:
    - PowerShell: wsl -l -v   -> Ubuntu-24.04 deve estar "Running"
    - num tablet/celular: http://<IP-do-Windows>:4200 deve abrir
  No Windows 10 não há interface gráfica Linux: o login do Dropbox e o
  atalho "Restauracao" (zenity) não aparecem; o Dropbox mostra um link
  no terminal para logar.

IMPRESSORAS / NFC-e NO WSL
--------------------------
CUPS e os drivers Elgin/Bematech instalam DENTRO do Ubuntu. Impressora
USB ligada no Windows muitas vezes NÃO aparece no WSL sem usbipd-win.
Impressora de rede (IP) costuma funcionar. Teste NFC-e neste PC antes
de deixar o restaurante.

PORTAS
------
  3000  ncommerce_api (Passenger/nginx)
  4200  ncommerce (front)

Acesso na LAN: http://<IP-do-Windows>:4200
