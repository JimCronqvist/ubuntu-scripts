#/bin/bash

if [ $# -lt 1 ] ; then
    echo "You have not passed any arguments, use this script like this: 'bash passwordless.sh ubuntu@www.domain.com'"
    echo ""
    exit 1;
fi
HOST=$1

FILENAME=$1
if [[ $FILENAME != *"@"* ]] ; then
    FILENAME=$(logname)"@"$FILENAME
fi
FILENAME=$(sed s/[^a-z0-9]/_/g <<< $FILENAME)
FILENAME=$HOME"/.ssh/"$FILENAME"_id_rsa"
echo $FILENAME
PUB_FILENAME=$FILENAME".pub"

ssh-keygen -t rsa -b 4096 -N "" -f $FILENAME
ssh-copy-id -i $PUB_FILENAME $HOST
