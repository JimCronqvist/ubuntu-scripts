#!/bin/bash

array=($@)
FILE=$1

if [ ! -f "$FILE" ]; then
    echo "The shell script file in the first parameter was not found, aborting."
    exit 1
fi

for i in "${!array[@]}"
do
    #echo "key: $i"
    #echo "value: ${array[$i]}"
    
    if [ $i -gt 0 ]; then
        ssh -t ${array[$i]} 'bash -s' < $FILE
    fi
done
