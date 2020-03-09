#!/bin/bash

#
# Install script for an OpenVPN Server
#


# Abort if not root
if [ "$(id -u)" -ne "0" ] ; then
    echo "This script needs to be ran from a user with root permissions.";
    exit 1;
fi

# Ensure correct hostname
echo "Your current hostname is: \"$(hostname --fqdn)\", please abort and update before you proceed if this is incorrect."
read -e -i "" -p "Press enter to continue" DUMMY_PAUSE

# Install docker & docker-compose
cd ~ && rm -f ~/install-docker-host.sh && wget https://raw.githubusercontent.com/JimCronqvist/ubuntu-scripts/master/install-docker-host.sh && chmod +x install-docker-host.sh
./install-docker-host.sh -o 7  # Step: Install Docker

# Set up OpenVPN
mkdir -p ~/openvpn && cd ~/openvpn

tee ~/openvpn/docker-compose.yml <<EOF
version: '2'
services:
  openvpn:
    cap_add:
      - NET_ADMIN
    image: kylemanna/openvpn
    container_name: openvpn
    ports:
      - "1194:1194/udp"
    restart: unless-stopped
    working_dir: /etc/openvpn/
    volumes:
      - ./openvpn-data/:/etc/openvpn
EOF

# Initial setup
docker-compose run --rm openvpn ovpn_genconfig -N -d -u udp://$(hostname --fqdn)
echo "Set a passphrase for the CA.key, and set the host"
docker-compose run --rm openvpn ovpn_initpki
sudo chown -R $(whoami): ./openvpn-data

# Start up the container
docker-compose up -d

# Generate Client Certificate
RANDOM_STRING=$(cat /dev/urandom | tr -dc 'a-z0-9' | fold -w 6 | head -n 1)
CLIENTNAME="$(hostname --fqdn)_$RANDOM_STRING"
docker-compose run --rm openvpn easyrsa build-client-full $CLIENTNAME nopass
echo "Enter the passphrase used during setup for the CA.key"
docker-compose run --rm openvpn ovpn_getclient $CLIENTNAME > $CLIENTNAME.ovpn
sed -i -E 's/^redirect-gateway def1/#redirect-gateway def1/g' $CLIENTNAME.ovpn
tee -a $CLIENTNAME.ovpn <<EOF

### DNS Configurations Below
#pull-filter ignore "dhcp-option DNS"
#dhcp-option DNS 8.8.8.8
#dhcp-option DNS 8.8.4.4
#block-outside-dns

### Route Configurations Below
#push "route 192.168.1.0 255.255.255.0 vpn_gateway 100"
#push "route 192.168.0.0 255.255.255.0 vpn_gateway 100"
#push "route 192.168.0.5 255.255.255.255 vpn_gateway 100"
#push "route 100.101.1.4 255.255.255.255 vpn_gateway 100"

pull-filter ignore redirect-gateway
#redirect-gateway def1
EOF
