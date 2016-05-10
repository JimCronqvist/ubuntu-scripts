#!/bin/bash

#
# This script will dump a MySQL database on a remote server and import it on the machine the script is executed on.
# WARNING: This script will drop all databases that match with the ones on the remote server on the local server.
#
# Requirements:
# - SSH login to the remote server by a certificate
# - slow_query_log must be turned off, you can turn it off by running the following mysql command:
#   SET GLOBAL slow_query_log=0
#
# Configuration:

DB_USER="root"
DB_PASS=""
SSH_HOST=""
SSH_USER="ubuntu"
SSH_CERT="./.ssh/id_rsa"

# End of configuration.

LOCAL_GZIP=gzip
REMOTE_GZIP=gzip

if [ -x /usr/bin/pigz ]; then
    LOCAL_GZIP=pigz
fi

if [ $(ssh -i $SSH_CERT $SSH_USER@$SSH_HOST "which pigz >/dev/null && echo 1") -eq 1 ]; then
    REMOTE_GZIP=pigz
fi

echo "$REMOTE_GZIP will be used for compression on the remote machine"
echo "$LOCAL_GZIP will be used for decompression on this machine"
date
echo "Starting the MySQL dump and import, this could take a while..."
ssh -i $SSH_CERT $SSH_USER@$SSH_HOST "mysqldump --single-transaction --events --triggers --routines --compress --all-databases --add-drop-database -u $DB_USER -p$DB_PASS | $REMOTE_GZIP -c --fast" | pv > latest.sql.gz && date && echo "Starting the import.." && pv latest.sql.gz | $LOCAL_GZIP -dc | mysql -u $DB_USER -p$DB_PASS
date
echo "The db import has finished."
