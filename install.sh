#!/bin/bash

#############################################
##        Automatic install script         ##
## Jim Cronqvist <jim.cronqvist@gmail.com> ##
##          Updated: 2014-04-22            ##
#############################################

#############################################
# Make sure that you are root or run with root permissions.
#############################################

# Abort if not root.
if [ "$(id -u)" -ne "0" ] ; then
    echo "This script needs to be ran from a user with root permissions.";
    exit 1;
fi


# Confirm function that will be used later for yes and no questions.
Confirm () {
  while true; do
    if [ "${2:-}" = "Y" ]; then
        prompt="Y/n"
        default=Y
    elif [ "${2:-}" = "N" ]; then
        prompt="y/N"
        default=N
    else
        prompt="y/n"
        default=
    fi

    read -p "${1:-Are you sure?} [$prompt]: " reply

    #Default?
    if [ -z "$reply" ]; then
        reply=$default
    fi

    case ${reply:-$2} in
        [Yy]* ) return 0;;
        [Nn]* ) return 1;;
    esac
done
}


# Install all the latest updates/upgrades.
if Confirm "Do you want to install all available updates in Ubuntu?" Y; then
	# To get the latest package lists
	apt-get update
	# Run all updates
	apt-get upgrade -y 
fi

# Start the basic installation.
if Confirm "Do you want to run the basic install script?" Y; then

	# To get the latest package lists
	apt-get update

	# Install ssh
	apt-get install ssh -y

	# Install lrzsz to use with Xshell ssh client, allows you to transfer files by dropping them in the console.
	sudo apt-get install lrzsz -y

	# Set vim as the default text-editor.
	export EDITOR="vi"

	# Install vim
	apt-get install vim -y

	# Install dialog
	sudo apt-get install dialog -y

	# Install htop
	apt-get install htop -y
	
	# Install iftop
	apt-get install iftop -y

	# Traceroute
	apt-get install traceroute -y
	
	# Install tools for mounting a samba/cifs storage.
	sudo apt-get install cifs-utils samba samba-common -y

	# Install NTP server
	sudo apt-get install ntp -y

	# Install curl
	sudo apt-get install curl -y

	# Install iostat
	sudo apt-get install sysstat -y

	# Install SNMP
	if Confirm "Do you want to install snmpd (will be open for everyone as default)?" N; then
		sudo apt-get install snmpd -y
		sudo mv /etc/snmp/snmpd.conf /etc/snmp/snmpd.conf.org
		sudo touch /etc/snmp/snmpd.conf
		sudo bash -c "echo 'rocommunity public' >> /etc/snmp/snmpd.conf"
		sudo bash -c "echo 'sysLocation \"Unknown\"' >> /etc/snmp/snmpd.conf"
		sudo bash -c "echo 'sysContact JimCronqvist' >> /etc/snmp/snmpd.conf"
		sudo bash -c "echo 'SNMPDOPTS=\"-Lsd -Lf /dev/null -u snmp -I -smux -p /var/run/snmpd.pid -c /etc/snmp/snmpd.conf\"' >> /etc/default/snmpd"
		sudo service snmpd restart
	fi

	if Confirm "Do you want to install zabbix agent (For monitoring)?" N; then
		# Install zabbix agent
		sudo apt-get install zabbix-agent -y
		sudo bash -c "echo 'Server=zabbix.'`dnsdomainname`',127.0.0.1' >> /etc/zabbix/zabbix_agentd.conf.d/zabbix.conf"
		sudo bash -c "echo 'Hostname='`hostname` >> /etc/zabbix/zabbix_agentd.conf.d/zabbix.conf"
		sudo service zabbix-agent restart
	fi
fi


# Start the installation of a web server
if Confirm "Do you want to install apache with php?" Y; then
	# Install apache & php
	apt-get install apache2 -y
	apt-get install php5 -y
	apt-get install php5-ldap -y
	apt-get install mysql-client-5.5 -y
	apt-get install php5-mysqlnd -y
	apt-get install php5-curl -y
	apt-get install php5-xsl -y
	apt-get install php5-gd -y
	apt-get install imagemagick -y
	apt-get install php5-imagick -y
	sudo apt-get install php5-json -y
	sudo apt-get install php5-intl -y
	sudo apt-get install memcached php5-memcached -y

	# Install php5 mcrypt
	sudo apt-get install php5-mcrypt -y
	sudo ln -s /etc/php5/conf.d/mcrypt.ini /etc/php5/mods-available/mcrypt.ini
	sudo php5enmod mcrypt
	
	# Enable mod_rewrite
	a2enmod rewrite
	service apache2 restart

	# Enable mod_headers
	sudo a2enmod headers
	sudo service apache2 restart
	
	# Disable autoindex to prevent directory listing
	sudo a2dismod autoindex
	sudo service apache2 restart
	
	# Install Git
	apt-get install git -y
	#apt-get install gitk -y

	#Disable PHP ubuntu garbage collector.
	rm /etc/cron.d/php5

	# Cleaning (Ubuntu 13.10 and less)
	rm /var/www/index.html
	# Cleaning (Ubuntu 14.04)
	rm /var/www/html/index.html
	rmdir /var/www/html

	# Set 777 permissions on thw www folder.
	chmod 0777 /var/www

	# Turn off the default Apache2 sites directly
	sudo a2dissite default
	sudo a2dissite 000-default.conf
	sudo service apache2 reload

	# Download composer
	curl -sS https://getcomposer.org/installer | php && sudo mv composer.phar /usr/local/bin/composer

	# Install phpdocumentor
	sudo apt-get install php-pear -y
	apt-get install graphviz -y
	pear channel-discover pear.phpdoc.org
	pear install phpdoc/phpDocumentor

	# Change default limits in Ubuntu.	
	if Confirm "Do you want to change the open files limit to 8192 instead of 1024? (Needed for powerful web servers)" Y; then
		sudo bash -c "echo '* soft nofile 8192' >> /etc/security/limits.conf"
		sudo bash -c "echo '* hard nofile 8192' >> /etc/security/limits.conf"
	fi
	
	if Confirm "Do you want to change the default TCP settings for a high-performance web-server?" Y; then
		sudo bash -c "echo 'net.ipv4.ip_local_port_range = 1024 65535' >> /etc/sysctl.conf"
		# Disable this one for now, might be dangerous in production environments.
		sudo bash -c "echo '#net.ipv4.tcp_tw_reuse = 1' >> /etc/sysctl.conf"
	fi

fi


if Confirm "Do you want to install a database (you will be given different choices if yes)?" N; then

	if ! grep "repo.percona.com" /etc/apt/sources.list > /dev/null; then
		# Adding repositories from Percona.
		sudo apt-get install lsb-release -y
		if sudo gpg --keyserver  hkp://keys.gnupg.net:80 --recv-keys 1C4CBDCDCD2EFD2A | grep "key 1C4CBDCDCD2EFD2A not found on keyserver" ; then
			echo "Error: Can't find the key for the Percona repository, please try to run this scrpt again.";
			exit;
		fi
		sudo gpg -a --export CD2EFD2A | sudo apt-key add -
		sudo echo "" >> /etc/apt/sources.list
		sudo echo "deb http://repo.percona.com/apt `sudo lsb_release -cs` main" >> /etc/apt/sources.list
		sudo echo "deb-src http://repo.percona.com/apt `lsb_release -cs` main" >> /etc/apt/sources.list
	fi
	
	if Confirm "Do you want to install xtrabackup from Percona?" Y; then
		# Install Xtrabackup
		sudo apt-get update
		sudo apt-get install percona-xtrabackup -y
	fi

	if Confirm "Do you want to install Oracle MySQL Server?" N; then
		# Optional installation of Mysql Server. Will trigger a question.
		sudo apt-get install mysql-server -y
		# To be able to connect to mysql remotely, add a "#" in /etc/mysql/my.cnf before "bind-address = 127.0.0.1".
		# Make sure that the user that you connect with has the setting: host = %.
	fi

	if Confirm "Do you want to install Percona MySQL server 5.6? (not cluster version)" N; then
		sudo apt-get install dialog -y
		sudo apt-get install percona-server-common-5.6 -y
		sudo apt-get autoremove -y
		sudo apt-get install percona-server-client-5.6 -y
		sudo apt-get install percona-server-server-5.6 -y
		sudo apt-get install percona-toolkit -y
	fi

	if Confirm "Do you want to install Percona XtraDB server 5.5? (cluster version)" N; then
		sudo apt-get install percona-xtradb-cluster-server-5.5 percona-xtradb-cluster-client-5.5 percona-xtradb-cluster-galera-2.x -y
		sudo apt-get install percona-toolkit -y
		sudo apt-get install pv -y
	fi

	if Confirm "Do you want to install Galera arbitrator to be used with Percona XtraDB Cluster?" N; then
		sudo apt-get install percona-xtradb-cluster-garbd-3.x -y
		sudo mv /etc/default/percona-xtradb-cluster-garbd-3.x /etc/default/garb
		# Run the following command to configure garbd later: sudo vi /etc/default/garb
		# After that run the following command to start the service: sudo service percona-xtradb-cluster-garbd-3.x restart

		# Setting: socket.checksum needs to be set when garbd is running 3.x and the cluster 2.x.
		# To test run: sudo garbd -a gcomm://1.2.3.4:4567,1.2.3.5:4567 -g "MySQL_PXC_Cluster" -o "socket.checksum = 1;" -l "/var/log/garbd.log" -d
		# To run as a deamon: sudo garbd -a gcomm://1.2.3.4:4567,1.2.3.5:4567 -g "MySQL_PXC_Cluster" -o "socket.checksum = 1;" -l "/var/log/garbd.log" -d
	fi
fi


if Confirm "Do you want to install VMware tools? (Make sure that the image is mounted first)" N; then
    # Install VMware tools.
    sudo apt-get install gcc make linux-headers-`uname -r` -y
    sudo mount /dev/cdrom /mnt
    sudo tar xvfz /mnt/VMwareTools-*.tar.gz -C /tmp/
    sudo perl /tmp/vmware-tools-distrib/vmware-install.pl -d
    sudo umount -f /mnt
fi


if Confirm "Do you want to install webmin?" N; then
    # Install webmin
    echo "" >> /etc/apt/sources.list
    echo "deb http://download.webmin.com/download/repository sarge contrib" >> /etc/apt/sources.list
    echo "deb http://webmin.mirror.somersettechsolutions.co.uk/repository sarge contrib " >> /etc/apt/sources.list
    cd /root
    wget http://www.webmin.com/jcameron-key.asc
    apt-key add jcameron-key.asc 
    apt-get update
    apt-get install webmin -y
fi


if Confirm "Is this a local development environment? (install samba+xdebug)" N; then
    # Install samba for easy development.
    sudo apt-get install samba samba-common -y
    sudo bash -c "echo 'security = user' >> /etc/samba/smb.conf"
    sudo bash -c "echo '[www]' >> /etc/samba/smb.conf"
    sudo bash -c "echo '    comment = www' >> /etc/samba/smb.conf"
    sudo bash -c "echo '    path = /var/www' >> /etc/samba/smb.conf"
    sudo bash -c "echo '    valid users = ubuntu' >> /etc/samba/smb.conf"
    sudo bash -c "echo '    public = no' >> /etc/samba/smb.conf"
    sudo bash -c "echo '    writable = yes' >> /etc/samba/smb.conf"
    sudo smbpasswd -a ubuntu
    sudo service smbd restart

    # Install xdebug.
    sudo apt-get install php5-xdebug -y

    sudo bash -c "cat <<EOF >> /etc/php5/apache2/php.ini

[xdebug]
xdebug.remote_enable=1
xdebug.remote_connect_back=1
xdebug.idekey=ubuntu
EOF"

fi

# Clean after this script.
apt-get autoremove -y
apt-get clean
apt-get autoclean
