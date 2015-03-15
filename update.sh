#!/bin/bash

for var in "$@"
do
    echo -e "$(tput setaf 2)\nConnecting to $var \n $(tput sgr0)"
    ssh -t $var "sudo apt-get dist-upgrade && grep -s -q 'Vendor: VMware' /proc/scsi/scsi && ! test -e /var/run/vmtoolsd.pid && sudo /usr/bin/vmware-config-tools.pl -d || echo -e 'Vmware tools does not need to be re-compiled\n'
done
