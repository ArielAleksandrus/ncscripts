#!/bin/bash

# Prompt for password to run sudo
PASSWORD=$(zenity --password)

# Give permission to cups's printer configuration, so we can backup it and restore it.
echo $PASSWORD | sudo -S chmod a+rw /etc/cups/printers.conf
