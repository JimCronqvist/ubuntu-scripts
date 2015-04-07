#!/bin/bash

#CREATE USER 'backup'@'localhost' IDENTIFIED BY 'secret'; GRANT SELECT, SHOW VIEW, RELOAD, REPLICATION CLIENT, EVENT, TRIGGER ON *.* TO 'backup'@'localhost';

DB_HOST="localhost"
DB_USER="backup"
DB_PASS="password"

mysqldump --single-transaction --master-data --complete-insert -h $DB_HOST -u $DB_USER -p$DB_PASS --all-databases > $DB_HOST"_"`date +%Y-%m-%d_%H.%M.%S.sql`
