#!/bin/bash

# Abort if not root.
if [ "$(id -u)" -ne "0" ] ; then
    echo "This script needs to be ran from a user with root permissions.";
    exit 1;
fi

MEM=$(free | awk '/Mem:/ {print $4}')
SWAP=$(free | awk '/Swap:/ {print $3}')

if [ $MEM -lt $SWAP ]; then
    echo "ERROR: not enough RAM to write swap back, nothing done" >&2
    exit 1
fi

swapoff -a && swapon -a
