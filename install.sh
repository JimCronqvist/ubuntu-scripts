#!/bin/bash

#############################################
##        Automatic install script         ##
## Jim Cronqvist <jim.cronqvist@gmail.com> ##
##          Updated: 2016-02-25            ##
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

APT_UPDATED=0

# APT GET UPDATE function
AptGetUpdate () {
    if [ $APT_UPDATED -eq 0 ]; then
        apt-get update
        APT_UPDATED=1
    fi
}


while :
do
    #clear
    cat<<EOF
==================================
install.sh by Jim Cronqvist
----------------------------------
(1) Install all available updates
(2) Cleaning (apt-get, /tmp, /boot)
(3) Basic installation and set-up (recommended)
(4) Configure settings
(5) Enable monitoring (SNMP & Zabbix)
(6) Install guest tools
(7) Install web tools (git, npm, uglifyjs)
(8) Install Apache2
(9) Install PHP 5 and Composer
(10) Install a database (MySQL/Percona Server/Percona XtraDB Cluster)
(11) Install keepalived
(12) Install haproxy
(13) Install Varnish cache
(0) Quit
----------------------------------
EOF

    read -p "Please enter your choice: " REPLY
    case "$REPLY" in
        
        "1") #Install all available updates
            
            # Get the latest package lists and install all available upgrades
            AptGetUpdate
            sudo apt-get dist-upgrade -y
            
            # Update the VMware tools in case it is not running but it has been installed earlier. For example in case a kernel has been updated.
            grep -s -q 'Vendor: VMware' /proc/scsi/scsi && ! test -e /var/run/vmtoolsd.pid && sudo /usr/bin/vmware-config-tools.pl -d
            
            ;;
            
        "2") # Cleaning (apt-get, /tmp, /boot)
            
            # Clean after apt-get
            apt-get autoremove -y
            apt-get clean
            apt-get autoclean
            
            # Empty the temp folder.
            if Confirm "Do you want to clean out the /tmp folder?" Y; then
                sudo rm -r /tmp/*
            fi
            
            # Clean the /boot partition
            if Confirm "Do you want to uninstall all old linux kernels to clear the /boot partition?" N; then
                echo "Currently installed linux kernel: "$(uname -r)
                echo "The following kernels will be uninstalled:"
                dpkg -l linux-{image,headers}-* | awk '/^ii/{print $2}' | grep -v $(uname -r | cut -f1,2 -d"-") | egrep --color '[0-9]+\.[0-9]+\.[0-9]+'
                if Confirm "Are you sure you want to continue?" N; then
                    # Remove all kernels that is installed but not the newest that is currently used
                    dpkg -l linux-{image,headers}-* | awk '/^ii/{print $2}' | grep -v $(uname -r | cut -f1,2 -d"-") | egrep --color '[0-9]+\.[0-9]+\.[0-9]+' | xargs sudo apt-get -y purge
                    echo ""
                    echo "All old kernels has been removed."
                fi
            fi
            ;;
            
        "3") #Basic installation and set-up (recommended)
            
            # Set backspace character to ^H
            echo 'stty erase ^H' >> ~/.bashrc
            
            # Check if the language is Swedish and ask if the user want to change to english in that case.
            if grep -q 'LANG="sv_SE.utf8"' /etc/default/locale; then
                echo "We have noticed that the server default language is not English."
                if Confirm "Do you want to change the server language to english?" Y; then
                    sudo cp /etc/default/locale /etc/default/locale.old
                    sudo update-locale LANG=en_US.UTF-8
                    # Activate the change without a reboot or logout/login.
                    . /etc/default/locale
                fi
            fi
            
            # To get the latest package lists
            #apt-get update
            AptGetUpdate
            
            # Install ssh
            apt-get install ssh -y
            
            # Install pkexec
            sudo apt-get install policykit-1 -y
            
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
            
            # Install tree
            sudo apt-get install tree -y
            
            # Install acct
            sudo apt-get install acct -y
            
            # Install pv
            sudo apt-get install pv -y
            
            # Install a MTA
            if Confirm "Do you want to install a MTA?" Y; then
                sudo apt-get install sendmail mailutils -y
            fi
            
            # Install rkhunter to find any potential root kits
            if Confirm "Do you want to install rkhunter" Y; then
                sudo apt-get install rkhunter chkrootkit -y
                #rkhunter --check
            fi            
            ;;
            
        "4") # Configure settings
            
            # Change default limits in Ubuntu.	
            if Confirm "Do you want to change the open files limit to 8192 instead of 1024? (Needed for powerful web servers)" Y; then
                sudo bash -c "echo '* soft nofile 8192' >> /etc/security/limits.conf"
                sudo bash -c "echo '* hard nofile 8192' >> /etc/security/limits.conf"
            fi
            
            if Confirm "Do you want to change the default TCP settings for a high-performance web-server?" Y; then
                sudo bash -c "echo 'net.ipv4.ip_local_port_range = 1024 65535' >> /etc/sysctl.conf"
                # Decrease TIME_WAIT seconds to 30 seconds instead of the default of 60 seconds.
                sudo bash -c "echo 'net.ipv4.tcp_fin_timeout = 30' >> /etc/sysctl.conf"
                # Disable this one for now, might be dangerous in production environments.
                sudo bash -c "echo '#net.ipv4.tcp_tw_reuse = 1' >> /etc/sysctl.conf"
                # Apply the changes
                sudo sysctl -p
            fi
            
            if Confirm "Do you want to change the dirty_ratio in order to avoid long io waits and force the OS to flush the IO changes to the disk array more often? Normally good for VMs with much RAM." N; then
                sudo bash -c "echo 'vm.dirty_background_ratio = 5' >> /etc/sysctl.conf"
                sudo bash -c "echo 'vm.dirty_ratio = 10' >> /etc/sysctl.conf"
                # Apply the changes
                sudo sysctl -p
            fi
            ;;
            
        "5") # Enable monitoring (SNMP & Zabbix)
            
            # Install SNMP
            if Confirm "Do you want to install snmpd (will be open for everyone as default)?" N; then
                sudo apt-get install snmpd -y
                sudo mv /etc/snmp/snmpd.conf /etc/snmp/snmpd.conf.org
                sudo touch /etc/snmp/snmpd.conf
                sudo bash -c "echo 'rocommunity public' >> /etc/snmp/snmpd.conf"
                sudo bash -c "echo 'sysLocation \"Unknown\"' >> /etc/snmp/snmpd.conf"
                sudo bash -c "echo 'sysContact JimCronqvist' >> /etc/snmp/snmpd.conf"
                sudo bash -c "echo 'SNMPDOPTS=\"-LS 0-4 d -Lf /dev/null -u snmp -I -smux -p /var/run/snmpd.pid -c /etc/snmp/snmpd.conf\"' >> /etc/default/snmpd"
                sudo service snmpd restart
            fi
            
            if Confirm "Do you want to install zabbix agent (For monitoring)?" N; then
                # Install zabbix agent
                sudo apt-get install zabbix-agent -y
                sudo bash -c "echo 'Server=zabbix.'`dnsdomainname` >> /etc/zabbix/zabbix_agentd.conf.d/zabbix.conf"
                sudo bash -c "echo 'ServerActive=zabbix.'`dnsdomainname` >> /etc/zabbix/zabbix_agentd.conf.d/zabbix.conf"
                sudo bash -c "echo 'Hostname='`hostname --fqdn` >> /etc/zabbix/zabbix_agentd.conf.d/zabbix.conf"
                sudo bash -c "echo 'EnableRemoteCommands=1' >> /etc/zabbix/zabbix_agentd.conf.d/zabbix.conf"
                sudo service zabbix-agent restart
            fi
            ;;
            
        "6") # Install guest tools
            
            # VMware tools
            if grep -s -q 'Vendor: VMware' /proc/scsi/scsi ; then
                if [ $(lsb_release -r | awk '{print $2}' | xargs printf "%.0f") -ge 14 ]; then
                    echo "14.04 or higher, use open-vm-tools"
                    AptGetUpdate
                    sudo apt-get install open-vm-tools -y
                else
                    if Confirm "Is the vmware tools installer mounted?" Y; then
                        sudo apt-get install gcc make linux-headers-`uname -r` -y
                        sudo mount /dev/cdrom /mnt
                        sudo tar xvfz /mnt/VMwareTools-*.tar.gz -C /tmp/
                        sudo perl /tmp/vmware-tools-distrib/vmware-install.pl -d
                        sudo umount -f /mnt
                    fi
                fi
                if Confirm "Do you want to add a symlink for the www folder?" Y; then
                    sudo mv /var/www /var/www_old 2>/dev/null
                    sudo ln -s /mnt/hgfs/www /var/www
                fi
            fi
            
            # Virtualbox guest additions
            if grep -s -q 'Vendor: VBOX' /proc/scsi/scsi ; then
                AptGetUpdate
                sudo apt-get install virtualbox-guest-dkms -y
                
                if Confirm "Do you want to add a second NIC?" Y; then
                    sudo bash -c "echo '' >> /etc/network/interfaces"
                    sudo bash -c "echo '# Virtualbox Host-only adapter' >> /etc/network/interfaces"
                    sudo bash -c "echo 'auto eth1' >> /etc/network/interfaces"
                    sudo bash -c "echo 'iface eth1 inet dhcp' >> /etc/network/interfaces"
                    sudo /etc/init.d/networking restart
                    sudo ifconfig eth1 up
                    sudo dhclient eth1
                fi
                
                sudo adduser www-data vboxsf
                sudo adduser ubuntu vboxsf
                
                if Confirm "Do you want to add a symlink for the www folder?" Y; then
                    sudo ln -s /media/sf_www /var/www
                fi
            fi
            ;;
            
        "7") # Install web tools (git, npm, uglifyjs)
            
            # Install Git
            apt-get install git -y
            #apt-get install gitk -y
            
            # Install npm & uglifyjs
            sudo apt-get install nodejs -y
            sudo apt-get install npm -y
            sudo npm install -g uglify-js
            ;;
            
        "8") # Install Apache2
            
            # Install apache2 & php
            sudo apt-get install apache2 -y
            sudo a2dismod mpm_event
            sudo a2enmod mpm_prefork
            
            # Enable mod_rewrite & mod_headers
            sudo a2enmod rewrite
            sudo a2enmod headers
            # Disable mod_autoindex to prevent directory listing
            sudo a2dismod autoindex 
            
            # Cleaning (Ubuntu 13.10 and less)
            rm /var/www/index.html
            # Cleaning (Ubuntu 14.04)
            rm /var/www/html/index.html
            rmdir /var/www/html
            
            # Set 777 permissions on the www folder.
            chmod 0777 /var/www
            
            # Turn off the default Apache2 sites directly
            sudo a2dissite default
            sudo a2dissite 000-default
            sudo a2dissite 000-default.conf
            
            sudo service apache2 restart
            
            # Install SSL for Apache2
            if Confirm "Do you want to enable SSL (https) for apache2?" N; then
                sudo a2enmod ssl
                sudo sed -i 's/SSLProtocol all/SSLProtocol All -SSLv2 -SSLv3/g' /etc/apache2/mods-available/ssl.conf
                sudo service apache2 restart
            fi
            ;;
            
        "9") # Install PHP 5 and Composer
            
            sudo apt-get install php5 -y
            sudo apt-get install php5-ldap -y
            sudo apt-get install mysql-client -y
            sudo apt-get install php5-mysqlnd -y
            sudo apt-get install php5-curl -y
            sudo apt-get install php5-xsl -y
            sudo apt-get install php5-gd -y
            sudo apt-get install imagemagick -y
            sudo apt-get install php5-imagick -y
            sudo apt-get install php5-json -y
            sudo apt-get install php5-intl -y
            sudo apt-get install memcached php5-memcached -y
            
            # Install php5 mcrypt
            sudo apt-get install php5-mcrypt -y
            sudo ln -s /etc/php5/conf.d/mcrypt.ini /etc/php5/mods-available/mcrypt.ini
            sudo php5enmod mcrypt
            
            # Disable PHP ubuntu default garbage collector.
            rm /etc/cron.d/php5
            
            # Download composer
            curl -sS https://getcomposer.org/installer | php && sudo mv composer.phar /usr/local/bin/composer
            
            # Install xdebug.
            if Confirm "Do you want to install xdebug?" N; then
            sudo apt-get install php5-xdebug -y
            sudo bash -c "cat <<EOF >> /etc/php5/apache2/php.ini
            
[xdebug]
xdebug.remote_enable=1
xdebug.remote_connect_back=1
xdebug.idekey=ubuntu
EOF"
            fi
            ;;
            
        "10") # Install a database (MySQL/Percona Server/Percona XtraDB Cluster)
            
            if ! grep "repo.percona.com" /etc/apt/sources.list > /dev/null; then
                # Adding repositories from Percona.
                sudo apt-get install lsb-release -y
                if sudo apt-key adv --keyserver keys.gnupg.net --recv-keys 1C4CBDCDCD2EFD2A | grep "key 1C4CBDCDCD2EFD2A not found on keyserver" ; then
                        echo "Error: Can't find the key for the Percona repository, please try to run this scrpt again.";
                        exit;
                fi
                sudo echo "" >> /etc/apt/sources.list
                sudo echo "deb http://repo.percona.com/apt `sudo lsb_release -cs` main" >> /etc/apt/sources.list
                sudo echo "deb-src http://repo.percona.com/apt `lsb_release -cs` main" >> /etc/apt/sources.list
                APT_UPDATED=0
                AptGetUpdate
            fi
            
            # Install Xtrabackup
            sudo apt-get install percona-xtrabackup -y
            
            if Confirm "Do you want to install Oracle MySQL Server?" N; then
                # Optional installation of Mysql Server. Will trigger a question.
                sudo apt-get install mysql-server -y
                # To be able to connect to mysql remotely, add a "#" in /etc/mysql/my.cnf before "bind-address = 127.0.0.1".
                # Make sure that the user that you connect with has the setting: host = %.
            fi
            
            if Confirm "Do you want to install Percona Server 5.6?" N; then
                sudo apt-get install dialog -y
                sudo apt-get install percona-server-common-5.6 -y
                sudo apt-get autoremove -y
                sudo apt-get install percona-server-client-5.6 -y
                sudo apt-get install percona-server-server-5.6 -y
                sudo apt-get install percona-toolkit -y
            fi
            
            if Confirm "Do you want to install Percona XtraDB Cluster 5.5? (cluster version)" N; then
                sudo apt-get install percona-xtradb-cluster-server-5.5 percona-xtradb-cluster-client-5.5 percona-xtradb-cluster-galera-2.x -y
                sudo apt-get install percona-toolkit -y
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
            ;;
            
        "11") # Install keepalived
            
            sudo apt-get install keepalived
            ;;
            
        "12") # Install ha-proxy
            
            add-apt-repository ppa:vbernat/haproxy-1.6
            APT_UPDATED=0
            AptGetUpdate
            apt-get install haproxy
            ;;
            
        "13") # Install Varnish cache
            
            
            
            ;;
            
        "0")
            exit
            ;;
        * )
            echo "Invalid option, please try again."
            ;;
    esac
done
