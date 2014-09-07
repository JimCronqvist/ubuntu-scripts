#!/bin/bash

#############################################
## Automatic Github deploy script          ##
## Jim Cronqvist <jim.cronqvist@gmail.com> ##
## Updated: 2014-05-12                     ##
#############################################

if [ $(logname) = "root" ]; then
    HOME_FOLDER="/root"
else
    HOME_FOLDER="/home/$(logname)"
fi

echo "This is a helper script to deploy a private repository, this script does not need to be used when you are using public repos."

read -p "Please enter the git SSH clone URL that you want to clone: " REPO
REPO=$(echo "$REPO" | cut -f2 -d":" | cut -f1 -d".")
REPO_NAME=$(echo "$REPO" | sed -e 's/.*\///g' | cut -f1 -d".")

read -e -i "/var/www/" -p "Please enter the path where you want to make the clone: " REPO_PATH
echo "The repo $REPO will be cloned into $REPO_PATH"
echo "Repo Name: $REPO_NAME"

cd $REPO_PATH
mkdir ~/.ssh -p
ssh-keygen -q -f $HOME_FOLDER"/.ssh/github-"$REPO_NAME"_id_rsa" -N ''
touch ~/.ssh/config
echo '' >> ~/.ssh/config
echo 'Host github-'$REPO_NAME'' >> ~/.ssh/config
echo 'HostName github.com' >> ~/.ssh/config
echo 'User git' >> ~/.ssh/config
echo 'IdentityFile ~/.ssh/github-'$REPO_NAME'_id_rsa' >> ~/.ssh/config

echo ''; echo 'Enter this key into GitHub ('$REPO').'; echo ""; cat $HOME_FOLDER"/.ssh/github-"$REPO_NAME"_id_rsa.pub"; echo '';
read -p "Please press enter to continue when the key is added into Github: "

echo "git clone git@github-"$REPO_NAME":/"$REPO".git"
git clone "git@github-"$REPO_NAME":/"$REPO".git"
