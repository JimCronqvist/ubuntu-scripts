#!/bin/bash

for var in "$@"
do
    ssh -t $var "sudo reboot"
done
