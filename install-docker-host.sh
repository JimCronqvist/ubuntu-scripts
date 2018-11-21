#!/bin/bash

#############################################
##        Automatic install script         ##
## Jim Cronqvist <jim.cronqvist@gmail.com> ##
##             For Docker Host             ##
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
(8) Install AWS CLI
(9) Install Buildkite
(10) Install database utilities (Xtrabackup, mysqldump)
(0) Quit
----------------------------------
EOF

       read -p "Please enter your choice: " REPLY
    fi

    case "$REPLY" in
        
        "1") # Install updates
            
            AptGetUpdate 
            sudo apt-get dist-upgrade -y

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
            echo 'stty erase ^H' >> ~/.bashrc
            
            # Turn off ec2 instances automatic renaming of the hostname at each reboot
            sudo sed -i 's/preserve_hostname: false/preserve_hostname: true/' /etc/cloud/cloud.cfg
            
            # Disable sudo password for user "ubuntu"
            sudo bash -c "echo 'ubuntu ALL=(ALL) NOPASSWD:ALL' | ( umask 337; cat >> /etc/sudoers.d/ubuntu; )"
            
            # Get the latest package lists
            AptGetUpdate
            
            # Install ssh, pkexec, lvm (ec2 does not come with this by default), lrzsz (xshell support), vim, with more.
            apt-get install ssh policykit-1 lvm2 lrzsz vim ntp curl tree pv software-properties-common -y
            
            # Set vim as the default text-editor.
            export EDITOR="vi"
            
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
	    
            # Install zabbix agent
            if Confirm "Do you want to install zabbix agent (For monitoring)?" N; then
                sudo apt-get install zabbix-agent -y
                sudo adduser zabbix adm
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
            sudo apt-get install apt-transport-https ca-certificates curl software-properties-common -y
            curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
            sudo add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
            APT_UPDATED=0
            AptGetUpdate
            sudo apt-get install docker-ce -y
            
            # Install docker-compose
            DOCKER_COMPOSE_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep 'tag_name' | cut -d\" -f4)
            sudo curl -L "https://github.com/docker/compose/releases/download/$DOCKER_COMPOSE_VERSION/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
            sudo chmod +x /usr/local/bin/docker-compose
            sudo curl -L "https://raw.githubusercontent.com/docker/compose/$DOCKER_COMPOSE_VERSION/contrib/completion/bash/docker-compose" -o /etc/bash_completion.d/docker-compose
            
            sudo adduser ubuntu docker
            
            ;;
	"8") # Install AWS CLI
            
            sudo apt install python-pip -y
            pip install awscli
            #aws configure
            
            ;;
        "9") # Install Buildkite
            
	    # Ensure docker is installed first
	    if [ -x "$(command -v docker)" ]; then
                echo "Please install docker first, aborting."
		exit
	    fi
	    
            # https://buildkite.com/docs/agent/v3/ubuntu
            sudo sh -c 'echo deb https://apt.buildkite.com/buildkite-agent stable main > /etc/apt/sources.list.d/buildkite-agent.list'
            sudo apt-key adv --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys 32A37959C2FA5C3C99EFBC32A79206696452D198
            APT_UPDATED=0
            AptGetUpdate
            sudo apt-get install -y buildkite-agent
            read -e -i "" -p "Please enter your buildkite agent token: " BUILDKITE_AGENT_TOKEN
            sudo sed -i "s/xxx/${BUILDKITE_AGENT_TOKEN}/g" /etc/buildkite-agent/buildkite-agent.cfg
            sudo adduser buildkite-agent docker
            sudo systemctl enable buildkite-agent && sudo systemctl start buildkite-agent
            
            ;;
        "10") # Install database utilities (Xtrabackup, mysqldump)
            
            # Install Xtrabackup
            sudo apt-get install percona-xtrabackup -y
            # Install mysql-utilities
            sudo apt-get install mysql-utilities -y
            
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
