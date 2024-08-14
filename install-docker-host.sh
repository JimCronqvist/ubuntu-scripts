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
(10) Import keys from GitHub
(11) Install kubectl, helm, customize, eksctl, argocd cli, kompose
(12) Install Node
(13) Install database utilities (Xtrabackup, mysqldump, mysql-client)
(14) Install Database
(15) Install Tailscale
(16) Install Go

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
            #sudo apt-get install cifs-utils samba samba-common nfs-common -y
            
            # Install an MTA
            #sudo apt-get install sendmail mailutils -y
            
            # Install security tools: rkhunter to find any potential root kits and acct
            sudo apt-get install rkhunter chkrootkit acct -y
            #rkhunter --check

            # Install Git & jq & yq
            sudo apt-get install git jq -y
            sudo snap install yq
            
            # Pre-save the Github host key
            ssh-keyscan github.com | sudo tee -a /etc/ssh/ssh_known_hosts
            
            # Guest tools - VMware tools
            if grep -s -q 'Vendor: VMware' /proc/scsi/scsi ; then
                AptGetUpdate
                sudo apt-get install open-vm-tools -y
            fi
            
            # If more than 4 GB ram, it is a "powerful" server, up the default open files limit in Ubuntu
            if [ $(free -m | awk '/^Mem:/{print $2}') -gt 4000 ]; then
                sudo bash -c "echo '* soft nofile $(echo 8192 $(ulimit -Sn) | xargs -n1 | sort -g | tail -n1)' >> /etc/security/limits.conf"
                sudo bash -c "echo '* hard nofile $(echo 8192 $(ulimit -Hn) | xargs -n1 | sort -g | tail -n1)' >> /etc/security/limits.conf"
            fi
            
            ;;
        "5") # Configure advanced settings
     
            # Change default open files limits in Ubuntu. Increase to 1048576, or the highest allowed system limit.
            MIN=$(echo 1048576 $(cat /proc/sys/fs/file-max) | xargs -n1 | sort -g | head -n1)
            if Confirm "Do you want to change the open files limit to ${MIN} instead of 1024? (Needed for VERY powerful servers)" N; then
                sudo bash -c "echo '* soft nofile ${MIN}' >> /etc/security/limits.conf"
                sudo bash -c "echo '* hard nofile ${MIN}' >> /etc/security/limits.conf"
            fi
            # Change default inotify limits in Ubuntu.
            if Confirm "Do you want to increase the inotify limits? (Needed for VERY powerful servers)" N; then
                sudo bash -c "echo 'fs.inotify.max_user_watches = 524288' >> /etc/sysctl.conf"
                sudo bash -c "echo 'fs.inotify.max_user_instances = 512' >> /etc/sysctl.conf"
                sudo sysctl -p
            fi
	    # Change default aio-max-nr limit in Ubuntu. By default too low for a machine that runs multiple instances of MySQL or lots of things.
            if Confirm "Do you want to increase the aio-max-nr limit? (Needed for machines running a lot of things in parallel, such as multiple MySQL instances)" N; then
                sudo bash -c "echo 'fs.aio-max-nr=524288' >> /etc/sysctl.conf"
                sudo bash -c "echo '#fs.aio-max-nr=1048576' >> /etc/sysctl.conf"
                sudo sysctl -p
            fi

            if Confirm "Do you want to change the default TCP settings for a high-performance web server?" N; then
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
            if Confirm "Do you want to install zabbix agent (For monitoring)?" N; then
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
        
        "10") # Import keys from GitHub
            
            echo "Nothing here"
            DEFAULT_GH="JimCronqvist"
            read -e -i "$DEFAULT_GH" -p "Please enter the usernames you want to import keys from (space separated if multiple): " IMPORT_GH
            ssh-import-id-gh $IMPORT_GH
            
            ;;
        
        "11") # Install kubectl, helm, kustomize, eksctl, argocd cli, kompose, k9s
        
            # Install kubectl if not previously installed
            if ! command -v kubectl &> /dev/null; then
                curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
                curl -LO "https://dl.k8s.io/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl.sha256"
                echo "$(cat kubectl.sha256)  kubectl" | sha256sum --check
                sudo rm kubectl.sha256
                sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
                sudo rm kubectl
                kubectl version

                # Auto complete & alias (run as your user)
                source <(kubectl completion bash)
                echo "source <(kubectl completion bash)" >> ~/.bashrc
                alias k=kubectl
                complete -o default -F __start_kubectl k
            fi
            
            # Install eksctl if not previously installed
            if ! command -v eksctl &> /dev/null; then
                echo "eksctl not found, installing..."
                curl --silent --location "https://github.com/weaveworks/eksctl/releases/latest/download/eksctl_$(uname -s)_amd64.tar.gz" | tar xz -C /tmp
                sudo mv /tmp/eksctl /usr/local/bin
                eksctl version
            fi

            # Install kustomize if not previously installed
            if ! command -v kustomize &> /dev/null; then
                curl -s "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh"  | bash
                sudo install -o root -g root -m 0755 kustomize /usr/local/bin/kustomize
                sudo rm kustomize
                kustomize version
            fi
            
            # Install helm if not previously installed
            if ! command -v helm &> /dev/null; then
                echo "helm not found, installing..."
                curl https://baltocdn.com/helm/signing.asc | sudo apt-key add -
                sudo apt install apt-transport-https --yes
                echo "deb https://baltocdn.com/helm/stable/debian/ all main" | sudo tee /etc/apt/sources.list.d/helm-stable-debian.list
                sudo apt update
                sudo apt install helm -y
                helm version
            fi

            # Install argocd if not previously installed
            if ! command -v argocd &> /dev/null; then
                echo "argocd not found, installing..."
                curl -sSL -o argocd-linux-amd64 https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
                sudo install -m 555 argocd-linux-amd64 /usr/local/bin/argocd
                rm argocd-linux-amd64
                argocd version  
            fi
	    
            # Install kompose if not previously installed
            if ! command -v kompose &> /dev/null; then
                echo "argocd not found, installing..."
                sudo curl -sSL https://github.com/kubernetes/kompose/releases/download/v1.28.0/kompose-linux-amd64 -o kompose
                sudo install -o root -g root -m 0755 kompose /usr/local/bin/kompose
                sudo rm kompose
                kompose version
            fi
            
            # Install k9s if not previously installed
            if ! command -v k9s &> /dev/null; then
                REPO="derailed/k9s"
                VERSION=$(curl -s https://api.github.com/repos/${REPO}/releases/latest | grep 'tag_name' | cut -d\" -f4)
                curl -o k9s.tar.gz -L "https://github.com/derailed/k9s/releases/download/${VERSION}/k9s_Linux_amd64.tar.gz"
                sudo tar -C /usr/local/bin/ -zxvf k9s.tar.gz k9s 
                sudo install -p -m 755 -o root -g root k9s /usr/local/bin/
            fi

            ;;
            
        "12") # Install Node
            
            # Install Node 16 LTS
            curl -sL https://deb.nodesource.com/setup_16.x | sudo -E bash -
            sudo apt install nodejs -y
            sudo npm install npm@latest -g
            sudo npm install yarn@latest -g
            
            # Correct permissions after install
            sudo chown ubuntu:ubuntu /home/ubuntu/ -R
            
            ;;

        "13") # Install Database Utilities (Xtrabackup, mysqldump, mysql-client)
            
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
        
        "14") # Install Database
            
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

        "15") # Install Tailscale

            sudo apt-get remove tailscale -y
            #rm -f /var/lib/tailscale/tailscaled.state
            curl -fsSL https://tailscale.com/install.sh | sh

            if Confirm "Do you intend to use Tailscale as a subnet router? (only needed for first-time installs)" N; then
                # The below is required for exposing it as a subnet router
                echo 'net.ipv4.ip_forward = 1' | sudo tee -a /etc/sysctl.d/99-tailscale.conf
                echo 'net.ipv6.conf.all.forwarding = 1' | sudo tee -a /etc/sysctl.d/99-tailscale.conf
                sudo sysctl -p /etc/sysctl.d/99-tailscale.conf
                echo ""
                echo "Run the following command to start the VPN and to advertise one or more subnets."
                echo "sudo tailscale up --advertise-routes=192.168.0.0/24,192.168.1.0/24"
            else
                echo ""
                echo "Run: 'sudo tailscale up' to start the VPN, with any additional optional arguments."
            fi
            
            ;;
        
        "16") # Install Go

            VERSION="1.21.3"
            curl -O -L "https://golang.org/dl/go${VERSION}.linux-amd64.tar.gz"
            sudo tar -xzf go${VERSION}.linux-amd64.tar.gz -C /usr/local/
            echo 'export PATH=$PATH:/usr/local/go/bin' | sudo tee -a /etc/profile
            source /etc/profile
            go version
            
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
