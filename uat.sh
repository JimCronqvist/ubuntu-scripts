#!/bin/bash

# Check for 2 passed arguments, otherwise abort.
if [ $# -lt 2 ] ; then
    echo "You have not passed the correct number of arguments. This script should be used with the following syntax:"
    echo "bash uat.sh /var/www/app /var/www/features"
    echo ""
    exit 1;
fi


REPO_HOME="${1%/}"
FEATURE_HOME="${2%/}"


CURRENT_SCRIPT=$(basename "$0")
CMD="$CURRENT_SCRIPT $@"
RUNNING=$(ps xah -opid,cmd | grep "$CMD" | grep -v '/bin/sh -c' | grep -v grep | wc -l)
if [ $RUNNING -gt 2 ]; then
    echo "Instance of ${CURRENT_SCRIPT} $@ is already running ($RUNNING)..."
    exit
fi

echo $(date)
cd $REPO_HOME || exit 1
mkdir -p $FEATURE_HOME

BASE_BRANCH="develop"
if [ $( git branch -r | grep '^  origin/develop$' | wc -l ) != 1 ]; then
    BASE_BRANCH="master"
fi

git fetch --all --prune
COMMIT=$(git describe --always)
git add . && git reset --hard && git checkout $BASE_BRANCH && git reset --hard origin/${BASE_BRANCH}
if [ "$COMMIT" != "$(git describe --always)" ]; then
    /usr/local/bin/composer install && yarn install --pure-lockfile
fi

for BRANCH in $(git for-each-ref --format='%(refname)' refs/remotes/)
do
    FEATURE_BRANCH=${BRANCH/refs\/remotes\/origin\//}
    if [[ $FEATURE_BRANCH == feature/* ]]; then

        GIT_DOMAIN=${FEATURE_BRANCH#*\/}
        FEATURE_DIR="${FEATURE_HOME}/${GIT_DOMAIN}"

        # Create a feature directory if it does not exist yet
        if [ ! -d $FEATURE_DIR ]; then
            echo "Creating new feature directory: ${FEATURE_DIR}"
            sudo rsync -a --stats ${REPO_HOME}/ ${FEATURE_DIR}/
            ( cd $FEATURE_DIR && git add . && git reset --hard && git checkout $FEATURE_BRANCH && /usr/local/bin/composer install && yarn install --pure-lockfile )
        fi

        # Update if commit id of local is not identical to remote feature branch
        if [ $(git rev-parse origin/${FEATURE_BRANCH}) != $( cd $FEATURE_DIR && git rev-parse HEAD ) ]; then
            echo "The branch '${FEATURE_BRANCH}' has remote changes and will be updated. "
            ( cd $FEATURE_DIR && git fetch --all --prune && git add . && git reset --hard && git checkout $FEATURE_BRANCH && git reset --hard origin/${FEATURE_BRANCH} && /usr/local/bin/composer install && yarn install --pure-lockfile )
        fi
    fi
done

# Remove branches that don't have a remote to keep things clean
if [ $( find $FEATURE_HOME -mindepth 1 -maxdepth 1 -type d | wc -l ) != 0 ]; then
    for FEATURE_DIR in $FEATURE_HOME/*
    do
        BRANCH="feature/${FEATURE_DIR##*/}"
        if [ $( git branch -r | grep ${BRANCH} | wc -l ) != 1 ]; then
            echo "${BRANCH} no longer exists, removing..."
            rm -rf $FEATURE_DIR
        fi
    done
fi
    
echo ""

# Abort if we already have installed the virtual hosts before
if [ -f /etc/apache2/sites-available/zzz_virtual_uat.conf ]; then
    exit 0
fi


###
# One time setup below
###

# Virtual host for the uat subdomains
cat | sudo tee /etc/apache2/sites-available/zzz_virtual_uat.conf <<EOF
<VirtualHost *:80>
    ServerName x.localhost
    ServerAlias *.uat.example.com
    VirtualDocumentRoot /var/www/features/%1/public
    <Directory /var/www/features/*/public>
        Options -Indexes +FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
    SetEnv APP_ENV uat
</VirtualHost>
EOF

cat | sudo tee /etc/apache2/sites-available/zzz_virtual_uat.ssl.conf <<EOF
<VirtualHost *:443>
    ServerName x.localhost
    ServerAlias *.uat.example.com
    VirtualDocumentRoot /var/www/features/%1/public
    <Directory /var/www/features/*/public>
        Options -Indexes +FollowSymLinks
        AllowOverride All
        Order allow,deny
        Allow from all
    </Directory>
    SetEnv APP_ENV uat
        
    SSLEngine on
    SSLCertificateFile /etc/apache2/ssl/ssl_certificate.crt
    SSLCertificateKeyFile /etc/apache2/ssl/uat.example.com.key
    SSLCertificateChainFile /etc/apache2/ssl/IntermediateCA.crt
    <FilesMatch "\.(cgi|shtml|phtml|php)$">
        SSLOptions +StdEnvVars
    </FilesMatch>
    <Directory /usr/lib/cgi-bin>
        SSLOptions +StdEnvVars
    </Directory>
    BrowserMatch "MSIE [2-6]" nokeepalive ssl-unclean-shutdown downgrade-1.0 force-response-1.0
    BrowserMatch "MSIE [17-9]" ssl-unclean-shutdown
</VirtualHost>
EOF

# Replace with the correct domain and enable the new sites
sudo sed -i 's/uat.example.com/'$(hostname --fqdn)'/g' /etc/apache2/sites-available/zzz_virtual_uat.conf
sudo sed -i 's/uat.example.com/'$(hostname --fqdn)'/g' /etc/apache2/sites-available/zzz_virtual_uat.ssl.conf
sudo a2ensite zzz_virtual_uat
sudo a2ensite zzz_virtual_uat.ssl
sudo service apache2 reload

# Set up the cronjob
sudo touch /var/log/uat.log
sudo chmod 0644 /var/log/uat.log
sudo chown ubuntu:ubuntu /var/log/uat.log

cat | sudo tee /etc/cron.d/uat <<EOF
#!/bin/bash
* * * * * ubuntu bash /home/ubuntu/uat.sh >> /var/log/uat.log 2>&1
EOF
sudo chmod 0644 /etc/cron.d/uat
