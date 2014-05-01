#!/bin/bash

# Abort if not root.
if [ "$(id -u)" -ne "0" ] ; then
echo "This script needs to be ran from a user with root permissions.";
    exit 1;
fi

# Check for 2 passed arguments, otherwise abort.
if [ $# != 2 ] ; then
    echo "You have not passed the correct number of arguments. This script should be used with the following syntax:"
    echo "sudo bash vhost.sh example.com /var/www/example.com"
    echo ""
    exit 1;
fi

virtual_host="<VirtualHost *:80>
    ServerName $1
    #ServerAlias $1
    DocumentRoot $2
    <Directory $2>
        Options -Indexes +FollowSymLinks
        AllowOverride All
        Order allow,deny
        Allow from all
    </Directory>
</VirtualHost>"

sudo bash -c "echo '$virtual_host' > /etc/apache2/sites-available/$1.conf"

echo "The site $1.conf has been created."
cat /etc/apache2/sites-available/$1.conf

a2ensite $1.conf
service apache2 reload
