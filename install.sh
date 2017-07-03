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

REPLY=0
INTERACTIVE=1
while getopts ":o:" opt; do
  case $opt in
    o )  REPLY="$OPTARG"; INTERACTIVE=0;;
    \? ) echo "Invalid option -$OPTARG" >&2; exit 1;;
    : )  echo "Option -$OPTARG requires an argument." >&2; exit 1;;
  esac
done

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
            default=N
        fi
            
        if [ $INTERACTIVE == 1 ]; then
            read -p "${1:-Are you sure?} [$prompt]: " reply
            #Default?
            if [ -z "$reply" ]; then
                reply=$default
            fi
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

DownloadNewConfigFile () {
    sudo cp $1{,.backup.`date +%Y-%m-%d_%H.%M.%S`}
    read -e -i "$2" -p "Please enter the path where you want to make the clone: " CONFIG_FILE
    wget -O $1 $CONFIG_FILE
    sed -i 's/example.com/'$(hostname --fqdn)'/g' $1
}


while :
do
    # Only ask for a choice if we are in interactive mode.
    if [ $INTERACTIVE == 1 ]; then

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
(7) Install web tools (git, npm, yarn, uglifyjs, hugo)
(8) Install Apache2
(9) Install PHP 5 and Composer
(10) Install PHP 7 and Composer
(11) Install a database (MySQL/Percona Server/Percona XtraDB Cluster)
(12) Install keepalived
(13) Install haproxy
(14) Install Varnish cache
(15) Install Redis
(16) Install FTP
(0) Quit
----------------------------------
EOF

       read -p "Please enter your choice: " REPLY
    fi

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
            
            # Turn off ec2 instances automatic renaming of the hostname at each reboot
            sudo sed -i 's/preserve_hostname: false/preserve_hostname: true/' /etc/cloud/cloud.cfg
            
            # To get the latest package lists
            #apt-get update
            AptGetUpdate
            
            # Install ssh
            apt-get install ssh -y
            
            # Install pkexec
            sudo apt-get install policykit-1 -y
            
            # LVM - Amazon EC2 instances does not come with this by default
            sudo apt-get install lvm2 -y
            
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
            
            # Install iotop
            apt-get install iotop -y
            
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
            
            # Install sysdig
            sudo apt-get install sysdig -y
            
            # Install tree
            sudo apt-get install tree -y
            
            # Install ncdu
            sudo apt-get install ncdu -y
            
            # Install acct
            sudo apt-get install acct -y
            
            # Install pv
            sudo apt-get install pv -y
            
            # Install dos2unix
            sudo apt-get install dos2unix -y
            
            # Install debconf-utils
            sudo apt-get install debconf-utils -y
            
            # Install required software for add-apt-repository
            sudo apt-get install software-properties-common -y
            
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
            
            # Change the port apache2 is listening on.
            if Confirm "Do you want to change the port that apache2 is listening on?" N; then
                read -e -i "80" -p "Please enter the old port: " OLD_PORT
                read -e -i "8080" -p "Please enter the old port: " NEW_PORT
                
                sed -i 's/:'$OLD_PORT'>/:'$NEW_PORT'>/g' /etc/apache2/sites-enabled/*
                sed -i 's/Listen '$OLD_PORT'$/Listen '$NEW_PORT'/g' /etc/apache2/ports.conf
                sudo service apache2 restart
            fi
			
            # Change default limits in Ubuntu.	
            if Confirm "Do you want to change the open files limit to 8192 instead of 1024? (Needed for powerful web servers)" Y; then
                sudo bash -c "echo '* soft nofile 8192' >> /etc/security/limits.conf"
                sudo bash -c "echo '* hard nofile 8192' >> /etc/security/limits.conf"
            fi
            
            # Change default limits in Ubuntu.	
            if Confirm "Do you want to change the open files limit to 100000 instead of 1024? (Needed for VERY powerful web servers)" Y; then
                sudo bash -c "echo '* soft nofile 100000' >> /etc/security/limits.conf"
                sudo bash -c "echo '* hard nofile 100000' >> /etc/security/limits.conf"
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
            
            if Confirm "Do you want to change the maximum shared memory to 128 MB?" N; then
                sudo bash -c "echo '#128 MB' >> /etc/sysctl.d/10-shared-memory.conf"
                sudo bash -c "echo 'kernel.shmmax=134217728' >> /etc/sysctl.d/10-shared-memory.conf"
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
		sudo adduser zabbix adm
                sudo bash -c "echo 'Server=zabbix.'`dnsdomainname` >> /etc/zabbix/zabbix_agentd.conf.d/zabbix.conf"
                sudo bash -c "echo 'ServerActive=zabbix.'`dnsdomainname` >> /etc/zabbix/zabbix_agentd.conf.d/zabbix.conf"
                sudo bash -c "echo 'Hostname='`hostname --fqdn` >> /etc/zabbix/zabbix_agentd.conf.d/zabbix.conf"
                sudo bash -c "echo 'EnableRemoteCommands=1' >> /etc/zabbix/zabbix_agentd.conf.d/zabbix.conf"
                sudo service zabbix-agent restart
                
                if Confirm "Do you want to install Percona Zabbix Templates?" N; then
                    sudo apt-get install percona-zabbix-templates -y
                    sudo cp /var/lib/zabbix/percona/templates/userparameter_percona_mysql.conf /etc/zabbix/zabbix_agentd.conf.d/
                    read -e -i "" -p "Please enter the root MySQL password: " PASS
                    
                    echo "<?php" >> /var/lib/zabbix/percona/scripts/ss_get_mysql_stats.php.cnf
                    echo "\$mysql_user = 'root';" >> /var/lib/zabbix/percona/scripts/ss_get_mysql_stats.php.cnf
                    echo "\$mysql_pass = '$PASS';" >> /var/lib/zabbix/percona/scripts/ss_get_mysql_stats.php.cnf
                    
                    # Change the home directory as the default is /var/run/zabbix and that is inside a tmpfs which will be cleared on reboot.
                    sudo service zabbix-agent stop
                    sudo usermod -d /home/zabbix -m zabbix
                    sudo service zabbix-agent restart
                    
                    echo "[client]" >> ~zabbix/.my.cnf && echo "user = root" >> ~zabbix/.my.cnf && echo "password = $PASS" >> ~zabbix/.my.cnf
                    sudo chown zabbix:zabbix ~zabbix/.my.cnf && chmod 0600 ~zabbix/.my.cnf
                    sudo apt-get install php7.0-cli -y
                    sudo apt-get install php7.0-mysql -y
                    echo "Edit the password in: /var/lib/zabbix/percona/scripts/ss_get_mysql_stats.php.cnf"
                    sudo service zabbix-agent restart
                    
                    echo "Testing:"
                    /var/lib/zabbix/percona/scripts/get_mysql_stats_wrapper.sh gg
                    sudo -u zabbix -H /var/lib/zabbix/percona/scripts/get_mysql_stats_wrapper.sh running-slave
                fi
            fi
            ;;
            
        "6") # Install guest tools
            
            # VMware tools
            if grep -s -q 'Vendor: VMware' /proc/scsi/scsi ; then
                if [ $(lsb_release -rs | xargs printf "%.0f") -ge 14 ]; then
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
                if Confirm "Do you want to add a symlink for the www folder?" N; then
                    sudo mv /var/www /var/www_old 2>/dev/null
                    sudo ln -s /mnt/hgfs/www /var/www
                fi
            fi
            
            # Virtualbox guest additions
            if grep -s -q 'Vendor: VBOX' /proc/scsi/scsi ; then
                AptGetUpdate
                sudo apt-get install virtualbox-guest-dkms -y
                
                if ! grep -s -q 'auto eth1' /etc/network/interfaces ; then
                    if Confirm "Do you want to add a second NIC?" Y; then
                        sudo bash -c "echo '' >> /etc/network/interfaces"
                        sudo bash -c "echo '# Virtualbox Host-only adapter' >> /etc/network/interfaces"
                        sudo bash -c "echo 'auto eth1' >> /etc/network/interfaces"
                        sudo bash -c "echo 'iface eth1 inet dhcp' >> /etc/network/interfaces"
                        sudo /etc/init.d/networking restart
                        sudo ifconfig eth1 up
                        sudo dhclient eth1
                    fi
                fi
                
                sudo adduser www-data vboxsf
                sudo adduser ubuntu vboxsf
                
                if Confirm "Do you want to mount the www folder (C:\Users\%USERPROFILE%\www) from the Windows host to '/var/www'?" Y; then
                    read -p "Please enter your Windows username: " WIN_USER
                    read -p "Please enter your Windows password: " WIN_PASS
                    MOUNT_COMMAND="sudo mount -t cifs -o username=$WIN_USER,password=$WIN_PASS,uid=ubuntu,gid=ubuntu,vers=3.02,mfsymlinks,file_mode=0777,dir_mode=0777 \"//10.0.2.2/C$/Users/$WIN_USER/www\" /var/www/"
                    echo $MOUNT_COMMAND
                    sudo mkdir -p /var/www
                    eval $MOUNT_COMMAND
                    sudo sed -i '/\/C\$\/Users\//d' /etc/rc.local
                    sudo sed -i '${/exit 0/d;}' /etc/rc.local
                    echo "" >> /etc/rc.local
                    echo $MOUNT_COMMAND >> /etc/rc.local
                    echo "" >> /etc/rc.local
                    echo "exit 0" >> /etc/rc.local
                elif Confirm "Do you want to add a symlink for the www folder?" N; then
                    sudo ln -s /media/sf_www /var/www
                fi
            fi
            ;;
            
        "7") # Install web tools (git, npm, uglifyjs, hugo)
            
            # Install Git
            apt-get install git -y
            #apt-get install gitk -y
            
            # Install npm & uglifyjs
            curl -sL https://deb.nodesource.com/setup_6.x | sudo -E bash -
            sudo apt-get install nodejs -y
            sudo npm install npm@latest -g
            sudo ln -s /usr/bin/nodejs /usr/bin/node
            sudo npm install -g bower
            sudo npm install -g uglify-js
            sudo npm install -g webpack
            sudo npm install -g yarn
            # Install hugo
            cd ~ && wget https://github.com/gohugoio/hugo/releases/download/v0.24.1/hugo_0.24.1_Linux-64bit.deb && sudo dpkg -i hugo_*_Linux-64bit.deb && rm hugo_*_Linux-64bit.deb && hugo version
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
            sudo a2dismod autoindex -f
            
            # Cleaning (Ubuntu 14.04+)
            rm /var/www/html/index.html
            rmdir /var/www/html
            
            # Set 777 permissions on the www folder.
            chmod 0777 /var/www
            
            # Turn off the default Apache2 sites directly
            sudo a2dissite default
            sudo a2dissite 000-default
            sudo a2dissite 000-default.conf
            
            sudo service apache2 restart
            
            if Confirm "Do you want to enable vhost_alias and proxy_http modules?" N; then
                a2enmod vhost_alias
                a2enmod proxy_http
                sudo service apache2 restart
            fi
            
            # Install SSL for Apache2
            if Confirm "Do you want to enable SSL (https) for apache2?" N; then
                sudo a2enmod ssl
                sudo sed -i 's/SSLProtocol all/SSLProtocol All -SSLv2 -SSLv3/g' /etc/apache2/mods-available/ssl.conf
                sudo service apache2 restart
            fi
            ;;
            
        "9") # Install PHP 5 and Composer
            
            if [ $(lsb_release -rs | xargs printf "%.0f") -lt 16 ]; then
            
                sudo apt-get install php5 php5-ldap php5-curl php5-xsl php5-gd php5-imagick php5-json php5-intl php5-redis -y
                sudo apt-get install mysql-client -y
                sudo apt-get install php5-mysqlnd -y
                sudo apt-get install imagemagick -y
            
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
            
            else
                echo "PHP 5 are not available on this Ubuntu version, please install PHP 7."
            fi
            ;;
            
        "10") # Install PHP 7 and Composer
            
            if [ $(lsb_release -rs | xargs printf "%.0f") -lt 16 ]; then
                sudo apt-get install -y language-pack-en-base
                sudo LC_ALL=en_US.UTF-8 add-apt-repository ppa:ondrej/php
            fi
            
            APT_UPDATED=0
            AptGetUpdate
            
            sudo apt-get install php7.0 php7.0-cli php7.0-ldap php7.0-curl php7.0-xsl php7.0-gd php7.0-json php7.0-intl php7.0-mcrypt php7.0-mbstring php7.0-zip php7.0-soap php7.0-bcmath -y
            sudo apt-get install mysql-client -y
            sudo apt-get install php7.0-mysqlnd -y
            sudo apt-get install imagemagick php-imagick -y
            #sudo apt-get install memcached php-memcached -y
            sudo apt-get install php-redis -y
            
            # Disable PHP ubuntu default garbage collector.
            sudo rm /etc/cron.d/php
	    
	    # Correct the permissions on the sessions folder when "files" are used as the php session driver.
	    sudo chown -R www-data:www-data /var/lib/php/sessions
            
            # Download composer
            curl -sS https://getcomposer.org/installer | php && sudo mv composer.phar /usr/local/bin/composer
            
            # Install the apache2 module for php7
            sudo apt-get install libapache2-mod-php7.0
            ;;
            
        "11") # Install a database (MySQL/Percona Server/Percona XtraDB Cluster)
            
            if ! grep "repo.percona.com" /etc/apt/sources.list > /dev/null; then
                # Adding repositories from Percona.
                sudo apt-get install lsb-release -y
                if sudo apt-key adv --keyserver keys.gnupg.net --recv-keys 8507EFA5 | grep "key 8507EFA5 not found on keyserver" ; then
                        echo "Error: Can't find the key for the Percona repository, please try to run this script again.";
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
            # Install mysql-utilities
            sudo apt-get install mysql-utilities -y
            
            if Confirm "Do you want to install Oracle MySQL Server?" N; then
                # Optional installation of Mysql Server. Will trigger a question.
                sudo apt-get install mysql-server -y
                sudo chmod 0755 /var/lib/mysql
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
                sudo chmod 0755 /var/lib/mysql
            fi
            
            if Confirm "Do you want to install Percona XtraDB Cluster 5.6?" N; then
                sudo apt-get install percona-xtradb-cluster-56 -y
                sudo apt-get install percona-toolkit -y
                sudo chmod 0755 /var/lib/mysql
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
            
        "12") # Install keepalived
            
            sudo apt-get install keepalived -y
            
            # Add a check if the setting is already like this?
            sudo bash -c "echo 'net.ipv4.ip_nonlocal_bind = 1' >> /etc/sysctl.conf"
            sudo sysctl -p
			
            if Confirm "Do you want to download a new configuration file?" Y; then
                DownloadNewConfigFile "/etc/keepalived/keepalived.conf" "https://raw.githubusercontent.com/JimCronqvist/ubuntu-scripts/master/configurations/sample_keepalived.conf"
                sudo service keepalived restart
            fi
            ;;
            
        "13") # Install ha-proxy
            
            add-apt-repository ppa:vbernat/haproxy-1.6
            APT_UPDATED=0
            AptGetUpdate
            apt-get install haproxy -y
            apt-get install vim-haproxy -y
            apt-get install hatop -y
			
            # Download a finished configuration file.
            if Confirm "Do you want to download a new configuration file?" Y; then
                DownloadNewConfigFile "/etc/haproxy/haproxy.cfg" "https://raw.githubusercontent.com/JimCronqvist/ubuntu-scripts/master/configurations/sample_haproxy.cfg"
                sudo service haproxy restart
                sudo service rsyslog restart
            fi
            ;;
            
        "14") # Install Varnish cache
            
            if [ $(lsb_release -rs | xargs printf "%.0f") -eq 14 ]; then
                apt-get install apt-transport-https
                curl https://repo.varnish-cache.org/GPG-key.txt | apt-key add -
                echo "deb https://repo.varnish-cache.org/ubuntu/ trusty varnish-4.1" >> /etc/apt/sources.list.d/varnish-cache.list
            fi
            
            APT_UPDATED=0
            AptGetUpdate
            apt-get install varnish -y
            sudo sed -i 's/SERVICE=.*/SERVICE="varnish"/' /etc/init.d/varnish
            
            if Confirm "Do you want to download a new configuration file?" Y; then
                DownloadNewConfigFile "/etc/varnish/production.vcl" "https://raw.githubusercontent.com/JimCronqvist/ubuntu-scripts/master/configurations/sample_varnish_production.vcl"
                sed -i 's/\/etc\/varnish\/default.vcl/\/etc\/varnish\/production.vcl/g' /etc/default/varnish
                sed -i 's/\/etc\/varnish\/default.vcl/\/etc\/varnish\/production.vcl/g' /lib/systemd/system/varnish.service
                sudo systemctl daemon-reload
                sudo service varnish restart
            fi
            ;;
        
        "15") # Install Redis
            
            sudo add-apt-repository ppa:chris-lea/redis-server
            APT_UPDATED=0
            AptGetUpdate
            sudo apt-get install redis-server -y
            ;;
            
        "16") # Install FTP
            
            # Install the FTP service
            sudo apt-get install vsftpd -y
            # Set up a new dummy shell (vsftpd does not allow logins if the shell does not exist)
            sudo bash -c "echo '/bin/false' >> /etc/shells"
            
            if ! grep -s -q 'Custom configuration from install.sh' /etc/vsftpd.conf ; then
                sudo tee -a <<EOF /etc/vsftpd.conf > /dev/null

# Custom configuration from install.sh
anonymous_enable=NO
local_enable=YES
write_enable=YES
chroot_local_user=YES

# When behind NAT, configure passive mode and public IP.
#pasv_address=x.x.x.x
pasv_min_port=10000
pasv_max_port=10024

# Log all FTP transfers and commands
#log_ftp_protocol=YES
EOF
                sudo service vsftpd restart
            fi
            
            # Set up for SFTP instead of FTP
            if ! grep -s -q 'Custom configuration from install.sh' /etc/ssh/sshd_config ; then
                # If there already is a "Subsystem sftp *" row, it needs to be commented first.
                sudo sed -e '/Subsystem sftp/ s/^#*/#/' -i /etc/ssh/sshd_config
                sudo tee -a <<EOF /etc/ssh/sshd_config > /dev/null

# Custom configuration from install.sh
Subsystem sftp internal-sftp
Match group sftponly
  ChrootDirectory %h
  ForceCommand internal-sftp
  AllowTcpForwarding no
  PermitTunnel no
  AllowAgentForwarding no
  X11Forwarding no
  PasswordAuthentication yes
EOF
            fi
            
            sudo addgroup sftponly
            sudo service ssh restart
            
            # Modify the 'ftp' user
            sudo mkdir /home/ftp -p
            sudo useradd -m ftp -g sftponly -s /bin/false
            sudo usermod -g sftponly -s /bin/false -m --home /home/ftp ftp
            sudo chown root:root /home/ftp
            sudo service vsftpd restart
            echo ""
            echo "Please enter the password for the 'ftp' user account"
            sudo passwd ftp
            ;;
        
        "0")
            exit
            ;;
        * )
            echo "Invalid option, please try again."
            ;;
    esac
    if [ $INTERACTIVE == 0 ]; then
        REPLY=0;
   fi
done
