#!/bin/bash

#############################################
##        Automatic install script         ##
## Jim Cronqvist <jim.cronqvist@gmail.com> ##
##             For Docker Host             ##
#############################################

export NEEDRESTART_MODE=a
export DEBIAN_FRONTEND=noninteractive

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

# APT-GET UPDATE function
APT_UPDATED=0
AptGetUpdate () {
    if [ $APT_UPDATED -eq 0 ]; then
        apt-get update
        APT_UPDATED=1
    fi
}


while :
do
    # Only ask for a choice if we are in interactive mode.
    if [ $INTERACTIVE == 1 ]; then

        echo ""
        echo "=================================="
        echo "install-docker-host.sh            "
        echo "----------------------------------"
        echo "Hostname: $(hostname --fqdn)"
        echo "IP: $(hostname -I)"
        echo "----------------------------------"
    	cat<<EOF
(1) Install updates
(2) Change hostname
(3) Cleaning (apt-get, /tmp, /boot)
(4) Install base tools and setup (recommended)
(5) Configure advanced settings
(6) Install and enable monitoring (SNMP & Zabbix)
(7) Install Docker
(8) Install AWS CLI v2
(9) Install Terraform
(10) Install Kubernetes (K3s)
(11) Install Node
(12) Install database utilities (Xtrabackup, mysqldump, mysql-client)
(13) Install Database

(0) Quit
----------------------------------
EOF

       read -p "Please enter your choice: " REPLY
    fi

    case "$REPLY" in
        
        "1") # Install updates
            
            AptGetUpdate 
            sudo NEEDRESTART_MODE=a apt-get dist-upgrade -y

            ;;
        "2") # Change hostname
            
            OLD_FQDN=$(hostname --fqdn)
            read -e -i "$OLD_FQDN" -p "Please enter the new hostname: " FQDN
            
            sudo hostnamectl set-hostname $FQDN
            sed -i "s/^Hostname=.*$/Hostname=${FQDN}/" /etc/zabbix/zabbix_agentd.conf.d/zabbix.conf
            
            echo ""
            echo "Hostname changed!"
            echo ""
            echo "Old: $OLD_FQDN"
            echo "New: $(hostname --fqdn)"
            echo ""
            
            ;;
        "3") # Cleaning (apt-get, /tmp, /boot)
            
            apt-get autoremove -y
            apt-get clean
            apt-get autoclean
            
            if Confirm "Do you want to clean out the /tmp folder?" Y; then
                sudo rm -r /tmp/*
            fi
            
            ;;
        "4") # Install base tools & setup (recommended)
            
            # Set backspace character to ^H
            echo 'stty erase ^H' >> /home/ubuntu/.bashrc
	    
            # Change prompt color for Ubuntu user
            sudo sed -i 's/#force_color_prompt=yes/force_color_prompt=yes/g' /home/ubuntu/.bashrc
            
            # Turn off ec2 instances automatic renaming of the hostname at each reboot
            sudo sed -i 's/preserve_hostname: false/preserve_hostname: true/' /etc/cloud/cloud.cfg
            
            # Disable sudo password for user "ubuntu"
            sudo bash -c "echo 'ubuntu ALL=(ALL) NOPASSWD:ALL' | ( umask 337; cat >> /etc/sudoers.d/ubuntu; )"
            
            # Prefer ipv4 over ipv6
            sudo sed -i -e '/precedence ::ffff:0:0\/96\s\s100/s/^#*//g' /etc/gai.conf
            
            # Add the universe repo
            sudo add-apt-repository universe -y
            
            # Get the latest package lists
            AptGetUpdate
            
            # Install ssh, pkexec, lvm (ec2 does not come with this by default), lrzsz (xshell support), vim, with more.
            apt-get install ssh policykit-1 lvm2 lrzsz vim ntp curl tree pv software-properties-common -y
            
            # Set vim as the default text-editor.
            export EDITOR="vim"
            
            # Install troubleshooting tools
            apt-get install htop iotop iftop traceroute sysstat sysdig ncdu -y

            # Install tools for mounting a samba/cifs & nfs storage.
            sudo apt-get install cifs-utils samba samba-common nfs-common -y
            
            # Install an MTA
            sudo apt-get install sendmail mailutils -y
            
            # Install security tools: rkhunter to find any potential root kits and acct
            sudo apt-get install rkhunter chkrootkit acct -y
            #rkhunter --check
			
            # Install Git
            sudo apt-get install git -y
            
            # Pre-save the Github host key
            ssh-keyscan github.com | sudo tee -a /etc/ssh/ssh_known_hosts
            
            # Guest tools - VMware tools
            if grep -s -q 'Vendor: VMware' /proc/scsi/scsi ; then
                AptGetUpdate
                sudo apt-get install open-vm-tools -y
            fi
            
            # If more than 4 GB ram, it is a "powerful" server, up the default open files limit in Ubuntu
            if [ $(free -m | awk '/^Mem:/{print $2}') -gt 4000 ]; then
                sudo bash -c "echo '* soft nofile 8192' >> /etc/security/limits.conf"
                sudo bash -c "echo '* hard nofile 8192' >> /etc/security/limits.conf"
            fi
            
            ;;
        "5") # Configure advanced settings
     
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
        "6") # Enable monitoring (SNMP & Zabbix)
            
            AptGetUpdate
	    
            # Install SNMP
            if Confirm "Do you want to install snmpd (will be open for everyone as default)?" Y; then
                sudo apt-get install snmpd -y
                sudo mv /etc/snmp/snmpd.conf /etc/snmp/snmpd.conf.org
                sudo touch /etc/snmp/snmpd.conf
                sudo bash -c "echo 'rocommunity public' >> /etc/snmp/snmpd.conf"
                sudo bash -c "echo 'sysLocation \"Unknown\"' >> /etc/snmp/snmpd.conf"
                sudo bash -c "echo 'sysContact JimCronqvist' >> /etc/snmp/snmpd.conf"
                sudo bash -c "echo 'SNMPDOPTS=\"-LS 0-4 d -Lf /dev/null -u snmp -I -smux -p /var/run/snmpd.pid -c /etc/snmp/snmpd.conf\"' >> /etc/default/snmpd"
                sudo service snmpd restart
            fi
	    
            # Install zabbix agent
            if Confirm "Do you want to install zabbix agent (For monitoring)?" Y; then
                sudo apt-get install zabbix-agent -y
                sudo adduser zabbix adm
                sudo bash -c "echo 'zabbix ALL=NOPASSWD: /usr/bin/lsof' | ( umask 337; cat >> /etc/sudoers.d/zabbix; )"
                sudo bash -c "echo 'Server=zabbix.'`dnsdomainname` >> /etc/zabbix/zabbix_agentd.conf.d/zabbix.conf"
                sudo bash -c "echo 'ServerActive=zabbix.'`dnsdomainname` >> /etc/zabbix/zabbix_agentd.conf.d/zabbix.conf"
                sudo bash -c "echo 'Hostname='`hostname --fqdn` >> /etc/zabbix/zabbix_agentd.conf.d/zabbix.conf"
                sudo bash -c "echo 'EnableRemoteCommands=1' >> /etc/zabbix/zabbix_agentd.conf.d/zabbix.conf"
                sudo service zabbix-agent restart
            fi
			
            ;;
        "7") # Install Docker
            
            AptGetUpdate
	    
            # Install Git if not previously installed
            apt-get install git -y
            
            # Install docker & dependencies
            sudo apt-get install apt-transport-https ca-certificates curl software-properties-common gnupg lsb-release -y
            curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
            APT_UPDATED=0
            AptGetUpdate
            sudo apt-get install docker-ce docker-ce-cli containerd.io docker-compose-plugin -y
            sudo tee -a /etc/docker/daemon.json <<EOF
{
    "default-address-pools": [
        {"base":"172.17.0.0/16","size":24},
        {"base":"172.18.0.0/16","size":24},
        {"base":"172.19.0.0/16","size":24},
        {"base":"172.20.0.0/14","size":24},
        {"base":"172.24.0.0/14","size":24},
        {"base":"172.28.0.0/14","size":24}
    ]
}
EOF
            sudo service docker reload
            sudo adduser ubuntu docker
	    
	        # Add an alias for 'docker-compose' v1 syntax
	        echo 'docker compose --compatibility "$@"' | sudo tee /usr/local/bin/docker-compose > /dev/null && sudo chmod +x /usr/local/bin/docker-compose
	    
            # Add a cronjob to prune unused data for docker (excluding volumes)
            sudo bash -c "echo '0 0 * * * root /usr/bin/docker system prune -a -f --filter \"until=48h\"' > /etc/cron.d/docker-system-prune"
            
            ;;
	    "8") # Install AWS CLI v2
            
            cd ~
            curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
            unzip awscliv2.zip
            sudo ./aws/install

            sudo -u ubuntu aws configure set default.region eu-north-1
            sudo -u ubuntu aws configure set default.output json
            #aws configure
            
            ;;

        "9") # Install Terraform
            
            wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
            echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
            APT_UPDATED=0
            AptGetUpdate
            sudo apt-get install terraform -y
            
            ;;
        
        "10") # Install Kubernetes (K3s)
            
            curl -sfL https://get.k3s.io | sh - 
            
            # Check for Ready node, takes ~30 seconds 
            #sudo k3s kubectl get node 

            # Install an optional dashboard?
            # https://docs.k3s.io/installation/kube-dashboard

            ;;
        
        "11") # Install Node
            
            # Install Node 16 LTS
            curl -sL https://deb.nodesource.com/setup_16.x | sudo -E bash -
            sudo apt install nodejs -y
            sudo npm install npm@latest -g
            sudo npm install yarn@latest -g
            
            # Correct permissions after install
            sudo chown ubuntu:ubuntu /home/ubuntu/ -R
            
            ;;

        "12") # Install Database Utilities (Xtrabackup, mysqldump, mysql-client)
            
            # Set up Percona apt repos
            if ! grep -sq "repo.percona.com" /etc/apt/sources.list.d/percona-tools-release.list; then
                wget https://repo.percona.com/apt/percona-release_latest.generic_all.deb
                sudo dpkg -i percona-release_latest.generic_all.deb
		rm -f percona-release_latest.generic_all.deb
                sudo percona-release enable tools release
                APT_UPDATED=0
                AptGetUpdate
            fi
            
            # Install Xtrabackup & mysql-utilities
            sudo apt-get install percona-xtrabackup mysql-utilities -y
            
            # Install mysql client
            sudo apt-get install mysql-client-core-5.7 -y
            
            ;;
        
        "13") # Install Database
            
            DB_INSTALLED=0
            
            # Set up Percona apt repos
            if ! grep -sq "repo.percona.com" /etc/apt/sources.list.d/percona-tools-release.list; then
                wget https://repo.percona.com/apt/percona-release_latest.generic_all.deb
                sudo dpkg -i percona-release_latest.generic_all.deb
		rm -f percona-release_latest.generic_all.deb
                sudo percona-release enable tools release
                APT_UPDATED=0
                AptGetUpdate
            fi
            
            # Install Xtrabackup & mysql-utilities
            sudo apt-get install percona-xtrabackup mysql-utilities -y
            
            # Install Percona Toolkit
            sudo apt-get install percona-toolkit -y


            # Install Percona Server
            if Confirm "Do you want to install Percona Server 5.7?" N; then
                sudo apt-get install dialog -y
                sudo apt-get install percona-server-server-5.7 -y
                DB_INSTALLED=1
            fi


            # Apply generic MySQL operations if a DB has been installed
            if [ $DB_INSTALLED == 1 ]; then
                sudo chmod 0755 /var/lib/mysql
                sudo cp /lib/systemd/system/mysql.service /etc/systemd/system/
                sudo bash -c "echo 'LimitNOFILE=infinity' >> /etc/systemd/system/mysql.service"
                sudo bash -c "echo 'LimitMEMLOCK=infinity' >> /etc/systemd/system/mysql.service"
                sudo systemctl daemon-reload && sudo systemctl restart mysql.service
		# Import Timezones into MySQL
		echo ""
		echo "Please enter your root password for MySQL in order for us to import timezones into MySQL."
                mysql_tzinfo_to_sql /usr/share/zoneinfo | mysql -h 127.0.0.1 -u root -p mysql
            fi
            
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
