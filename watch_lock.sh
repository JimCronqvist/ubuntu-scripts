#!/bin/bash

CURRENT_SCRIPT=$(basename "$0")
BASE_DIR="/var/www"
LOG_FILE="/dev/null"


RUNNING=$(pgrep -fl ${CURRENT_SCRIPT} | grep -E "bash|${CURRENT_SCRIPT}" | wc -l)
if [ $RUNNING -gt 2 ]; then
    echo "Instance of ${CURRENT_SCRIPT} is already running ($RUNNING)..."
    exit
fi

composer config --global discard-changes true

declare -A LOCKFILES

LB='\033[1;34m'
GR='\033[0;32m'
YL='\033[1;33m'
RD='\033[0;31m'
NC='\033[0m' # No Color


function checkLockFiles {
    # Scan each folder for lock files and monitor their change
    for LOCKFILE in $(find ${BASE_DIR}/*/*.lock -maxdepth 0); do
        if [ -d "$(dirname $LOCKFILE)/.git" ]; then
            cd $(dirname $LOCKFILE)
            if [ "$(git ls-files $LOCKFILE | wc -l)" != "1" ]; then
                echo -e " - ${LB}${LOCKFILE}${NC}: ${RD}Skipping - lock file not commited${NC}" | tee -a $LOG_FILE
                continue;
            fi
            LOCKFILE_NAME=$(basename $LOCKFILE)
            OLD_COMMIT_ID=${LOCKFILES[${LOCKFILE}]}
            CURRENT_COMMIT_ID=$(git log -n 1 --pretty=format:%h -- ${LOCKFILE_NAME})

            if [ "$OLD_COMMIT_ID" == '' ] || [ "$OLD_COMMIT_ID" != "$CURRENT_COMMIT_ID" ]; then
                if [ "$OLD_COMMIT_ID" == '' ]; then
                    echo -e " - ${LB}${LOCKFILE}${NC}: First iteration. Now at commit: ${GR}${CURRENT_COMMIT_ID}${NC}" | tee -a $LOG_FILE
                else
                    echo -e " - ${LB}${LOCKFILE}${NC}: Change detected. Updated from ${YL}${OLD_COMMIT_ID}${NC} to ${GR}${CURRENT_COMMIT_ID}${NC}" | tee -a $LOG_FILE
                fi

                case $LOCKFILE_NAME in
                    "composer.lock" )
                        composer install &> /dev/null ;;
                    "yarn.lock" )
                        yarn install --pure-lockfile &> /dev/null ;;
                esac
                LOCKFILES[$LOCKFILE]=$CURRENT_COMMIT_ID
            else
                echo -e " - ${LB}${LOCKFILE}${NC}: Unchanged @ commit ${YL}${CURRENT_COMMIT_ID}${NC}" | tee -a $LOG_FILE
            fi
        fi
    done
}

echo $(date) | tee -a $LOG_FILE

while [ 1 ]
do
    checkLockFiles
    sleep 10
done
