#!/bin/bash

#############################################
##        Automatic install script         ##
## Jim Cronqvist <jim.cronqvist@gmail.com> ##
##          Updated: 2017-11-08            ##
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

        echo ""
        echo "=================================="
        echo "install.sh by Jim Cronqvist"
        echo "----------------------------------"
        echo "Hostname: $(hostname --fqdn)"
        echo "IP: $(hostname -I)"
        echo "----------------------------------"
    	cat<<EOF
(1) Install all available updates
(2) Cleaning (apt-get, /tmp, /boot)
(3) Basic installation and set-up (recommended)
(4) Configure advanced settings
(5) Enable monitoring (SNMP & Zabbix)
(6) Change hostname
(7) Install web tools (git, npm, yarn, uglifyjs, hugo)
(8) Install Apache2
(9) Install (NOTHING HERE)
(10) Install PHP 7.0 and Composer
(11) Install a database (MySQL/Percona Server/Percona XtraDB Cluster)
(12) Install keepalived
(13) Install haproxy (for web)
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
            
            # Get the latest package lists
            AptGetUpdate
            
            # Install ssh, pkexec, lvm (ec2 does not come with this by default), lrzsz (xshell support), vim, dialog
            apt-get install ssh policykit-1 lvm2 lrzsz vim dialog -y
            
            # Set vim as the default text-editor.
            export EDITOR="vi"
            
            # Install troubleshooting tools
            apt-get install htop iotop iftop traceroute sysstat sysdig ncdu -y
                        
            # Install tools for mounting a samba/cifs & nfs storage.
            sudo apt-get install cifs-utils samba samba-common nfs-common -y
            
            # Install basics that is good to have
            sudo apt-get install ntp curl tree pv dos2unix debconf-utils software-properties-common -y
                                   
            # Install acct
            sudo apt-get install acct -y
            
            # Install an MTA
            sudo apt-get install sendmail mailutils -y
            
            # Install rkhunter to find any potential root kits
            sudo apt-get install rkhunter chkrootkit -y
            #rkhunter --check
            
            # Guest tools - VMware tools
            if grep -s -q 'Vendor: VMware' /proc/scsi/scsi ; then
                AptGetUpdate
                sudo apt-get install open-vm-tools -y
            fi
            
            # Guest tools - Virtualbox guest additions
            if grep -s -q 'Vendor: VBOX' /proc/scsi/scsi ; then
                sudo apt-get install virtualbox-guest-dkms -y

                sudo adduser ubuntu vboxsf
                sudo adduser www-data vboxsf
            fi
            
            # If more than 4 GB ram, it is a "powerful" server, up the default open files limit in Ubuntu
            if [ $(free -m | awk '/^Mem:/{print $2}') -gt 4000 ]; then
                sudo bash -c "echo '* soft nofile 8192' >> /etc/security/limits.conf"
                sudo bash -c "echo '* hard nofile 8192' >> /etc/security/limits.conf"
            fi
            
            ;;
            
        "4") # Configure advanced settings
            		            
            # Change default limits in Ubuntu.	
            if Confirm "Do you want to change the open files limit to 100000 instead of 1024? (Needed for VERY powerful web servers)" N; then
                sudo bash -c "echo '* soft nofile 100000' >> /etc/security/limits.conf"
                sudo bash -c "echo '* hard nofile 100000' >> /etc/security/limits.conf"
            fi
            
            if Confirm "Do you want to change the default TCP settings for a high-performance web-server?" N; then
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
            
        "6") # Change hostname
            
            OLD_FQDN=$(hostname --fqdn)
            read -e -i "$OLD_FQDN" -p "Please enter the new hostname: " FQDN
            
            sudo hostnamectl set-hostname $FQDN
            sed -i "s/^Hostname=.*$/Hostname=${FQDN}/" /etc/zabbix/zabbix_agentd.conf.d/zabbix.conf
            
            echo ""
            echo "Hostname changed, there could be more locations where it is necessary to update, such as:"
            echo "- Apache2 vhosts files in /etc/apache2/sites-enabled"
            echo "- Varnish/ha-proxy configuration files"
            echo ""
            echo "Old: $OLD_FQDN"
            echo "New: $(hostname --fqdn)"
            echo ""
            
            ;;
            
        "7") # Install web tools (git, npm, uglifyjs, hugo)
            
            # Install Git
            apt-get install git -y
            
            # Install npm & uglifyjs
            curl -sL https://deb.nodesource.com/setup_6.x | sudo -E bash -
            sudo apt-get install nodejs -y
            sudo npm install npm@latest -g
            sudo ln -s /usr/bin/nodejs /usr/bin/node
            sudo npm install -g bower
            sudo npm install -g uglify-js
            sudo npm install -g webpack
            sudo npm install -g yarn
	    
	    # Correct permissions after install
	    sudo chown ubuntu:ubuntu /home/ubuntu/ -R
	    
            # Install hugo
            cd ~ && wget https://github.com/gohugoio/hugo/releases/download/v0.25/hugo_0.25_Linux-64bit.deb && sudo dpkg -i hugo_*_Linux-64bit.deb && rm hugo_*_Linux-64bit.deb && hugo version
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
            
        "9") # Install Nothing
            
            echo "Nothing here"
            
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
            
            # Install xdebug.
            if Confirm "Do you want to install xdebug?" N; then
                sudo apt-get install php-xdebug -y
                sudo bash -c "cat <<EOF >> /etc/php/7.0/apache2/php.ini

[xdebug]
xdebug.remote_enable=1
xdebug.remote_connect_back=1
xdebug.idekey=ubuntu
EOF"
            fi
                
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
            
            if Confirm "Do you want to install Oracle MySQL Server?" Y; then
                # Optional installation of Mysql Server. Will trigger a question.
                sudo apt-get install mysql-server -y
                sudo chmod 0755 /var/lib/mysql
                sudo cp /lib/systemd/system/mysql.service /etc/systemd/system/
                sudo bash -c "echo 'LimitNOFILE=infinity' >> /etc/systemd/system/mysql.service"
                sudo bash -c "echo 'LimitMEMLOCK=infinity' >> /etc/systemd/system/mysql.service"
                sudo systemctl daemon-reload && sudo systemctl restart mysql.service
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
                sudo cp /lib/systemd/system/mysql.service /etc/systemd/system/
                sudo bash -c "echo 'LimitNOFILE=infinity' >> /etc/systemd/system/mysql.service"
                sudo bash -c "echo 'LimitMEMLOCK=infinity' >> /etc/systemd/system/mysql.service"
                sudo systemctl daemon-reload && sudo systemctl restart mysql.service
            fi
            
            if Confirm "Do you want to install Percona XtraDB Cluster 5.6?" N; then
                sudo apt-get install percona-xtradb-cluster-56 -y
                sudo apt-get install percona-toolkit -y
                sudo chmod 0755 /var/lib/mysql
                sudo cp /lib/systemd/system/mysql.service /etc/systemd/system/
                sudo bash -c "echo 'LimitNOFILE=infinity' >> /etc/systemd/system/mysql.service"
                sudo bash -c "echo 'LimitMEMLOCK=infinity' >> /etc/systemd/system/mysql.service"
                sudo systemctl daemon-reload && sudo systemctl restart mysql.service
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
            
        "13") # Install ha-proxy for web
            
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
            
            # If the certificate that we expect to have does not exist, generate one until the user has replaced it with a valid one to prevent that haproxy does not start up properly.
            FQDN=$(hostname --fqdn)
            if [ ! -f "/etc/ssl/private/$FQDN.pem" ]; then
                sudo openssl req -x509 -nodes -days 365 -newkey rsa:4096 -keyout /etc/ssl/private/$FQDN.pem -out /etc/ssl/private/$FQDN.pem -subj "/C=/ST=/L=/O=/CN= "
                sudo chmod 0600 /etc/ssl/private/$FQDN.pem
                sudo service haproxy restart
            fi
	    
            # Change the port apache2 is listening on, since haproxy is listening on the same one by default (at least in the sample configuration above).
            if Confirm "Do you want to change the port that apache2 is listening on from 80 to 8080?" Y; then
                OLD_PORT=80
                NEW_PORT=8080
                sed -i 's/:'$OLD_PORT'>/:'$NEW_PORT'>/g' /etc/apache2/sites-enabled/*
                sed -i 's/Listen '$OLD_PORT'$/Listen '$NEW_PORT'/g' /etc/apache2/ports.conf
                sudo service apache2 restart
                sudo service haproxy restart
            fi
            
            # Check if there is any apache2 site configured, otherwise recommend creating one now.
            if [ $(ls -l /etc/apache2/sites-enabled/ | tail -n +2 | wc -l) -eq 0 ]; then
                echo "" && echo "NOTE: You have no enabled apache2 site, you should probably create one now." && echo ""
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
            #sudo systemctl stop varnishlog && sudo systemctl disable varnishlog
            
            if Confirm "Do you want to download a new configuration file?" Y; then
                DownloadNewConfigFile "/etc/varnish/production.vcl" "https://raw.githubusercontent.com/JimCronqvist/ubuntu-scripts/master/configurations/sample_varnish_production.vcl"
                sudo sed -i 's/\/etc\/varnish\/default.vcl/\/etc\/varnish\/production.vcl/g' /etc/default/varnish
                sudo cp /lib/systemd/system/varnish.service /etc/systemd/system/
                sudo sed -i 's/\/etc\/varnish\/default.vcl/\/etc\/varnish\/production.vcl/g' /etc/systemd/system/varnish.service
                sudo sed -i 's/-s malloc,256m/-s malloc,1G -p workspace_client=256k/g' /etc/systemd/system/varnish.service
                sudo sed -i 's/-a :6081 -T/-a :6081 -a :6086,PROXY -T/g' /etc/systemd/system/varnish.service
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
listen=YES
listen_ipv6=NO
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
