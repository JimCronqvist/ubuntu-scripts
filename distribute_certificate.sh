#!/bin/bash
for var in "$@"
do
	ssh-copy-id -i ~/.ssh/id_rsa.pub "ubuntu@"$var && ssh -t $var "sudo bash -c \"echo 'ubuntu ALL=(ALL) NOPASSWD:ALL' | ( umask 337; cat >> /etc/sudoers.d/ubuntu; )\""
done
