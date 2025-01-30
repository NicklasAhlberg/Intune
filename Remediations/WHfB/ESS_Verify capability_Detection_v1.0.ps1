<#
.SYNOPSIS
Use this script to verify that ESS has been enabled 
.DESCRIPTION
This script checks if ESS has been enabled. This version checks the internal camera and not the fingerprint sensor at this point
.EXAMPLE
Run it manually on a local device or use Intune remediation script
.NOTES
NAME: ESS_Verify capability_Detection_v1.0.ps1
.WARRANTY
THIS CODE AND INFORMATION IS PROVIDED "AS IS" WITHOUT WARRANTY OF ANY KIND, EITHER EXPRESSED OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE IMPLIED WARRANTIES OF MERCHANTABILITY AND/OR FITNESS FOR A PARTICULAR PURPOSE.
.AUTHOR
Nicklas Ahlberg, https://rockenroll.tech
#>

# Define the log path and event ID
$LogPath = "Microsoft-Windows-Biometrics/Operational"
$EventID = 1108

# Check if the log exists
if (Get-WinEvent -ListLog $LogPath -ErrorAction SilentlyContinue) {
    Write-Host "Searching for Event ID $EventID in log: $LogPath`n"

    # Retrieve events with the specified ID
    $Events = Get-WinEvent -LogName $LogPath -FilterXPath "*[System[EventID=$EventID]]"

    if ($Events) {
        Write-Host "Found the following events:`n"
        foreach ($Event in $Events) {
            # Display event details
            Write-Host "TimeCreated: $($Event.TimeCreated)"
            Write-Host "Message: $($Event.Message)"
            Write-Host "------------------------------------"
        }
    }
    
    else {
        Write-Host "No events with ID $EventID found in the log: $LogPath"
    }
}

else {
    Write-Host "The specified log path '$LogPath' does not exist or is not accessible."
}

# Check if event messages contain the specified text
$SearchText1 = "(ROOT\WINDOWSHELLOFACESOFTWAREDRIVER\0000)"
$SearchText2 = "Virtual Secure Mode"

$MatchingEvents = $Events | Where-Object { $_.Message -like "*$SearchText1*" -and $_.Message -like "*$SearchText2*" }

if ($MatchingEvents) {
    Write-Host "`nEvents containing the text '$SearchText1' and '$SearchText2':`n"
    foreach ($Event in $MatchingEvents) {
        # Display event details
        Write-Host "TimeCreated: $($Event.TimeCreated)"
        Write-Host "Message: $($Event.Message)"
        Write-Host "------------------------------------"
        Write-output "ESS has been enabled"
        Exit 0
    }
}

else {
    Write-Host "`nNo events containing the text '$SearchText1' and '$SearchText2' found."
    Write-Output "ESS has not been enabled"
    Exit 1
}