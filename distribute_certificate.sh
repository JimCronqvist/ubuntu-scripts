#!/bin/bash
for var in "$@"
do
	ssh-copy-id -i ~/.ssh/id_rsa.pub "ubuntu@"$var && ssh -t $var "sudo bash -c \"echo 'ubuntu ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers.d/ubuntu\""
done
