#/bin/bash

echo Get network summary
ss -s

echo Count of all connections
netstat -an | wc -l

echo Count of all connections on a specific port
netstat -an | grep :443 | wc -l

echo Count of all categories of connections, such as TIME_WAIT, LISTEN, etc.
netstat -ant | awk '{print $6}' | sort | uniq -c | sort -n

echo Display all services that are listening on a port
netstat -nlpt
