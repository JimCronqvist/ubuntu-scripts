## Windows Zabbix Agent

Windows MSI installer for the zabbix agent can be found here: http://www.suiviperf.com/zabbix/


## Templates

### zabbix_os_linux_logs_template.xml

Execute the following command in order to make sure that the zabbix user has the correct permission for the log files: 

`sudo adduser zabbix adm`

### zabbix_os_ubuntu_template.xml

Execute the following command in order to give the zabbix user access to run the lsof cmd with sudo: 

`sudo bash -c "echo 'zabbix ALL=NOPASSWD: /usr/bin/lsof' | ( umask 337; cat >> /etc/sudoers.d/zabbix; )"`
