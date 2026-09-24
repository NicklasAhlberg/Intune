### RE

$version = '2.3.0.0'

# Runs as an Azure Automation runbook on the PowerShell 7.4 runtime or later (ForEach-Object
# -Parallel below is PS7 only). Authenticates with the Automation account's managed identity,
# so the Az.Accounts module must be present in the runtime environment. The identity needs these
# Graph app roles: DeviceManagementConfiguration.ReadWrite.All,
# DeviceManagementManagedDevices.Read.All, Group.ReadWrite.All, Device.Read.All.

# Leave empty for the system-assigned identity, or set the client ID of a user-assigned one
$managedIdentityClientId = ''

# When $true, the script still reads the tenant but only reports what it would create, assign or
# delete. Nothing is written: Invoke-ApiWithRetry refuses any request that is not a GET.
$whatIf = $false

# Set to 'automatic' or 'manual' - controls group/policy naming and driver update approval behaviour
$approval = 'Automatic'

# Number of days to defer automatic driver approvals - only applies when $approval is 'automatic'
$automaticDays = 7

# When set to a group display name, only device models found in that group are processed.
# Leave empty to query all Windows devices in the tenant.
$limitingGroup = ''

# Set to one Lenovo machine type (the first 4 characters of the model, e.g. '21AH') to run for
# that model only. The run covers the whole family the machine type belongs to, exactly as a
# full run would. Leave empty to process every model.
$singleMachineType = ''

# Models whose display name starts with any of these strings are skipped entirely
$excludeModels = @(
    'Cloud PC',
    'Virtual Machine',
    'AHV'
)

# 'Family'      - one group per Lenovo friendly name. All machine types that share the name
#                 (e.g. 21AH and 21AJ for a ThinkPad T14 Gen 3) land in the same group.
# 'MachineType' - one group per 4-character machine type, named "<friendly name> (21AH)".
#                 Use this if two variants of the same marketing name take different driver packs.
# 'Model'       - one group per exact model string (the original v1.0 behaviour).
# Manufacturers other than Lenovo already report a family-style model string and are untouched.
$groupBy = 'Family'

# Lenovo publishes a machine type to friendly name list for its BIOS Simulator. It is public,
# needs no authentication, and is the same source Damien Van Robaeys' MTM_to_FriendlyName.ps1 uses.
# Set $useLenovoCatalog to $false to work purely from the manual table below.
$useLenovoCatalog = $true
$lenovoCatalogUrl = 'https://download.lenovo.com/bsco/public/allModels.json'

# Manual overrides, applied on top of the downloaded list. Entries here always win, so this is
# where to correct a name you dislike or fill a gap if the download is unavailable.
# Machine types that had no match are listed in the run log as a WARN.
$lenovoFamilyNames = @{
    # '21CB' = 'ThinkPad T14 Gen 3'
}

# Reverse index (friendly name -> every machine type carrying it), filled in from the catalog.
# Used so a Family group's membership rule also covers machine types not yet enrolled.
$lenovoFamilyTypes = @{}

# Writes a timestamped log line to the console; WARN and ERROR also emit to their native PS streams.
# Uses Write-Host so log messages never pollute the pipeline in functions that return data.
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $formatted = "[$timestamp] [$Level] $Message"
    Write-Host $formatted
    switch ($Level) {
        "WARN" { Write-Warning $Message }
        "ERROR" { Write-Error   $Message }
    }
}

# Downloads Lenovo's public model list and returns a hashtable of machine type -> friendly name.
# Returns an empty hashtable on any failure; the caller falls back to the manual table.
function Get-LenovoFamilyMap {
    param([string]$Uri)

    $map = @{}

    try {
        $entries = Invoke-RestMethod -Uri $Uri -Method GET -TimeoutSec 60
    }
    catch {
        Write-Log "Could not download the Lenovo model list ($Uri): $_" -Level "WARN"
        Write-Log "Falling back to the manual `$lenovoFamilyNames table." -Level "WARN"
        return $map
    }

    foreach ($entry in $entries) {
        $name = $entry.name
        if (-not $name) { continue }

        # The list also carries BIOS setting entries; skip them the same way Damien's script does
        if ($name -match '\-UEFI Lenovo|dTPM|fTPM|Asset') { continue }

        # Entries read "<friendly name> (<machine type>)", e.g. "ThinkPad T14 Gen 3 (21AH)"
        if ($name -notmatch '^(?<family>[^(]+)\((?<types>[^)]*)\)') { continue }

        $family = $Matches['family'].Trim()
        if (-not $family) { continue }

        # The bracket can hold more than one machine type. \b keeps this to standalone 4-character
        # tokens so a full 10-character MTM is never chopped into fragments.
        foreach ($match in [regex]::Matches($Matches['types'], '\b[0-9A-Za-z]{4}\b')) {
            $type = $match.Value.ToUpper()
            if (-not $map.ContainsKey($type)) { $map[$type] = $family }
        }
    }

    if ($map.Count -eq 0) {
        Write-Log "The Lenovo model list downloaded but no machine types could be parsed from it - the format may have changed." -Level "WARN"
    }

    $map
}

# Returns the 4-character machine type when the model string is a Lenovo MTM, otherwise $null.
# An MTM is the machine type followed by a 6-character configuration code, e.g. 21CB00ABMX -> 21CB.
function Get-LenovoMachineType {
    param([string]$Model)

    if ($Model.Trim() -match '^(?<mt>[0-9]{2}[A-Z0-9]{2})[A-Z0-9]{6}$') {
        return $Matches['mt'].ToUpper()
    }
    $null
}

# Maps a raw Intune model string onto a hardware family.
# Returns:
#   Key         - stable identifier used to group models together
#   DisplayName - what goes into the group/policy name
#   MatchType   - 'Prefix' (dynamic rule uses -startsWith) or 'Exact' (-eq)
#   MatchValues - every value the dynamic membership rule should compare against
function Get-ModelFamily {
    param([string]$Model)

    $m = $Model.Trim()

    # Lenovo MTM: only the first 4 characters (the machine type) identify the platform
    $prefix = if ($groupBy -ne 'Model') { Get-LenovoMachineType -Model $m } else { $null }
    if ($prefix) {
        $name = if ($lenovoFamilyNames.ContainsKey($prefix)) { $lenovoFamilyNames[$prefix] } else { $null }

        if ($groupBy -eq 'Family' -and $name) {
            # Collapse every machine type sharing this friendly name into one group, and let the
            # rule cover types that exist in the catalog but have not been enrolled yet.
            $types = if ($lenovoFamilyTypes.ContainsKey($name)) { @($lenovoFamilyTypes[$name]) } else { @($prefix) }

            return [pscustomobject]@{
                Key         = $name
                DisplayName = $name
                MatchType   = 'Prefix'
                MatchValues = @($types | Sort-Object -Unique)
            }
        }

        return [pscustomobject]@{
            Key         = $prefix
            DisplayName = if ($name) { "$name ($prefix)" } else { "Lenovo $prefix" }
            MatchType   = 'Prefix'
            MatchValues = @($prefix)
        }
    }

    # Dell, HP, Microsoft and friends already report a family-style name ("Latitude 5440",
    # "EliteBook 840 G9"), so the model string is the family. Same path when $groupBy = 'Model'.
    [pscustomobject]@{
        Key         = $m
        DisplayName = $m
        MatchType   = 'Exact'
        MatchValues = @($m)
    }
}

# Returns a Microsoft Graph access token for the Automation account's managed identity, as a
# plain string. Throws on failure so the runbook stops before it starts creating objects.
function Get-GraphToken {
    # Keep the Az context to this job so concurrent runbook jobs never share a credential
    Disable-AzContextAutosave -Scope Process | Out-Null

    if ($managedIdentityClientId) {
        Write-Log "Authenticating with the user-assigned managed identity ($managedIdentityClientId)."
        Connect-AzAccount -Identity -AccountId $managedIdentityClientId | Out-Null
    }
    else {
        Write-Log "Authenticating with the system-assigned managed identity."
        Connect-AzAccount -Identity | Out-Null
    }

    # Az.Accounts 5.0 changed Token from a plain string to a SecureString, so accept either -
    # the installed module version varies between Automation accounts.
    $raw = (Get-AzAccessToken -ResourceUrl 'https://graph.microsoft.com' -WarningAction SilentlyContinue).Token

    if ($raw -is [System.Security.SecureString]) {
        return ConvertFrom-SecureString -SecureString $raw -AsPlainText
    }
    [string]$raw
}

# Wraps Invoke-RestMethod with automatic retry on 429/5xx;
# honours the Retry-After header on throttling, falls back to exponential backoff otherwise
function Invoke-ApiWithRetry {
    param(
        [hashtable]$Headers,
        [string]$Uri,
        [string]$Method = "GET",
        [string]$Body,
        [string]$ContentType,
        [int]$MaxRetries = 5,
        [int]$TimeoutSec = 60
    )

    # Safety net for WhatIf mode: callers report instead of writing, so a write reaching this
    # point means a write site is missing its $whatIf check. Stop rather than change the tenant.
    # Fails closed: writes only go through when $whatIf is exactly $false, so a missing value
    # (e.g. $whatIf not brought into a parallel runspace) blocks them as well.
    if ($Method -ne 'GET' -and ($whatIf -isnot [bool] -or $whatIf)) {
        throw "WhatIf is on or not set - blocked $Method $Uri"
    }

    $attempt = 0
    while ($attempt -lt $MaxRetries) {
        try {
            $params = @{
                Headers    = $Headers
                Uri        = $Uri
                Method     = $Method
                TimeoutSec = $TimeoutSec
            }
            if ($Body) { $params.Body = $Body }
            if ($ContentType) { $params.ContentType = $ContentType }

            return Invoke-RestMethod @params
        }
        catch {
            $statusCode = $_.Exception.Response.StatusCode.value__
            if ($statusCode -eq 429 -or $statusCode -ge 500) {
                # On 429, read Retry-After from the response header if present
                $retryAfter = $null
                if ($statusCode -eq 429) {
                    $headerValues = [string[]]@()
                    if ($_.Exception.Response.Headers.TryGetValues('Retry-After', [ref]$headerValues)) {
                        $retryAfter = [int]$headerValues[0]
                    }
                }
                # Fall back to capped exponential backoff if no header was present
                if ($null -eq $retryAfter) {
                    $retryAfter = [int][Math]::Min(10 * [Math]::Pow(2, $attempt), 60)
                }

                $source = if ($statusCode -eq 429 -and $headerValues.Count -gt 0) { 'Retry-After header' } else { 'backoff' }
                $attempt++
                Write-Log "HTTP $statusCode - waiting ${retryAfter}s via $source (attempt $attempt/$MaxRetries): $Uri" -Level "WARN"
                Start-Sleep -Seconds $retryAfter
            }
            else {
                throw
            }
        }
    }
    throw "Max retries ($MaxRetries) reached for $Uri"
}

# Reads a Graph collection, following @odata.nextLink until every page is in, and returns all
# items. Errors propagate so each caller can log them in its own words.
function Get-GraphAllPages {
    param(
        [string]$Uri,
        [hashtable]$Headers
    )

    $items = [System.Collections.Generic.List[object]]::new()
    do {
        $response = Invoke-ApiWithRetry -Uri $Uri -Method GET -ContentType 'application/json' -Headers $Headers
        if ($response.value) { $items.AddRange(@($response.value)) }
        $Uri = $response.'@odata.nextLink'
    } while ($Uri)

    $items
}

# Returns every group whose name starts with Drivers-FW- (id and displayName).
# startsWith is an advanced query on the Groups API: it needs ConsistencyLevel: eventual and
# $count=true. Eventual means a group created seconds ago can still be missing from the result.
function Get-DriversFWGroups {
    $advancedHeaders = $headers + @{ 'ConsistencyLevel' = 'eventual' }
    Get-GraphAllPages `
        -Uri "https://graph.microsoft.com/beta/groups?`$filter=startsWith(displayName,'Drivers-FW-')&`$select=id,displayName&`$count=true" `
        -Headers $advancedHeaders
}

# Retrieves all unique Windows device models from Intune via paged Graph API calls
function Get-ModelsFromIntune {
    try {
        $devices = @(Get-GraphAllPages -Headers $headers `
                -Uri "https://graph.microsoft.com/beta/deviceManagement/managedDevices?`$filter=operatingSystem eq 'Windows'&`$select=model")
    }
    catch {
        Write-Log "Failed to retrieve devices from Intune: $_" -Level "ERROR"
        throw
    }

    $devices | Where-Object { $_.model } | Select-Object -ExpandProperty 'model' | Sort-Object -Unique
}

# Retrieves device objects (entra id + model) for members of a specific Entra ID group.
# Model names are sourced from Intune (reliable) via azureADDeviceId cross-reference,
# because the Entra ID device object's model property is often unpopulated for MDM devices.
# Returns objects with: id (Entra directory object ID for group membership) and model.
function Get-DevicesFromGroup {
    param([string]$GroupName)

    # Step 1: Resolve group display name to ID
    $escapedName = $GroupName -replace "'", "''"
    $lookup = Invoke-ApiWithRetry `
        -Uri "https://graph.microsoft.com/beta/groups?`$filter=displayName eq '$escapedName'&`$select=id,displayName" `
        -Method GET -ContentType 'application/json' -Headers $headers

    if ($lookup.value.Count -eq 0) {
        Write-Log "Limiting group not found: $GroupName" -Level "ERROR"
        throw "Group '$GroupName' not found in Entra ID."
    }

    $groupId = $lookup.value[0].id
    Write-Log "Limiting scope to group: $($lookup.value[0].displayName) ($groupId)"

    # Step 2: Get group member devices - id (directory object ID) and deviceId (Azure AD device ID)
    # OData cast filters to device-type members only, skipping users and other object types
    try {
        $groupDevices = @(Get-GraphAllPages -Headers $headers `
                -Uri "https://graph.microsoft.com/beta/groups/$groupId/members/microsoft.graph.device?`$select=id,deviceId")
    }
    catch {
        Write-Log "Failed to retrieve group members: $_" -Level "ERROR"
        throw
    }

    Write-Log "Found $($groupDevices.Count) device(s) in limiting group."

    # Build a lookup: azureADDeviceId (lowercase) -> Entra directory object id
    $deviceIdMap = @{}
    foreach ($d in $groupDevices) {
        if ($d.deviceId) { $deviceIdMap[$d.deviceId.ToLower()] = $d.id }
    }

    # Step 3: Fetch all Intune Windows devices - azureADDeviceId links back to the Entra device
    try {
        $intuneDevices = @(Get-GraphAllPages -Headers $headers `
                -Uri "https://graph.microsoft.com/beta/deviceManagement/managedDevices?`$filter=operatingSystem eq 'Windows'&`$select=azureADDeviceId,model")
    }
    catch {
        Write-Log "Failed to retrieve Intune devices: $_" -Level "ERROR"
        throw
    }

    # Step 4: Return only Intune devices that are members of the limiting group,
    # carrying their Entra directory object id for static group member assignment later
    $result = [System.Collections.Generic.List[object]]::new()
    foreach ($device in $intuneDevices) {
        if ($device.model -and $device.azureADDeviceId) {
            $entraId = $deviceIdMap[$device.azureADDeviceId.ToLower()]
            if ($entraId) {
                $result.Add([pscustomobject]@{
                        id    = $entraId
                        model = $device.model
                    })
            }
        }
    }

    Write-Log "Matched $($result.Count) Intune device(s) to limiting group members."
    $result
}

# Finds and permanently deletes all groups and driver update policies created by this script (prefix: Drivers-FW-)
# Call manually: Remove-DriversFWGroups
function Remove-DriversFWGroups {
    # Capitalise approval so suffix matches the naming convention (e.g. 'automatic' -> 'Automatic')
    $approvalSuffix = (Get-Culture).TextInfo.ToTitleCase($approval)

    Write-Log "Searching for Drivers-FW-*-$approvalSuffix groups and policies..."

    try {
        $groups = @(Get-DriversFWGroups)
    }
    catch {
        Write-Log "Failed to retrieve groups: $_" -Level "ERROR"
        throw
    }

    # When $limitingGroup is set, only target resources with the -Pilot suffix
    $limitingSuffix = if ($limitingGroup) { '-Pilot' } else { '' }

    # Filter client-side to only the approval mode (and limiting) suffix
    $groups = @($groups | Where-Object { $_.displayName -like "Drivers-FW-*-$approvalSuffix$limitingSuffix" })

    # Intune endpoints do not support startsWith - fetch all profiles and filter client-side
    try {
        $policies = @(Get-GraphAllPages -Headers $headers `
                -Uri "https://graph.microsoft.com/beta/deviceManagement/windowsDriverUpdateProfiles?`$select=id,displayName")
    }
    catch {
        Write-Log "Failed to retrieve driver update policies: $_" -Level "ERROR"
        throw
    }

    # Trailing wildcard covers the -7d suffix on automatic policy names; ends with $limitingSuffix
    $policies = @($policies | Where-Object { $_.displayName -like "Drivers-FW-*-$approvalSuffix*$limitingSuffix" })

    if ($groups.Count -eq 0 -and $policies.Count -eq 0) {
        Write-Log "No Drivers-FW-$approvalSuffix$limitingSuffix groups or policies found. Nothing to remove."
        return
    }

    Write-Log "Found $($groups.Count) group(s) and $($policies.Count) policy(ies) to remove."

    $countGroupsRemoved = 0
    $countGroupsFailed = 0
    $countPoliciesRemoved = 0
    $countPoliciesFailed = 0

    # Safeguard patterns - a resource must match exactly before it can be deleted.
    # Both standard and -Pilot variants are accepted; the mode-specific filter above already narrowed the list.
    $groupPattern = '^Drivers-FW-.+-(Automatic|Manual)(-Pilot)?$'
    $policyPattern = '^Drivers-FW-.+-(Automatic(-\d+d)?|Manual)(-Pilot)?$'

    foreach ($group in $groups) {
        if ($group.displayName -notmatch $groupPattern) {
            Write-Log "Safeguard blocked removal of unexpected group: $($group.displayName)" -Level "WARN"
            $countGroupsFailed++
            continue
        }
        if ($whatIf) {
            Write-Log "[WHATIF] Would remove group: $($group.displayName) ($($group.id))"
            $countGroupsRemoved++
            continue
        }
        try {
            Invoke-ApiWithRetry -Uri "https://graph.microsoft.com/beta/groups/$($group.id)" `
                -Method DELETE -Headers $headers | Out-Null

            Write-Log "Group removed: $($group.displayName) ($($group.id))"
            $countGroupsRemoved++
        }
        catch {
            Write-Log "Failed to remove group '$($group.displayName)': $_" -Level "ERROR"
            $countGroupsFailed++
        }
    }

    foreach ($policy in $policies) {
        if ($policy.displayName -notmatch $policyPattern) {
            Write-Log "Safeguard blocked removal of unexpected policy: $($policy.displayName)" -Level "WARN"
            $countPoliciesFailed++
            continue
        }
        if ($whatIf) {
            Write-Log "[WHATIF] Would remove policy: $($policy.displayName) ($($policy.id))"
            $countPoliciesRemoved++
            continue
        }
        try {
            Invoke-ApiWithRetry `
                -Uri "https://graph.microsoft.com/beta/deviceManagement/windowsDriverUpdateProfiles/$($policy.id)" `
                -Method DELETE -Headers $headers | Out-Null

            Write-Log "Policy removed: $($policy.displayName) ($($policy.id))"
            $countPoliciesRemoved++
        }
        catch {
            Write-Log "Failed to remove policy '$($policy.displayName)': $_" -Level "ERROR"
            $countPoliciesFailed++
        }
    }

    $removed = if ($whatIf) { 'to remove' } else { 'removed' }

    Write-Log "------------------------------------------------------------"
    if ($whatIf) { Write-Log "WhatIf removal complete - nothing was deleted." }
    else { Write-Log "Removal complete." }
    Write-Log ("  {0,-19}: {1}" -f "Groups $removed", $countGroupsRemoved)
    Write-Log ("  {0,-19}: {1}" -f "Groups failed", $countGroupsFailed)
    Write-Log ("  {0,-19}: {1}" -f "Policies $removed", $countPoliciesRemoved)
    Write-Log ("  {0,-19}: {1}" -f "Policies failed", $countPoliciesFailed)
    Write-Log "------------------------------------------------------------"
}

Write-Log "New-DriverFWGroupsAndPolicies.ps1 v$version"

# A value like 'true' or 1 would be read inconsistently across the script, so refuse to start
if ($whatIf -isnot [bool]) {
    throw "`$whatIf must be `$true or `$false, not '$whatIf'."
}
if ($whatIf) {
    # WARN so the banner also shows on the job's Warnings tab in Azure Automation
    Write-Log "*** WHATIF MODE - the tenant is only read, no changes will be made ***" -Level "WARN"
}

# Only a bare machine type is accepted: a full model code or a product name is rejected here,
# before sign-in, rather than silently matching nothing later
if ($singleMachineType) {
    if ($singleMachineType -notmatch '^[0-9]{2}[A-Z0-9]{2}$') {
        throw "`$singleMachineType must be a 4-character Lenovo machine type such as '21AH', not '$singleMachineType'."
    }
    $singleMachineType = $singleMachineType.ToUpper()
    Write-Log "Single machine type mode: $singleMachineType"
}

$token = Get-GraphToken
if ([string]::IsNullOrWhiteSpace($token)) {
    throw "Could not obtain a Microsoft Graph access token for the managed identity."
}

# Reusable auth header for all Graph API calls
$headers = @{ Authorization = "Bearer $token" }

if ($limitingGroup) {
    Write-Log "Querying device models from limiting group: $limitingGroup"
    $limitingGroupDevices = @(Get-DevicesFromGroup -GroupName $limitingGroup)
    $models = @($limitingGroupDevices | Select-Object -ExpandProperty model | Sort-Object -Unique)
}
else {
    Write-Log "Querying Intune for all Windows device models..."
    $limitingGroupDevices = $null
    $models = @(Get-ModelsFromIntune)
}

# Remove excluded models - prefix match so e.g. 'Cloud PC' catches all Cloud PC variants
$models = @($models | Where-Object {
        $m = $_
        -not ($excludeModels | Where-Object { $m -like "$_*" })
    })

Write-Log "Found $($models.Count) unique model(s) after exclusions."

# In single machine type mode, stop here if no device has that machine type, before the catalog
# download and before anything is fetched or written
if ($singleMachineType) {
    $singleTypeModels = @($models | Where-Object { (Get-LenovoMachineType -Model $_) -eq $singleMachineType })
    if ($singleTypeModels.Count -eq 0) {
        $source = if ($limitingGroup) { "the limiting group '$limitingGroup'" } else { 'Intune' }
        Write-Log "No devices with machine type $singleMachineType found in $source - nothing to do." -Level "WARN"
        return
    }
    Write-Log "Machine type $singleMachineType found in model(s): $($singleTypeModels -join ', ')"
}

# The catalog only names Lenovo machine types, so skip the download when nothing would use it
$hasLenovoModels = @($models | Where-Object { Get-LenovoMachineType -Model $_ }).Count -gt 0

# Merge the downloaded machine type list under the manual overrides, then build the reverse index
if ($useLenovoCatalog -and $groupBy -eq 'Model') {
    Write-Log "Skipping the Lenovo machine type list - it is not used when grouping by Model."
}
elseif ($useLenovoCatalog -and -not $hasLenovoModels) {
    Write-Log "Skipping the Lenovo machine type list - no Lenovo models in scope."
}
elseif ($useLenovoCatalog) {
    Write-Log "Downloading the Lenovo machine type list..."
    $catalogMap = Get-LenovoFamilyMap -Uri $lenovoCatalogUrl

    $addedFromCatalog = 0
    foreach ($type in $catalogMap.Keys) {
        if (-not $lenovoFamilyNames.ContainsKey($type)) {
            $lenovoFamilyNames[$type] = $catalogMap[$type]
            $addedFromCatalog++
        }
    }
    Write-Log "Loaded $addedFromCatalog machine type(s) from the Lenovo list ($($lenovoFamilyNames.Count) known in total)."
}

foreach ($type in $lenovoFamilyNames.Keys) {
    $name = $lenovoFamilyNames[$type]
    if (-not $lenovoFamilyTypes.ContainsKey($name)) { $lenovoFamilyTypes[$name] = [System.Collections.Generic.List[string]]::new() }
    $lenovoFamilyTypes[$name].Add($type)
}

# Collapse the raw model strings into families. Each family carries the list of model
# strings that rolled into it, which the static-membership path uses to pick devices.
$families = @(
    $models |
    ForEach-Object { [pscustomobject]@{ Model = $_; Family = (Get-ModelFamily -Model $_) } } |
    Group-Object { $_.Family.Key } |
    ForEach-Object {
        $f = $_.Group[0].Family
        [pscustomobject]@{
            Key         = $f.Key
            DisplayName = $f.DisplayName
            MatchType   = $f.MatchType
            MatchValues = $f.MatchValues
            Models      = @($_.Group | Select-Object -ExpandProperty Model | Sort-Object -Unique)
        }
    } |
    Sort-Object DisplayName
)

Write-Log "Collapsed into $($families.Count) family(ies) (grouping mode: $groupBy)."

# In single machine type mode, keep only the families that contain it. Families are filtered
# rather than models, so a family keeps all its models: pilot members are picked from them.
if ($singleMachineType) {
    $families = @($families | Where-Object {
            @($_.Models | Where-Object { (Get-LenovoMachineType -Model $_) -eq $singleMachineType }).Count -gt 0
        })
    foreach ($f in $families) {
        Write-Log "Limiting run to '$($f.DisplayName)' (machine types: $($f.MatchValues -join ', '))."
    }
}
foreach ($f in $families) {
    if ($f.Models.Count -gt 1 -or $f.MatchValues.Count -gt 1) {
        Write-Log "  $($f.DisplayName) - machine types: $($f.MatchValues -join ', ') - models seen: $($f.Models -join ', ')"
    }
}

# Surface unmapped Lenovo machine types so the override table can be filled in over time
$unmapped = @($families | Where-Object { $_.DisplayName -match '^Lenovo [0-9A-Z]{4}$' })
if ($unmapped.Count -gt 0) {
    Write-Log "No friendly name found for $($unmapped.Count) machine type(s): $($unmapped.Key -join ', ')" -Level "WARN"
}

# Pre-fetch all existing driver update policies - the endpoint does not support $filter,
# so we fetch once here and do a client-side check inside the parallel loop
Write-Log "Fetching existing driver update policies..."
try {
    $allPolicies = @(Get-GraphAllPages -Headers $headers `
            -Uri "https://graph.microsoft.com/beta/deviceManagement/windowsDriverUpdateProfiles?`$select=displayName")
}
catch {
    Write-Log "Failed to fetch existing driver update policies: $_" -Level "ERROR"
    throw
}
$existingPolicyNames = @($allPolicies | Select-Object -ExpandProperty displayName)
Write-Log "Found $($existingPolicyNames.Count) existing driver update policy(ies)."

# Pre-fetch the script's existing groups in one paged query instead of one lookup per family.
# Keyed by display name (case-insensitive, like Entra); if names repeat, the first one wins.
Write-Log "Fetching existing Drivers-FW groups..."
try {
    $allGroups = @(Get-DriversFWGroups)
}
catch {
    Write-Log "Failed to fetch existing groups: $_" -Level "ERROR"
    throw
}
$existingGroupIds = @{}
foreach ($g in $allGroups) {
    if (-not $existingGroupIds.ContainsKey($g.displayName)) { $existingGroupIds[$g.displayName] = $g.id }
}
Write-Log "Found $($existingGroupIds.Count) existing Drivers-FW group(s)."

# Function bodies go into the parallel runspaces as text, because $using: cannot carry a script
# block. This keeps a single definition of each instead of a second copy inside the loop.
$writeLogDef = ${function:Write-Log}.ToString()
$invokeApiDef = ${function:Invoke-ApiWithRetry}.ToString()

$action = if ($whatIf) { 'Planning' } else { 'Creating' }
Write-Log "$action groups and driver update policies for all discovered families (approval mode: $approval)..."

$results = $families | ForEach-Object -Parallel {
    # Rebuild the outer script's functions in this runspace from their text
    ${function:Write-Log} = $using:writeLogDef
    ${function:Invoke-ApiWithRetry} = $using:invokeApiDef

    # Bring outer variables into this scope
    $headers = $using:headers
    $whatIf = $using:whatIf
    $approval = $using:approval
    $automaticDays = $using:automaticDays
    $existingPolicyNames = $using:existingPolicyNames
    $existingGroupIds = $using:existingGroupIds
    $limitingGroup = $using:limitingGroup
    $limitingGroupDevices = $using:limitingGroupDevices
    $family = $_
    $familyName = $family.DisplayName

    $outcome = [pscustomobject]@{
        GroupCreated     = $false
        GroupSkipped     = $false
        GroupFailed      = $false
        PolicyCreated    = $false
        PolicySkipped    = $false
        PolicyFailed     = $false
        PolicyAssigned   = $false
        AssignmentFailed = $false
    }

    # Holds the group ID so the policy assignment can reference it after both blocks run
    $groupId = $null

    # In WhatIf mode a new group gets no ID, so this records that it would have been created
    $groupWouldExist = $false

    # When a limiting group is in use, append -Pilot so these resources are
    # clearly distinct from full-tenant groups and policies
    $limitingSuffix = if ($limitingGroup) { '-Pilot' } else { '' }

    # Names are suffixed with the approval mode (and optionally -Pilot) so they are self-describing
    if ($approval -eq 'automatic') {
        $groupName = "Drivers-FW-$familyName-Automatic$limitingSuffix"
        $policyName = "Drivers-FW-$familyName-Automatic-${automaticDays}d$limitingSuffix"
    }
    else {
        $groupName = "Drivers-FW-$familyName-Manual$limitingSuffix"
        $policyName = "Drivers-FW-$familyName-Manual$limitingSuffix"
    }

    # Escaped group name for use in OData filter string (OData represents ' as '')
    $groupNameEscaped = $groupName -replace "'", "''"

    # mailNickname must be alphanumeric with hyphens only, max 64 chars
    $mailNickname = ($groupName -replace '[^a-zA-Z0-9]', '-').ToLower()
    if ($mailNickname.Length -gt 64) { $mailNickname = $mailNickname.Substring(0, 64) }

    # --- Entra ID group ---
    try {
        # Most groups are found in the pre-fetched list. That list comes from an eventually
        # consistent query, so a miss is confirmed with a direct lookup before anything is
        # created; a group made moments ago by an earlier run is then still found.
        $existingGroupId = $existingGroupIds[$groupName]
        if (-not $existingGroupId) {
            $lookup = Invoke-ApiWithRetry `
                -Uri "https://graph.microsoft.com/beta/groups?`$filter=displayName eq '$groupNameEscaped'&`$select=id,displayName" `
                -Method GET -ContentType 'application/json' -Headers $headers
            if ($lookup.value.Count -gt 0) { $existingGroupId = $lookup.value[0].id }
        }

        if ($existingGroupId) {
            Write-Log "Group already in place, skipping: $groupName"
            $outcome.GroupSkipped = $true
            $groupId = $existingGroupId
        }
        else {
            if ($limitingGroup) {
                # Static/assigned group - a dynamic rule would match devices outside the limiting group
                $groupBody = @{
                    displayName     = $groupName
                    mailEnabled     = $false
                    mailNickname    = $mailNickname
                    securityEnabled = $true
                } | ConvertTo-Json
            }
            else {
                # Dynamic group - membership rule targets every device in this family tenant-wide.
                # Prefix families use -startsWith so all configuration codes under a machine type
                # are caught, including ones that have not been enrolled yet.
                if ($family.MatchType -eq 'Prefix') {
                    $clauses = @($family.MatchValues | ForEach-Object { "device.deviceModel -startsWith `"$_`"" })
                }
                else {
                    $clauses = @($family.MatchValues | ForEach-Object { "device.deviceModel -eq `"$_`"" })
                }
                $membershipRule = "($($clauses -join ' -or '))"

                # Entra caps membership rules at 3072 characters. Very large families would blow
                # past that, so keep only the machine types actually seen in the tenant.
                if ($family.MatchType -eq 'Prefix' -and $membershipRule.Length -gt 3000) {
                    Write-Log "Membership rule for '$familyName' is $($membershipRule.Length) chars - trimming to machine types present in the tenant." -Level "WARN"
                    $seen = @($family.Models | ForEach-Object { $_.Substring(0, 4).ToUpper() } | Sort-Object -Unique)
                    $clauses = @($seen | ForEach-Object { "device.deviceModel -startsWith `"$_`"" })
                    $membershipRule = "($($clauses -join ' -or '))"
                }

                $groupBody = @{
                    displayName                   = $groupName
                    mailEnabled                   = $false
                    mailNickname                  = $mailNickname
                    securityEnabled               = $true
                    groupTypes                    = @("DynamicMembership")
                    # Dynamic rule uses double quotes as required by the Azure AD membership rule syntax
                    membershipRule                = $membershipRule
                    membershipRuleProcessingState = "On"
                } | ConvertTo-Json
            }

            if ($whatIf) {
                Write-Log "[WHATIF] Would create group: $groupName"
                if ($limitingGroup) { Write-Log "[WHATIF]   Membership: static (assigned)" }
                else { Write-Log "[WHATIF]   Membership rule: $membershipRule" }
                $outcome.GroupCreated = $true
                $groupWouldExist = $true
            }
            else {
                $group = Invoke-ApiWithRetry -Uri "https://graph.microsoft.com/beta/groups" `
                    -Method POST -ContentType 'application/json' -Headers $headers -Body $groupBody

                Write-Log "Group created: $($group.displayName) ($($group.id))"
                $outcome.GroupCreated = $true
                $groupId = $group.id
            }

            # Add matching devices from the limiting group as static members (batches of 20)
            if ($limitingGroup) {
                $matchingDevices = @($limitingGroupDevices | Where-Object { $family.Models -contains $_.model })
                if ($matchingDevices.Count -gt 0 -and $whatIf) {
                    Write-Log "[WHATIF] Would add $($matchingDevices.Count) device(s) to group: $groupName"
                }
                elseif ($matchingDevices.Count -gt 0) {
                    $added = 0
                    for ($i = 0; $i -lt $matchingDevices.Count; $i += 20) {
                        $batch = $matchingDevices[$i..([Math]::Min($i + 19, $matchingDevices.Count - 1))]
                        $refs = $batch | ForEach-Object { "https://graph.microsoft.com/beta/directoryObjects/$($_.id)" }
                        $memberBody = @{ 'members@odata.bind' = @($refs) } | ConvertTo-Json

                        Invoke-ApiWithRetry -Uri "https://graph.microsoft.com/beta/groups/$groupId" `
                            -Method PATCH -ContentType 'application/json' -Headers $headers -Body $memberBody | Out-Null
                        $added += $batch.Count
                    }
                    Write-Log "Added $added device(s) to group: $groupName"
                }
                else {
                    Write-Log "No devices in limiting group match family '$familyName' - group created but has no members" -Level "WARN"
                }
            }
        }
    }
    catch {
        Write-Log "Failed to process group for family '$familyName': $_" -Level "ERROR"
        $outcome.GroupFailed = $true
    }

    # --- Windows Driver Update Profile ---
    try {
        # Check against the pre-fetched list - the endpoint does not support $filter
        if ($existingPolicyNames -contains $policyName) {
            Write-Log "Policy already in place, skipping: $policyName"
            $outcome.PolicySkipped = $true
        }
        else {
            $policyBody = @{
                displayName     = $policyName
                description     = if ($approval -eq 'automatic') { "Automatic approvals" } else { "Manual" }
                roleScopeTagIds = @("0")
                approvalType    = $approval
            }
            if ($approval -eq 'automatic') { $policyBody['deploymentDeferralInDays'] = $automaticDays }

            if ($whatIf) {
                $deferral = if ($approval -eq 'automatic') { ", deferral $automaticDays day(s)" } else { '' }
                Write-Log "[WHATIF] Would create policy: $policyName (approval: $approval$deferral)"
                $outcome.PolicyCreated = $true
            }
            else {
                $policy = Invoke-ApiWithRetry `
                    -Uri "https://graph.microsoft.com/beta/deviceManagement/windowsDriverUpdateProfiles" `
                    -Method POST -ContentType 'application/json' -Headers $headers -Body ($policyBody | ConvertTo-Json)

                Write-Log "Policy created: $($policy.displayName) ($($policy.id))"
                $outcome.PolicyCreated = $true
            }

            # Assign the policy to its corresponding group immediately after creation
            if ($whatIf -and ($groupId -or $groupWouldExist)) {
                Write-Log "[WHATIF] Would assign policy $policyName to group: $groupName"
                $outcome.PolicyAssigned = $true
            }
            elseif ($groupId) {
                try {
                    $assignBody = @{
                        assignments = @(
                            @{
                                target = @{
                                    '@odata.type' = '#microsoft.graph.groupAssignmentTarget'
                                    groupId       = $groupId
                                }
                            }
                        )
                    } | ConvertTo-Json -Depth 4

                    Invoke-ApiWithRetry `
                        -Uri "https://graph.microsoft.com/beta/deviceManagement/windowsDriverUpdateProfiles/$($policy.id)/assign" `
                        -Method POST -ContentType 'application/json' -Headers $headers -Body $assignBody | Out-Null

                    Write-Log "Policy assigned to group: $groupName"
                    $outcome.PolicyAssigned = $true
                }
                catch {
                    Write-Log "Failed to assign policy '$policyName' to group '$groupName': $_" -Level "ERROR"
                    $outcome.AssignmentFailed = $true
                }
            }
            else {
                Write-Log "No group ID available - skipping assignment for: $policyName" -Level "WARN"
            }
        }
    }
    catch {
        Write-Log "Failed to process policy for family '$familyName': $_" -Level "ERROR"
        $outcome.PolicyFailed = $true
    }

    $outcome

} -ThrottleLimit 10

# Aggregate per-model outcome objects into totals for the summary
$countGroupsCreated = ($results | Where-Object GroupCreated).Count
$countGroupsSkipped = ($results | Where-Object GroupSkipped).Count
$countGroupsFailed = ($results | Where-Object GroupFailed).Count
$countPoliciesCreated = ($results | Where-Object PolicyCreated).Count
$countPoliciesSkipped = ($results | Where-Object PolicySkipped).Count
$countPoliciesFailed = ($results | Where-Object PolicyFailed).Count
$countAssigned = ($results | Where-Object PolicyAssigned).Count
$countAssignmentFailed = ($results | Where-Object AssignmentFailed).Count

# WhatIf labels say what a real run would do, so the job log cannot be mistaken for a real run
$created = if ($whatIf) { 'to create' } else { 'created' }
$done = if ($whatIf) { 'to make' } else { 'done' }

Write-Log "------------------------------------------------------------"
if ($whatIf) { Write-Log "WhatIf run complete - no changes were made (approval mode: $approval)." }
else { Write-Log "Run complete  (approval mode: $approval)." }
Write-Log ("  {0,-20}: {1}" -f "Models discovered", $models.Count)
Write-Log ("  {0,-20}: {1}" -f "Families targeted", $families.Count)
Write-Log ("  {0,-20}: {1}" -f "Groups $created", $countGroupsCreated)
Write-Log ("  {0,-20}: {1}" -f "Groups in place", $countGroupsSkipped)
Write-Log ("  {0,-20}: {1}" -f "Groups failed", $countGroupsFailed)
Write-Log ("  {0,-20}: {1}" -f "Policies $created", $countPoliciesCreated)
Write-Log ("  {0,-20}: {1}" -f "Policies in place", $countPoliciesSkipped)
Write-Log ("  {0,-20}: {1}" -f "Policies failed", $countPoliciesFailed)
Write-Log ("  {0,-20}: {1}" -f "Assignments $done", $countAssigned)
Write-Log ("  {0,-20}: {1}" -f "Assignments failed", $countAssignmentFailed)
Write-Log "------------------------------------------------------------"
if ($whatIf) {
    Write-Log "*** WHATIF MODE - nothing above was written to the tenant ***" -Level "WARN"
}