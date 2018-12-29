#!/bin/bash

if [ ! -f "./vpn-route-fix.command" ]; then
    curl -O https://raw.githubusercontent.com/JimCronqvist/ubuntu-scripts/master/mac-osx/vpn-route-fix.command && chmod +x ./vpn-route-fix.command
fi

function vpn-connect {
/usr/bin/env osascript <<-EOF
tell application "System Events"
	tell current location of network preferences
		set VPN to service "VPN (PPTP)" -- your VPN connection name here
		if exists VPN then connect VPN
		repeat until (connected of current configuration of VPN)
			delay 1
		end repeat
	end tell
end tell
EOF
./vpn-route-fix.command
}

vpn-connect
