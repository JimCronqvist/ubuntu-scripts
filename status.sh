#/bin/bash

SEND_TO=""

#Create a temp file and open a file descriptor and delete the file in order to make sure that it will get deleted at the end of this script even though it crashes.
temp=$(mktemp /tmp/status.XXXXXX)
exec 3>"$temp"
rm "$temp"

# Perform some checks
HOSTNAME=$(hostname --fqdn)
echo "Hostname:" $HOSTNAME >> "$temp"
echo "" >> "$temp"
echo "Available security updates:" $(/usr/lib/update-notifier/apt-check 2>&1 | cut -d';' -f2) >> "$temp"
echo "Available normal updates:" $(/usr/lib/update-notifier/apt-check 2>&1 | cut -d';' -f1) >> "$temp"
RESTART_REQUIRED=$(test -e /var/run/reboot-required && echo Yes || echo No)
echo "Restart required: $RESTART_REQUIRED" >> "$temp"
echo "" >> "$temp"
echo "Load average:" $(cat /proc/loadavg | cut -d ' ' -f1-3) "("$(nproc)" cores)" >> "$temp"
MEMORY_USAGE=$(free | awk 'FNR == 3 {printf "%.1f\n", $3/($3+$4)*100}')
echo "Memory usage: $MEMORY_USAGE%" >> "$temp"
echo "" >> "$temp"
echo "Disk stats:" >> "$temp"
df -Th | sed 's/Mounted on/MountedOn/g' | column -t | sort -n -k6n >> "$temp"
echo "" >> "$temp"
echo "I/O Stats:" >> "$temp"
iostat -cyx 2 1 | sed 's/avg-cpu://g' | head -n 4 | tail -n 2 | column -t | sort -n -k6n >> "$temp"
echo "" >> "$temp"

# Print out the result.
cat "$temp"

# Send out an email report.
if [ ! -z $SEND_TO ] ; then
    echo "Sending email.."
    if [ -e /usr/bin/mail ]; then
        cat "$temp" | mail -s "Status check for $HOSTNAME" "$SEND_TO" && echo "Email sent." || echo "Email failed."
    else
        echo "No MTA is installed."
    fi
fi
