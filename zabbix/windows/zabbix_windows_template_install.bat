@echo off

echo "Adding needed UserParameters to the configuration..."

echo. >> "C:\Program Files\Zabbix agent\zabbix_agentd.conf"
echo. >> "C:\Program Files\Zabbix agent\zabbix_agentd.conf"
echo ####### UserParameters for Windows Server Template - Jim Cronqvist ####### >> "C:\Program Files\Zabbix agent\zabbix_agentd.conf"
echo EnableRemoteCommands=1 >> "C:\Program Files\Zabbix agent\zabbix_agentd.conf"
echo UnsafeUserParameters=1 >> "C:\Program Files\Zabbix agent\zabbix_agentd.conf"
echo Timeout=30 >> "C:\Program Files\Zabbix agent\zabbix_agentd.conf"
echo UserParameter = system.discovery[*],%%systemroot%%\system32\cscript.exe /nologo /T:30 "\Program Files\Zabbix Agent\zabbix_win_system_discovery.vbs" $1 >> "C:\Program Files\Zabbix agent\zabbix_agentd.conf"
echo UserParameter = quota[*],%%systemroot%%\system32\cscript.exe /nologo /T:30 "\Program Files\Zabbix Agent\zabbix_win_quota.vbs" $1 $2 >> "C:\Program Files\Zabbix agent\zabbix_agentd.conf"
echo UserParameter = wu.all,%%systemroot%%\system32\cscript.exe /nologo /T:30 "\Program Files\Zabbix Agent\zabbix_wus_update_all.vbs" >> "C:\Program Files\Zabbix agent\zabbix_agentd.conf"
echo UserParameter = wu.crit,%%systemroot%%\system32\cscript.exe /nologo /T:30 "\Program Files\Zabbix Agent\zabbix_wus_update_crit.vbs" >> "C:\Program Files\Zabbix agent\zabbix_agentd.conf"
echo UserParameter = server.domain,%%systemroot%%\system32\cscript.exe /nologo /T:30 "\Program Files\Zabbix Agent\zabbix_user_domain.vbs" >> "C:\Program Files\Zabbix agent\zabbix_agentd.conf"
echo UserParameter = server.roles,%%systemroot%%\system32\cscript.exe /nologo /T:30 "\Program Files\Zabbix Agent\zabbix_server_role.vbs" >> "C:\Program Files\Zabbix agent\zabbix_agentd.conf"
echo UserParameter = server.serial,%%systemroot%%\system32\cscript.exe /nologo /T:30 "\Program Files\Zabbix Agent\zabbix_server_serialnumber.vbs" >> "C:\Program Files\Zabbix agent\zabbix_agentd.conf"

echo "Downloading Windows Zabbix Scripts needed for the Windows Template..."

powershell -Command "(New-Object Net.WebClient).DownloadFile('https://raw.githubusercontent.com/jjmartres/Zabbix/master/zbx-templates/zbx-windows/zbx-windows-envmon/zabbix_server_role.vbs', 'C:\Program Files\Zabbix agent\zabbix_server_role.vbs')"
powershell -Command "(New-Object Net.WebClient).DownloadFile('https://raw.githubusercontent.com/jjmartres/Zabbix/master/zbx-templates/zbx-windows/zbx-windows-envmon/zabbix_server_serialnumber.vbs', 'C:\Program Files\Zabbix agent\zabbix_server_serialnumber.vbs')"
powershell -Command "(New-Object Net.WebClient).DownloadFile('https://raw.githubusercontent.com/jjmartres/Zabbix/master/zbx-templates/zbx-windows/zbx-windows-envmon/zabbix_user_domain.vbs', 'C:\Program Files\Zabbix agent\zabbix_user_domain.vbs')"
powershell -Command "(New-Object Net.WebClient).DownloadFile('https://raw.githubusercontent.com/jjmartres/Zabbix/master/zbx-templates/zbx-windows/zbx-windows-envmon/zabbix_win_quota.vbs', 'C:\Program Files\Zabbix agent\zabbix_win_quota.vbs')"
powershell -Command "(New-Object Net.WebClient).DownloadFile('https://raw.githubusercontent.com/jjmartres/Zabbix/master/zbx-templates/zbx-windows/zbx-windows-envmon/zabbix_win_system_discovery.vbs', 'C:\Program Files\Zabbix agent\zabbix_win_system_discovery.vbs')"
powershell -Command "(New-Object Net.WebClient).DownloadFile('https://raw.githubusercontent.com/jjmartres/Zabbix/master/zbx-templates/zbx-windows/zbx-windows-envmon/zabbix_wus_update_all.vbs', 'C:\Program Files\Zabbix agent\zabbix_wus_update_all.vbs')"
powershell -Command "(New-Object Net.WebClient).DownloadFile('https://raw.githubusercontent.com/jjmartres/Zabbix/master/zbx-templates/zbx-windows/zbx-windows-envmon/zabbix_wus_update_crit.vbs', 'C:\Program Files\Zabbix agent\zabbix_wus_update_crit.vbs')"

echo "Restarting the Zabbix Agent"
net stop "Zabbix Agent" && net start "Zabbix Agent"

echo "Finished."
