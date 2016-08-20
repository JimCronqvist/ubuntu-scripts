#!/bin/bash

for var in "$@"
do
    echo -e "$(tput setaf 2)\nConnecting to $var \n $(tput sgr0)"
    ssh -t $var "sudo apt-get autoremove"
done
