#!/bin/bash

#
# This script will dump a single MySQL database from a remote server and import it onto the machine the script is executed on.
# WARNING: This script will drop the database on the local server if it already exist.
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

DATABASE="test"
DATABASE_OLD=${DATABASE}"_old"
DATABASE_TEMP=${DATABASE}"_temp"

# End of configuration.


function timestamp() {
    date +"%Y-%m-%d %H:%M:%S"
}

function rename_db {
    SOURCE_SCHEMA=$1
    TARGET_SCHEMA=$2
    
    echo "$(timestamp): Renaming DB ${SOURCE_SCHEMA} to ${TARGET_SCHEMA}"

    TIMESTAMP=`date +%s`
    TABLES=`mysql -p${DB_DEST_PASS} -u ${DB_DEST_USER} -h ${DB_DEST_HOST} -P 3306 --protocol=tcp -e "select TABLE_NAME from information_schema.tables where table_schema='$SOURCE_SCHEMA' and TABLE_TYPE='BASE TABLE'" -sss`

    STATUS=$?
    if [ "$STATUS" != 0 ] || [ -z "$TABLES" ]; then
        echo "$(timestamp): Error retrieving tables from ${SOURCE_SCHEMA}"
        exit 1
    fi  
    
    echo "$(timestamp): Drop the target schema if it exists and create a new schema"
    mysql -p${DB_DEST_PASS} -u ${DB_DEST_USER} -h ${DB_DEST_HOST} -P 3306 --protocol=tcp -e "DROP SCHEMA IF EXISTS ${TARGET_SCHEMA}; CREATE SCHEMA ${TARGET_SCHEMA}"
 
    echo "$(timestamp): Dropping old tables from ${TARGET_SCHEMA} and renaming tables FROM ${SOURCE_SCHEMA}"

    VIEWS=`mysql -h ${DB_DEST_HOST} -u ${DB_DEST_USER} -p${DB_DEST_PASS} --protocol=tcp -P 3306 -e "select TABLE_NAME from information_schema.tables where table_schema='${SOURCE_SCHEMA}' and TABLE_TYPE='VIEW'" -sss`
    if [ -n "$VIEWS" ]; then
           mysqldump -h ${DB_DEST_HOST} -p${DB_DEST_PASS} -u ${DB_DEST_USER} --protocol=tcp -P 3306 ${SOURCE_SCHEMA} $VIEWS > /tmp/${SOURCE_SCHEMA}_views${TIMESTAMP}.dump
    fi  

    for TABLE in $TABLES; do
        echo "$(timestamp): Drop and rename ${SOURCE_SCHEMA}.${TABLE} to ${TARGET_SCHEMA}.${TABLE}"
        mysql -h ${DB_DEST_HOST} -P 3306 --protocol=tcp -p${DB_DEST_PASS} -u ${DB_DEST_USER} -e "SET FOREIGN_KEY_CHECKS=0; RENAME TABLE ${SOURCE_SCHEMA}.${TABLE} TO ${TARGET_SCHEMA}.${TABLE}"
    done

    if [ -n "$VIEWS" ]; then
        echo "$(timestamp): loading views"
        mysql -h ${DB_DEST_HOST} -p${DB_DEST_PASS} -u ${DB_DEST_USER} --protocol=tcp -P 3306 ${TARGET_SCHEMA} < /tmp/${SOURCE_SCHEMA}_views${TIMESTAMP}.dump
    fi  

    # finally drop the source schema
    mysql -p${DB_DEST_PASS} -u ${DB_DEST_USER} -h ${DB_DEST_HOST} -P 3306 --protocol=tcp -e "DROP SCHEMA IF EXISTS ${SOURCE_SCHEMA}"
}

function drop_db {
    SCHEMA=$1
    echo "$(timestamp): Dropping database ${SCHEMA}"
    mysql -p${DB_DEST_PASS} -u ${DB_DEST_USER} -h ${DB_DEST_HOST} -P 3306 --protocol=tcp -e "DROP SCHEMA IF EXISTS ${SCHEMA}"
}

function create_db {
    SCHEMA=$1
    echo "$(timestamp): Creating database ${SCHEMA}"
    mysql -p${DB_DEST_PASS} -u ${DB_DEST_USER} -h ${DB_DEST_HOST} -P 3306 --protocol=tcp -e "CREATE DATABASE ${SCHEMA}"
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
ssh -i $SSH_CERT $SSH_USER@$SSH_HOST "mysqldump --single-transaction --events --triggers --routines --set-gtid-purged=OFF --compress -u ${DB_SOURCE_USER} -p${DB_SOURCE_PASS} ${DATABASE} | ${REMOTE_GZIP} -c --fast" | pv > latest.sql.gz 
echo "$(timestamp): MySQL dump downloaded"

echo "$(timestamp): Decompressing the dump" 
pv latest.sql.gz | $LOCAL_GZIP -dc > latest.sql && rm -f latest.sql.gz

echo "$(timestamp): Check the integrity of the dump"
if tail -n 1 latest.sql | grep -v -q 'Dump completed on'; then
    echo "$(timestamp): MySQL dump is not complete, aborting."
    exit 1
fi
echo "$(timestamp): Integrity validated"

echo "$(timestamp): Prepare the databases for import"
drop_db ${DATABASE_TEMP}
create_db ${DATABASE_TEMP}
drop_db ${DATABASE_OLD}

echo "$(timestamp): Starting the MySQL import, this might take a while..."
pv latest.sql | mysql -u $DB_DEST_USER -p$DB_DEST_PASS -A -D${DATABASE_TEMP}

STATUS=$?
if [ "$STATUS" != 0 ]; then
    echo "$(timestamp): Error during the import, aborting."
    exit 1
fi
echo "$(timestamp): MySQL import sucessfully finished"

echo "$(timestamp): Set the newly imorted database as active"
rename_db ${DATABASE} ${DATABASE_OLD}
rename_db ${DATABASE_TEMP} ${DATABASE}

echo "$(timestamp): Completed"

exit 0
