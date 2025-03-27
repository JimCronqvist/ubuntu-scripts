# Ensure we run in Administrator mode, otherwise trigger it
if (!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) { Start-Process powershell.exe "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs; exit }

# Functions
function Check-Command($cmdname) {
    return [bool](Get-Command -Name $cmdname -ErrorAction SilentlyContinue)
}

# Write out computer info
Write-Host "OS Info:" -ForegroundColor Green
Get-CimInstance Win32_OperatingSystem | Format-List Name, Version, InstallDate, OSArchitecture
(Get-ItemProperty HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor\0\).ProcessorNameString

# Set a new computer name
#$computerName = Read-Host 'Enter New Computer Name'
#Write-Host "Renaming this computer to: " $computerName  -ForegroundColor Yellow
#Rename-Computer -NewName $computerName


# Modify some Windows behaviors
## Disable "Show more options" context menu
reg add "HKCU\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32" /f /ve

## Placement of the start menu (first = left, second = center)
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v TaskbarAl /t REG_DWORD /d 0 /f
#reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v TaskbarAl /t REG_DWORD /d 1 /f

# Disable "Use the Print Screen key to open screen capture" - to let LightShot control the PRNTSCRN hotkey
reg add "HKCU\Control Panel\Keyboard" /v PrintScreenKeyForSnippingEnabled /t REG_DWORD /d 0 /f

# Disable OneDrive from taking over the print screen key as well
reg add "HKCU\SOFTWARE\Microsoft\OneDrive" /v "DisableScreenshotShortcut" /t REG_DWORD /d 1 /f
#reg add "HKCU\SOFTWARE\Microsoft\OneDrive" /v "DisableScreenshotShortcut" /t REG_DWORD /d 0 /f

# Enable seconds in the clock in the taskbar
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v ShowSecondsInSystemClock /t REG_DWORD /d 1 /f; taskkill /im explorer.exe /f; start explorer.exe
#reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v ShowSecondsInSystemClock /t REG_DWORD /d 0 /f; taskkill /im explorer.exe /f; start explorer.exe

## Modify Windows Explorer settings
cmd.exe /c "reg add HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced /v HideFileExt /t REG_DWORD /d 0 /f"
cmd.exe /c "reg add HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced /v Hidden /t REG_DWORD /d 1 /f"
cmd.exe /c "reg add HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced /v Start_TrackDocs /t REG_DWORD /d 0 /f"

## Exclude www from Windows Defender
Add-MpPreference -ExclusionPath "$env:USERPROFILE\www"
Add-MpPreference -ExclusionPath '\\wsl.localhost\Ubuntu\var\www'

## Enabling Hardware-Accelerated GPU Scheduling...
#New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\" -Name 'HwSchMode' -Value '2' -PropertyType DWORD -Force

## Power options - Disable sleep & turn off screens after 15 minutes when on AC power
Powercfg /Change monitor-timeout-ac 15
Powercfg /Change standby-timeout-ac 0


# Remove UWP bloatwares - To list all appx packages: Get-AppxPackage | Format-Table -Property Name,Version,PackageFullName
Get-AppxPackage "Microsoft.GetHelp" | Remove-AppxPackage -AllUsers
Get-AppxPackage "Microsoft.Getstarted" | Remove-AppxPackage -AllUsers
Get-AppxPackage "Microsoft.BingNews" | Remove-AppxPackage -AllUsers

# Enable Windows Feature - Telnet Client
Enable-WindowsOptionalFeature -Online -FeatureName TelnetClient -All -NoRestart

# Enable Windows Developer Mode
#reg add "HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock" /t REG_DWORD /f /v "AllowDevelopmentWithoutDevLicense" /d "1"

# Install Chocolatey - https://community.chocolatey.org/packages
if (Check-Command -cmdname 'choco') {
    Write-Host "Choco is already installed, skip installation."
}
else {
    # Install Choco
    Set-ExecutionPolicy Bypass -Scope Process -Force; iex ((New-Object System.Net.WebClient).DownloadString('https://chocolatey.org/install.ps1'))
}

# Install applications via Choco
choco install -y 7zip.install
choco install -y googlechrome
choco install -y chromium
choco install -y firefox
choco install -y vlc
choco install -y notepadplusplus.install
choco install -y lightshot.install
choco install -y dropbox
choco install -y teamviewer
choco install -y lens
choco install -y jetbrainstoolbox
choco install -y tailscale
#choco install -y openvpn-connect
#choco install -y icue
choco install -y crystaldiskinfo
choco install -y crystaldiskmark
choco install -y hwinfo
choco install -y spotify
choco install -y streamdeck
#choco install -y equalizerapo
# Peace Equalizer addon: https://sourceforge.net/projects/peace-equalizer-apo-extension/files/latest/download
#choco install -y slack
#choco install -y plexmediaserver
#choco install -y mqtt-explorer
choco install -y another-redis-desktop-manager
#choco install -y docker-desktop
choco install -y postman
#choco install -y sysinternals
#choco install -y powershell-core
choco install -y chocolateygui

# Install 'gsudo'
PowerShell -Command "Set-ExecutionPolicy RemoteSigned -scope Process; [Net.ServicePointManager]::SecurityProtocol = 'Tls12'; iwr -useb https://raw.githubusercontent.com/gerardog/gsudo/master/installgsudo.ps1 | iex"


# Install a Powershell module for Windows Updates"
Install-Module -Name PSWindowsUpdate -Force -Confirm:$False

# Check and Install Windows Updates
Get-WindowsUpdate -AcceptAll -Install -ForceInstall -AutoReboot


# Install WSL2 - after we have the latest windows updates
wsl --install -d Ubuntu
wsl --version

# Install WSL2 USB support using a third-party tool: https://github.com/dorssel/usbipd-win
#winget install usbipd --accept-package-agreements --accept-source-agreements

# Install Docker Desktop
choco install -y docker-desktop
#net localgroup "docker-users" "<your username>" /add # Run this to avoid a reboot?

# Set up Ubuntu
#wsl --cd ~ -e bash -c "sudo install -o 1000 -g 1000 -m 777 -d /var/www"
#wsl --cd ~ -e bash -c "echo '' >> .bashrc && echo 'cd /var/www' >> .bashrc"
#wsl --cd ~ -e bash -c "ssh-keygen -q -t ed25519 -N '' -f ~/.ssh/id_rsa <<<n >/dev/null; echo 'Add your new SSH Key in GitHub:'; cat ~/.ssh/id_rsa.pub"
#wsl --cd ~ -e bash -c "sudo apt update && sudo apt upgrade -y"

# Prepare for bridge connection for WSL2
#New-VMSwitch -Name "WSL_External" -AllowManagement $True –NetAdapterName "Ethernet"
#$wslconfig = @"
#[wsl2]
#networkingMode=bridged
#vmSwitch=WSL_External
##dhcp=false
#ipv6=true
#"@
#Add-Content "$HOME\.wslconfig" $wslconfig
#wsl --shutdown
#wsl -d Ubuntu

# Install complete
Write-Host "------------------------------------" -ForegroundColor Green
Read-Host -Prompt "Setup is done, restart is required, press [ENTER] to restart computer."
Restart-Computer
