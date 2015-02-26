#!/bin/bash

#############################################
## Apache2 tuning script                   ##
## Jim Cronqvist <jim.cronqvist@gmail.com> ##
## Updated: 2014-10-19                     ##
#############################################

# Abort if not root.
if [ "$(id -u)" -ne "0" ] ; then
    echo "This script needs to be ran from a user with root permissions.";
    exit 1;
fi

read -p "Warning: This script will stop and start your Apache service, please press any key to continue."
echo ""

# Checking what kind apache2 installation is installed depending on which distribution we are on
if [ -e /etc/debian_version ]; then
	APACHE="apache2"
	APACHE_MPM=$(apache2ctl -V | grep 'Server MPM:' | awk '{print $3}')
	APACHE_VERSION=$(apache2ctl -V | grep 'Server version:' | cut -f3,4 -d" ")
	APACHE_INFO="$APACHE_VERSION $APACHE_MPM"
elif [ -e /etc/redhat-release ]; then
	APACHE="httpd"
	APACHE_INFO="$APACHE"
fi

# Get the amount of memory that Apache is using in MB.
APACHE_LARGEST_PROC_MEMORY=$(ps -aylC $APACHE | grep "$APACHE" | awk '{print $8}' | sort -n | tail -n 1)
APACHE_LARGEST_PROC_MEMORY=$(expr $APACHE_LARGEST_PROC_MEMORY / 1024)

# Get the amount of memory that Apache is using in average
APACHE_USER=$(ps -ef|awk '/sbin\/(httpd|apache2)/ && !/root/ {print $1}' | uniq)
APACHE_RAM_AVERAGE=$(ps -u $APACHE_USER -o pid= | xargs pmap -d | awk '/private/ {c+=1; sum+=$4} END {printf "%.2f", sum/c/1024}')
APACHE_NUM_PROC=$(ps -u $APACHE_USER -o pid= | wc -l)

# Get the amount of memory that MySQL is using in MB
MYSQL_MEMORY=$(ps -aylC mysqld | grep "mysqld" | awk '{print $8}' | sort -n | tail -n 1)
if [ -z $MYSQL_MEMORY ] ; then
    MYSQL_MEMORY=0
fi
MYSQL_MEMORY=$(expr $MYSQL_MEMORY / 1024)

# Stop Apache to be able to get the amount of free memory available for Apache.
/etc/init.d/$APACHE stop

TOTAL_MEMORY=$(free -m | head -n 2 | tail -n 1 | awk '{print $2}')
TOTAL_FREE_MEMORY=$(free -m | head -n 2 | tail -n 1 | awk '{print $4}')
TOTAL_USED_SWAP=$(free -m | head -n 4 | tail -n 1 | awk '{print $3}')

MAX_CLIENTS=$(awk 'BEGIN {printf "%.0f", '$TOTAL_FREE_MEMORY'/'$APACHE_RAM_AVERAGE'}')
MIN_SPARE_SERVERS=$(expr $MAX_CLIENTS / 4)
MAX_SPARE_SERVERS=$(expr $MAX_CLIENTS / 2)

# Starting Apache again.
/etc/init.d/$APACHE start

# Display all values
echo "-----------------------------------------------"
echo "You are running:	$APACHE_INFO"
echo "Total memory:		$TOTAL_MEMORY MB"
echo "Free memory:		$TOTAL_FREE_MEMORY MB"
echo "Swap usage:		$TOTAL_USED_SWAP MB"
echo "Largest Apache process:	$APACHE_LARGEST_PROC_MEMORY MB (inc shared mem)"
echo "Average Apache process:	$APACHE_RAM_AVERAGE MB"
echo "Active Apache process:	$APACHE_NUM_PROC processes"
echo "MySQL memory usage:	$MYSQL_MEMORY MB"
if [[ $TOTAL_USED_SWAP > $TOTAL_MEMORY ]]; then
      SWAP_STATUS="Too high usage!"
else
      SWAP_STATUS="OK"
fi
echo "Virtual memory status:	$SWAP_STATUS"
echo "-----------------------------------------------"
echo ""
echo "Insert in the end of '/etc/apache2/apache2.conf'"
echo ""
echo "<IfModule mpm_prefork_module>"
echo "	StartServers	$MIN_SPARE_SERVERS"
echo "	MinSpareServers	$MIN_SPARE_SERVERS"
echo "	MaxSpareServers	$MAX_SPARE_SERVERS"
echo "	MaxClients	$MAX_CLIENTS"
echo "	ServerLimit	$MAX_CLIENTS"
if [ $MAX_CLIENTS -lt 50 ]; then
	echo "	MaxRequestPerChiLd	1000"
elif [ $MAX_CLIENTS -lt 100 ]; then
	echo "  MaxRequestsPerChild     2500"
elif [ $MAX_CLIENTS -lt 500 ]; then
	echo "  MaxRequestsPerChild     7500"
else
	echo "  MaxRequestsPerChild     20000"
fi
echo "</IfModule>"
