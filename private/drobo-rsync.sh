#!/bin/bash

#If you are using cygwin, please make sure that you are mounting the /cygdrive within /etc/fstab with the option "noacl" to prevent weird permissions.


FROM="/cygdrive/j/"
TO="/cygdrive/i/"


if [ $# -lt 1 ] ; then
    echo "You need to pass in which of the root folders in the backup you want to backup, for example: ./drobo-rsync.sh Pictures"
    exit 1
fi

for var in "$@"
do
    echo -e "$(tput setaf 2)\nSyncing folder: \"$var\" \n $(tput sgr0)"
    echo "Backup started at $(date '+%Y-%m-%d %H:%M:%S')" >> "$TO/$var.log"
    rsync -vrltDW -hh --no-p --no-g --chmod=ugo=rwX --progress --stats "$FROM/$var/" "$TO/$var/"
    echo "Backup finished at $(date '+%Y-%m-%d %H:%M:%S')" >> "$TO/$var.log"
done
