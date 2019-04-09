#!/usr/bin/env bash

# Configure this script to run at 2am daily by:
# sudo bash -c "echo '0 2 * * * root /root/mysql-backup.sh' >> /etc/cron.d/mysql-backup"

USER="root"
PASS="password"
BACKUP_DIR="/var/backups/mysql"
KEEP_BACKUPS=30
SOCKET="/var/lib/mysql/mysql.sock"
HOST="127.0.0.1"
COMPRESSION_LEVEL=6


MYSQL="$(which mysql)"
MYSQLDUMP="$(which mysqldump)"
GZIP="$(which gzip)"
HOSTNAME="$(hostname --fqdn)"

BLUE=$(tput setaf 6)
GREEN=$(tput setaf 2)
RED=$(tput setaf 1)
NORMAL=$(tput sgr0)

bytesToHuman() {
    b=${1:-0}; d=''; s=0; S=(Bytes {K,M,G,T,P,E,Z,Y}iB)
    while ((b > 1024)); do
        d="$(printf ".%02d" $((b % 1024 * 100 / 1024)))"
        b=$((b / 1024))
        let s++
    done
    echo "$b$d ${S[$s]}"
}

timestamp() {
    date +"%Y-%m-%d %H:%M:%S"
}

# Create the $CON variable: Use $SOCKET if not empty, otherwise use $HOST
CON="--socket=${SOCKET}"
if [ -z "${SOCKET}" ]; then
    CON="--host=${HOST}"
fi

mkdir -p "${BACKUP_DIR}"
echo -e "${BLUE}$(timestamp): Run MySQL backup for the following databases:${NORMAL}"
DBS="$(MYSQL_PWD="${PASS}" $MYSQL --no-defaults $CON -u $USER -Bse 'SHOW DATABASES;' | grep -Ev '^(information_schema|performance_schema|test|sys)$')"
echo "$DBS" | sed -e 's/^/- /'
echo ""

for db in $DBS
do
    FILE="${BACKUP_DIR}/${HOSTNAME}.${db}.`date +%Y-%m-%d_%H.%M.%S`.sql.gz"

    START=$(date +%s)
    MYSQL_PWD="${PASS}" $MYSQLDUMP --no-defaults --no-tablespaces --single-transaction --quick --quote-names --max_allowed_packet=16M --set-gtid-purged=OFF --triggers --routines --events $CON -u "${USER}" "${db}" | $GZIP -${COMPRESSION_LEVEL} > "${FILE}"
    RESULT=$?
    END=$(date +%s)
    SECONDS=$((END-START))

    SIZE=$(wc -c < "${FILE}")

    if [ $RESULT -eq 0 ]; then
        echo -e "${GREEN}Database '${db}' backup successfully completed.${NORMAL} (${SECONDS} seconds)"
        echo "created '${FILE}' ($(bytesToHuman ${SIZE}))"
    else
        echo -e "${RED}Error found during backup of database '${db}'${NORMAL}"
    fi

    PREFIX="${BACKUP_DIR}/${HOSTNAME}.${db}."
    NUM_BACKUPS=$(ls -l "${PREFIX}"* | wc -l)
    if [ $NUM_BACKUPS > $KEEP_BACKUPS ]; then
        NUM_REMOVE=$[NUM_BACKUPS - KEEP_BACKUPS]
        REMLIST=$(ls -ctr "${PREFIX}"* | head -n ${NUM_REMOVE})
        for i in $REMLIST
        do
            rm -v -f $i
        done
    fi    

    echo ""
done

echo "Backup completed at: $(timestamp)."
