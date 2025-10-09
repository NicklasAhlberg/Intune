<#	
	.NOTES
	===========================================================================
	 Created on:   	2025-10-09 07:28
	 Created by:   	Nicklas Ahlberg
	 Organization: 	rockenroll.tech
	 Filename:     	Mitigate-IT1168328-Remediation.ps1
     Version:      	1.0.0
	===========================================================================
	.DESCRIPTION
		Detect and delete contents of C:\Windows\Temp\WinGet\defaultState to mitigate incident #IT1168328
		Microsoft does recommend a manual reboot after remediation. You may add that to this script or inform the user to do so at their earliest convenience.
	.WARRANTY
		The script is provided "AS IS" with no warranties
#>

# Detect and delete files
$folderPath = "C:\Windows\Temp\WinGet\defaultState"
try {
    if (Test-Path $folderPath) {
        Get-ChildItem -Path $folderPath -Recurse -Force | Remove-Item -Recurse -Force
        Write-Output "Files in $folderPath have been deleted."; Exit 0
    }

    else {
        Write-Output "No files found in $folderPath."; Exit 0
    }
}

catch {
    Write-Output "An error occurred: $_"; Exit 1
}