<#	
	.NOTES
	===========================================================================
	 Created on:   	2025-10-14
	 Created by:   	Nicklas Ahlberg
	 Organization: 	Rockenroll.tech
	 Filename:     	Report - Unsupported iPhone and iPads.ps1
	 Version:       1.0.1.1
	===========================================================================
	.DESCRIPTION
		Use this script to create a report of unsupported iPhones and iPads in Intune.
        https://learn.microsoft.com/en-us/intune/intune-service/fundamentals/whats-new#plan-for-change-intune-is-moving-to-support-iosipados-17-and-later
	.WARRANTY
		The script is provided "AS IS" with no warranties
#>

#region Module management
$installModuleParameters = @{
    'Name'         = "ImportExcel", "MSAL.PS"
    'AllowClobber' = $true
    'Force'        = $true
    'Confirm'      = $false
}
#Install-Module @installModuleParameters

$importModuleParameters = @{
    'Name'  = "ImportExcel", "MSAL.PS"
    'Force' = $true
}
Import-Module @importModuleParameters
#endRegion

# Sign in (Delegated permissions needed: DeviceManagementManagedDevices.Read.All)
$connectionDetails = @{
    'TenantID' = '<TENANT_ID>'
    'ClientID' = '<CLIENT_ID>'
}
$token = (Get-MsalToken @connectionDetails).AccessToken

# Get all Apple devices
$appleDevicesParameters = @{
    'uri'         = "https://graph.microsoft.com/beta/deviceManagement/managedDevices?`$filter=manufacturer eq 'Apple'"
    'method'      = 'GET'
    'contenttype' = "application/json"
}
$appleDevicesCall = Invoke-RestMethod -Headers @{ Authorization = "Bearer $($token)" } @appleDevicesParameters # Get first page (1000 devices)
$appleDevices = $appleDevicesCall.value

$appleNextLink = $appleDevicesCall."@odata.nextLink" # Check for pagination
while ($appleNextLink -ne $null) {
    $appleDevicesCall = (Invoke-RestMethod -Headers @{ Authorization = "Bearer $($token)" } -Uri $appleNextLink -Method 'GET')
    $appleNextLink = $appleDevicesCall."@odata.nextLink"
    $appleDevices += $appleDevicesCall.value
}

# Separate iPhones and iPads
$iPhoneDevices = $appleDevices | Where-Object { $_.model -like 'iPhone*' }
$ipadDevices = $appleDevices | Where-Object { $_.model -like 'iPad*' }

# Identify devices below minimum OS version (iOS 17 for iPhones and iPads)
$iPhoneDevicesBelowiOS17 = $iPhoneDevices | Where-Object { $_.osVersion -lt '17.0' }
$ipadDevicesBelowiOS17 = $ipadDevices | Where-Object { $_.osVersion -lt '17.0' }

# Supported iPhone models (https://support.apple.com/guide/iphone/iphone-models-compatible-with-ios-17-iphe3fa5df43/17.0/ios/17.0)
$supportediPhoneModels = @(
    "iPhone XR",
    "iPhone XS",
    "iPhone XS Max",
    "iPhone 11",
    "iPhone 11 Pro",
    "iPhone 11 Pro Max",
    "iPhone 12 mini",
    "iPhone 12",
    "iPhone 12 Pro",
    "iPhone 12 Pro Max",
    "iPhone 13 mini",
    "iPhone 13",
    "iPhone 13 Pro",
    "iPhone 13 Pro Max",
    "iPhone 14",
    "iPhone 14 Plus",
    "iPhone 14 Pro",
    "iPhone 14 Pro Max",
    "iPhone 15",
    "iPhone 15 Plus",
    "iPhone 15 Pro",
    "iPhone 15 Pro Max",
    "iPhone SE (2nd generation)",
    "iPhone SE (3rd generation)"
)

# Supported iPad models (https://support.apple.com/guide/ipad/ipad-models-compatible-with-ipados-17-ipad213a25b2/17.0/ipados/17.0)
$supportediPadModels = @(
    'iPad mini (6th generation)',
    'iPad (10th generation)',
    'iPad Air (4th generation)',
    'iPad Air (5th generation)',
    'iPad Air (11")(M2)',
    'iPad Air (13")(M2)',
    'iPad Pro (11")(1st generation)',
    'iPad Pro (11")(2nd generation)',
    'iPad Pro (11")(3rd generation)',
    'iPad Pro (11")(4th generation)',
    'iPad Pro (11")(M4)',
    'iPad Pro (12.9")(3rd generation)',
    'iPad Pro (12.9")(4th generation)',
    'iPad Pro (12.9")(5th generation)',
    'iPad Pro (12.9")(6th generation)',
    'iPad Pro (13")(M4)',
    'iPad mini (5th generation)',
    'iPad (6th generation)',
    'iPad (7th generation)',
    'iPad (8th generation)',
    'iPad (9th generation)',
    'iPad Air (3rd generation)',
    'iPad Pro (10.5")',
    'iPad Pro (12.9")(2nd generation)'
)

# Identify unsupported devices
$unsupportedIPhones = $iPhoneDevicesBelowiOS17 | Where-Object { $supportediPhoneModels -notcontains $_.model }
$unsupportediPads = $ipadDevicesBelowiOS17 | Where-Object { $supportediPadModels -notcontains $_.model }

# Export iPhone results
$iPhoneResults = $null
$iPhoneResults = foreach ($iPhone in $unsupportedIPhones) {
    [PSCustomObject]@{
        "Device Name" = $iPhone.deviceName
        "Model"       = $iPhone.model
        "OS Version"  = $iPhone.osVersion
    }
}

# Export iPad results
$iPadResults = $null
$iPadResults = foreach ($iPad in $unsupportediPads) {
    [PSCustomObject]@{
        "Device Name" = $iPad.deviceName
        "Model"       = $iPad.model
        "OS Version"  = $iPad.osVersion
    }
}   

# Export to Excel
$iPhoneResults | Export-Excel .\"$(New-Guid).xlsx" -AutoSize -AutoFilter -FreezeTopRow -TableStyle Medium11 -Show
$iPadResults | Export-Excel .\"$(New-Guid).xlsx" -AutoSize -AutoFilter -FreezeTopRow -TableStyle Medium11 -Show