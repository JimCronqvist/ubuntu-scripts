Ubuntu shell scripts
==============

A collection of small shell scripts for Ubuntu. These are some of my scripts for provisining a new VMware Ubuntu machine for PHP development. Feel free to use and fork.

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

## Zabbix template for Ubuntu Server OS
- Information about available normal packages updates
- Information about available security packages updates
- Information about if a reboot is required
- Information about if VMware tools is running
