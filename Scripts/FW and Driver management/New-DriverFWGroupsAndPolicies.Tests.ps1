#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

<#
.SYNOPSIS
    Pester tests for New-DriverFWGroupsAndPolicies.ps1.

.DESCRIPTION
    The runbook has no param block and runs top to bottom as soon as it is loaded, so it cannot
    simply be dot-sourced. Instead these tests parse it with the PowerShell AST and:

      - load its top-level functions on their own for the unit tests;
      - build a runnable copy of the whole script for the end-to-end tests, with the config
        values at the top swapped for test settings and ForEach-Object -Parallel swapped for a
        sequential process block (Pester mocks do not reach into parallel runspaces).

    Every Graph and Lenovo call is answered by an in-memory fake tenant. Nothing leaves the
    machine and no Az sign-in happens.

    Tests tagged KnownIssue describe the intended behaviour for bugs that are not fixed yet.
    They are skipped; remove -Skip once the fix is in.

.EXAMPLE
    Invoke-Pester -Path .\New-DriverFWGroupsAndPolicies.Tests.ps1 -Output Detailed
#>

BeforeAll {
    $script:RunbookPath = Join-Path $PSScriptRoot 'New-DriverFWGroupsAndPolicies.ps1'

    $tokens = $null
    $parseErrors = $null
    $script:RunbookAst = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:RunbookPath, [ref]$tokens, [ref]$parseErrors)
    $script:RunbookParseErrors = $parseErrors
    $script:RunbookText = $script:RunbookAst.Extent.Text

    # --- Load the runbook's top-level functions into this scope ---
    $script:TopLevelFunctions = @($script:RunbookAst.EndBlock.Statements |
        Where-Object { $_ -is [System.Management.Automation.Language.FunctionDefinitionAst] })
    . ([scriptblock]::Create(($script:TopLevelFunctions | ForEach-Object { $_.Extent.Text }) -join "`n`n"))

    # --- Locate the ForEach-Object -Parallel command and turn its body into a sequential one ---
    $script:ParallelCommandAst = $script:RunbookAst.Find({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -eq 'ForEach-Object' -and
            @($node.CommandElements | Where-Object {
                    $_ -is [System.Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq 'Parallel'
                }).Count -gt 0
        }, $true)

    $script:ParallelScriptBlockAst = $script:ParallelCommandAst.CommandElements |
        Where-Object { $_ -is [System.Management.Automation.Language.ScriptBlockExpressionAst] } |
        Select-Object -First 1

    $inner = $script:ParallelScriptBlockAst.Extent.Text
    $inner = $inner.Substring(1, $inner.Length - 2)
    # $using:x becomes $x, which the sequential block reads from the calling scope
    $script:ParallelBodyText = $inner -replace '\$using:', '$$'

    # --- Stubs so the Az cmdlets can be mocked without the Az module being loaded ---
    function Connect-AzAccount { [CmdletBinding()] param([switch]$Identity, [string]$AccountId) }
    function Disable-AzContextAutosave { [CmdletBinding()] param([string]$Scope) }
    function Get-AzAccessToken { [CmdletBinding()] param([string]$ResourceUrl) }

    # Returns the value of a top-level "$name = <constant>" assignment in the runbook
    function Get-RunbookSetting {
        param([string]$Name)
        $assign = $script:RunbookAst.EndBlock.Statements | Where-Object {
            $_ -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $_.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
            $_.Left.VariablePath.UserPath -eq $Name
        } | Select-Object -First 1
        if (-not $assign) { throw "Runbook has no top-level assignment for `$$Name" }
        $assign.Right.Expression.SafeGetValue()
    }

    # Builds an HTTP error shaped like the one Invoke-RestMethod throws in PowerShell 7
    function New-HttpError {
        param([int]$StatusCode, [string]$RetryAfter)
        $response = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]$StatusCode)
        if ($RetryAfter) { $response.Headers.Add('Retry-After', $RetryAfter) }
        [Microsoft.PowerShell.Commands.HttpResponseException]::new(
            "Response status code does not indicate success: $StatusCode", $response)
    }

    # --- In-memory fake tenant ---

    function New-FakeTenant {
        [pscustomobject]@{
            Devices         = [System.Collections.Generic.List[object]]::new()
            Groups          = [System.Collections.Generic.List[object]]::new()
            Policies        = [System.Collections.Generic.List[object]]::new()
            Catalog         = @()
            CatalogFails    = $false
            FailGroupCreate = $false
            FailDeleteIds   = @()
            # Groups the eventually consistent startsWith query does not return yet
            StaleGroupNames = @()
            PageSize        = 100
            NextId          = 0
            Requests        = [System.Collections.Generic.List[object]]::new()
        }
    }

    function Add-FakeDevice {
        param($Tenant, [string]$Model, [switch]$InLimitingGroup, [switch]$NotInIntune)
        $n = $Tenant.Devices.Count + 1
        $Tenant.Devices.Add([pscustomobject]@{
                Model           = $Model
                AzureADDeviceId = ('aad-{0:d4}' -f $n)
                EntraId         = ('ent-{0:d4}' -f $n)
                InLimitingGroup = [bool]$InLimitingGroup
                InIntune        = -not $NotInIntune
            })
    }

    function Add-FakeGroup {
        param($Tenant, [string]$DisplayName, [string]$Id)
        if (-not $Id) { $Tenant.NextId++; $Id = "grp-$($Tenant.NextId)" }
        $group = [pscustomobject]@{
            id          = $Id
            displayName = $DisplayName
            Body        = $null
            RawBody     = $null
            Members     = [System.Collections.Generic.List[string]]::new()
        }
        $Tenant.Groups.Add($group)
        $group
    }

    function Add-FakePolicy {
        param($Tenant, [string]$DisplayName, [string]$Id)
        if (-not $Id) { $Tenant.NextId++; $Id = "pol-$($Tenant.NextId)" }
        $policy = [pscustomobject]@{
            id          = $Id
            displayName = $DisplayName
            Body        = $null
            Assignments = [System.Collections.Generic.List[object]]::new()
        }
        $Tenant.Policies.Add($policy)
        $policy
    }

    function New-CatalogEntry {
        param([string]$Family, [string]$Type)
        [pscustomobject]@{ name = "$Family ($Type)" }
    }

    # Serves one page of a collection, following the same @odata.nextLink contract as Graph
    function Get-FakePage {
        param($Items, [string]$Uri, [int]$PageSize)
        $all = @($Items | Where-Object { $null -ne $_ })
        $skip = 0
        if ($Uri -match '[?&]\$skiptoken=(\d+)') { $skip = [int]$Matches[1] }
        $result = [ordered]@{ value = @($all | Select-Object -Skip $skip -First $PageSize) }
        if ($skip + $PageSize -lt $all.Count) {
            $base = $Uri -replace '&\$skiptoken=\d+', ''
            $result['@odata.nextLink'] = "$base&`$skiptoken=$($skip + $PageSize)"
        }
        [pscustomobject]$result
    }

    # Answers the requests the runbook makes. Anything unexpected throws, so a new endpoint
    # in the runbook shows up as a test failure instead of passing silently.
    function Invoke-FakeGraph {
        param($Tenant, [string]$Method, [string]$Uri, [string]$Body, $Headers)

        $Method = $Method.ToUpperInvariant()
        $Tenant.Requests.Add([pscustomobject]@{ Method = $Method; Uri = $Uri; Body = $Body; Headers = $Headers })

        if ($Uri -like 'https://download.lenovo.com/*') {
            if ($Tenant.CatalogFails) { throw 'Simulated network failure' }
            return $Tenant.Catalog
        }

        $path = ($Uri -split '\?', 2)[0] -replace '^https://graph\.microsoft\.com/beta', ''
        $route = "$Method $path"

        if ($route -eq 'GET /deviceManagement/managedDevices') {
            # Intune reports azureADDeviceId in upper case here and Entra in lower case below,
            # so every limiting-group test also covers the case-insensitive join
            $items = $Tenant.Devices | Where-Object InIntune | ForEach-Object {
                [pscustomobject]@{ model = $_.Model; azureADDeviceId = $_.AzureADDeviceId.ToUpperInvariant() }
            }
            return Get-FakePage -Items $items -Uri $Uri -PageSize $Tenant.PageSize
        }

        if ($route -eq 'GET /groups') {
            if ($Uri -match "startsWith\(displayName,'([^']*)'\)") {
                $prefix = $Matches[1]
                $items = $Tenant.Groups | Where-Object {
                    $_.displayName.StartsWith($prefix, 'OrdinalIgnoreCase') -and $_.displayName -notin $Tenant.StaleGroupNames
                }
            }
            elseif ($Uri -match "displayName eq '((?:[^']|'')*)'") {
                $name = $Matches[1] -replace "''", "'"
                $items = $Tenant.Groups | Where-Object displayName -EQ $name
            }
            else {
                $items = $Tenant.Groups
            }
            return Get-FakePage -Items ($items | Select-Object id, displayName) -Uri $Uri -PageSize $Tenant.PageSize
        }

        if ($route -match '^GET /groups/[^/]+/members/microsoft\.graph\.device$') {
            $items = $Tenant.Devices | Where-Object InLimitingGroup | ForEach-Object {
                [pscustomobject]@{ id = $_.EntraId; deviceId = $_.AzureADDeviceId.ToLowerInvariant() }
            }
            return Get-FakePage -Items $items -Uri $Uri -PageSize $Tenant.PageSize
        }

        if ($route -eq 'POST /groups') {
            if ($Tenant.FailGroupCreate) { throw (New-HttpError -StatusCode 400) }
            $parsed = $Body | ConvertFrom-Json
            $group = Add-FakeGroup -Tenant $Tenant -DisplayName $parsed.displayName
            $group.Body = $parsed
            $group.RawBody = $Body
            return [pscustomobject]@{ id = $group.id; displayName = $group.displayName }
        }

        if ($route -match '^PATCH /groups/([^/]+)$') {
            $id = $Matches[1]
            $group = $Tenant.Groups | Where-Object id -EQ $id | Select-Object -First 1
            foreach ($ref in ($Body | ConvertFrom-Json).'members@odata.bind') {
                $group.Members.Add(($ref -split '/')[-1])
            }
            return $null
        }

        if ($route -match '^DELETE /groups/([^/]+)$') {
            $id = $Matches[1]
            if ($Tenant.FailDeleteIds -contains $id) { throw (New-HttpError -StatusCode 403) }
            $group = $Tenant.Groups | Where-Object id -EQ $id | Select-Object -First 1
            [void]$Tenant.Groups.Remove($group)
            return $null
        }

        if ($route -eq 'GET /deviceManagement/windowsDriverUpdateProfiles') {
            return Get-FakePage -Items ($Tenant.Policies | Select-Object id, displayName) -Uri $Uri -PageSize $Tenant.PageSize
        }

        if ($route -eq 'POST /deviceManagement/windowsDriverUpdateProfiles') {
            $parsed = $Body | ConvertFrom-Json
            $policy = Add-FakePolicy -Tenant $Tenant -DisplayName $parsed.displayName
            $policy.Body = $parsed
            return [pscustomobject]@{ id = $policy.id; displayName = $policy.displayName }
        }

        if ($route -match '^POST /deviceManagement/windowsDriverUpdateProfiles/([^/]+)/assign$') {
            $id = $Matches[1]
            $policy = $Tenant.Policies | Where-Object id -EQ $id | Select-Object -First 1
            foreach ($a in ($Body | ConvertFrom-Json).assignments) { $policy.Assignments.Add($a.target) }
            return $null
        }

        if ($route -match '^DELETE /deviceManagement/windowsDriverUpdateProfiles/([^/]+)$') {
            $id = $Matches[1]
            if ($Tenant.FailDeleteIds -contains $id) { throw (New-HttpError -StatusCode 403) }
            $policy = $Tenant.Policies | Where-Object id -EQ $id | Select-Object -First 1
            [void]$Tenant.Policies.Remove($policy)
            return $null
        }

        throw "Fake Graph has no route for: $Method $Uri"
    }

    # --- Runnable copy of the whole runbook ---

    # Returns the runbook text with the named top-level config values replaced by
    # $RunbookSettings['name'] and the parallel loop replaced by a sequential one
    function Get-RunbookVariant {
        param([string[]]$SettingNames)

        $edits = [System.Collections.Generic.List[object]]::new()

        foreach ($name in $SettingNames) {
            $assign = $script:RunbookAst.EndBlock.Statements | Where-Object {
                $_ -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                $_.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
                $_.Left.VariablePath.UserPath -eq $name
            } | Select-Object -First 1
            if (-not $assign) { throw "Runbook has no top-level assignment for `$$name" }

            $edits.Add([pscustomobject]@{
                    Start = $assign.Right.Extent.StartOffset
                    End   = $assign.Right.Extent.EndOffset
                    Text  = "`$RunbookSettings['$name']"
                })
        }

        $edits.Add([pscustomobject]@{
                Start = $script:ParallelCommandAst.Extent.StartOffset
                End   = $script:ParallelCommandAst.Extent.EndOffset
                Text  = "& { process {$($script:ParallelBodyText)} }"
            })

        $text = $script:RunbookText
        foreach ($e in ($edits | Sort-Object Start -Descending)) {
            $text = $text.Substring(0, $e.Start) + $e.Text + $text.Substring($e.End)
        }
        $text
    }

    # Runs the runbook end to end against whatever the mocks return. Config values are pinned
    # to known defaults so editing the header of the real script does not change test results.
    function Invoke-Runbook {
        param([hashtable]$Settings = @{})

        $RunbookSettings = @{
            managedIdentityClientId = ''
            whatIf                  = $false
            approval                = 'Automatic'
            automaticDays           = 7
            limitingGroup           = ''
            singleMachineType       = ''
            excludeModels           = @('Cloud PC', 'Virtual Machine', 'AHV')
            groupBy                 = 'Family'
            useLenovoCatalog        = $true
            lenovoFamilyNames       = @{}
        }
        foreach ($key in $Settings.Keys) { $RunbookSettings[$key] = $Settings[$key] }

        & ([scriptblock]::Create((Get-RunbookVariant -SettingNames @($RunbookSettings.Keys))))
    }

    # A small tenant: three Lenovo T14 Gen 3 devices across two machine types, one Dell, and
    # two models that the default exclusions should drop
    function Initialize-StandardTenant {
        param($Tenant)
        foreach ($model in '21AH00ABMX', '21AH00XYMX', '21AJ00CDMX', 'Latitude 5440',
            'Cloud PC Enterprise 2vCPU/8GB/128GB', 'Virtual Machine') {
            Add-FakeDevice -Tenant $Tenant -Model $model
        }
        $Tenant.Catalog = @(
            New-CatalogEntry 'ThinkPad T14 Gen 3' '21AH'
            New-CatalogEntry 'ThinkPad T14 Gen 3' '21AJ'
            New-CatalogEntry 'ThinkPad T14 Gen 3' '21CF'
            New-CatalogEntry 'ThinkPad X1 Carbon Gen 11' '21HM'
        )
    }
}

Describe 'Script structure' {
    It 'parses without errors' {
        $script:RunbookParseErrors | Should -BeNullOrEmpty
    }

    It 'defines the expected top-level functions' {
        $names = $script:TopLevelFunctions.Name
        foreach ($expected in 'Write-Log', 'Get-LenovoFamilyMap', 'Get-LenovoMachineType', 'Get-ModelFamily',
            'Get-GraphToken', 'Invoke-ApiWithRetry', 'Get-GraphAllPages', 'Get-DriversFWGroups',
            'Get-ModelsFromIntune', 'Get-DevicesFromGroup', 'Remove-DriversFWGroups') {
            $names | Should -Contain $expected
        }
    }

    It 'has exactly one ForEach-Object -Parallel loop' {
        $script:ParallelCommandAst | Should -Not -BeNullOrEmpty
        $script:ParallelScriptBlockAst | Should -Not -BeNullOrEmpty
    }

    It 'defines no functions of its own inside the parallel block' {
        @($script:ParallelScriptBlockAst.ScriptBlock.FindAll({
                    param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst]
                }, $true)) | Should -BeNullOrEmpty
    }

    It 'rebuilds every script function the parallel block needs, including ones they call' {
        # A parallel runspace starts empty: any script function it calls must be rebuilt from
        # $using: text first, or the call fails at run time. The end-to-end tests cannot catch
        # that, because they run the block in a scope that can see the outer functions.
        $body = $script:ParallelScriptBlockAst.ScriptBlock
        $scriptFunctions = @($script:TopLevelFunctions.Name)

        $rebuilt = @($body.FindAll({
                    param($n)
                    $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                    $n.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
                    $n.Left.VariablePath.DriveName -eq 'function' -and
                    $n.Right.Expression -is [System.Management.Automation.Language.UsingExpressionAst]
                }, $true) | ForEach-Object { $_.Left.VariablePath.UserPath -replace '^function:', '' })

        $called = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $queue = [System.Collections.Generic.Queue[object]]::new()
        $queue.Enqueue($body)
        while ($queue.Count -gt 0) {
            $node = $queue.Dequeue()
            $names = $node.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) |
                ForEach-Object { $_.GetCommandName() } | Where-Object { $_ -in $scriptFunctions }
            foreach ($name in $names) {
                if ($called.Add($name)) { $queue.Enqueue(($script:TopLevelFunctions | Where-Object Name -EQ $name)) }
            }
        }

        $called.Count | Should -BeGreaterThan 0
        foreach ($name in $called) { $rebuilt | Should -Contain $name }
    }

    It 'passes each function text to the parallel block from the matching function' {
        $script:RunbookText | Should -Match '\$writeLogDef = \$\{function:Write-Log\}\.ToString\(\)'
        $script:RunbookText | Should -Match '\$invokeApiDef = \$\{function:Invoke-ApiWithRetry\}\.ToString\(\)'
        $script:ParallelBodyText | Should -Match '\$\{function:Write-Log\} = \$writeLogDef'
        $script:ParallelBodyText | Should -Match '\$\{function:Invoke-ApiWithRetry\} = \$invokeApiDef'
    }
}

Describe 'Write paths (WhatIf safety)' {
    # These read the script's code rather than run it. The end-to-end tests run the parallel
    # block in an ordinary child scope that can see every outer variable, so they cannot catch
    # a variable that is missing from a real parallel runspace. These checks can.

    It 'brings $whatIf into the parallel runspace' {
        $usingNames = @($script:ParallelScriptBlockAst.FindAll({
                    param($n) $n -is [System.Management.Automation.Language.UsingExpressionAst]
                }, $true) | ForEach-Object { $_.SubExpression.VariablePath.UserPath })
        $usingNames | Should -Contain 'whatIf'
        $script:ParallelBodyText | Should -Match '(?m)^\s*\$whatIf = \$whatIf\s*$'
    }

    It 'calls Invoke-RestMethod only from Invoke-ApiWithRetry, apart from the read-only Lenovo download' {
        $calls = @($script:RunbookAst.FindAll({
                    param($n)
                    $n -is [System.Management.Automation.Language.CommandAst] -and
                    $n.GetCommandName() -in 'Invoke-RestMethod', 'irm'
                }, $true))

        foreach ($call in $calls) {
            $fn = $call.Parent
            while ($fn -and $fn -isnot [System.Management.Automation.Language.FunctionDefinitionAst]) { $fn = $fn.Parent }
            $fn.Name | Should -BeIn @('Invoke-ApiWithRetry', 'Get-LenovoFamilyMap')
            if ($fn.Name -eq 'Get-LenovoFamilyMap') { $call.Extent.Text | Should -Match '-Method GET\b' }
        }
        # Invoke-ApiWithRetry plus the Lenovo download
        $calls.Count | Should -Be 2
    }

    It 'uses no other command or .NET type that could write to the tenant' {
        $commands = @($script:RunbookAst.FindAll({
                    param($n) $n -is [System.Management.Automation.Language.CommandAst]
                }, $true) | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ })
        $commands | Where-Object {
            $_ -match '^(Invoke-WebRequest|iwr|curl|wget|Invoke-MgGraphRequest|Invoke-AzRestMethod)$' -or
            $_ -match '^(New|Set|Remove|Update|Add|Clear|Grant|Revoke|Invoke)-(Az|Mg)'
        } | Should -BeNullOrEmpty

        $types = @($script:RunbookAst.FindAll({
                    param($n)
                    $n -is [System.Management.Automation.Language.TypeExpressionAst] -or
                    $n -is [System.Management.Automation.Language.TypeConstraintAst]
                }, $true) | ForEach-Object { $_.TypeName.FullName })
        $types | Where-Object { $_ -match 'HttpClient|WebClient|WebRequest|HttpWebRequest' } | Should -BeNullOrEmpty
    }

    It 'has exactly the six known write calls' {
        # If this fails because a write was added: give it a $whatIf branch that reports instead,
        # add a WhatIf test for it, then update this list.
        $writes = foreach ($call in $script:RunbookAst.FindAll({
                    param($n)
                    $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Invoke-ApiWithRetry'
                }, $true)) {
            $els = $call.CommandElements
            $method = 'GET'
            for ($i = 0; $i -lt $els.Count - 1; $i++) {
                if ($els[$i] -is [System.Management.Automation.Language.CommandParameterAst] -and $els[$i].ParameterName -eq 'Method') {
                    $method = $els[$i + 1].Extent.Text.Trim("'", '"')
                }
            }
            if ($method -ne 'GET') { $method.ToUpper() }
        }

        # Group create, policy create, assign / pilot members / group and policy delete (cleanup)
        @($writes | Sort-Object) | Should -Be @('DELETE', 'DELETE', 'PATCH', 'POST', 'POST', 'POST')
    }
}

Describe 'Parallel block in real parallel runspaces' {
    # The end-to-end tests run the parallel block sequentially so the fakes can reach it. These
    # run the real ForEach-Object -Parallel command instead, to prove the functions and $using:
    # variables arrive in a fresh runspace. Mocks do not reach there, so each case is set up so
    # nothing is sent: every group is in the prefetch, and every write is reported or blocked.

    BeforeAll {
        # Runs the script's own parallel command over $Families with the given $using: values
        function Invoke-RealParallel {
            param([object[]]$Families, [hashtable]$Vars, [string]$CommandText = $script:ParallelCommandAst.Extent.Text)

            $writeLogDef = ${function:Write-Log}.ToString()
            $invokeApiDef = ${function:Invoke-ApiWithRetry}.ToString()
            $headers = @{ Authorization = 'Bearer not-used' }
            $limitingGroup = ''
            $limitingGroupDevices = $null
            $approval = $Vars.approval
            $automaticDays = $Vars.automaticDays
            $whatIf = $Vars.whatIf
            $existingPolicyNames = $Vars.existingPolicyNames
            $existingGroupIds = $Vars.existingGroupIds

            $output = & ([scriptblock]::Create("`$Families | $CommandText")) 6>&1 2>&1 3>&1
            # Note: -is [pscustomobject] matches almost anything in the pipeline, so sort by type
            $isRecord = {
                $_ -is [System.Management.Automation.InformationRecord] -or
                $_ -is [System.Management.Automation.WarningRecord] -or
                $_ -is [System.Management.Automation.ErrorRecord]
            }
            [pscustomobject]@{
                Outcomes = @($output | Where-Object { -not (& $isRecord) -and $_.PSObject.Properties['GroupCreated'] })
                Messages = @($output | Where-Object $isRecord | ForEach-Object { "$_" })
            }
        }

        $script:Family = [pscustomobject]@{
            Key = 'Latitude 5440'; DisplayName = 'Latitude 5440'; MatchType = 'Exact'
            MatchValues = @('Latitude 5440'); Models = @('Latitude 5440')
        }
        $script:GroupIds = @{ 'Drivers-FW-Latitude 5440-Automatic' = 'grp-1' }
    }

    It 'rebuilds Write-Log and Invoke-ApiWithRetry and runs a WhatIf plan end to end' {
        $r = Invoke-RealParallel -Families @($script:Family) -Vars @{
            approval = 'Automatic'; automaticDays = 7; whatIf = $true
            existingPolicyNames = @(); existingGroupIds = $script:GroupIds
        }

        $r.Outcomes.Count | Should -Be 1
        $r.Outcomes[0].GroupSkipped | Should -BeTrue
        $r.Outcomes[0].PolicyCreated | Should -BeTrue
        $r.Outcomes[0].PolicyAssigned | Should -BeTrue
        $r.Outcomes[0].PolicyFailed | Should -BeFalse
        @($r.Messages | Where-Object { $_ -like '*`[WHATIF`] Would create policy: Drivers-FW-Latitude 5440-Automatic-7d*' }).Count |
            Should -Be 1
        @($r.Messages | Where-Object { $_ -like '*`[WHATIF`] Would assign policy*' }).Count | Should -Be 1
        # Write-Log's timestamp format proves the rebuilt function is the script's own
        $r.Messages | Where-Object { $_ -like '*Would create policy*' } |
            Should -Match '^\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\] \[INFO\] '
    }

    It 'skips a family whose group and policy exist, sending nothing' {
        $r = Invoke-RealParallel -Families @($script:Family) -Vars @{
            approval = 'Automatic'; automaticDays = 7; whatIf = $false
            existingPolicyNames = @('Drivers-FW-Latitude 5440-Automatic-7d'); existingGroupIds = $script:GroupIds
        }

        $r.Outcomes[0].GroupSkipped | Should -BeTrue
        $r.Outcomes[0].PolicySkipped | Should -BeTrue
        @($r.Messages | Where-Object { $_ -like '*`[ERROR`]*' }) | Should -BeNullOrEmpty
    }

    It 'blocks the write when $whatIf is not brought into the runspace (fail-closed)' {
        # Same command with the $whatIf line removed: the runspace sees no $whatIf at all
        $text = $script:ParallelCommandAst.Extent.Text -replace '(?m)^\s*\$whatIf = \$using:whatIf\s*$', ''
        $text | Should -Not -Match '\$using:whatIf'

        $r = Invoke-RealParallel -CommandText $text -Families @($script:Family) -Vars @{
            approval = 'Automatic'; automaticDays = 7; whatIf = $false
            existingPolicyNames = @(); existingGroupIds = $script:GroupIds
        }

        $r.Outcomes[0].PolicyFailed | Should -BeTrue
        $r.Outcomes[0].PolicyCreated | Should -BeFalse
        @($r.Messages | Where-Object { $_ -like '*WhatIf is on or not set - blocked POST*' }).Count | Should -BeGreaterThan 0
    }
}

Describe 'Shipped configuration' {
    It 'sets $whatIf to a boolean' {
        Get-RunbookSetting 'whatIf' | Should -BeOfType [bool]
    }

    It 'sets $singleMachineType to empty or a 4-character machine type' {
        Get-RunbookSetting 'singleMachineType' | Should -Match '^([0-9]{2}[A-Za-z0-9]{2})?$'
    }

    It 'sets $approval to automatic or manual' {
        (Get-RunbookSetting 'approval').ToLower() | Should -BeIn @('automatic', 'manual')
    }

    It 'sets $automaticDays within the 0-30 range Intune accepts' {
        Get-RunbookSetting 'automaticDays' | Should -BeIn (0..30)
    }

    It 'sets $groupBy to a supported mode' {
        Get-RunbookSetting 'groupBy' | Should -BeIn @('Family', 'MachineType', 'Model')
    }

    It 'points the Lenovo catalog at an https URL' {
        Get-RunbookSetting 'lenovoCatalogUrl' | Should -BeLike 'https://*'
    }
}

Describe 'Write-Log' {
    BeforeEach {
        Mock Write-Host {}
        Mock Write-Warning {}
        Mock Write-Error {}
    }

    It 'writes a timestamped INFO line to the host only' {
        Write-Log 'hello'
        Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter {
            $Object -match '^\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\] \[INFO\] hello$'
        }
        Should -Invoke Write-Warning -Times 0 -Exactly
        Should -Invoke Write-Error -Times 0 -Exactly
    }

    It 'also emits WARN to the warning stream' {
        Write-Log 'careful' -Level 'WARN'
        Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter { $Object -like '*`[WARN`] careful' }
        Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter { $Message -eq 'careful' }
    }

    It 'also emits ERROR to the error stream' {
        Write-Log 'broken' -Level 'ERROR'
        Should -Invoke Write-Error -Times 1 -Exactly -ParameterFilter { $Message -eq 'broken' }
    }
}

Describe 'Get-LenovoFamilyMap' {
    BeforeEach {
        Mock Write-Host {}
        Mock Write-Warning {}
    }

    It 'maps a machine type to its friendly name' {
        Mock Invoke-RestMethod { New-CatalogEntry 'ThinkPad T14 Gen 3' '21AH' }
        $map = Get-LenovoFamilyMap -Uri 'https://example.test/models.json'
        $map['21AH'] | Should -Be 'ThinkPad T14 Gen 3'
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
            $Uri.OriginalString -eq 'https://example.test/models.json'
        }
    }

    It 'reads every machine type from a bracket that lists several' {
        Mock Invoke-RestMethod { [pscustomobject]@{ name = 'ThinkPad X13 Gen 2 (20WK, 20WL)' } }
        $map = Get-LenovoFamilyMap -Uri 'https://example.test/models.json'
        $map['20WK'] | Should -Be 'ThinkPad X13 Gen 2'
        $map['20WL'] | Should -Be 'ThinkPad X13 Gen 2'
    }

    It 'upper-cases machine types' {
        Mock Invoke-RestMethod { [pscustomobject]@{ name = 'ThinkPad E14 (21ah)' } }
        $map = Get-LenovoFamilyMap -Uri 'https://example.test/models.json'
        $map.ContainsKey('21AH') | Should -BeTrue
    }

    It 'keeps the first friendly name when a machine type appears twice' {
        Mock Invoke-RestMethod {
            New-CatalogEntry 'ThinkPad A' '21AH'
            New-CatalogEntry 'ThinkPad B' '21AH'
        }
        (Get-LenovoFamilyMap -Uri 'https://example.test/models.json')['21AH'] | Should -Be 'ThinkPad A'
    }

    It 'skips BIOS setting entries' {
        Mock Invoke-RestMethod {
            [pscustomobject]@{ name = 'Secure Boot -UEFI Lenovo (21AA)' }
            [pscustomobject]@{ name = 'Security Chip dTPM (21AB)' }
            [pscustomobject]@{ name = 'Security Chip fTPM (21AC)' }
            [pscustomobject]@{ name = 'Asset Tag (21AD)' }
            New-CatalogEntry 'ThinkPad Real' '21AE'
        }
        $map = Get-LenovoFamilyMap -Uri 'https://example.test/models.json'
        $map.Keys | Should -Be @('21AE')
    }

    It 'does not chop a full 10-character MTM into 4-character fragments' {
        Mock Invoke-RestMethod { [pscustomobject]@{ name = 'ThinkPad T14 Gen 3 (21AH00ABMX)' } }
        (Get-LenovoFamilyMap -Uri 'https://example.test/models.json').Count | Should -Be 0
    }

    It 'skips entries with no name or no bracket' {
        Mock Invoke-RestMethod {
            [pscustomobject]@{ name = $null }
            [pscustomobject]@{ name = 'ThinkPad without a bracket' }
            [pscustomobject]@{ name = ' (21AF)' }
        }
        (Get-LenovoFamilyMap -Uri 'https://example.test/models.json').Count | Should -Be 0
    }

    It 'warns when the download succeeds but nothing can be parsed' {
        Mock Invoke-RestMethod { [pscustomobject]@{ name = 'nothing useful' } }
        Get-LenovoFamilyMap -Uri 'https://example.test/models.json' | Out-Null
        Should -Invoke Write-Host -ParameterFilter { $Object -like '*no machine types could be parsed*' }
    }

    It 'returns an empty map and warns when the download fails' {
        Mock Invoke-RestMethod { throw 'offline' }
        $map = Get-LenovoFamilyMap -Uri 'https://example.test/models.json'
        $map | Should -BeOfType [hashtable]
        $map.Count | Should -Be 0
        Should -Invoke Write-Host -ParameterFilter { $Object -like '*Could not download the Lenovo model list*' }
    }
}

Describe 'Get-LenovoMachineType' {
    It 'returns the machine type of <Model>' -ForEach @(
        @{ Model = '21AH00ABMX'; Expected = '21AH' }
        @{ Model = '21ah00abmx'; Expected = '21AH' }
        @{ Model = '  20XW003JUS '; Expected = '20XW' }
    ) {
        Get-LenovoMachineType -Model $Model | Should -Be $Expected
    }

    It 'returns $null for <Model>' -ForEach @(
        @{ Model = 'Latitude 5440' }
        @{ Model = 'Surface Go' }
        @{ Model = 'AB21000000' }
        @{ Model = '21AH00ABM' }
        @{ Model = '21AH00ABMXX' }
        @{ Model = '' }
    ) {
        Get-LenovoMachineType -Model $Model | Should -BeNullOrEmpty
    }
}

Describe 'Get-ModelFamily' {
    BeforeEach {
        $lenovoFamilyNames = @{ '21AH' = 'ThinkPad T14 Gen 3'; '21AJ' = 'ThinkPad T14 Gen 3' }
        $lenovoFamilyTypes = @{ 'ThinkPad T14 Gen 3' = @('21AJ', '21AH', '21AH') }
    }

    Context 'Family mode' {
        BeforeEach { $groupBy = 'Family' }

        It 'groups a known machine type under its friendly name, covering every type of that name' {
            $f = Get-ModelFamily -Model '21AH00ABMX'
            $f.Key | Should -Be 'ThinkPad T14 Gen 3'
            $f.DisplayName | Should -Be 'ThinkPad T14 Gen 3'
            $f.MatchType | Should -Be 'Prefix'
            $f.MatchValues | Should -Be @('21AH', '21AJ')
        }

        It 'gives both machine types of a family the same key' {
            (Get-ModelFamily -Model '21AJ00CDMX').Key | Should -Be (Get-ModelFamily -Model '21AH00ABMX').Key
        }

        It 'falls back to the single machine type when the reverse index has no entry' {
            $lenovoFamilyTypes = @{}
            (Get-ModelFamily -Model '21AH00ABMX').MatchValues | Should -Be @('21AH')
        }

        It 'names an unknown machine type "Lenovo <type>"' {
            $f = Get-ModelFamily -Model '21ZZ00ABMX'
            $f.Key | Should -Be '21ZZ'
            $f.DisplayName | Should -Be 'Lenovo 21ZZ'
            $f.MatchType | Should -Be 'Prefix'
            $f.MatchValues | Should -Be @('21ZZ')
        }

        It 'upper-cases a lower-case MTM' {
            (Get-ModelFamily -Model '21ah00abmx').MatchValues | Should -Be @('21AH', '21AJ')
        }

        It 'trims surrounding whitespace before matching' {
            (Get-ModelFamily -Model '  21AH00ABMX ').Key | Should -Be 'ThinkPad T14 Gen 3'
        }
    }

    Context 'MachineType mode' {
        BeforeEach { $groupBy = 'MachineType' }

        It 'makes one family per machine type, named "friendly name (type)"' {
            $f = Get-ModelFamily -Model '21AH00ABMX'
            $f.Key | Should -Be '21AH'
            $f.DisplayName | Should -Be 'ThinkPad T14 Gen 3 (21AH)'
            $f.MatchValues | Should -Be @('21AH')
        }

        It 'keeps two machine types of the same family apart' {
            (Get-ModelFamily -Model '21AJ00CDMX').Key | Should -Not -Be (Get-ModelFamily -Model '21AH00ABMX').Key
        }
    }

    Context 'Model mode' {
        BeforeEach { $groupBy = 'Model' }

        It 'uses the exact MTM string' {
            $f = Get-ModelFamily -Model '21AH00ABMX'
            $f.Key | Should -Be '21AH00ABMX'
            $f.MatchType | Should -Be 'Exact'
            $f.MatchValues | Should -Be @('21AH00ABMX')
        }
    }

    Context 'Non-Lenovo models' {
        It 'uses the model string as an exact match in <Mode> mode' -ForEach @(
            @{ Mode = 'Family' }
            @{ Mode = 'MachineType' }
            @{ Mode = 'Model' }
        ) {
            $groupBy = $Mode
            $f = Get-ModelFamily -Model 'Latitude 5440'
            $f.Key | Should -Be 'Latitude 5440'
            $f.DisplayName | Should -Be 'Latitude 5440'
            $f.MatchType | Should -Be 'Exact'
            $f.MatchValues | Should -Be @('Latitude 5440')
        }

        It 'does not treat a 10-character string with the wrong shape as a Lenovo MTM' {
            $groupBy = 'Family'
            (Get-ModelFamily -Model 'Surface Go').MatchType | Should -Be 'Exact'
            (Get-ModelFamily -Model 'AB21000000').MatchType | Should -Be 'Exact'
        }
    }
}

Describe 'Get-GraphToken' {
    BeforeEach {
        Mock Write-Host {}
        Mock Disable-AzContextAutosave {}
        Mock Connect-AzAccount {}
        Mock Get-AzAccessToken { [pscustomobject]@{ Token = 'plain-token' } }
        $managedIdentityClientId = ''
    }

    It 'keeps the Az context to this process' {
        Get-GraphToken | Out-Null
        Should -Invoke Disable-AzContextAutosave -Times 1 -Exactly -ParameterFilter { $Scope -eq 'Process' }
    }

    It 'uses the system-assigned identity when no client ID is set' {
        Get-GraphToken | Out-Null
        Should -Invoke Connect-AzAccount -Times 1 -Exactly -ParameterFilter { $Identity -and -not $AccountId }
    }

    It 'uses the user-assigned identity when a client ID is set' {
        $managedIdentityClientId = '11111111-2222-3333-4444-555555555555'
        Get-GraphToken | Out-Null
        Should -Invoke Connect-AzAccount -Times 1 -Exactly -ParameterFilter {
            $Identity -and $AccountId -eq '11111111-2222-3333-4444-555555555555'
        }
    }

    It 'requests a token for Microsoft Graph' {
        Get-GraphToken | Out-Null
        Should -Invoke Get-AzAccessToken -Times 1 -Exactly -ParameterFilter { $ResourceUrl -eq 'https://graph.microsoft.com' }
    }

    It 'returns a plain-string token as is (Az.Accounts before 5.0)' {
        Get-GraphToken | Should -Be 'plain-token'
    }

    It 'converts a SecureString token to plain text (Az.Accounts 5.0 and later)' {
        Mock Get-AzAccessToken {
            [pscustomobject]@{ Token = (ConvertTo-SecureString 'secure-token' -AsPlainText -Force) }
        }
        $token = Get-GraphToken
        $token | Should -BeOfType [string]
        $token | Should -Be 'secure-token'
    }
}

Describe 'Invoke-ApiWithRetry' {
    BeforeEach {
        Mock Write-Host {}
        Mock Write-Warning {}
        $script:sleeps = [System.Collections.Generic.List[double]]::new()
        Mock Start-Sleep { $script:sleeps.Add($Seconds) }
        $script:calls = 0
        $whatIf = $false
    }

    It 'returns the response on success and passes Body and ContentType through' {
        Mock Invoke-RestMethod { [pscustomobject]@{ ok = $true } }
        $r = Invoke-ApiWithRetry -Uri 'https://graph.microsoft.com/beta/x' -Method POST -Headers @{ a = 1 } `
            -Body '{"a":1}' -ContentType 'application/json'
        $r.ok | Should -BeTrue
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
            "$Method" -eq 'Post' -and $Body -eq '{"a":1}' -and $ContentType -eq 'application/json' -and $TimeoutSec -eq 60
        }
    }

    It 'leaves out Body and ContentType when they are not given' {
        Mock Invoke-RestMethod { 'ok' }
        Invoke-ApiWithRetry -Uri 'https://graph.microsoft.com/beta/x' -Method DELETE -Headers @{} | Out-Null
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
            -not $PSBoundParameters.ContainsKey('Body') -and -not $PSBoundParameters.ContainsKey('ContentType')
        }
    }

    It 'waits for the Retry-After value on 429 and then succeeds' {
        Mock Invoke-RestMethod {
            $script:calls++
            if ($script:calls -lt 3) { throw (New-HttpError -StatusCode 429 -RetryAfter '7') }
            'done'
        }
        Invoke-ApiWithRetry -Uri 'https://graph.microsoft.com/beta/x' -Headers @{} | Should -Be 'done'
        $script:sleeps | Should -Be @(7, 7)
        Should -Invoke Write-Host -Times 2 -Exactly -ParameterFilter { $Object -like '*HTTP 429*waiting 7s via Retry-After header*' }
    }

    It 'falls back to backoff on 429 when there is no Retry-After header' {
        Mock Invoke-RestMethod {
            $script:calls++
            if ($script:calls -lt 2) { throw (New-HttpError -StatusCode 429) }
            'done'
        }
        Invoke-ApiWithRetry -Uri 'https://graph.microsoft.com/beta/x' -Headers @{} | Should -Be 'done'
        $script:sleeps | Should -Be @(10)
        Should -Invoke Write-Host -ParameterFilter { $Object -like '*via backoff*' }
    }

    It 'backs off exponentially on 5xx, capped at 60 seconds, then gives up' {
        Mock Invoke-RestMethod { throw (New-HttpError -StatusCode 503) }
        { Invoke-ApiWithRetry -Uri 'https://graph.microsoft.com/beta/x' -Headers @{} } |
            Should -Throw 'Max retries (5) reached for https://graph.microsoft.com/beta/x'
        $script:sleeps | Should -Be @(10, 20, 40, 60, 60)
        Should -Invoke Invoke-RestMethod -Times 5 -Exactly
    }

    It 'honours a custom MaxRetries' {
        Mock Invoke-RestMethod { throw (New-HttpError -StatusCode 500) }
        { Invoke-ApiWithRetry -Uri 'https://graph.microsoft.com/beta/x' -Headers @{} -MaxRetries 2 } |
            Should -Throw 'Max retries (2)*'
        Should -Invoke Invoke-RestMethod -Times 2 -Exactly
    }

    It 'rethrows <StatusCode> immediately without retrying' -ForEach @(
        @{ StatusCode = 400 }
        @{ StatusCode = 403 }
        @{ StatusCode = 404 }
    ) {
        Mock Invoke-RestMethod { throw (New-HttpError -StatusCode $StatusCode) }
        { Invoke-ApiWithRetry -Uri 'https://graph.microsoft.com/beta/x' -Headers @{} } | Should -Throw
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly
        $script:sleeps.Count | Should -Be 0
    }

    It 'rethrows errors that carry no HTTP response' {
        Mock Invoke-RestMethod { throw 'DNS failure' }
        { Invoke-ApiWithRetry -Uri 'https://graph.microsoft.com/beta/x' -Headers @{} } | Should -Throw 'DNS failure'
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly
    }

    Context 'WhatIf mode' {
        BeforeEach {
            $whatIf = $true
            Mock Invoke-RestMethod { 'ok' }
        }

        It 'still lets GET requests through' {
            Invoke-ApiWithRetry -Uri 'https://graph.microsoft.com/beta/x' -Method GET -Headers @{} | Should -Be 'ok'
            Should -Invoke Invoke-RestMethod -Times 1 -Exactly
        }

        It 'blocks <Method> without sending it' -ForEach @(
            @{ Method = 'POST' }
            @{ Method = 'PATCH' }
            @{ Method = 'DELETE' }
            @{ Method = 'PUT' }
            @{ Method = 'MERGE' }
            @{ Method = 'post' }
        ) {
            { Invoke-ApiWithRetry -Uri 'https://graph.microsoft.com/beta/x' -Method $Method -Headers @{} } |
                Should -Throw "WhatIf is on or not set - blocked $Method https://graph.microsoft.com/beta/x"
            Should -Invoke Invoke-RestMethod -Times 0 -Exactly
        }
    }

    Context 'Fail-closed guard' {
        BeforeEach {
            Mock Invoke-RestMethod { 'ok' }
        }

        It 'blocks writes when $whatIf is <Label>' -ForEach @(
            @{ Label = 'not set at all'; Value = $null }
            @{ Label = "the string 'false'"; Value = 'false' }
            @{ Label = 'the number 0'; Value = 0 }
        ) {
            $whatIf = $Value
            { Invoke-ApiWithRetry -Uri 'https://graph.microsoft.com/beta/x' -Method POST -Headers @{} } |
                Should -Throw 'WhatIf is on or not set - blocked POST*'
            Should -Invoke Invoke-RestMethod -Times 0 -Exactly
        }

        It 'still allows GET when $whatIf is not set' {
            $whatIf = $null
            Invoke-ApiWithRetry -Uri 'https://graph.microsoft.com/beta/x' -Headers @{} | Should -Be 'ok'
        }
    }
}

Describe 'Get-GraphAllPages' {
    BeforeEach {
        Mock Write-Host {}
        $script:Tenant = New-FakeTenant
        Mock Invoke-RestMethod {
            Invoke-FakeGraph -Tenant $script:Tenant -Method "$Method" -Uri $Uri.OriginalString -Body $Body -Headers $Headers
        }
        $uri = "https://graph.microsoft.com/beta/deviceManagement/windowsDriverUpdateProfiles?`$select=id,displayName"
    }

    It 'follows every nextLink and returns all items in order' {
        $script:Tenant.PageSize = 2
        1..5 | ForEach-Object { Add-FakePolicy -Tenant $script:Tenant -DisplayName "Policy $_" | Out-Null }

        $items = @(Get-GraphAllPages -Uri $uri -Headers @{ Authorization = 'Bearer x' })

        $items.displayName | Should -Be @('Policy 1', 'Policy 2', 'Policy 3', 'Policy 4', 'Policy 5')
        $script:Tenant.Requests.Count | Should -Be 3
    }

    It 'returns nothing for an empty collection' {
        @(Get-GraphAllPages -Uri $uri -Headers @{}).Count | Should -Be 0
    }

    It 'returns a single item as one item' {
        Add-FakePolicy -Tenant $script:Tenant -DisplayName 'Only' | Out-Null
        $items = @(Get-GraphAllPages -Uri $uri -Headers @{})
        $items.Count | Should -Be 1
        $items[0].displayName | Should -Be 'Only'
    }

    It 'sends the given headers on every page' {
        $script:Tenant.PageSize = 1
        1..2 | ForEach-Object { Add-FakePolicy -Tenant $script:Tenant -DisplayName "Policy $_" | Out-Null }
        Get-GraphAllPages -Uri $uri -Headers @{ Authorization = 'Bearer x'; Extra = 'y' } | Out-Null
        $script:Tenant.Requests | ForEach-Object { $_.Headers['Extra'] | Should -Be 'y' }
    }

    It 'lets errors through to the caller' {
        Mock Invoke-RestMethod { throw (New-HttpError -StatusCode 403) }
        { Get-GraphAllPages -Uri $uri -Headers @{} } | Should -Throw
    }
}

Describe 'Get-DriversFWGroups' {
    BeforeEach {
        Mock Write-Host {}
        $headers = @{ Authorization = 'Bearer test' }
        $script:Tenant = New-FakeTenant
        Mock Invoke-RestMethod {
            Invoke-FakeGraph -Tenant $script:Tenant -Method "$Method" -Uri $Uri.OriginalString -Body $Body -Headers $Headers
        }
    }

    It 'returns only groups whose name starts with Drivers-FW-' {
        Add-FakeGroup -Tenant $script:Tenant -DisplayName 'Drivers-FW-Latitude 5440-Automatic' | Out-Null
        Add-FakeGroup -Tenant $script:Tenant -DisplayName 'Some Other Group' | Out-Null
        @(Get-DriversFWGroups).displayName | Should -Be @('Drivers-FW-Latitude 5440-Automatic')
    }

    It 'sends the advanced-query header and $count=true, keeping the bearer token' {
        Get-DriversFWGroups | Out-Null
        $request = $script:Tenant.Requests[0]
        $request.Uri | Should -BeLike "*`$filter=startsWith(displayName,'Drivers-FW-')*"
        $request.Uri | Should -BeLike "*`$count=true*"
        $request.Headers['ConsistencyLevel'] | Should -Be 'eventual'
        $request.Headers['Authorization'] | Should -Be 'Bearer test'
    }

    It 'does not add ConsistencyLevel to the shared $headers' {
        Get-DriversFWGroups | Out-Null
        $headers.ContainsKey('ConsistencyLevel') | Should -BeFalse
    }
}

Describe 'Get-ModelsFromIntune' {
    BeforeEach {
        Mock Write-Host {}
        Mock Write-Error {}
        $headers = @{ Authorization = 'Bearer test' }
        $script:Tenant = New-FakeTenant
        Mock Invoke-RestMethod {
            Invoke-FakeGraph -Tenant $script:Tenant -Method "$Method" -Uri $Uri.OriginalString -Body $Body -Headers $Headers
        }
    }

    It 'follows every page and returns unique, sorted, non-empty models' {
        $script:Tenant.PageSize = 2
        foreach ($m in 'Latitude 5440', '21AH00ABMX', 'Latitude 5440', '', 'OptiPlex 7010') {
            Add-FakeDevice -Tenant $script:Tenant -Model $m
        }

        $models = @(Get-ModelsFromIntune)

        $models | Should -Be @('21AH00ABMX', 'Latitude 5440', 'OptiPlex 7010')
        @($script:Tenant.Requests | Where-Object Uri -Like '*/managedDevices*').Count | Should -Be 3
    }

    It 'asks only for Windows devices and only the model property' {
        Add-FakeDevice -Tenant $script:Tenant -Model 'Latitude 5440'
        Get-ModelsFromIntune | Out-Null
        $script:Tenant.Requests[0].Uri | Should -BeLike "*`$filter=operatingSystem eq 'Windows'*"
        $script:Tenant.Requests[0].Uri | Should -BeLike "*`$select=model"
    }

    It 'logs and rethrows when Graph fails' {
        Mock Invoke-RestMethod { throw (New-HttpError -StatusCode 403) }
        { Get-ModelsFromIntune } | Should -Throw
        Should -Invoke Write-Host -ParameterFilter { $Object -like '*Failed to retrieve devices from Intune*' }
    }
}

Describe 'Get-DevicesFromGroup' {
    BeforeEach {
        Mock Write-Host {}
        Mock Write-Error {}
        $headers = @{ Authorization = 'Bearer test' }
        $script:Tenant = New-FakeTenant
        Mock Invoke-RestMethod {
            Invoke-FakeGraph -Tenant $script:Tenant -Method "$Method" -Uri $Uri.OriginalString -Body $Body -Headers $Headers
        }
    }

    It 'throws when the group does not exist' {
        { Get-DevicesFromGroup -GroupName 'Nope' } | Should -Throw "*Group 'Nope' not found in Entra ID*"
    }

    It 'escapes apostrophes in the group name filter' {
        Add-FakeGroup -Tenant $script:Tenant -DisplayName "O'Brien Pilots" -Id 'grp-limit' | Out-Null
        Get-DevicesFromGroup -GroupName "O'Brien Pilots" | Out-Null
        $script:Tenant.Requests[0].Uri | Should -BeLike "*displayName eq 'O''Brien Pilots'*"
    }

    It 'returns only group members that are in Intune and have a model, with their Entra object ID' {
        Add-FakeGroup -Tenant $script:Tenant -DisplayName 'Pilot Devices' -Id 'grp-limit' | Out-Null
        Add-FakeDevice -Tenant $script:Tenant -Model 'Latitude 5440' -InLimitingGroup            # ent-0001: kept
        Add-FakeDevice -Tenant $script:Tenant -Model '21AH00ABMX' -InLimitingGroup               # ent-0002: kept
        Add-FakeDevice -Tenant $script:Tenant -Model 'OptiPlex 7010'                             # not in group
        Add-FakeDevice -Tenant $script:Tenant -Model 'EliteBook 840' -InLimitingGroup -NotInIntune
        Add-FakeDevice -Tenant $script:Tenant -Model '' -InLimitingGroup                         # no model

        $result = @(Get-DevicesFromGroup -GroupName 'Pilot Devices')

        $result.Count | Should -Be 2
        ($result | Where-Object model -EQ 'Latitude 5440').id | Should -Be 'ent-0001'
        ($result | Where-Object model -EQ '21AH00ABMX').id | Should -Be 'ent-0002'
    }

    It 'follows paging on both the member and device queries' {
        $script:Tenant.PageSize = 1
        Add-FakeGroup -Tenant $script:Tenant -DisplayName 'Pilot Devices' -Id 'grp-limit' | Out-Null
        1..3 | ForEach-Object { Add-FakeDevice -Tenant $script:Tenant -Model "Model $_" -InLimitingGroup }

        @(Get-DevicesFromGroup -GroupName 'Pilot Devices').Count | Should -Be 3
        @($script:Tenant.Requests | Where-Object Uri -Like '*/members/*').Count | Should -Be 3
        @($script:Tenant.Requests | Where-Object Uri -Like '*/managedDevices*').Count | Should -Be 3
    }
}

Describe 'Remove-DriversFWGroups' {
    BeforeEach {
        Mock Write-Host {}
        Mock Write-Warning {}
        Mock Write-Error {}
        $headers = @{ Authorization = 'Bearer test' }
        $approval = 'Automatic'
        $limitingGroup = ''
        $whatIf = $false

        $script:Tenant = New-FakeTenant
        Mock Invoke-RestMethod {
            Invoke-FakeGraph -Tenant $script:Tenant -Method "$Method" -Uri $Uri.OriginalString -Body $Body -Headers $Headers
        }

        foreach ($name in 'Drivers-FW-Latitude 5440-Automatic', 'Drivers-FW-Latitude 5440-Manual',
            'Drivers-FW-Latitude 5440-Automatic-Pilot', 'Drivers-FW-Latitude 5440-Manual-Pilot',
            'Some Other Group') {
            Add-FakeGroup -Tenant $script:Tenant -DisplayName $name | Out-Null
        }
        foreach ($name in 'Drivers-FW-Latitude 5440-Automatic-7d', 'Drivers-FW-Latitude 5440-Manual',
            'Drivers-FW-Latitude 5440-Automatic-7d-Pilot', 'Drivers-FW-Latitude 5440-Manual-Pilot',
            'Some Other Policy') {
            Add-FakePolicy -Tenant $script:Tenant -DisplayName $name | Out-Null
        }
    }

    It 'removes only the standard Automatic group and policy in automatic mode' {
        Remove-DriversFWGroups

        $script:Tenant.Groups.displayName | Should -Not -Contain 'Drivers-FW-Latitude 5440-Automatic'
        $script:Tenant.Groups.displayName | Should -Contain 'Drivers-FW-Latitude 5440-Manual'
        $script:Tenant.Groups.displayName | Should -Contain 'Drivers-FW-Latitude 5440-Automatic-Pilot'
        $script:Tenant.Groups.displayName | Should -Contain 'Some Other Group'

        $script:Tenant.Policies.displayName | Should -Not -Contain 'Drivers-FW-Latitude 5440-Automatic-7d'
        $script:Tenant.Policies.displayName | Should -Contain 'Drivers-FW-Latitude 5440-Manual'
        $script:Tenant.Policies.displayName | Should -Contain 'Some Other Policy'
    }

    It 'accepts a lower-case approval value' {
        $approval = 'automatic'
        Remove-DriversFWGroups
        $script:Tenant.Groups.displayName | Should -Not -Contain 'Drivers-FW-Latitude 5440-Automatic'
    }

    It 'removes only the standard Manual group and policy in manual mode' {
        $approval = 'Manual'
        Remove-DriversFWGroups

        $script:Tenant.Groups.displayName | Should -Not -Contain 'Drivers-FW-Latitude 5440-Manual'
        $script:Tenant.Groups.displayName | Should -Contain 'Drivers-FW-Latitude 5440-Automatic'
        $script:Tenant.Groups.displayName | Should -Contain 'Drivers-FW-Latitude 5440-Manual-Pilot'
        $script:Tenant.Policies.displayName | Should -Not -Contain 'Drivers-FW-Latitude 5440-Manual'
        $script:Tenant.Policies.displayName | Should -Contain 'Drivers-FW-Latitude 5440-Automatic-7d'
    }

    It 'removes only -Pilot resources when a limiting group is set' {
        $limitingGroup = 'Pilot Devices'
        Remove-DriversFWGroups

        $script:Tenant.Groups.displayName | Should -Not -Contain 'Drivers-FW-Latitude 5440-Automatic-Pilot'
        $script:Tenant.Groups.displayName | Should -Contain 'Drivers-FW-Latitude 5440-Automatic'
        $script:Tenant.Groups.displayName | Should -Contain 'Drivers-FW-Latitude 5440-Manual-Pilot'
        $script:Tenant.Policies.displayName | Should -Not -Contain 'Drivers-FW-Latitude 5440-Automatic-7d-Pilot'
        $script:Tenant.Policies.displayName | Should -Contain 'Drivers-FW-Latitude 5440-Automatic-7d'
    }

    It 'sends ConsistencyLevel: eventual on the startsWith group query' {
        Remove-DriversFWGroups
        $query = $script:Tenant.Requests | Where-Object Uri -Like '*startsWith(displayName*' | Select-Object -First 1
        $query.Headers['ConsistencyLevel'] | Should -Be 'eventual'
        $query.Headers['Authorization'] | Should -Be 'Bearer test'
    }

    It 'lets the safeguard block a name that passes the wildcard but not the strict pattern' {
        Add-FakeGroup -Tenant $script:Tenant -DisplayName 'Drivers-FW--Automatic' | Out-Null
        Remove-DriversFWGroups

        $script:Tenant.Groups.displayName | Should -Contain 'Drivers-FW--Automatic'
        Should -Invoke Write-Host -ParameterFilter { $Object -like '*Safeguard blocked removal of unexpected group: Drivers-FW--Automatic*' }
    }

    It 'does nothing when there is nothing to remove' {
        $script:Tenant.Groups.Clear()
        $script:Tenant.Policies.Clear()
        Remove-DriversFWGroups

        @($script:Tenant.Requests | Where-Object Method -EQ 'DELETE').Count | Should -Be 0
        Should -Invoke Write-Host -ParameterFilter { $Object -like '*Nothing to remove*' }
    }

    It 'carries on after a failed delete and counts it' {
        $blocked = $script:Tenant.Groups | Where-Object displayName -EQ 'Drivers-FW-Latitude 5440-Automatic'
        $script:Tenant.FailDeleteIds = @($blocked.id)

        Remove-DriversFWGroups

        $script:Tenant.Groups.displayName | Should -Contain 'Drivers-FW-Latitude 5440-Automatic'
        $script:Tenant.Policies.displayName | Should -Not -Contain 'Drivers-FW-Latitude 5440-Automatic-7d'
        Should -Invoke Write-Host -ParameterFilter { $Object -match 'Groups removed\s+: 0$' }
        Should -Invoke Write-Host -ParameterFilter { $Object -match 'Groups failed\s+: 1$' }
    }

    Context 'WhatIf mode' {
        BeforeEach {
            $whatIf = $true
            $script:GroupsBefore = @($script:Tenant.Groups.displayName)
            $script:PoliciesBefore = @($script:Tenant.Policies.displayName)
            Remove-DriversFWGroups
        }

        It 'deletes nothing' {
            @($script:Tenant.Requests | Where-Object Method -NE 'GET').Count | Should -Be 0
            $script:Tenant.Groups.displayName | Should -Be $script:GroupsBefore
            $script:Tenant.Policies.displayName | Should -Be $script:PoliciesBefore
        }

        It 'reports each group and policy it would remove' {
            Should -Invoke Write-Host -ParameterFilter { $Object -like '*`[WHATIF`] Would remove group: Drivers-FW-Latitude 5440-Automatic (*' }
            Should -Invoke Write-Host -ParameterFilter { $Object -like '*`[WHATIF`] Would remove policy: Drivers-FW-Latitude 5440-Automatic-7d (*' }
            Should -Invoke Write-Host -Times 0 -Exactly -ParameterFilter { $Object -like '*Would remove group: Drivers-FW-Latitude 5440-Manual*' }
        }

        It 'labels the summary as a WhatIf run' {
            Should -Invoke Write-Host -ParameterFilter { $Object -like '*WhatIf removal complete - nothing was deleted*' }
            Should -Invoke Write-Host -ParameterFilter { $Object -match 'Groups to remove\s+: 1$' }
            Should -Invoke Write-Host -Times 0 -Exactly -ParameterFilter { $Object -like '*Groups removed*' }
        }
    }

    It 'leaves -Pilot policies alone in standard <Mode> mode' -Tag 'KnownIssue' -Skip -ForEach @(
        @{ Mode = 'Automatic'; Pilot = 'Drivers-FW-Latitude 5440-Automatic-7d-Pilot' }
        @{ Mode = 'Manual'; Pilot = 'Drivers-FW-Latitude 5440-Manual-Pilot' }
    ) {
        # The policy filter "Drivers-FW-*-<mode>*" also matches "...-<mode>[-7d]-Pilot", so a
        # standard cleanup deletes pilot policies while their pilot groups survive.
        $approval = $Mode
        Remove-DriversFWGroups
        $script:Tenant.Policies.displayName | Should -Contain $Pilot
    }
}

Describe 'Runbook end to end' {
    BeforeEach {
        Mock Write-Host {}
        Mock Write-Warning {}
        Mock Write-Error {}
        Mock Start-Sleep {}
        Mock Disable-AzContextAutosave {}
        Mock Connect-AzAccount {}
        Mock Get-AzAccessToken { [pscustomobject]@{ Token = 'fake-token' } }

        $script:Tenant = New-FakeTenant
        Mock Invoke-RestMethod {
            Invoke-FakeGraph -Tenant $script:Tenant -Method "$Method" -Uri $Uri.OriginalString -Body $Body -Headers $Headers
        }
    }

    Context 'Default run (automatic approval, Family grouping)' {
        BeforeEach {
            Initialize-StandardTenant -Tenant $script:Tenant
            Invoke-Runbook
            $script:T14Group = $script:Tenant.Groups | Where-Object displayName -EQ 'Drivers-FW-ThinkPad T14 Gen 3-Automatic'
            $script:DellGroup = $script:Tenant.Groups | Where-Object displayName -EQ 'Drivers-FW-Latitude 5440-Automatic'
        }

        It 'creates one group per family and skips the excluded models' {
            $script:Tenant.Groups.displayName | Should -Be @(
                'Drivers-FW-Latitude 5440-Automatic'
                'Drivers-FW-ThinkPad T14 Gen 3-Automatic'
            )
        }

        It 'makes the Lenovo group dynamic, covering every catalog machine type of that name' {
            $script:T14Group.Body.membershipRule |
                Should -Be '(device.deviceModel -startsWith "21AH" -or device.deviceModel -startsWith "21AJ" -or device.deviceModel -startsWith "21CF")'
            $script:T14Group.Body.membershipRuleProcessingState | Should -Be 'On'
            $script:T14Group.RawBody | Should -Match '"groupTypes":\s*\[\s*"DynamicMembership"\s*\]'
        }

        It 'uses an exact match for non-Lenovo models' {
            $script:DellGroup.Body.membershipRule | Should -Be '(device.deviceModel -eq "Latitude 5440")'
        }

        It 'creates a non-mail security group with a clean mailNickname' {
            $script:T14Group.Body.securityEnabled | Should -BeTrue
            $script:T14Group.Body.mailEnabled | Should -BeFalse
            $script:T14Group.Body.mailNickname | Should -Be 'drivers-fw-thinkpad-t14-gen-3-automatic'
        }

        It 'creates an automatic driver policy per family with the deferral' {
            $policy = $script:Tenant.Policies | Where-Object displayName -EQ 'Drivers-FW-ThinkPad T14 Gen 3-Automatic-7d'
            $policy | Should -Not -BeNullOrEmpty
            $policy.Body.approvalType | Should -Be 'Automatic'
            $policy.Body.deploymentDeferralInDays | Should -Be 7
            $policy.Body.description | Should -Be 'Automatic approvals'
            @($policy.Body.roleScopeTagIds) | Should -Be @('0')
            $script:Tenant.Policies.Count | Should -Be 2
        }

        It 'assigns each policy to its own group' {
            $expected = @{
                'Drivers-FW-ThinkPad T14 Gen 3-Automatic-7d' = $script:T14Group.id
                'Drivers-FW-Latitude 5440-Automatic-7d'      = $script:DellGroup.id
            }
            foreach ($name in $expected.Keys) {
                $policy = $script:Tenant.Policies | Where-Object displayName -EQ $name
                $policy.Assignments.Count | Should -Be 1
                $policy.Assignments[0].groupId | Should -Be $expected[$name]
                $policy.Assignments[0].'@odata.type' | Should -Be '#microsoft.graph.groupAssignmentTarget'
            }
        }

        It 'sends the bearer token on Graph calls' {
            $graphCalls = @($script:Tenant.Requests | Where-Object Uri -Like 'https://graph.microsoft.com/*')
            $graphCalls.Count | Should -BeGreaterThan 0
            $graphCalls | ForEach-Object { $_.Headers['Authorization'] | Should -Be 'Bearer fake-token' }
        }

        It 'reports the totals in the summary' {
            Should -Invoke Write-Host -ParameterFilter { $Object -match 'Models discovered\s+: 4$' }
            Should -Invoke Write-Host -ParameterFilter { $Object -match 'Families targeted\s+: 2$' }
            Should -Invoke Write-Host -ParameterFilter { $Object -match 'Groups created\s+: 2$' }
            Should -Invoke Write-Host -ParameterFilter { $Object -match 'Policies created\s+: 2$' }
            Should -Invoke Write-Host -ParameterFilter { $Object -match 'Assignments done\s+: 2$' }
            Should -Invoke Write-Host -ParameterFilter { $Object -match 'Groups failed\s+: 0$' }
        }
    }

    Context 'Approval mode' {
        It 'names everything -Manual and sets no deferral in manual mode' {
            Initialize-StandardTenant -Tenant $script:Tenant
            Invoke-Runbook -Settings @{ approval = 'Manual' }

            $script:Tenant.Groups.displayName | Should -Contain 'Drivers-FW-Latitude 5440-Manual'
            $policy = $script:Tenant.Policies | Where-Object displayName -EQ 'Drivers-FW-Latitude 5440-Manual'
            $policy.Body.approvalType | Should -Be 'Manual'
            $policy.Body.description | Should -Be 'Manual'
            $policy.Body.PSObject.Properties.Name | Should -Not -Contain 'deploymentDeferralInDays'
        }

        It 'puts a custom deferral into the policy name and body' {
            Initialize-StandardTenant -Tenant $script:Tenant
            Invoke-Runbook -Settings @{ automaticDays = 14 }

            $policy = $script:Tenant.Policies | Where-Object displayName -EQ 'Drivers-FW-Latitude 5440-Automatic-14d'
            $policy.Body.deploymentDeferralInDays | Should -Be 14
        }
    }

    Context 'Existing objects' {
        BeforeEach {
            Add-FakeDevice -Tenant $script:Tenant -Model 'Latitude 5440'
        }

        It 'skips a family whose group and policy already exist' {
            Add-FakeGroup -Tenant $script:Tenant -DisplayName 'Drivers-FW-Latitude 5440-Automatic' | Out-Null
            Add-FakePolicy -Tenant $script:Tenant -DisplayName 'Drivers-FW-Latitude 5440-Automatic-7d' | Out-Null

            Invoke-Runbook

            @($script:Tenant.Requests | Where-Object Method -EQ 'POST').Count | Should -Be 0
            Should -Invoke Write-Host -ParameterFilter { $Object -like '*Group already in place, skipping*' }
            Should -Invoke Write-Host -ParameterFilter { $Object -like '*Policy already in place, skipping*' }
        }

        It 'creates the missing policy and assigns it to the existing group' {
            Add-FakeGroup -Tenant $script:Tenant -DisplayName 'Drivers-FW-Latitude 5440-Automatic' -Id 'grp-existing' | Out-Null

            Invoke-Runbook

            @($script:Tenant.Requests | Where-Object { $_.Method -eq 'POST' -and $_.Uri -like '*/groups' }).Count | Should -Be 0
            $policy = $script:Tenant.Policies | Where-Object displayName -EQ 'Drivers-FW-Latitude 5440-Automatic-7d'
            $policy.Assignments[0].groupId | Should -Be 'grp-existing'
        }

        It 'finds an existing group in the prefetch without a per-family lookup' {
            Add-FakeGroup -Tenant $script:Tenant -DisplayName 'Drivers-FW-Latitude 5440-Automatic' -Id 'grp-existing' | Out-Null

            Invoke-Runbook

            @($script:Tenant.Requests | Where-Object Uri -Like '*displayName eq*') | Should -BeNullOrEmpty
            $prefetch = @($script:Tenant.Requests | Where-Object Uri -Like '*startsWith(displayName*')
            $prefetch.Count | Should -Be 1
            $prefetch[0].Headers['ConsistencyLevel'] | Should -Be 'eventual'
            ($script:Tenant.Policies | Where-Object displayName -EQ 'Drivers-FW-Latitude 5440-Automatic-7d').Assignments[0].groupId |
                Should -Be 'grp-existing'
        }

        It 'matches prefetched group names case-insensitively, like Entra' {
            Add-FakeGroup -Tenant $script:Tenant -DisplayName 'DRIVERS-FW-LATITUDE 5440-AUTOMATIC' -Id 'grp-upper' | Out-Null
            Invoke-Runbook
            @($script:Tenant.Requests | Where-Object { $_.Method -eq 'POST' -and $_.Uri -like '*/groups' }) | Should -BeNullOrEmpty
        }

        It 'confirms a prefetch miss with a direct lookup instead of creating a duplicate' {
            # The group exists, but the eventually consistent startsWith query has not caught up
            Add-FakeGroup -Tenant $script:Tenant -DisplayName 'Drivers-FW-Latitude 5440-Automatic' -Id 'grp-fresh' | Out-Null
            $script:Tenant.StaleGroupNames = @('Drivers-FW-Latitude 5440-Automatic')

            Invoke-Runbook

            @($script:Tenant.Requests | Where-Object Uri -Like "*displayName eq 'Drivers-FW-Latitude 5440-Automatic'*").Count | Should -Be 1
            @($script:Tenant.Requests | Where-Object { $_.Method -eq 'POST' -and $_.Uri -like '*/groups' }) | Should -BeNullOrEmpty
            @($script:Tenant.Groups | Where-Object displayName -EQ 'Drivers-FW-Latitude 5440-Automatic').Count | Should -Be 1
            ($script:Tenant.Policies | Where-Object displayName -EQ 'Drivers-FW-Latitude 5440-Automatic-7d').Assignments[0].groupId |
                Should -Be 'grp-fresh'
        }

        It 'stops before creating anything when the group prefetch fails' {
            Mock Invoke-RestMethod {
                if ($Uri.OriginalString -like '*startsWith(displayName*') { throw (New-HttpError -StatusCode 403) }
                Invoke-FakeGraph -Tenant $script:Tenant -Method "$Method" -Uri $Uri.OriginalString -Body $Body -Headers $Headers
            }
            { Invoke-Runbook } | Should -Throw
            @($script:Tenant.Requests | Where-Object Method -NE 'GET') | Should -BeNullOrEmpty
            Should -Invoke Write-Host -ParameterFilter { $Object -like '*Failed to fetch existing groups*' }
        }

        It 'finds an existing policy on a later page' {
            $script:Tenant.PageSize = 1
            Add-FakeGroup -Tenant $script:Tenant -DisplayName 'Drivers-FW-Latitude 5440-Automatic' | Out-Null
            Add-FakePolicy -Tenant $script:Tenant -DisplayName 'Unrelated 1' | Out-Null
            Add-FakePolicy -Tenant $script:Tenant -DisplayName 'Unrelated 2' | Out-Null
            Add-FakePolicy -Tenant $script:Tenant -DisplayName 'Drivers-FW-Latitude 5440-Automatic-7d' | Out-Null

            Invoke-Runbook

            @($script:Tenant.Requests | Where-Object { $_.Method -eq 'POST' -and $_.Uri -like '*windowsDriverUpdateProfiles' }).Count |
                Should -Be 0
        }

        It 'creates the policy unassigned and warns when the group cannot be created' {
            $script:Tenant.FailGroupCreate = $true

            Invoke-Runbook

            $policy = $script:Tenant.Policies | Where-Object displayName -EQ 'Drivers-FW-Latitude 5440-Automatic-7d'
            $policy | Should -Not -BeNullOrEmpty
            $policy.Assignments.Count | Should -Be 0
            Should -Invoke Write-Host -ParameterFilter { $Object -like '*No group ID available*' }
            Should -Invoke Write-Host -ParameterFilter { $Object -match 'Groups failed\s+: 1$' }
        }

        It 'does not stack a second policy on a group when only the deferral days change' -Tag 'KnownIssue' -Skip {
            # The group name has no day count but the policy name does, so changing
            # $automaticDays reuses the group and assigns a second driver policy to it.
            Add-FakeGroup -Tenant $script:Tenant -DisplayName 'Drivers-FW-Latitude 5440-Automatic' | Out-Null
            Add-FakePolicy -Tenant $script:Tenant -DisplayName 'Drivers-FW-Latitude 5440-Automatic-7d' | Out-Null

            Invoke-Runbook -Settings @{ automaticDays = 14 }

            $script:Tenant.Policies.displayName | Should -Not -Contain 'Drivers-FW-Latitude 5440-Automatic-14d'
        }
    }

    Context 'Lenovo friendly names' {
        BeforeEach {
            Initialize-StandardTenant -Tenant $script:Tenant
        }

        It 'lets a manual override win over the downloaded name' {
            Invoke-Runbook -Settings @{ lenovoFamilyNames = @{ '21AH' = 'T14 G3' } }

            $override = $script:Tenant.Groups | Where-Object displayName -EQ 'Drivers-FW-T14 G3-Automatic'
            $override.Body.membershipRule | Should -Be '(device.deviceModel -startsWith "21AH")'
            $catalog = $script:Tenant.Groups | Where-Object displayName -EQ 'Drivers-FW-ThinkPad T14 Gen 3-Automatic'
            $catalog.Body.membershipRule |
                Should -Be '(device.deviceModel -startsWith "21AJ" -or device.deviceModel -startsWith "21CF")'
        }

        It 'falls back to "Lenovo <type>" and warns when the download fails' {
            $script:Tenant.CatalogFails = $true
            Invoke-Runbook

            $script:Tenant.Groups.displayName | Should -Contain 'Drivers-FW-Lenovo 21AH-Automatic'
            $script:Tenant.Groups.displayName | Should -Contain 'Drivers-FW-Lenovo 21AJ-Automatic'
            Should -Invoke Write-Host -ParameterFilter { $Object -like '*No friendly name found for 2 machine type(s): 21AH, 21AJ*' }
        }

        It 'does not download the catalog when $useLenovoCatalog is off' {
            Invoke-Runbook -Settings @{ useLenovoCatalog = $false; lenovoFamilyNames = @{ '21AH' = 'T14'; '21AJ' = 'T14' } }

            @($script:Tenant.Requests | Where-Object Uri -Like 'https://download.lenovo.com/*').Count | Should -Be 0
            $group = $script:Tenant.Groups | Where-Object displayName -EQ 'Drivers-FW-T14-Automatic'
            $group.Body.membershipRule | Should -Be '(device.deviceModel -startsWith "21AH" -or device.deviceModel -startsWith "21AJ")'
        }

        It 'does not download the catalog when grouping by Model' {
            Invoke-Runbook -Settings @{ groupBy = 'Model' }

            @($script:Tenant.Requests | Where-Object Uri -Like 'https://download.lenovo.com/*') | Should -BeNullOrEmpty
            Should -Invoke Write-Host -ParameterFilter { $Object -like '*Skipping the Lenovo machine type list - it is not used when grouping by Model*' }
        }

        It 'does not download the catalog when no Lenovo models are in scope' {
            $script:Tenant.Devices.Clear()
            Add-FakeDevice -Tenant $script:Tenant -Model 'Latitude 5440'
            Add-FakeDevice -Tenant $script:Tenant -Model 'EliteBook 840 G9'

            Invoke-Runbook

            @($script:Tenant.Requests | Where-Object Uri -Like 'https://download.lenovo.com/*') | Should -BeNullOrEmpty
            Should -Invoke Write-Host -ParameterFilter { $Object -like '*Skipping the Lenovo machine type list - no Lenovo models in scope*' }
            $script:Tenant.Groups.Count | Should -Be 2
        }

        It 'ignores excluded models when deciding whether to download' {
            # A Lenovo-looking model that the exclusions remove must not trigger the download
            $script:Tenant.Devices.Clear()
            Add-FakeDevice -Tenant $script:Tenant -Model 'Latitude 5440'
            Add-FakeDevice -Tenant $script:Tenant -Model '21AH00ABMX'

            Invoke-Runbook -Settings @{ excludeModels = @('21AH') }

            @($script:Tenant.Requests | Where-Object Uri -Like 'https://download.lenovo.com/*') | Should -BeNullOrEmpty
        }

        It 'downloads the catalog exactly once when Lenovo models are in scope' {
            Invoke-Runbook
            @($script:Tenant.Requests | Where-Object Uri -Like 'https://download.lenovo.com/*').Count | Should -Be 1
        }

        It 'trims a membership rule over 3000 characters to the machine types in the tenant' {
            $script:Tenant.Devices.Clear()
            Add-FakeDevice -Tenant $script:Tenant -Model '3042ABCDEF'
            $script:Tenant.Catalog = @(0..99 | ForEach-Object { New-CatalogEntry 'ThinkPad Huge' ('3{0:d3}' -f $_) })

            Invoke-Runbook

            $group = $script:Tenant.Groups | Where-Object displayName -EQ 'Drivers-FW-ThinkPad Huge-Automatic'
            $group.Body.membershipRule | Should -Be '(device.deviceModel -startsWith "3042")'
            Should -Invoke Write-Host -ParameterFilter { $Object -like '*trimming to machine types present in the tenant*' }
        }
    }

    Context 'Grouping modes' {
        BeforeEach {
            Initialize-StandardTenant -Tenant $script:Tenant
        }

        It 'creates one group per machine type in MachineType mode' {
            Invoke-Runbook -Settings @{ groupBy = 'MachineType' }

            $script:Tenant.Groups.displayName | Should -Be @(
                'Drivers-FW-Latitude 5440-Automatic'
                'Drivers-FW-ThinkPad T14 Gen 3 (21AH)-Automatic'
                'Drivers-FW-ThinkPad T14 Gen 3 (21AJ)-Automatic'
            )
            ($script:Tenant.Groups | Where-Object displayName -Like '*(21AH)*').Body.membershipRule |
                Should -Be '(device.deviceModel -startsWith "21AH")'
        }

        It 'creates one exact-match group per model string in Model mode' {
            Invoke-Runbook -Settings @{ groupBy = 'Model' }

            $script:Tenant.Groups.Count | Should -Be 4
            ($script:Tenant.Groups | Where-Object displayName -EQ 'Drivers-FW-21AH00ABMX-Automatic').Body.membershipRule |
                Should -Be '(device.deviceModel -eq "21AH00ABMX")'
        }
    }

    Context 'Limiting group (pilot)' {
        BeforeEach {
            Add-FakeGroup -Tenant $script:Tenant -DisplayName 'Pilot Devices' -Id 'grp-limit' | Out-Null
            1..25 | ForEach-Object { Add-FakeDevice -Tenant $script:Tenant -Model '21AH00ABMX' -InLimitingGroup }
            Add-FakeDevice -Tenant $script:Tenant -Model 'Latitude 5440' -InLimitingGroup
            Add-FakeDevice -Tenant $script:Tenant -Model 'OptiPlex 7010'
            $script:Tenant.Catalog = @(New-CatalogEntry 'ThinkPad T14 Gen 3' '21AH')

            Invoke-Runbook -Settings @{ limitingGroup = 'Pilot Devices' }

            $script:T14Pilot = $script:Tenant.Groups | Where-Object displayName -EQ 'Drivers-FW-ThinkPad T14 Gen 3-Automatic-Pilot'
            $script:DellPilot = $script:Tenant.Groups | Where-Object displayName -EQ 'Drivers-FW-Latitude 5440-Automatic-Pilot'
        }

        It 'only builds families for models in the limiting group, with -Pilot names' {
            @($script:Tenant.Groups | Where-Object displayName -Like 'Drivers-FW-*').displayName | Should -Be @(
                'Drivers-FW-Latitude 5440-Automatic-Pilot'
                'Drivers-FW-ThinkPad T14 Gen 3-Automatic-Pilot'
            )
            $script:Tenant.Policies.displayName | Should -Contain 'Drivers-FW-ThinkPad T14 Gen 3-Automatic-7d-Pilot'
        }

        It 'creates static groups with no membership rule' {
            $script:T14Pilot.Body.PSObject.Properties.Name | Should -Not -Contain 'groupTypes'
            $script:T14Pilot.Body.PSObject.Properties.Name | Should -Not -Contain 'membershipRule'
        }

        It 'adds the matching devices by Entra object ID, in batches of 20' {
            $script:T14Pilot.Members.Count | Should -Be 25
            $script:T14Pilot.Members | Should -Contain 'ent-0001'
            $script:DellPilot.Members | Should -Be @('ent-0026')

            $patches = @($script:Tenant.Requests | Where-Object { $_.Method -eq 'PATCH' -and $_.Uri -like "*/groups/$($script:T14Pilot.id)" })
            $patches.Count | Should -Be 2
        }

        It 'binds members through directoryObjects references' {
            $patch = $script:Tenant.Requests | Where-Object Method -EQ 'PATCH' | Select-Object -First 1
            ($patch.Body | ConvertFrom-Json).'members@odata.bind'[0] |
                Should -BeLike 'https://graph.microsoft.com/beta/directoryObjects/ent-*'
        }

        It 'assigns each pilot policy to its pilot group' {
            $policy = $script:Tenant.Policies | Where-Object displayName -EQ 'Drivers-FW-ThinkPad T14 Gen 3-Automatic-7d-Pilot'
            $policy.Assignments[0].groupId | Should -Be $script:T14Pilot.id
        }
    }

    Context 'Names and escaping' {
        It 'escapes apostrophes in the group lookup and keeps them in the display name' {
            Add-FakeDevice -Tenant $script:Tenant -Model "O'Neil Workstation"
            Invoke-Runbook

            $lookup = $script:Tenant.Requests | Where-Object Uri -Like '*displayName eq*' | Select-Object -First 1
            $lookup.Uri | Should -BeLike "*displayName eq 'Drivers-FW-O''Neil Workstation-Automatic'*"
            $script:Tenant.Groups.displayName | Should -Contain "Drivers-FW-O'Neil Workstation-Automatic"
        }

        It 'keeps mailNickname to 64 lower-case alphanumeric-or-hyphen characters' {
            Add-FakeDevice -Tenant $script:Tenant -Model 'Some Extremely Long Workstation Model Name That Keeps Going Pro Max Ultra'
            Invoke-Runbook

            $nick = $script:Tenant.Groups[0].Body.mailNickname
            $nick.Length | Should -Be 64
            $nick | Should -MatchExactly '^[a-z0-9-]+$'
        }
    }

    Context 'WhatIf mode' {
        It 'sends no write requests at all in a standard run' {
            Initialize-StandardTenant -Tenant $script:Tenant
            Invoke-Runbook -Settings @{ whatIf = $true }

            @($script:Tenant.Requests | Where-Object Method -NE 'GET').Count | Should -Be 0
            $script:Tenant.Groups.Count | Should -Be 0
            $script:Tenant.Policies.Count | Should -Be 0
        }

        It 'reports each group, rule, policy and assignment a real run would make' {
            Initialize-StandardTenant -Tenant $script:Tenant
            Invoke-Runbook -Settings @{ whatIf = $true }

            Should -Invoke Write-Host -ParameterFilter { $Object -like '*`[WHATIF`] Would create group: Drivers-FW-ThinkPad T14 Gen 3-Automatic' }
            Should -Invoke Write-Host -ParameterFilter {
                $Object -like '*`[WHATIF`]   Membership rule: (device.deviceModel -startsWith "21AH" -or device.deviceModel -startsWith "21AJ" -or device.deviceModel -startsWith "21CF")'
            }
            Should -Invoke Write-Host -ParameterFilter { $Object -like '*`[WHATIF`] Would create group: Drivers-FW-Latitude 5440-Automatic' }
            Should -Invoke Write-Host -ParameterFilter {
                $Object -like '*`[WHATIF`] Would create policy: Drivers-FW-Latitude 5440-Automatic-7d (approval: Automatic, deferral 7 day(s))'
            }
            Should -Invoke Write-Host -Times 2 -Exactly -ParameterFilter { $Object -like '*`[WHATIF`] Would assign policy*' }
            Should -Invoke Write-Host -ParameterFilter {
                $Object -like '*`[WHATIF`] Would assign policy Drivers-FW-Latitude 5440-Automatic-7d to group: Drivers-FW-Latitude 5440-Automatic'
            }
            Should -Invoke Write-Host -Times 0 -Exactly -ParameterFilter { $Object -like '*No group ID available*' }
        }

        It 'reports a manual policy without a deferral' {
            Add-FakeDevice -Tenant $script:Tenant -Model 'Latitude 5440'
            Invoke-Runbook -Settings @{ whatIf = $true; approval = 'Manual' }

            Should -Invoke Write-Host -ParameterFilter {
                $Object -like '*`[WHATIF`] Would create policy: Drivers-FW-Latitude 5440-Manual (approval: Manual)'
            }
        }

        It 'still skips objects that already exist, and plans assignment to an existing group' {
            Add-FakeDevice -Tenant $script:Tenant -Model 'Latitude 5440'
            Add-FakeDevice -Tenant $script:Tenant -Model 'OptiPlex 7010'
            Add-FakeGroup -Tenant $script:Tenant -DisplayName 'Drivers-FW-Latitude 5440-Automatic' | Out-Null
            Add-FakePolicy -Tenant $script:Tenant -DisplayName 'Drivers-FW-Latitude 5440-Automatic-7d' | Out-Null
            Add-FakeGroup -Tenant $script:Tenant -DisplayName 'Drivers-FW-OptiPlex 7010-Automatic' | Out-Null

            Invoke-Runbook -Settings @{ whatIf = $true }

            @($script:Tenant.Requests | Where-Object Method -NE 'GET').Count | Should -Be 0
            Should -Invoke Write-Host -Times 0 -Exactly -ParameterFilter { $Object -like '*Would create group*' }
            Should -Invoke Write-Host -Times 0 -Exactly -ParameterFilter { $Object -like '*Would create policy: Drivers-FW-Latitude*' }
            Should -Invoke Write-Host -ParameterFilter {
                $Object -like '*`[WHATIF`] Would assign policy Drivers-FW-OptiPlex 7010-Automatic-7d to group: Drivers-FW-OptiPlex 7010-Automatic'
            }
        }

        It 'reports pilot group members instead of adding them' {
            Add-FakeGroup -Tenant $script:Tenant -DisplayName 'Pilot Devices' -Id 'grp-limit' | Out-Null
            1..25 | ForEach-Object { Add-FakeDevice -Tenant $script:Tenant -Model 'Latitude 5440' -InLimitingGroup }

            Invoke-Runbook -Settings @{ whatIf = $true; limitingGroup = 'Pilot Devices' }

            @($script:Tenant.Requests | Where-Object Method -NE 'GET').Count | Should -Be 0
            Should -Invoke Write-Host -ParameterFilter { $Object -like '*`[WHATIF`]   Membership: static (assigned)' }
            Should -Invoke Write-Host -ParameterFilter {
                $Object -like '*`[WHATIF`] Would add 25 device(s) to group: Drivers-FW-Latitude 5440-Automatic-Pilot'
            }
        }

        It 'marks the run as WhatIf at the start and in the summary' {
            Initialize-StandardTenant -Tenant $script:Tenant
            Invoke-Runbook -Settings @{ whatIf = $true }

            Should -Invoke Write-Warning -Times 2 -Exactly -ParameterFilter { $Message -like '`*`*`* WHATIF MODE*' }
            Should -Invoke Write-Host -ParameterFilter { $Object -like '*WhatIf run complete - no changes were made*' }
            Should -Invoke Write-Host -ParameterFilter { $Object -match 'Groups to create\s+: 2$' }
            Should -Invoke Write-Host -ParameterFilter { $Object -match 'Policies to create\s+: 2$' }
            Should -Invoke Write-Host -ParameterFilter { $Object -match 'Assignments to make\s+: 2$' }
            Should -Invoke Write-Host -Times 0 -Exactly -ParameterFilter { $Object -match 'Groups created' }
        }

        It 'writes nothing with approval <Approval>, grouping <GroupBy>, pilot <Pilot>' -ForEach @(
            foreach ($a in 'Automatic', 'Manual') {
                foreach ($g in 'Family', 'MachineType', 'Model') {
                    foreach ($p in $false, $true) { @{ Approval = $a; GroupBy = $g; Pilot = $p } }
                }
            }
        ) {
            Initialize-StandardTenant -Tenant $script:Tenant
            $settings = @{ whatIf = $true; approval = $Approval; groupBy = $GroupBy }
            if ($Pilot) {
                Add-FakeGroup -Tenant $script:Tenant -DisplayName 'Pilot Devices' -Id 'grp-limit' | Out-Null
                foreach ($d in $script:Tenant.Devices) { $d.InLimitingGroup = $true }
                $settings['limitingGroup'] = 'Pilot Devices'
            }
            # One family already half set up, so the "existing group, new policy" path runs too
            Add-FakeGroup -Tenant $script:Tenant -DisplayName "Drivers-FW-Latitude 5440-$Approval$(if ($Pilot) { '-Pilot' })" | Out-Null
            $groupsBefore = @($script:Tenant.Groups | ForEach-Object { "$($_.id)|$($_.displayName)|$($_.Members.Count)" })

            Invoke-Runbook -Settings $settings

            @($script:Tenant.Requests | Where-Object Method -NE 'GET') | Should -BeNullOrEmpty
            @($script:Tenant.Groups | ForEach-Object { "$($_.id)|$($_.displayName)|$($_.Members.Count)" }) | Should -Be $groupsBefore
            $script:Tenant.Policies.Count | Should -Be 0
            # A blocked write would surface as an error; there must be none
            Should -Invoke Write-Host -Times 0 -Exactly -ParameterFilter { $Object -like '*`[ERROR`]*' }
            Should -Invoke Write-Host -ParameterFilter { $Object -like '*`[WHATIF`] Would*' }
        }

        It 'refuses to start when $whatIf is <Label>, before touching the tenant' -ForEach @(
            @{ Label = "the string 'false'"; Value = 'false' }
            @{ Label = 'the number 1'; Value = 1 }
            @{ Label = 'null'; Value = $null }
        ) {
            Add-FakeDevice -Tenant $script:Tenant -Model 'Latitude 5440'
            { Invoke-Runbook -Settings @{ whatIf = $Value } } | Should -Throw '*$whatIf must be $true or $false*'
            $script:Tenant.Requests.Count | Should -Be 0
            Should -Invoke Connect-AzAccount -Times 0 -Exactly
        }

        It 'prints no WhatIf banner in a normal run' {
            Add-FakeDevice -Tenant $script:Tenant -Model 'Latitude 5440'
            Invoke-Runbook
            Should -Invoke Write-Host -Times 0 -Exactly -ParameterFilter { $Object -like '*WHATIF*' }
        }
    }

    Context 'Single machine type' {
        BeforeEach {
            Initialize-StandardTenant -Tenant $script:Tenant
        }

        It 'covers the whole family of the machine type and nothing else (Family mode)' {
            Invoke-Runbook -Settings @{ singleMachineType = '21AH' }

            $script:Tenant.Groups.displayName | Should -Be @('Drivers-FW-ThinkPad T14 Gen 3-Automatic')
            $script:Tenant.Groups[0].Body.membershipRule |
                Should -Be '(device.deviceModel -startsWith "21AH" -or device.deviceModel -startsWith "21AJ" -or device.deviceModel -startsWith "21CF")'
            $script:Tenant.Policies.displayName | Should -Be @('Drivers-FW-ThinkPad T14 Gen 3-Automatic-7d')
            $script:Tenant.Policies[0].Assignments[0].groupId | Should -Be $script:Tenant.Groups[0].id
            Should -Invoke Write-Host -ParameterFilter { $Object -like '*Single machine type mode: 21AH' }
            Should -Invoke Write-Host -ParameterFilter { $Object -like "*Limiting run to 'ThinkPad T14 Gen 3' (machine types: 21AH, 21AJ, 21CF)*" }
            Should -Invoke Write-Host -ParameterFilter { $Object -match 'Families targeted\s+: 1$' }
        }

        It 'accepts a lower-case machine type' {
            Invoke-Runbook -Settings @{ singleMachineType = '21ah' }
            $script:Tenant.Groups.displayName | Should -Be @('Drivers-FW-ThinkPad T14 Gen 3-Automatic')
            # Matching ignores case anyway; the log should still show the canonical upper-case form
            Should -Invoke Write-Host -ParameterFilter { $Object -cmatch 'Single machine type mode: 21AH$' }
        }

        It 'reaches the same family through another of its machine types' {
            Invoke-Runbook -Settings @{ singleMachineType = '21AJ' }
            $script:Tenant.Groups.displayName | Should -Be @('Drivers-FW-ThinkPad T14 Gen 3-Automatic')
        }

        It 'covers only that machine type in MachineType mode' {
            Invoke-Runbook -Settings @{ singleMachineType = '21AH'; groupBy = 'MachineType' }
            $script:Tenant.Groups.displayName | Should -Be @('Drivers-FW-ThinkPad T14 Gen 3 (21AH)-Automatic')
        }

        It 'creates one group per model code of that machine type in Model mode' {
            Invoke-Runbook -Settings @{ singleMachineType = '21AH'; groupBy = 'Model' }
            @($script:Tenant.Groups.displayName | Sort-Object) |
                Should -Be @('Drivers-FW-21AH00ABMX-Automatic', 'Drivers-FW-21AH00XYMX-Automatic')
        }

        It 'stops with a warning, before fetching or writing anything, when no device has the machine type' {
            Invoke-Runbook -Settings @{ singleMachineType = '21ZZ' }

            Should -Invoke Write-Host -ParameterFilter { $Object -like '*No devices with machine type 21ZZ found in Intune - nothing to do.' }
            Should -Invoke Write-Warning -ParameterFilter { $Message -like '*machine type 21ZZ*' }
            @($script:Tenant.Requests | Where-Object Method -NE 'GET') | Should -BeNullOrEmpty
            @($script:Tenant.Requests | Where-Object Uri -Like 'https://download.lenovo.com/*') | Should -BeNullOrEmpty
            @($script:Tenant.Requests | Where-Object Uri -Like '*windowsDriverUpdateProfiles*') | Should -BeNullOrEmpty
            @($script:Tenant.Requests | Where-Object Uri -Like '*/groups*') | Should -BeNullOrEmpty
            Should -Invoke Write-Host -Times 0 -Exactly -ParameterFilter { $Object -like '*Run complete*' }
        }

        It 'treats a machine type whose models are all excluded as not found' {
            Invoke-Runbook -Settings @{ singleMachineType = '21AH'; excludeModels = @('21AH') }

            Should -Invoke Write-Host -ParameterFilter { $Object -like '*No devices with machine type 21AH found*' }
            $script:Tenant.Groups.Count | Should -Be 0
        }

        It 'rejects <Value> before signing in' -ForEach @(
            @{ Value = '21AH00ABMX' }
            @{ Value = 'ThinkPad T14 Gen 3' }
            @{ Value = '21A' }
            @{ Value = 'AB21' }
        ) {
            { Invoke-Runbook -Settings @{ singleMachineType = $Value } } |
                Should -Throw '*$singleMachineType must be a 4-character Lenovo machine type*'
            Should -Invoke Connect-AzAccount -Times 0 -Exactly
            $script:Tenant.Requests.Count | Should -Be 0
        }

        It 'keeps every family member in pilot mode, not just devices of the given type' {
            $script:Tenant.Devices.Clear()
            Add-FakeGroup -Tenant $script:Tenant -DisplayName 'Pilot Devices' -Id 'grp-limit' | Out-Null
            Add-FakeDevice -Tenant $script:Tenant -Model '21AH00ABMX' -InLimitingGroup   # ent-0001
            Add-FakeDevice -Tenant $script:Tenant -Model '21AJ00CDMX' -InLimitingGroup   # ent-0002
            Add-FakeDevice -Tenant $script:Tenant -Model 'Latitude 5440' -InLimitingGroup

            Invoke-Runbook -Settings @{ singleMachineType = '21AH'; limitingGroup = 'Pilot Devices' }

            $pilot = @($script:Tenant.Groups | Where-Object displayName -Like 'Drivers-FW-*')
            $pilot.displayName | Should -Be @('Drivers-FW-ThinkPad T14 Gen 3-Automatic-Pilot')
            @($pilot[0].Members | Sort-Object) | Should -Be @('ent-0001', 'ent-0002')
        }

        It 'names the limiting group in the not-found warning' {
            $script:Tenant.Devices.Clear()
            Add-FakeGroup -Tenant $script:Tenant -DisplayName 'Pilot Devices' -Id 'grp-limit' | Out-Null
            Add-FakeDevice -Tenant $script:Tenant -Model 'Latitude 5440' -InLimitingGroup

            Invoke-Runbook -Settings @{ singleMachineType = '21AH'; limitingGroup = 'Pilot Devices' }

            Should -Invoke Write-Host -ParameterFilter { $Object -like "*found in the limiting group 'Pilot Devices' - nothing to do.*" }
        }

        It 'plans only that family in WhatIf mode' {
            Invoke-Runbook -Settings @{ singleMachineType = '21AH'; whatIf = $true }

            @($script:Tenant.Requests | Where-Object Method -NE 'GET') | Should -BeNullOrEmpty
            Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter { $Object -like '*`[WHATIF`] Would create group:*' }
            Should -Invoke Write-Host -ParameterFilter { $Object -like '*`[WHATIF`] Would create group: Drivers-FW-ThinkPad T14 Gen 3-Automatic' }
        }
    }

    Context 'Authentication' {
        It 'stops before touching Graph when no token comes back' {
            Mock Get-AzAccessToken { [pscustomobject]@{ Token = '' } }
            Add-FakeDevice -Tenant $script:Tenant -Model 'Latitude 5440'

            { Invoke-Runbook } | Should -Throw '*Could not obtain a Microsoft Graph access token*'
            $script:Tenant.Requests.Count | Should -Be 0
        }

        It 'passes a user-assigned identity client ID to Connect-AzAccount' {
            Add-FakeDevice -Tenant $script:Tenant -Model 'Latitude 5440'
            Invoke-Runbook -Settings @{ managedIdentityClientId = 'abc-123' }
            Should -Invoke Connect-AzAccount -Times 1 -Exactly -ParameterFilter { $AccountId -eq 'abc-123' }
        }
    }
}
