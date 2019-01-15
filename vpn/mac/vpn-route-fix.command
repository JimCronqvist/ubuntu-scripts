#!/bin/bash

##
## VPN fix for Mac OS X ##
##

VPN_GATEWAY=$(ifconfig ppp0 2>&1 | grep inet | awk '{ print $4 }')

if [ "$VPN_GATEWAY" == "" ]; then
    echo "VPN is not connected" && exit 0
fi

echo ""
echo "If you get prompted for your password now, please enter your Mac OS X user account password."
sudo echo "" > /dev/null

ROUTER=$(netstat -rn | grep -v ppp0 | awk '/^default/ {print $2}' | grep -v "$VPN_GATEWAY" | head -n 1)
NETWORK=$(echo $ROUTER | cut -d'.' -f1-3)

VPN_LOCAL_IP=$(netstat -rn -f inet | grep lo0 | grep "$NETWORK" | awk '{ print $1 }')
if [ -z "$VPN_LOCAL_IP" ]; then
    VPN_LOCAL_IP=$(ifconfig ppp0 | sed -En 's/127.0.0.1//;s/.*inet (addr:)?(([0-9]*\.){3}[0-9]*).*/\2/p')
fi

for (( i=1; i <= 254; i++ ))
do
    IP="$NETWORK.$i"
    if [ "$IP" != "$ROUTER" ] && [ "$IP" != "$VPN_LOCAL_IP" ]; then
        sudo route add -host $IP $VPN_GATEWAY -ifp ppp0
    else
        echo "Ignoring IP $IP"
    fi
done

echo ""
echo "VPN gateway:  $VPN_GATEWAY"
echo "Home router:  $ROUTER"
echo "VPN local IP: $VPN_LOCAL_IP"
echo ""
