#!/usr/bin/env bash

#
# This script will dump a single MySQL database table from a remote server and import it onto the machine the script is executed on.
# WARNING: This script will drop the database table on the local server if it already exist with the suffix "_old"
#
# Requirements:
# - SSH passwordless login to the remote db server
# - slow_query_log must be turned off, turn off by running the following mysql command:
#   SET GLOBAL slow_query_log=0
#
# Configuration:

SSH_HOST=""
SSH_USER="ubuntu"
SSH_CERT="/home/ubuntu/.ssh/id_rsa"

DB_SOURCE_USER="root"
DB_SOURCE_PASS=""

DB_DEST_HOST="localhost"
DB_DEST_USER="root"
DB_DEST_PASS=""

DATABASE="mtxprd"

TABLE=$1
TABLE_SUFFIX_OLD="_old"

# End of configuration.


function timestamp() {
    date +"%Y-%m-%d %H:%M:%S"
}


function drop_table {
    DROP_TABLE=$1
    echo "$(timestamp): Dropping table ${DROP_TABLE}"
    mysql -h ${DB_DEST_HOST} -P 3306 --protocol=tcp -u ${DB_DEST_USER} -p"${DB_DEST_PASS}" -e "DROP TABLE IF EXISTS \`${DATABASE}\`.\`${DROP_TABLE}\`"
}

function rename_table {
    SOURCE_TABLE=$1
    TARGET_TABLE=$2
    echo "$(timestamp): Rename ${DATABASE}.${SOURCE_TABLE} to ${DATABASE}.${TARGET_TABLE}"
    mysql -h ${DB_DEST_HOST} -P 3306 --protocol=tcp -u ${DB_DEST_USER} -p"${DB_DEST_PASS}" -e "SET FOREIGN_KEY_CHECKS=0; RENAME TABLE \`${DATABASE}\`.\`${SOURCE_TABLE}\` TO \`${DATABASE}\`.\`${TARGET_TABLE}\`"
}

LOCAL_GZIP=gzip
REMOTE_GZIP=gzip

if [ -x /usr/bin/pigz ]; then
    LOCAL_GZIP=pigz
fi

if [ $(ssh -i $SSH_CERT $SSH_USER@$SSH_HOST "which pigz >/dev/null && echo 1") -eq 1 ]; then
    REMOTE_GZIP=pigz
fi

echo "$(timestamp): $REMOTE_GZIP will be used for compression on the remote machine"
echo "$(timestamp): $LOCAL_GZIP will be used for decompression on this machine"

echo "$(timestamp): Starting the MySQL dump, this might take a while..."
ssh -i $SSH_CERT $SSH_USER@$SSH_HOST "mysqldump --single-transaction --set-gtid-purged=OFF --compress -u ${DB_SOURCE_USER} -p${DB_SOURCE_PASS} ${DATABASE} ${TABLE} | ${REMOTE_GZIP} -c --fast" | pv > latest.sql.gz
echo "$(timestamp): MySQL dump downloaded"

echo "$(timestamp): Decompressing the dump"
pv latest.sql.gz | $LOCAL_GZIP -dc > latest.sql && rm -f latest.sql.gz

echo "$(timestamp): Check the integrity of the dump"
if tail -n 1 latest.sql | grep -v -q 'Dump completed on'; then
    echo "$(timestamp): MySQL dump is not complete, aborting."
    exit 1
fi
echo "$(timestamp): Integrity validated"

echo "$(timestamp): Prepare the database for import"
drop_table "${TABLE}${TABLE_SUFFIX_OLD}"
rename_table "${TABLE}" "${TABLE}${TABLE_SUFFIX_OLD}"

echo "$(timestamp): Starting the MySQL import, this might take a while..."
pv latest.sql | mysql -u ${DB_DEST_USER} -p"${DB_DEST_PASS}" -A -D${DATABASE}

STATUS=$?
if [ "$STATUS" != 0 ]; then
    echo "$(timestamp): Error during the import, aborting."
    exit 1
fi
echo "$(timestamp): MySQL import sucessfully finished"
echo "$(timestamp): Completed"

exit 0
