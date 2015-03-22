
Add-PSSnapin "VMware.VimAutomation.Core" | Out-Null

$user="Administrator@vsphere.local"
$pass="password"
$vCenterServer="192.168.1.1"
$MailtoAddresses= "email.1@gmail.com","email.2@gmail.com"

#Connect to the vCenter Server
Connect-VIServer -Server $vCenterServer -Protocol https -User $user -Password $pass -WarningAction SilentlyContinue | Out-Null
$sessionManager = Get-View -Id $global:DefaultVIServer.ExtensionData.Content.SessionManager
$sessionManager.SetLocale(“en-US”)

#Configure the alarms
#To get all alarm replace the next line with: Get-AlarmDefinition | %{
Get-AlarmDefinition "Datastore usage on disk" | %{
   $_ | Get-AlarmAction -ActionType "SendEmail" | Remove-AlarmAction -Confirm:$false
   $_ | Set-AlarmDefinition -ActionRepeatMinutes (60 * 6); # Repeat every 6 hours.
   $_ | New-AlarmAction -Email -To @($MailtoAddresses) | %{
      $_ | New-AlarmActionTrigger -StartStatus "Green" -EndStatus "Yellow" -Repeat
      $_ | Get-AlarmActionTrigger | ?{$_.repeat -eq $false} | Remove-AlarmActionTrigger -Confirm:$false
      $_ | New-AlarmActionTrigger -StartStatus "Yellow" -EndStatus "Red" -Repeat
      $_ | New-AlarmActionTrigger -StartStatus "Red" -EndStatus "Yellow" -Repeat
      $_ | New-AlarmActionTrigger -StartStatus "Yellow" -EndStatus "Green"
   }
}

#Disconnect
Disconnect-VIServer -Server $vCenterServer -Force:$true -Confirm:$false
