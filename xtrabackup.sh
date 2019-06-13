#!/bin/bash

set -eu

#
# xtrabackup.sh script that performs full and incremental backups, as well as the restore procedure. With backup rotation.
#
# Ensure the user has the correct permissions, create a user by:
# CREATE USER 'xtrabackup'@'localhost' IDENTIFIED BY 'password';
# GRANT RELOAD, LOCK TABLES, PROCESS, REPLICATION CLIENT, CREATE TABLESPACE, CREATE, INSERT, SELECT, Show Databases ON *.* TO 'xtrabackup'@'localhost';
# FLUSH PRIVILEGES;
#
# Configure this script to run a full backup at 3am and incremental backups the others, daily by:
# sudo bash -c "echo '0 3 * * * root ulimit -n 1048576 && /root/xtrabackup.sh full' >> /etc/cron.d/xtrabackup"
# sudo bash -c "echo '0 0-2,4-23 * * * root ulimit -n 1048576 && /root/xtrabackup.sh incr' >> /etc/cron.d/xtrabackup"
#
#
# Written by Jim Cronqvist <jim.cronqvist@gmail.com>
#



## Start of Config

PASSWORD="password"
MAX_FULL_BACKUPS=3
VERBOSE=0

SOCKET="/var/lib/mysql/mysql.sock"
USER="xtrabackup"
BACKUP_DIR="/var/backups/xtrabackup"
DATA_DIR="/var/lib/mysql"
DELETE_OLD_BACKUPS_AT="after" # Allows: before|after - use "after" in all cases except if you are low on disk space

## End of Config


BLUE=$(tput setaf 6)
GREEN=$(tput setaf 2)
RED=$(tput setaf 1)
NORMAL=$(tput sgr0)

XTRABACKUP_CON_ARGS="--socket=$SOCKET --user=$USER --password=$PASSWORD"
RESTORE_DIR="$BACKUP_DIR/restore"


timestamp() {
    date +"%Y-%m-%d %H:%M:%S"
}

log() {
    echo -e "${BLUE}[$(date +"%Y-%m-%d %H:%M:%S")]: $@ ${NORMAL}"
}

die() {
	echo -e 1>&2 "${RED}[$(date +"%Y-%m-%d %H:%M:%S")]: $@ ${NORMAL}"
	exit 1
}

timestampFolder() {
    date +"%Y-%m-%d_%H-%M-%S"
}

requireInstalled() {
    INSTALLED=$(which "$1")
    [[ -f "$INSTALLED" ]] || die "$1: command not found. Please install to proceed."
}


usage() {
    echo "Usage: $(basename $0) [full|incr|list|restore]"
    echo " full      Perform Full Backup"
    echo " incr      Perform Incremental Backup"
    echo " list      List all available backups to restore from"
    echo " restore   Prepare a restore. Safe to run on a running MySQL server, it is prepared in a temp folder."
    echo ""
    exit 1
}

delete_old_backups()
{
    if [[ "$1" == "$DELETE_OLD_BACKUPS_AT" ]]; then
        # Delete empty folders without a full backup inside - they should not exist
        find "$BACKUP_DIR" -maxdepth 1 -mmin +1 -type d -empty -delete

        log "Delete old backups $1 completion"
        find "$BACKUP_DIR" -maxdepth 2 -type d -name full | grep -v "$RESTORE_DIR" | sort | head -n -${MAX_FULL_BACKUPS} | sed 's/\/full$//g' | while read backup
        do
            rm -rf "$backup/"
        done
        log "Old backups has been deleted!"
    fi
}

log_file() {
    if [[ "$VERBOSE" == "true" ]] || [[ "$VERBOSE" == "1" ]]; then
        echo "/proc/$$/fd/1"
    else
        echo "/tmp/xtrabackup-${FUNCNAME[1]}-$(timestampFolder).log"
    fi
}

xtrabackup_fail () {
	die "Xtrabackup (${FUNCNAME[1]}) Failed! See $(echo "$LOG_FILE" | sed 's/\&>> //') for details, aborting.\n"
}

full_backup()
{
    LOG_FILE="$(log_file)"

    THIS_BACKUP_DIR="$BACKUP_DIR/$(timestampFolder)"
    mkdir -p "$THIS_BACKUP_DIR"
    delete_old_backups "before"
    log "Performing Full backup"
    xtrabackup --backup ${XTRABACKUP_CON_ARGS} --check-privileges --history --slave-info --galera-info --compress --compress-threads=4 --target-dir="$THIS_BACKUP_DIR/full" &>> "$LOG_FILE" || xtrabackup_fail
    log "Full backup Done!"
    delete_old_backups "after"

    rm -f "$LOG_FILE"
}

incremental_backup()
{
    LOG_FILE="$(log_file)"

    # Find the last full backup dir
    THIS_BACKUP_DIR=$(find "$BACKUP_DIR" -maxdepth 2 -type d -name full | grep -v "$RESTORE_DIR" | sort | tail -n 1 | sed 's/\/full$//g')
    log "Last full backup: $THIS_BACKUP_DIR/full"
    if [[ ! -d "$THIS_BACKUP_DIR/full" ]]; then
        die "ERROR: Unable to find the last Full backup. Aborting..."
    fi

    # Calculate which increment number this new backup will have in relation to any previous incremental backups
    NUMBER=1
    INCREMENTAL_BASEDIR="$THIS_BACKUP_DIR/full"
    if [[ -f "$THIS_BACKUP_DIR/last_incremental_number" ]]; then
        NUMBER=$(($(cat "$THIS_BACKUP_DIR/last_incremental_number") + 1))
        INCREMENTAL_BASEDIR="$THIS_BACKUP_DIR/incr$(($NUMBER - 1))"
    fi

    # Ensure the folder is empty, in case there has been any previous failed increment
    rm -rf "$THIS_BACKUP_DIR/incr$NUMBER/"

    log "Performing Incremental backup #$NUMBER"
    xtrabackup --backup ${XTRABACKUP_CON_ARGS} --check-privileges --history --slave-info --galera-info --compress --compress-threads=4 --incremental --target-dir="$THIS_BACKUP_DIR/incr$NUMBER" --incremental-basedir="$INCREMENTAL_BASEDIR" &>> "$LOG_FILE" || xtrabackup_fail

    echo "$NUMBER" > "$THIS_BACKUP_DIR/last_incremental_number"
    log "Incremental backup #$NUMBER done!"

    rm -f "$LOG_FILE"
}

restore()
{
    requireInstalled "qpress"
    LOG_FILE="$(log_file)"

    # Prompt to choose which backup we want to restore
    echo "For more details about the backups available, please use the list option first."
    echo ""
    PS3='Please choose which backup to restore: '
    FULL_BACKUPS=($(find "$BACKUP_DIR" -mindepth 2 -maxdepth 2 -type d | grep -v "$RESTORE_DIR" | sort | sed -r 's/(.*)\//\1|/'))
    select opt in "${FULL_BACKUPS[@]}"
    do
        FULL_BACKUP_DIR=$(echo "$opt" | cut -d'|' -f1 | sed 's/\/full$//g')
        INCREMENT=$(( $(echo "$opt" | cut -d'|' -f2 | sed -r 's/(incr|full)//') + 0 ))

        if [[ ! -z $FULL_BACKUP_DIR ]]; then
            break
        fi
    done

    log "Xtrabackup Restore initialized - Backup chosen to restore: $FULL_BACKUP_DIR (with $INCREMENT increments)"

    log "Syncing the backup to the restore folder..."
    rsync --quiet -ah --delete "$FULL_BACKUP_DIR/" "$RESTORE_DIR/" || die "Sync of the backup to the restore folder failed"
    log "Sync done!"

    log "Decompressing the Full backup..."
    xtrabackup --decompress --remove-original --parallel=4 --target-dir="$RESTORE_DIR/full" &>> "$LOG_FILE" || xtrabackup_fail
    log "Decompressing done!"

    log "Preparing the Full backup..."
    xtrabackup --prepare --apply-log-only --target-dir="$RESTORE_DIR/full" &>> "$LOG_FILE" || restore_fail
    log "Preparing done!"

    P=1
    while [[ -d "$RESTORE_DIR/incr$P" ]] && [[ ${P} -le ${INCREMENT} ]]
    do
        log "Decompressing incremental #$P"
        xtrabackup --decompress --remove-original --parallel=4 --target-dir="$RESTORE_DIR/incr$P" &>> "$LOG_FILE" || xtrabackup_fail
        log "Decompressing incremental #$P done!"

        log "Preparing incremental #$P"
        xtrabackup --prepare --apply-log-only --target-dir="$RESTORE_DIR/full" --incremental-dir="$RESTORE_DIR/incr$P" &>> "$LOG_FILE" || xtrabackup_fail
        log "Preparing incremental #$P done!"
        P=$(($P+1))
    done

    # Finalizing the prepare by rolling back the uncommitted transactions to avoid MySQL going into crash recovery on start
    log "Rolling back the uncommitted transactions to make the backup fully ready for restore"
    xtrabackup --prepare --target-dir="$RESTORE_DIR/full" &>> "$LOG_FILE" || xtrabackup_fail
    log "Restore is now fully prepared!"

    rm -f "$LOG_FILE"

    echo ""
    echo "Run the following commands to use the restored backup:"
    echo "sudo systemctl stop mysql"
    echo "sudo rm -rf $DATA_DIR/*"
    echo "sudo xtrabackup --move-back \"$RESTORE_DIR/full\""
    echo "sudo chown -R mysql:mysql $DATA_DIR"
    echo "sudo systemctl start mysql"
}

list()
{
    mkdir -p "$BACKUP_DIR"
    echo "$BACKUP_DIR"
    find "$BACKUP_DIR" -maxdepth 2 -type d -name full | sort | sed 's/\/full$//g' | sed "s#$BACKUP_DIR/##g" | while read backup
    do
        SIZE=$(du -sh "$BACKUP_DIR/$backup/full" | cut -f1)
        DATE=$(echo "$backup" | sed 's/_/ /' | sed 's/-/:/g3')
        if [[ "$DATE" == "restore" ]]; then
            echo -e "── Restore ($SIZE) - ${RED}Consider deleting this data to free up space${NORMAL}"
        else
            echo "── Full: $DATE ($SIZE)"
        fi

        find "$BACKUP_DIR/$backup" -maxdepth 1 -type d -name incr* | sort | sed "s#$BACKUP_DIR/##g" | while read incr
        do
            DATE=$(stat "$BACKUP_DIR/$incr" | grep 'Modify:' | cut -d' ' -f 2-3 | cut -d '.' -f1)
            INCREMENT=$(echo "$incr" | cut -d'/' -f 2 | sed 's/incr//')
            SIZE=$(du -sh "$BACKUP_DIR/$incr" | cut -f1)
            echo "   └── Incr $INCREMENT: $DATE ($SIZE)"
        done
    done

    echo ""
    echo "Total: $(find "$BACKUP_DIR" -maxdepth 2 -type d -name full | grep -v "$RESTORE_DIR" | wc -l) full backups"
}


requireInstalled "xtrabackup"

case ${1:-help} in
    "full")
        full_backup
        ;;
    "incr")
        incremental_backup
        ;;
    "restore")
        restore
        ;;
    "list")
        list
        ;;
    *)
        usage
        ;;
esac

