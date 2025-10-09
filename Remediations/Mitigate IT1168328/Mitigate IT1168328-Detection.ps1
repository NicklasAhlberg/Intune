<#	
	.NOTES
	===========================================================================
	 Created on:   	2025-10-09 07:31
	 Created by:   	Nicklas Ahlberg
	 Organization: 	rockenroll.tech
	 Filename:     	Mitigate-IT1168328-Detection.ps1
     Version:      	1.0.0
	===========================================================================
	.DESCRIPTION
		Detect contents of C:\Windows\Temp\WinGet\defaultState to mitigate incident #IT1168328
	.WARRANTY
		The script is provided "AS IS" with no warranties
#>

# Detect and delete files
$folderPath = "C:\Windows\Temp\WinGet\defaultState"

if (Test-Path $folderPath) {

	Write-Output "Files in $folderPath was detected."; #Exit 1
}

else {
	Write-Output "No files found in $folderPath."; #Exit 0
}