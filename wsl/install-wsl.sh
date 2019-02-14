#!/bin/bash

#
# Install script for Docker on Windows Subsystem for Linux (WSL)
# Prerequisites: Enable "Expose daemon on tcp://localhost:2375 without TLS" in Docker for Windows -> Settings.
#

sudo apt-get update
sudo apt-get dist-upgrade -y
sudo apt-get install -y apt-transport-https ca-certificates curl software-properties-commom unzip

# Install docker
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
sudo apt-key fingerprint 0EBFCD88
sudo add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
sudo apt-get update
sudo apt-get install -y docker-ce
sudo usermod -aG docker $USER
echo "export DOCKER_HOST=tcp://localhost:2375" >> ~/.bashrc && source ~/.bashrc
sudo tee -a /etc/wsl.conf <<EOF
[automount]
root = /
options = "metadata"
EOF

# Install docker-compose
DOCKER_COMPOSE_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep 'tag_name' | cut -d\" -f4)
sudo curl -L "https://github.com/docker/compose/releases/download/$DOCKER_COMPOSE_VERSION/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose
sudo curl -L "https://raw.githubusercontent.com/docker/compose/$DOCKER_COMPOSE_VERSION/contrib/completion/bash/docker-compose" -o /etc/bash_completion.d/docker-compose

# Install AWS CLI
curl "https://s3.amazonaws.com/aws-cli/awscli-bundle.zip" -o "awscli-bundle.zip"
unzip awscli-bundle.zip
sudo ./awscli-bundle/install -i /usr/local/aws -b /usr/local/bin/aws
rm awscli-bundle.zip -f && rm ./awscli-bundle/ -rf

# Install mysql-utilities
sudo apt-get install mysql-utilities -y

# Set up SSH Agent Forwarding: Warning - using a wildcard for hosts, use with care, security risks exist.
mkdir -p ~/.ssh && chmod 0600 ~/.ssh
tee -a ~/.ssh/config <<EOF
Host *
  ForwardAgent yes
EOF
chmod 0600 ~/.ssh/config
echo 'eval `ssh-agent -s` && ssh-add ~/.ssh/id_rsa' >> ~/.bashrc && source ~/.bashrc

# Install node 10
curl -sL https://deb.nodesource.com/setup_10.x | sudo -E bash -
sudo apt install nodejs -y


echo "Install complete, please copy your 'id_rsa' file into '~/.ssh/' and restart your computer."
