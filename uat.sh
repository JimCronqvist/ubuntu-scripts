#!/bin/bash

FEATURE_HOME="/var/www/features"
REPO_HOME="/var/www/app"
LOG_FILE="/var/log/uat.log"


echo $(date) | tee -a $LOG_FILE
cd $REPO_HOME || exit 1
mkdir -p $FEATURE_HOME

git fetch origin
git remote update origin --prune

for BRANCH in $(git for-each-ref --format='%(refname)' refs/remotes/)
do
    FEATURE_BRANCH=${BRANCH/refs\/remotes\/origin\//}
    if [[ $FEATURE_BRANCH == feature/* ]]; then

        GIT_DOMAIN=${FEATURE_BRANCH#*\/}
        FEATURE_DIR="${FEATURE_HOME}/${GIT_DOMAIN}"

        # Create a feature directory if it does not exist yet
        if [ ! -d $FEATURE_DIR ]; then
            echo "Creating new feature directory: ${FEATURE_DIR}" | tee -a $LOG_FILE
            cp -R ${REPO_HOME} ${FEATURE_DIR}/
            ( cd $FEATURE_DIR && git reset --hard && git checkout $FEATURE_BRANCH && composer install && yarn install --pure-lockfile )
        fi

        # Update if commit id of local is not identical to remote feature branch
        if [ $(git rev-parse origin/${FEATURE_BRANCH}) != $( cd $FEATURE_DIR && git rev-parse HEAD ) ]; then
            echo "The branch '${FEATURE_BRANCH}' has remote changes and will be updated. " | tee -a $LOG_FIL
            ( cd $FEATURE_DIR && git reset --hard && git pull && composer install && yarn install --pure-lockfile )
        fi
    fi
done

# Remove branches that don't have a remote to keep things clean
for FEATURE_DIR in $FEATURE_HOME/*
do
    BRANCH="feature/${FEATURE_DIR##*/}"
    if [ $( git branch -r | grep ${BRANCH} | wc -l ) != 1 ]; then
        echo "${BRANCH} no longer exists, removing..." | tee -a $LOG_FIL
        rm -rf $FEATURE_DIR
    fi
done
