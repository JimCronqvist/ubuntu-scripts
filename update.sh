#!/bin/bash

for var in "$@"
do
    ssh -t $var "sudo apt-get dist-upgrade && grep -s -q 'Vendor: VMware' /proc/scsi/scsi && ! test -e /var/run/vmtoolsd.pid && sudo /usr/bin/vmware-config-tools.pl -d || echo -e '\nVmware tools does not need to be re-compiled\n'"
done
