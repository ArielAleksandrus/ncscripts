# Create, migrate and seed database
cd ~/NCommerce/ncommerce_api && bundle exec rake db:create db:migrate db:seed
sudo systemctl reload nginx

USERNAME="$(whoami)"

# Create the cron jobs
(crontab -l 2>/dev/null; echo "@reboot /home/${USERNAME}/NCommerce/ncommerce_api/vendor/scripts/start_ngrok.sh /home/${USERNAME}/NCommerce/ncommerce_api | at now + 2 minutes\n@monthly /home/${USERNAME}/NCommerce/ncommerce_api/vendor/scripts/backup_nfce.sh") | crontab -
sudo su <<EOF
(crontab -l 2>/dev/null; echo -e "* * * * * /home/${USERNAME}/NCommerce/ncommerce_api/vendor/scripts/chown_files.sh /home/${USERNAME}/NCommerce/ncommerce_api\n* * * * * ( sleep 30; /home/${USERNAME}/NCommerce/ncommerce_api/vendor/scripts/chown_files.sh /home/${USERNAME}/NCommerce/ncommerce_api )\n30 18 * * 2 /home/${USERNAME}/NCommerce/ncommerce_api/vendor/scripts/backup.sh /home/${USERNAME}/NCommerce/ncommerce_api\n30 17 * * 4 /home/${USERNAME}/NCommerce/ncommerce_api/vendor/scripts/backup.sh /home/${USERNAME}/NCommerce/ncommerce_api\n30 18 * * 6 /home/${USERNAME}/NCommerce/ncommerce_api/vendor/scripts/backup.sh /home/${USERNAME}/NCommerce/ncommerce_api") | crontab -
EOF

sudo service cron reload
