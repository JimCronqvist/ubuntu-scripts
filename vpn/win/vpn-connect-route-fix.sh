#!/bin/sh

# Ensure this value matches the name of the VPN connection, it also requires you to have chosen "Remember Password" when setting it up.
VPN_ADAPTER_NAME="VPN"

#
# This script is only useful if your home network AND the VPN network both uses a local class C network, and therefore collides.
# This script will connect and add routes for all hosts except required ones locally, such as the home router and your local IP.
#

die() {
    echo "$*" >&2
    exit 1
}

[ "$VPN_ADAPTER_NAME" ] || die "VPN PPTP Adapter name not set!"

if [ "$(uname -o)" != 'MS/Windows' ]; then
    id -G | grep -qE '\<(114|544)\>' || die 'Not running with admin rights.'
fi

if [ ! $(rasdial.exe | grep -q "No connections") ]; then 
    echo "Disconnecting any existing connection that might exist."
    rasdial.exe "$VPN_ADAPTER_NAME" /d
fi

echo "Connecting to the VPN '$VPN_ADAPTER_NAME'"
rasdial.exe "$VPN_ADAPTER_NAME"

echo "Getting IP address on VPN network."
VPN_LOCAL_IP=$(netsh.exe interface ip show config name="$VPN_ADAPTER_NAME" | grep 'IP Address' | tr -d '\r' | tr -d '\n' | tr -d ' ' | cut -d: -f2)
[ "$VPN_LOCAL_IP" ] || die 'Could not find the IP on VPN network! Exiting.'
echo "Detected VPN IP address as '$VPN_LOCAL_IP'."

echo "Getting VPN interface number."
IF=$(ROUTE.EXE print -4 | grep "$VPN_ADAPTER_NAME" | awk -F. '{gsub(" ", "");print $1}')
[ "$IF" ] || die 'Could not get interface number! Exiting.'
echo "Detected VPN interface number as '$IF'."

echo "Getting home IP address"
LOCAL_IP=$(ROUTE.EXE print -4 | awk '{ print $4 }' | grep ^192.168.*  | grep -v "$VPN_LOCAL_IP" | head -n 1)
[ "$LOCAL_IP" ] || die 'Could not find the home IP address! Exiting.'
echo "Detected home IP address as '$LOCAL_IP'."

echo "Getting router IP address"
ROUTER=$(ROUTE.EXE print -4 | sed 's/^\s*//g' | grep '^0.0.0.0' | grep "$LOCAL_IP" | awk '{ print $3 }' | head -n 1)
[ "$ROUTER" ] || die 'Could not find the router IP address! Exiting.'
echo "Detected router IP address as '$ROUTER'."

NETWORK=$(echo $ROUTER | cut -d'.' -f1-3)

# Adding routes

echo "Adding a broad low priority route for local networks to go over the VPN."
echo ROUTE ADD 192.168.0.0/16 0.0.0.0 IF "$IF"
ROUTE.EXE ADD 192.168.0.0/16 0.0.0.0 IF "$IF"

for (( i=1; i <= 254; i++ ))
do
    IP="$NETWORK.$i"
    if [ "$IP" != "$ROUTER" ] && [ "$IP" != "$VPN_LOCAL_IP" ] && [ "$IP" != "$LOCAL_IP" ]; then
        echo ROUTE ADD "$IP/32" 0.0.0.0 IF "$IF"
        ROUTE.EXE ADD "$IP/32" 0.0.0.0 IF "$IF"
    else
        echo "Ignoring IP $IP"
    fi
done

echo ""
echo "Local IP:      $LOCAL_IP"
echo "Home router:   $ROUTER"
echo "Network:       $NETWORK.0/24"
echo "VPN local IP:  $VPN_LOCAL_IP"
echo "VPN Interface: $IF"
echo ""


echo "VPN should be up and ready to use now."
read -r _

exit 0
