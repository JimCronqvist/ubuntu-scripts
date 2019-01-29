#!/bin/bash

#
# Clone a bigger database to a smaller one for test usage, containing only the X newest rows for the tables.
#

DUMP_LIMIT=100000
EXCLUDE_DATA_FOR=( )
IGNORE_DUMP_LIMIT_FOR=( )

SOURCE_DB_HOST=
SOURCE_DB_USER=
SOURCE_DB_PASS=
SOURCE_DB_DATABASE=

DEST_DB_HOST=localhost
DEST_DB_USER=root
DEST_DB_PASS=
DEST_DB_ROOT_PASS=
DEST_DB_DATABASE=

# -------------------------------------------------------------------------------------------------------------------- #

RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

printf "\n${BLUE}There is a limit of ${DUMP_LIMIT} rows per table, except for:${NC} ${EXCLUDE_DATA_FOR[@]}\n"
printf "\n${RED}The following tables will be created but no data will be copied:${NC}\n"
printf "%s\n" "${EXCLUDE_DATA_FOR[@]}"

mysql -u ${SOURCE_DB_USER} -p${SOURCE_DB_PASS} -h ${SOURCE_DB_HOST} -N -e "
    SELECT
        information_schema.TABLES.table_name as name,
        information_schema.columns.column_name as primary_col
    FROM
        information_schema.TABLES
    LEFT JOIN
        information_schema.columns ON information_schema.columns.table_name = information_schema.TABLES.table_name
        AND information_schema.columns.table_schema = information_schema.TABLES.table_schema
        AND information_schema.columns.column_key = 'PRI'
    WHERE
        information_schema.TABLES.table_schema = '${SOURCE_DB_DATABASE}'" | while read name primary_col
do
    EXCLUDE=""
    for t in "${EXCLUDE_DATA_FOR[@]}"; do
        if [ "${t}" == "${name}" ]; then
            EXCLUDE="--no-data"
            break
        fi
    done

    # Create the database if it does not exist
    mysql -u root -p${DEST_DB_ROOT_PASS} -h ${DEST_DB_HOST} --execute="CREATE SCHEMA IF NOT EXISTS '${DEST_DB_DATABASE}';"

    # Dump the source database and import it to the destination database
    if [ "${primary_col}" == "NULL" ]; then
        printf "Dumping ${name} into destination database '${DEST_DB_DATABASE}' ${EXCLUDE}\n"
        mysqldump -u ${SOURCE_DB_USER} -p${SOURCE_DB_PASS} -h ${SOURCE_DB_HOST} \
            ${EXCLUDE} "${SOURCE_DB_DATABASE}" "${name}" | \
            mysql -u root -p${DEST_DB_ROOT_PASS} -h ${DEST_DB_HOST} "${DEST_DB_DATABASE}"
    else
        LIMIT_STATEMENT="LIMIT ${DUMP_LIMIT}"
        for t in "${IGNORE_DUMP_LIMIT_FOR[@]}"; do
            if [ "${t}" == "${name}" ]; then
                LIMIT_STATEMENT=""
                break
            fi
        done
        printf "Dumping ${name} into destination database '${DEST_DB_DATABASE}' ${EXCLUDE} ${LIMIT_STATEMENT}\n"
        mysqldump -u ${SOURCE_DB_USER} -p${SOURCE_DB_PASS} -h ${SOURCE_DB_HOST} \
            $EXCLUDE --opt --where="1 ORDER BY ${primary_col} DESC ${LIMIT_STATEMENT}" "${SOURCE_DB_DATABASE}" "${name}" | \
            mysql -u root -p${DEST_DB_ROOT_PASS} -h ${DEST_DB_HOST} "${DEST_DB_DATABASE}"
    fi
done

# Grant user access
mysql -u root -p${DEST_DB_ROOT_PASS} -h ${DEST_DB_HOST} \
    --execute="GRANT ALL PRIVILEGES ON ${DEST_DB_DATABASE}.* TO ${DEST_DB_USER} IDENTIFIED BY '${DEST_DB_PASS}';"
