#!/bin/bash

COPY_IDENTITY_FILE="/home/ubuntu/.ssh/id_rsa.pub"

for var in "$@"
do
    cat $COPY_IDENTITY_FILE | ssh -t $var 'umask 0077; mkdir -p .ssh; cat >> .ssh/authorized_keys && echo "Key copied" || echo "Key not copied"'
    
    # Optional if you want to enable sudo without password - if not, comment it away
    ssh -t $var "sudo bash -c \"echo 'ubuntu ALL=(ALL) NOPASSWD:ALL' | ( umask 337; cat >> /etc/sudoers.d/ubuntu; )\""
    
    # Run the below command on the remote server to disable password authentication via ssh
    #sudo sed -i -E 's/(#?)PasswordAuthentication (yes|no)/PasswordAuthentication no/g' /etc/ssh/sshd_config && sudo service ssh restart
done
