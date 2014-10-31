#!/bin/bash

###################################################
## Automatic Apache2 virtual host install script ##
## Jim Cronqvist <jim.cronqvist@gmail.com>       ##
## Updated: 2014-05-06                           ##
###################################################


# Abort if not root.
if [ "$(id -u)" -ne "0" ] ; then
echo "This script needs to be ran from a user with root permissions.";
    exit 1;
fi

# Check for 2 passed arguments, otherwise abort.
if [ $# -lt 2 ] ; then
    echo "You have not passed the correct number of arguments. This script should be used with the following syntax:"
    echo "sudo bash vhost.sh example.com /var/www/example.com"
    echo "or with SSL:"
    echo "sudo bash vhost.sh example.com /var/www/example.com --ssl"
    echo ""
    exit 1;
fi

SSL=0
if echo $* | grep -e " --ssl" -q ; then
    SSL=1
fi

if [ $SSL -eq 1 ]; then
    virtual_host="<VirtualHost *:443>
        ServerName $1
        #ServerAlias $1
        DocumentRoot $2
        <Directory $2>
            Options -Indexes +FollowSymLinks
            AllowOverride All
            Order allow,deny
            Allow from all
        </Directory>
        
        SSLEngine on
        SSLCertificateFile /etc/apache2/ssl/ssl_certificate.crt
        SSLCertificateKeyFile /etc/apache2/ssl/$1.key
	    SSLCertificateChainFile /etc/apache2/ssl/IntermediateCA.crt
        <FilesMatch "\.(cgi|shtml|phtml|php)$">
            SSLOptions +StdEnvVars
        </FilesMatch>
        <Directory /usr/lib/cgi-bin>
            SSLOptions +StdEnvVars
        </Directory>
        BrowserMatch "MSIE [2-6]" \
            nokeepalive ssl-unclean-shutdown \
            downgrade-1.0 force-response-1.0
        BrowserMatch "MSIE [17-9]" ssl-unclean-shutdown
    </VirtualHost>"
else
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
fi

if [ $SSL -eq 1 ]; then
    sudo bash -c "echo '$virtual_host' > /etc/apache2/sites-available/$1.ssl.conf"
    echo "The site $1.ssl.conf has been created."
    cat /etc/apache2/sites-available/$1.ssl.conf
    a2ensite $1.ssl.conf
else
    sudo bash -c "echo '$virtual_host' > /etc/apache2/sites-available/$1.conf"
    echo "The site $1.conf has been created."
    cat /etc/apache2/sites-available/$1.conf
    a2ensite $1.conf
fi

service apache2 reload
