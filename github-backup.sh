#!/bin/bash

CONTEXT="$1"
NAME="$2"
TOKEN="$3"

if [ $# -lt 2 ]; then
    echo "Usage: ./github-backup.sh {orgs|users} {orgname|username} [token]"
    exit 1
fi

if [ "$CONTEXT" != "users" ] && [ "$CONTEXT" != "orgs" ]; then
    echo "First parameter can only be either 'orgs' or 'users' depending on if you want to use an organization or a normal user to clone all repos from."
    exit 1
fi

echo "Cloning all repos from '$CONTEXT/$NAME'"

for page in {1..10} # 10 = Gives a max of 1000 repos
do
    URL="https://api.github.com/$CONTEXT/$NAME/repos?page=$page&per_page=100"
    if [ -z "$TOKEN" ]; then
        echo -n "GET $URL (No authentication)"
        GIT_URLS=$(curl -s "$URL" | grep -e 'git_url*' | cut -d \" -f 4)
    else
        echo -n "GET $URL (With authentication)"
        GIT_URLS=$(curl -s -H "Authorization: token $TOKEN" "$URL" | grep -e 'git_url*' | cut -d \" -f 4)	
    fi
    
    if [ -z "$GIT_URLS" ]; then
        NUM=0
    else
        NUM=$(echo "$GIT_URLS" | wc -l)
    fi

    echo " - $NUM repos found"
	
    if [ $NUM -gt 0 ]; then
        echo "$GIT_URLS" | sed 's#git://github.com/#git@github.com:#g' | xargs -P4 -L1 git clone -q
    fi

    [ $NUM -lt 100 ] && break
done

exit 0
