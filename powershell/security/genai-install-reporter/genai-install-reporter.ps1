<#
.SYNOPSIS
Reports managed devices that have generative AI apps installed, using Intune detected apps.

.DESCRIPTION
Reads the Intune detected apps inventory through Microsoft Graph, selects apps whose display
name matches the AI app patterns, and lists the managed devices and primary users where they
were found. Report-only by default. With -Apply, the primary users of those devices are added
to an existing assigned (not dynamic) Entra ID security group so they can be targeted for
acceptable use training or a sanctioned-tier rollout.

Requires PowerShell 7 and the Microsoft.Graph.Authentication module. Delegated Graph scopes:
DeviceManagementManagedDevices.Read.All, plus GroupMember.ReadWrite.All when -Apply is used.

.PARAMETER TenantId
Entra ID tenant ID or domain of the customer tenant to audit.

.PARAMETER AiAppPattern
Case-insensitive display name fragments that identify generative AI apps.

.PARAMETER ReportPath
Optional path of a CSV file that receives the findings.

.PARAMETER Apply
Adds the affected primary users to the group given in -ReviewGroupId.

.PARAMETER ReviewGroupId
Object ID of the assigned Entra ID security group that receives the affected users.

.EXAMPLE
./genai-install-reporter.ps1 -TenantId <tenant-id>

.EXAMPLE
./genai-install-reporter.ps1 -TenantId <tenant-id> -Apply -ReviewGroupId <group-object-id>
#>
#Requires -Version 7.0
#Requires -Modules Microsoft.Graph.Authentication
[CmdletBinding(DefaultParameterSetName = 'Report')]
param(
    [Parameter(Mandatory)]
    [string]$TenantId,

    [string[]]$AiAppPattern = @('ChatGPT', 'OpenAI', 'Claude', 'Anthropic', 'Perplexity'),

    [string]$ReportPath,

    [Parameter(Mandatory, ParameterSetName = 'Apply')]
    [switch]$Apply,

    [Parameter(Mandatory, ParameterSetName = 'Apply')]
    [string]$ReviewGroupId
)

$ErrorActionPreference = 'Stop'

$graphRoot = 'https://graph.microsoft.com/v1.0'
$detectedAppsUri = "$graphRoot/deviceManagement/detectedApps"
# Relationship path not confirmed against current Graph docs, see README Unverified section.
$detectedAppDevicesPath = 'managedDevices'

$graphScopes = @('DeviceManagementManagedDevices.Read.All')
if ($Apply) {
    $graphScopes += 'GroupMember.ReadWrite.All'
}

Connect-MgGraph -TenantId $TenantId -Scopes $graphScopes -NoWelcome

$aiAppRegex = ($AiAppPattern | ForEach-Object { [regex]::Escape($_) }) -join '|'

$aiDetectedApps = [System.Collections.Generic.List[hashtable]]::new()
$nextUri = $detectedAppsUri
while ($nextUri) {
    $page = Invoke-MgGraphRequest -Method GET -Uri $nextUri
    foreach ($detectedApp in $page['value']) {
        if ($detectedApp['displayName'] -match $aiAppRegex) {
            $aiDetectedApps.Add($detectedApp)
        }
    }
    $nextUri = $null
    if ($page.ContainsKey('@odata.nextLink')) {
        $nextUri = $page['@odata.nextLink']
    }
}

$aiFindings = [System.Collections.Generic.List[pscustomobject]]::new()
foreach ($aiApp in $aiDetectedApps) {
    $nextUri = "$detectedAppsUri/$($aiApp['id'])/$detectedAppDevicesPath"
    while ($nextUri) {
        $page = Invoke-MgGraphRequest -Method GET -Uri $nextUri
        foreach ($managedDevice in $page['value']) {
            $aiFindings.Add([pscustomobject]@{
                AppName           = $aiApp['displayName']
                AppVersion        = $aiApp['version']
                DeviceName        = $managedDevice['deviceName']
                OperatingSystem   = $managedDevice['operatingSystem']
                UserPrincipalName = $managedDevice['userPrincipalName']
                UserId            = $managedDevice['userId']
            })
        }
        $nextUri = $null
        if ($page.ContainsKey('@odata.nextLink')) {
            $nextUri = $page['@odata.nextLink']
        }
    }
}

if ($aiFindings.Count -eq 0) {
    Write-Warning 'No managed devices with matching generative AI apps were found.'
}

if ($PSBoundParameters.ContainsKey('ReportPath')) {
    $aiFindings | Export-Csv -Path $ReportPath -NoTypeInformation
}

if ($Apply) {
    $groupMembersUri = "$graphRoot/groups/$ReviewGroupId/members?`$select=id"
    $existingMemberIds = [System.Collections.Generic.HashSet[string]]::new()
    $nextUri = $groupMembersUri
    while ($nextUri) {
        $page = Invoke-MgGraphRequest -Method GET -Uri $nextUri
        foreach ($groupMember in $page['value']) {
            [void]$existingMemberIds.Add($groupMember['id'])
        }
        $nextUri = $null
        if ($page.ContainsKey('@odata.nextLink')) {
            $nextUri = $page['@odata.nextLink']
        }
    }

    # Shared devices have an empty userId and cannot be added to a group.
    $affectedUserIds = $aiFindings |
        Where-Object { $_.UserId } |
        Select-Object -ExpandProperty UserId -Unique

    foreach ($affectedUserId in $affectedUserIds) {
        if ($existingMemberIds.Contains($affectedUserId)) {
            continue
        }
        $memberReference = @{ '@odata.id' = "$graphRoot/directoryObjects/$affectedUserId" }
        Invoke-MgGraphRequest -Method POST -Uri "$graphRoot/groups/$ReviewGroupId/members/`$ref" `
            -Body ($memberReference | ConvertTo-Json) -ContentType 'application/json'
        Write-Information "Added user $affectedUserId to group $ReviewGroupId" -InformationAction Continue
    }
}
else {
    Write-Information 'Report-only run. Pass -Apply with -ReviewGroupId to add affected users to the review group.' -InformationAction Continue
}

Disconnect-MgGraph | Out-Null

$aiFindings | Sort-Object AppName, DeviceName
