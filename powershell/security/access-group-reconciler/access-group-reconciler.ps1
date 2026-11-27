#Requires -Version 7.0
<#
.SYNOPSIS
Reconciles approved access requests with the membership of an Entra ID group and writes an audit log.

.DESCRIPTION
Compares a CSV export of approved ITSM requests (columns UserPrincipalName and TicketId) with the
user members of an Entra ID group read through Microsoft Graph. Each user is reported as
ApprovedNotInGroup, InGroupNoApproval or Aligned, and every row is written to the audit CSV with
its ticket ID.

The default run is report-only. With -Apply, approved users missing from the group are added and
their membership is checked afterwards. Members without an approved request are never removed.

Requires the environment variable GRAPH_ACCESS_TOKEN, a Microsoft Graph bearer token with
GroupMember.Read.All and User.Read.All (add GroupMember.ReadWrite.All for -Apply). The group must
be assigned, not dynamic and not synchronized from on-premises Active Directory.

.PARAMETER GroupId
Object ID of the Entra ID group that grants access to the application.

.PARAMETER ApprovedRequestsPath
CSV file with the approved requests exported from the ITSM system.

.PARAMETER AuditLogPath
Path of the audit CSV that is written by every run.

.PARAMETER Apply
Adds approved users that are missing from the group. Without this switch nothing is changed.

.EXAMPLE
./access-group-reconciler.ps1 -GroupId <group-object-id> -ApprovedRequestsPath ./approved.csv -AuditLogPath ./audit.csv

.EXAMPLE
./access-group-reconciler.ps1 -GroupId <group-object-id> -ApprovedRequestsPath ./approved.csv -AuditLogPath ./audit.csv -Apply
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$GroupId,

    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$ApprovedRequestsPath,

    [Parameter(Mandatory)]
    [string]$AuditLogPath,

    [switch]$Apply
)

$ErrorActionPreference = 'Stop'

$graphBaseUri = 'https://graph.microsoft.com/v1.0'
$graphTimeoutSeconds = 60
$requiredColumns = @('UserPrincipalName', 'TicketId')

if (-not (Test-Path -Path 'env:GRAPH_ACCESS_TOKEN')) {
    throw 'The environment variable GRAPH_ACCESS_TOKEN is not set.'
}
$graphHeaders = @{ Authorization = "Bearer $env:GRAPH_ACCESS_TOKEN" }

$approvedRequests = @(Import-Csv -LiteralPath $ApprovedRequestsPath)
if ($approvedRequests.Count -eq 0) {
    throw "No approved requests found in $ApprovedRequestsPath."
}
$presentColumns = $approvedRequests[0].PSObject.Properties.Name
foreach ($requiredColumn in $requiredColumns) {
    if ($requiredColumn -notin $presentColumns) {
        throw "Column $requiredColumn is missing from $ApprovedRequestsPath."
    }
}

# A user can have several tickets, so the IDs are joined to keep every ticket in the audit trail.
$approvedTicketsByUpn = @{}
foreach ($approvedRequest in $approvedRequests) {
    $approvedUpn = $approvedRequest.UserPrincipalName.Trim().ToLowerInvariant()
    if ($approvedTicketsByUpn.ContainsKey($approvedUpn)) {
        $approvedTicketsByUpn[$approvedUpn] += ";$($approvedRequest.TicketId)"
    }
    else {
        $approvedTicketsByUpn[$approvedUpn] = $approvedRequest.TicketId
    }
}

$groupMemberIdsByUpn = @{}
$membersUri = "$graphBaseUri/groups/$GroupId/members/microsoft.graph.user?`$select=id,userPrincipalName&`$top=999"
while ($membersUri) {
    $membersPage = Invoke-RestMethod -Method Get -Uri $membersUri -Headers $graphHeaders -TimeoutSec $graphTimeoutSeconds
    foreach ($member in $membersPage.value) {
        $groupMemberIdsByUpn[$member.userPrincipalName.ToLowerInvariant()] = $member.id
    }
    if ($membersPage.PSObject.Properties.Name -contains '@odata.nextLink') {
        $membersUri = $membersPage.'@odata.nextLink'
    }
    else {
        $membersUri = $null
    }
}

$auditRecords = [System.Collections.Generic.List[object]]::new()
$auditTimestamp = (Get-Date).ToUniversalTime().ToString('o')

foreach ($approvedUpn in $approvedTicketsByUpn.Keys | Sort-Object) {
    $ticketIds = $approvedTicketsByUpn[$approvedUpn]

    if ($groupMemberIdsByUpn.ContainsKey($approvedUpn)) {
        $auditRecords.Add([pscustomobject]@{
            Timestamp = $auditTimestamp; UserPrincipalName = $approvedUpn; TicketId = $ticketIds
            Finding = 'Aligned'; Action = 'None'; Verified = ''
        })
        continue
    }

    if (-not $Apply) {
        $auditRecords.Add([pscustomobject]@{
            Timestamp = $auditTimestamp; UserPrincipalName = $approvedUpn; TicketId = $ticketIds
            Finding = 'ApprovedNotInGroup'; Action = 'WouldAdd'; Verified = ''
        })
        continue
    }

    $escapedUpn = [uri]::EscapeDataString($approvedUpn)
    $approvedUser = Invoke-RestMethod -Method Get -Uri "$graphBaseUri/users/${escapedUpn}?`$select=id" -Headers $graphHeaders -TimeoutSec $graphTimeoutSeconds

    $addMemberBody = @{ '@odata.id' = "$graphBaseUri/directoryObjects/$($approvedUser.id)" } | ConvertTo-Json
    Invoke-RestMethod -Method Post -Uri "$graphBaseUri/groups/$GroupId/members/`$ref" -Headers $graphHeaders `
        -ContentType 'application/json' -Body $addMemberBody -TimeoutSec $graphTimeoutSeconds | Out-Null

    $membershipCheckBody = @{ ids = @($GroupId) } | ConvertTo-Json
    $membershipCheck = Invoke-RestMethod -Method Post -Uri "$graphBaseUri/users/$($approvedUser.id)/checkMemberObjects" -Headers $graphHeaders `
        -ContentType 'application/json' -Body $membershipCheckBody -TimeoutSec $graphTimeoutSeconds

    $auditRecords.Add([pscustomobject]@{
        Timestamp = $auditTimestamp; UserPrincipalName = $approvedUpn; TicketId = $ticketIds
        Finding = 'ApprovedNotInGroup'; Action = 'Added'; Verified = ($GroupId -in $membershipCheck.value)
    })
}

foreach ($memberUpn in $groupMemberIdsByUpn.Keys | Sort-Object) {
    if (-not $approvedTicketsByUpn.ContainsKey($memberUpn)) {
        $auditRecords.Add([pscustomobject]@{
            Timestamp = $auditTimestamp; UserPrincipalName = $memberUpn; TicketId = ''
            Finding = 'InGroupNoApproval'; Action = 'ReviewManually'; Verified = ''
        })
    }
}

$auditRecords | Export-Csv -LiteralPath $AuditLogPath -NoTypeInformation -Encoding utf8
$auditRecords | Format-Table -AutoSize

if (-not $Apply) {
    Write-Warning 'Report-only run: no group membership was changed. Use -Apply to add approved users.'
}
