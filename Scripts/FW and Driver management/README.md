# Driver and Firmware Groups and Policies

`New-DriverFWGroupsAndPolicies.ps1` is an Azure Automation runbook. It gives every Windows hardware family in Intune its own Entra ID device group and its own Windows Driver Update policy, and it assigns each policy to its group. Driver and firmware approvals can then be managed per hardware model instead of for the whole fleet at once.

Runs can be repeated safely. Groups and policies that already exist are skipped, so the runbook can run on a schedule and pick up new models as they are enrolled.

## Contents

- [How it works](#how-it-works)
- [Requirements](#requirements)
- [Setup](#setup)
- [Configuration](#configuration)
- [Grouping modes](#grouping-modes)
- [Naming](#naming)
- [Run modes](#run-modes)
- [Reading the job output](#reading-the-job-output)
- [Cleanup](#cleanup)
- [Known issues](#known-issues)
- [Tests](#tests)
- [Version history](#version-history)

## How it works

1. **Sign in** with the Automation account's managed identity and get a Microsoft Graph token.
2. **Collect models:** the model of every Windows device in Intune, or only the devices in a limiting group. Excluded models (Cloud PC, VMs and so on) are dropped.
3. **Name Lenovo models:** Lenovo devices report a model code such as `21AH00ABMX` instead of a product name. The first four characters (`21AH`, the *machine type*) are looked up in Lenovo's public model list to get a friendly name such as `ThinkPad T14 Gen 3`.
4. **Group models into families.** How depends on the [grouping mode](#grouping-modes).
5. **Read what already exists:** all driver update policies, and all groups named `Drivers-FW-*`.
6. **Create what's missing**, several families in parallel:
   - A group per family:
     - Normally a **dynamic** group, with a membership rule on `device.deviceModel`.
     - In pilot mode, a **static** group filled with the matching pilot devices.
   - A Windows Driver Update policy per family, with automatic or manual approval.
   - An assignment of each new policy to its group.
7. **Log a summary** of what was created, skipped and failed.

## Requirements

- **An Azure Automation account** with a **PowerShell 7.4** (or later) runtime. The runbook uses `ForEach-Object -Parallel`, which Windows PowerShell 5.1 doesn't have.
- **The `Az.Accounts` module** in that runtime environment.
- **A managed identity** on the Automation account, either system- or user-assigned.
- **These Microsoft Graph application permissions** granted to that identity:

  | Permission | Used for |
  |---|---|
  | `DeviceManagementConfiguration.ReadWrite.All` | Reading, creating, assigning and deleting driver update policies |
  | `DeviceManagementManagedDevices.Read.All` | Reading device models from Intune |
  | `Group.ReadWrite.All` | Reading, creating, filling and deleting groups |
  | `Device.Read.All` | Reading device members of the limiting group |

- **Microsoft Entra ID P1** or higher, for dynamic groups.
- **The Intune and Windows licensing that Windows Driver Update policies require** in your tenant.

## Setup

1. **Create the runbook.** In the Automation account, create a PowerShell runbook on the 7.4 runtime and paste in the contents of `New-DriverFWGroupsAndPolicies.ps1`.
2. **Enable the managed identity** on the Automation account (system-assigned is simplest).
3. **Grant the Graph permissions** to the identity. There's no portal page for this, so use Microsoft Graph PowerShell, signed in as an admin who can grant application permissions:

   ```powershell
   Connect-MgGraph -Scopes 'AppRoleAssignment.ReadWrite.All', 'Application.Read.All'

   # The managed identity's service principal; for a system-assigned identity it has the
   # same name as the Automation account
   $mi    = Get-MgServicePrincipal -Filter "displayName eq '<automation account name>'"
   $graph = Get-MgServicePrincipal -Filter "appId eq '00000003-0000-0000-c000-000000000000'"

   foreach ($permission in 'DeviceManagementConfiguration.ReadWrite.All', 'DeviceManagementManagedDevices.Read.All',
       'Group.ReadWrite.All', 'Device.Read.All') {
       $role = $graph.AppRoles | Where-Object { $_.Value -eq $permission -and $_.AllowedMemberTypes -contains 'Application' }
       New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $mi.Id `
           -PrincipalId $mi.Id -ResourceId $graph.Id -AppRoleId $role.Id
   }
   ```

4. **Do a dry run first.** Set `$whatIf = $true`, start the runbook and read the job output (see [WhatIf mode](#whatif-mode)).
5. **Run it for real.** Set `$whatIf = $false`. You can then link a schedule if new models should be picked up automatically.

If you use a user-assigned identity, put its client ID in `$managedIdentityClientId`.

## Configuration

All settings are variables at the top of the script.

| Setting | Default | What it does |
|---|---|---|
| `$managedIdentityClientId` | `''` | Empty uses the system-assigned identity. Set it to a client ID to use a user-assigned one. |
| `$whatIf` | `$false` | `$true` reads the tenant and reports what would change, without changing anything. See [WhatIf mode](#whatif-mode). |
| `$approval` | `'Automatic'` | `'Automatic'` or `'Manual'`. Sets the approval type of new policies and appears in the group and policy names. |
| `$automaticDays` | `7` | Days to defer automatic approvals (0 to 30). Only used with automatic approval, and it appears in the policy name. |
| `$limitingGroup` | `''` | The display name of an Entra ID group. When set, only models found in that group are processed. See [Pilot mode](#pilot-mode-limiting-group). |
| `$singleMachineType` | `''` | One Lenovo machine type, such as `'21AH'`. When set, only that model's family is processed. See [Single machine type mode](#single-machine-type-mode). |
| `$excludeModels` | Cloud PC, Virtual Machine, AHV | Models whose name **starts with** any of these are skipped. |
| `$groupBy` | `'Family'` | `'Family'`, `'MachineType'` or `'Model'`. See [Grouping modes](#grouping-modes). |
| `$useLenovoCatalog` | `$true` | Download Lenovo's public model list to name machine types. |
| `$lenovoCatalogUrl` | Lenovo's `allModels.json` | Where the model list is downloaded from. |
| `$lenovoFamilyNames` | empty | Manual names by machine type, e.g. `'21CB' = 'ThinkPad T14 Gen 3'`. These always win over the download. |

The runbook refuses to start if `$whatIf` isn't a true/false value, or if `$singleMachineType` isn't a 4-character machine type.

## Grouping modes

`$groupBy` decides how model strings are combined into families. It only affects Lenovo devices. Other manufacturers already report a product-style model such as `Latitude 5440` or `EliteBook 840 G9`, so each model string is its own family, matched exactly.

| Mode | One group per | Example for T14 Gen 3 devices (21AH, 21AJ) | Membership rule |
|---|---|---|---|
| `Family` (default) | Lenovo friendly name | `ThinkPad T14 Gen 3` | `-startsWith` on **every** machine type of that name in Lenovo's list, including ones not enrolled yet |
| `MachineType` | 4-character machine type | `ThinkPad T14 Gen 3 (21AH)` and `ThinkPad T14 Gen 3 (21AJ)` | `-startsWith` on that machine type |
| `Model` | Exact model string | `21AH00ABMX`, `21AH00XYMX`, ... | `-eq` on the model string |

Use `MachineType` when two variants with the same product name need different driver packs.

**Membership rule length.** Entra caps membership rules at 3072 characters. If a Family rule would pass 3000 characters, it's cut down to the machine types actually present in the tenant, and a warning is logged.

**Lenovo names.** If a machine type isn't in Lenovo's list or in `$lenovoFamilyNames`, its family is named `Lenovo 21XX`. The run log lists these machine types as a warning, so you can add names to `$lenovoFamilyNames`. If the download fails, the run carries on with the manual table only.

## Naming

| Object | Automatic approval | Manual approval |
|---|---|---|
| Group | `Drivers-FW-<family>-Automatic` | `Drivers-FW-<family>-Manual` |
| Policy | `Drivers-FW-<family>-Automatic-<days>d` | `Drivers-FW-<family>-Manual` |

In pilot mode, `-Pilot` is added to the end of every name. A group's mail nickname is its name in lower case, with every character other than a letter or digit turned into `-`, cut to 64 characters. Policies get the Default scope tag (`0`).

The runbook recognises its own objects by these names. It decides whether a group or policy already exists by its display name, so renaming one makes the next run create a new one.

## Run modes

### WhatIf mode

Set `$whatIf = $true` to see what a run would do without changing the tenant.

**What still happens:**
- The runbook signs in, reads from Graph and downloads Lenovo's model list.
- It checks for existing groups and policies in the usual way.

**What changes:**
- Every change is written to the log as a `[WHATIF] Would ...` line instead. This covers creating a group (with its membership rule), adding pilot members, creating a policy (with its approval settings) and assigning it.
- The summary says `to create` instead of `created`.
- A WARN banner at the start and end marks the job as a dry run. It also shows on the job's Warnings tab.

**The safeguard:** WhatIf is enforced in two places. Every place that would make a change checks `$whatIf`. On top of that, the function that sends every Graph request refuses anything except a GET unless `$whatIf` is exactly `$false`. A missing check, or a missing value, therefore blocks the change instead of making it.

### Pilot mode (limiting group)

Set `$limitingGroup` to the display name of an Entra ID group of devices. Then:

- **Models:** only models of devices in that group are processed.
- **Groups:** they're **static** instead of dynamic, and they're filled with the matching devices from the limiting group. A dynamic rule would also match devices outside the pilot.
- **Names:** every group and policy name ends in `-Pilot`, so pilot objects never clash with the full-tenant ones.

Device models come from Intune and are matched to group members through the Entra device ID, because the model field on Entra device objects is often empty.

### Single machine type mode

Set `$singleMachineType` to one Lenovo machine type, the first four characters of the model code (for example `'21AH'` for `21AH00ABMX`). The run then covers only the family that machine type belongs to.

- **Family mode:** `21AH` covers the whole `ThinkPad T14 Gen 3` family (21AH, 21AJ, 21CF, ...). The group and policy are exactly what a full run would create, so a later full run reports them as already in place.
- **MachineType mode:** only the `(21AH)` group.
- **Model mode:** one group per `21AH...` model code in the tenant.
- **Not found:** if no device in scope has that machine type, the run logs a warning and stops before downloading, fetching or writing anything.
- **Input check:** only a bare machine type is accepted. A full model code or a product name stops the run before it signs in.
- **Combining modes:** it works together with WhatIf and pilot mode. In pilot mode every device of the family in the limiting group is added, not just the given machine type.

## Reading the job output

Every line is timestamped and marked `[INFO]`, `[WARN]` or `[ERROR]`. WARN and ERROR lines also go to the job's Warnings and Errors tabs. A run ends with a summary like this:

```
Run complete  (approval mode: Automatic).
  Models discovered   : 14
  Families targeted   : 9
  Groups created      : 2
  Groups in place     : 7
  Groups failed       : 0
  Policies created    : 2
  Policies in place   : 7
  Policies failed     : 0
  Assignments done    : 2
  Assignments failed  : 0
```

**Warnings worth acting on:**

| Log message | Meaning |
|---|---|
| `No friendly name found for N machine type(s)` | Add those machine types to `$lenovoFamilyNames`. |
| `Could not download the Lenovo model list` | The run carries on with `$lenovoFamilyNames` only. |
| `Membership rule for '...' is N chars - trimming` | The rule was cut to the machine types present in the tenant. |
| `No group ID available - skipping assignment` | The group couldn't be created, so the new policy is unassigned. |
| `HTTP 429 - waiting Ns` | Graph is throttling. Requests are retried up to 5 times, honouring `Retry-After`. |

## Cleanup

The script contains a `Remove-DriversFWGroups` function, but **the runbook never calls it**. To use it:

1. Add this line directly after the line that sets `$headers`. The `return` stops the rest of the runbook, so nothing is created again straight after the cleanup:

   ```powershell
   Remove-DriversFWGroups; return
   ```

2. Run the runbook once.
3. Remove the line again.

What it removes:
- **Standard mode:** every group and policy for the current `$approval`, e.g. all `Drivers-FW-*-Automatic` groups and `Drivers-FW-*-Automatic*` policies.
- **When `$limitingGroup` is set:** only the `-Pilot` ones.

Every name must also pass a strict pattern check before anything is deleted.

> Run it with `$whatIf = $true` first. It then lists what it would delete. Also see known issue 1 below.

## Known issues

1. **Standard cleanup also deletes pilot policies.** The policy filter `Drivers-FW-*-Automatic*` also matches `...-Automatic-7d-Pilot`, and the same happens in Manual mode. The pilot groups survive, but their policies are deleted.
2. **Changing `$automaticDays` stacks policies.** The group name has no day count but the policy name does. After a change, the existing group is reused and a second policy (for example `-14d`) is assigned to it.
3. **No repair of assignments.** If a policy already exists but its group had to be recreated, the new group isn't assigned.
4. **Pilot groups are filled only once.** Members are added only when the group is created. Devices added to the limiting group later aren't added on later runs.
5. **Pilot mode reads every Windows device in Intune** to find the models of the group's members. This is slow in large tenants.

Items 1 and 2 have skipped tests, tagged `KnownIssue`, that describe the correct behaviour.

## Tests

`New-DriverFWGroupsAndPolicies.Tests.ps1` is a Pester suite. It needs PowerShell 7 and Pester 5.5 or later.

```powershell
Invoke-Pester -Path .\New-DriverFWGroupsAndPolicies.Tests.ps1 -Output Detailed
```

**Nothing leaves the machine:**
- Every Graph and Lenovo call is answered by an in-memory fake tenant, which records each request.
- The Az sign-in commands are replaced with stand-ins.
- A request the fake doesn't recognise fails the test.

**How the script is tested:** the runbook starts working as soon as it's loaded, so the suite never runs it directly. It reads the script's code instead and:
- loads the functions on their own for unit tests;
- runs a copy of the whole script for end-to-end tests, with its settings replaced by fixed test values. The parallel loop runs one family at a time in that copy, so the fakes can see it.

A few tests also run the real `ForEach-Object -Parallel` block in real parallel threads. They're set up so nothing can reach the network.

**What's covered:**
- Every function.
- All grouping and approval modes, pilot mode, WhatIf and single machine type mode.
- Retry and throttling, paging, and escaping of names.
- Checks that read the script's code for WhatIf safety. For example, the script must contain exactly six calls that change the tenant, and nothing may call Graph without going through the guarded function.

Tests tagged `KnownIssue` are skipped. Remove `-Skip` from a test once its issue is fixed.

## Version history

| Version | Changes |
|---|---|
| 2.3.0.0 | `$singleMachineType`: run for one Lenovo machine type's family. |
| 2.2.0.0 | Existing groups fetched in one query instead of one per family. The parallel block reuses the script's functions instead of its own copies. Shared paging helper. The Lenovo list is only downloaded when needed. Plain-ASCII script, so it also parses in Windows PowerShell 5.1. |
| 2.1.0.0 | `$whatIf` dry-run mode, with a guard on every write request. |
| 2.0.0.0 | Family and machine type grouping using Lenovo's model list, pilot mode, managed identity sign-in, parallel processing. |
