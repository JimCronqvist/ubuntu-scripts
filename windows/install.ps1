# Ensure we run in Administrator mode, otherwise trigger it
if (!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) { Start-Process powershell.exe "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs; exit }

# Functions
function Check-Command($cmdname) {
    return [bool](Get-Command -Name $cmdname -ErrorAction SilentlyContinue)
}

function Remove-UWP {
    param (
        [string]$name
    )
    Write-Host "Removing UWP $name..." -ForegroundColor Yellow
    Get-AppxPackage $name | Remove-AppxPackage
    Get-AppxPackage $name | Remove-AppxPackage -AllUsers
}

# Write out computer info
Write-Host "OS Info:" -ForegroundColor Green
Get-CimInstance Win32_OperatingSystem | Format-List Name, Version, InstallDate, OSArchitecture
(Get-ItemProperty HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor\0\).ProcessorNameString

# Set a new computer name
$computerName = Read-Host 'Enter New Computer Name'
Write-Host "Renaming this computer to: " $computerName  -ForegroundColor Yellow
Rename-Computer -NewName $computerName

# Modify some Windows behaviors
## Disable "Show more options" context menu
reg add "HKCU\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32" /f /ve

# Power options
Write-Host ""
Write-Host "Change the power plan, disable sleep and turn off screens after 15 minutes when on AC power..." -ForegroundColor Green
Write-Host "------------------------------------" -ForegroundColor Green
Powercfg /Change monitor-timeout-ac 15
Powercfg /Change standby-timeout-ac 0

# Remove UWP bloatwares - To list all appx packages: Get-AppxPackage | Format-Table -Property Name,Version,PackageFullName
Write-Host "Removing UWP bloatwares..." -ForegroundColor Green
Write-Host "------------------------------------" -ForegroundColor Green
$uwpRubbishApps = @(
    "Microsoft.GetHelp"
    "Microsoft.YourPhone"
    "Microsoft.Getstarted"
)
foreach ($uwp in $uwpRubbishApps) {
    Remove-UWP $uwp
}

# Windows Features
Write-Host ""
Write-Host "Enabling Hyper-V (required for wsl2) and Telnet Client..." -ForegroundColor Green
Write-Host "------------------------------------" -ForegroundColor Green
Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All # Is VirtualMachinePlatform enought for wsl2?
Enable-WindowsOptionalFeature -Online -FeatureName TelnetClient -All

# Install WSL2
# ...


# Enable Windows Developer Mode
#Write-Host ""
#Write-Host "Enable Windows Developer Mode..." -ForegroundColor Green
#Write-Host "------------------------------------" -ForegroundColor Green
#reg add "HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock" /t REG_DWORD /f /v "AllowDevelopmentWithoutDevLicense" /d "1"

# Install Chocolatey - https://community.chocolatey.org/packages
if (Check-Command -cmdname 'choco') {
    Write-Host "Choco is already installed, skip installation."
}
else {
    Write-Host ""
    Write-Host "Installing Choco for Windows..." -ForegroundColor Green
    Write-Host "------------------------------------" -ForegroundColor Green
    Set-ExecutionPolicy Bypass -Scope Process -Force; iex ((New-Object System.Net.WebClient).DownloadString('https://chocolatey.org/install.ps1'))
}

# Install applications via Choco
Write-Host ""
Write-Host "Installing Choco Applications..." -ForegroundColor Green
Write-Host "------------------------------------" -ForegroundColor Green

$Apps = @(
    "7zip.install",
    "googlechrome",
    "firefox"
    "vlc",
    "notepadplusplus.install",
    "lightshot.install",
    "dropbox",
    "jetbrainstoolbox",
    "authy-desktop",
    "openvpn-connect",
    "icue",
    "hwinfo",
    "spotify",
    
    #"docker-desktop",
    
    #"nodejs-lts",
    #"postman",
    #"sysinternals",
    #"powershell-core",
    "chocolateygui"
)
foreach ($app in $Apps) {
    choco install $app -y
}
# Install 'gsudo'
PowerShell -Command "Set-ExecutionPolicy RemoteSigned -scope Process; [Net.ServicePointManager]::SecurityProtocol = 'Tls12'; iwr -useb https://raw.githubusercontent.com/gerardog/gsudo/master/installgsudo.ps1 | iex"

Write-Host "Apply Windows Explorer settings..." -ForegroundColor Green
cmd.exe /c "reg add HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced /v HideFileExt /t REG_DWORD /d 0 /f"
cmd.exe /c "reg add HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced /v Hidden /t REG_DWORD /d 1 /f"

Write-Host "Exclude repos from Windows Defender..." -ForegroundColor Green
Add-MpPreference -ExclusionPath "$env:USERPROFILE\www"

#Write-Host "Enabling Hardware-Accelerated GPU Scheduling..." -ForegroundColor Green
#New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\" -Name 'HwSchMode' -Value '2' -PropertyType DWORD -Force

# -----------------------------------------------------------------------------
Write-Host ""
Write-Host "Check for Windows Updates..." -ForegroundColor Green
Write-Host "------------------------------------" -ForegroundColor Green
Install-Module -Name PSWindowsUpdate -Force
Write-Host "Install Windows Updates..." -ForegroundColor Green
Get-WindowsUpdate -AcceptAll -Install -ForceInstall -AutoReboot

# Install complete
Write-Host "------------------------------------" -ForegroundColor Green
Read-Host -Prompt "Setup is done, restart is required, press [ENTER] to restart computer."
Restart-Computer
