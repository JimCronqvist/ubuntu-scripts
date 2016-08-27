#!/bin/bash

# Installation
#
# 1. Add this file at /var/spool/apt-mirror/var/postmirror_bash.sh
# 2. Execute the following line: 
#    sudo bash -c "echo 'bash ./postmirror_bash.sh' >> /var/spool/apt-mirror/var/postmirror.sh"
#

# CONFIGURE THIS ONE TO REFLECT YOUR LOCAL APT-MIRROR DOMAIN OR IP
LOCAL_MIRROR="ubuntu-mirror.diakrit.local"

# Global configuration
WGET="wget -qc -O -"
RSYNC="rsync -rtlH --delete --delete-after"
REMOTE_URL="rsync://archive.ubuntu.com/ubuntu"
MIRROR_DIR="/var/spool/apt-mirror/mirror/archive.ubuntu.com/ubuntu"
DIST=$(lsb_release -cs)

# meta-release files
${WGET} http://changelogs.ubuntu.com/meta-release | sed -e "s/archive.ubuntu.com/$LOCAL_MIRROR/g" > ${MIRROR_DIR}/meta-release
${WGET} http://changelogs.ubuntu.com/meta-release-lts | sed -e "s/archive.ubuntu.com/$LOCAL_MIRROR/g" > ${MIRROR_DIR}/meta-release-lts

# dist-upgrader-all packages
dists=(${DIST})

for dist in "${dists[@]}"
do
  mkdir -p ${MIRROR_DIR}/dists/${dists}-updates/main/dist-upgrader-all/current
  ${RSYNC} ${REMOTE_URL}/dists/${dist}-updates/main/dist-upgrader-all/current/${dist}.tar.gz ${MIRROR_DIR}/dists/${dist}-updates/main/dist-upgrader-all/current/
  ${RSYNC} ${REMOTE_URL}/dists/${dist}-updates/main/dist-upgrader-all/current/${dist}.tar.gz.gpg ${MIRROR_DIR}/dists/${dist}-updates/main/dist-upgrader-all/current/
  ${RSYNC} ${REMOTE_URL}/dists/${dist}-updates/main/dist-upgrader-all/current/ReleaseAnnouncement ${MIRROR_DIR}/dists/${dist}-updates/main/dist-upgrader-all/current/
  ${RSYNC} ${REMOTE_URL}/dists/${dist}-updates/main/dist-upgrader-all/current/ReleaseAnnouncement.html ${MIRROR_DIR}/dists/${dist}-updates/main/dist-upgrader-all/current/
done

dists=(${DIST} ${DIST}-security ${DIST}-updates)

for dist in "${dists[@]}"
do
  ${RSYNC} ${REMOTE_URL}/dists/${dist}/main/i18n/ ${MIRROR_DIR}/dists/${dist}/main/i18n/
  ${RSYNC} ${REMOTE_URL}/dists/${dist}/multiverse/i18n/ ${MIRROR_DIR}/dists/${dist}/multiverse/i18n/
  ${RSYNC} ${REMOTE_URL}/dists/${dist}/restricted/i18n/ ${MIRROR_DIR}/dists/${dist}/restricted/i18n/
  ${RSYNC} ${REMOTE_URL}/dists/${dist}/universe/i18n/ ${MIRROR_DIR}/dists/${dist}/universe/i18n/
done
