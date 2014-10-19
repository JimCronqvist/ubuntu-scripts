Ubuntu shell scripts
==============

A collection of small shell scripts for Ubuntu. These are some of my scripts for provisining a new VMware Ubuntu machine for PHP development and some others good to have scripts. Feel free to use and fork.

## Install script
install.sh
`sudo bash install.sh`

## Set up a virtual host in apache2
vhost.sh
`sudo bash vhost.sh example.com /var/www/example.com`

## Deploy a private repository from Github and set up SSH-Keys
github.sh
`bash github.sh`

## List all cronjobs
list_cronjobs.sh
`bash list_cronjobs.sh`

## Update remote servers
update.sh
`bash update.sh user@server1.com user@server2.com`

## Restart remote servers
reboot.sh
`bash reboot.sh user@server1.com user@server2.com`

## Copy a certificate (pub-key) to remote servers
`bash distribute_certificate.sh www.server1.com www.server2.com`

## Tuning apache2
apache.sh
`sudo bash apache.sh`

## Empty swap usage
swap2ram.sh
`sudo bash swap2ram.sh`

## Zabbix template for Ubuntu Server OS
- Information about available normal packages updates
- Information about available security packages updates
- Information about if a reboot is required
- Information about if VMware tools is running
