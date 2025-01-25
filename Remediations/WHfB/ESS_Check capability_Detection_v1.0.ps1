<#
.SYNOPSIS
Use this script to check if a device is ESS-capable.
.DESCRIPTION
This script checks if a device is ESS-capable. It checks USB host controllers and cameras.
.EXAMPLE
Run it manually on a local device or use Intune remediation script to check if a device is ESS-capable.
.NOTES
NAME: ESS_Check capability_Detection_v1.0.ps1
.WARRANTY
THIS CODE AND INFORMATION IS PROVIDED "AS IS" WITHOUT WARRANTY OF ANY KIND, EITHER EXPRESSED OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE IMPLIED WARRANTIES OF MERCHANTABILITY AND/OR FITNESS FOR A PARTICULAR PURPOSE.
.AUTHOR
Nicklas Ahlberg, https://rockenroll.tech
#>

$ErrorActionPreference = "silentlycontinue"
# Function to check device capabilities
$essCapableDevices = @()
function Check-ESSCapability {
    param (
        [string]$deviceName
    )

    $device = Get-PnpDevice | Where-Object { $_.FriendlyName -like "*$deviceName*" }
    if ($device) {
        $deviceId = $device.InstanceId
        $deviceProperties = Get-PnpDeviceProperty -InstanceId $deviceId -KeyName "DEVPKEY_Device_Capabilities"
        
        if ($deviceProperties.Data -band 0x0400) {
            Write-Output "The device '$deviceName' is ESS-capable."
            $essCapableDevices += $deviceName
        }

        else {
            Write-Output "The device '$deviceName' is not ESS-capable."
        }
    }

    else {
        Write-Output "Device '$deviceName' not found."
    }
}

# Get USB host controllers
$hostControllers = Get-PnpDevice | Where-Object { $_.FriendlyName -like "*eXtensible Host Controller*" }

foreach ($controller in $hostControllers) {
    Check-ESSCapability -deviceName $controller.FriendlyName
}

# Get cameras
$cameras = Get-PnpDevice -Class Camera -PresentOnly

foreach ($camera in $cameras) {
    Check-ESSCapability -deviceName $camera.FriendlyName
}

if ($essCapableDevices) {
    Write-Output "This computer is ESS-capable."
    Exit:0
}

else { 
    Write-Output "This computer is not ESS-capable."
    Exit:1 
}
