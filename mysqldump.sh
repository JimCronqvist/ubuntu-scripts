#!/bin/bash

#CREATE USER 'backup'@'localhost' IDENTIFIED BY 'secret'; GRANT SELECT, SHOW VIEW, RELOAD, REPLICATION CLIENT, EVENT, TRIGGER ON *.* TO 'backup'@'localhost';

DB_HOST="localhost"
DB_USER="backup"
DB_PASS="password"

# Keep the SQL dumps for X days, 0 = forever
KEEP_DAYS=0
BACKUP_FOLDER="/home/ubuntu/mysqldump/"


mkdir -p "$BACKUP_FOLDER"

# Delete old backup files.
if [ $KEEP_DAYS -gt 0 ]; then
    find "$BACKUP_FOLDER"* -maxdepth 0 -type f -mtime +$KEEP_DAYS -iname "$DB_HOST*.sql" -print -delete
fi

mysqldump --single-transaction --master-data --complete-insert --events --triggers --routines -h $DB_HOST -u $DB_USER -p$DB_PASS --all-databases > "$BACKUP_FOLDER$DB_HOST""_"`date +%Y-%m-%d_%H.%M.%S.sql`
