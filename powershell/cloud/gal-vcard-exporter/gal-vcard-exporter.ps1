#Requires -Version 7.0
#Requires -Modules Microsoft.Graph.Authentication
<#
.SYNOPSIS
Exports the enabled Entra ID member users with a mailbox as one vCard 3.0 file each.

.DESCRIPTION
Reads users from Microsoft Graph and compares them with the vCard files already present in
OutputDirectory. The vCard UID is the Entra object ID, so a CardDAV server that serves the
directory never creates duplicates. Files of disabled or deleted users are listed as removals.
The default run only reports added, changed and removed contacts. With -Apply the files are
written and obsolete files are deleted. Only files carrying the export marker are ever touched.

.PARAMETER TenantId
Entra tenant ID or verified domain to sign in to.

.PARAMETER OutputDirectory
Directory that holds the exported .vcf files, one per user.

.PARAMETER MaxRemovalPercent
Abort -Apply when more than this percentage of the existing exported files would be removed.
Protects against deleting the whole address book after a partial or empty Graph response.

.PARAMETER Apply
Write new and changed vCard files and delete files of users that left the directory.

.EXAMPLE
./gal-vcard-exporter.ps1 -TenantId <tenant-id> -OutputDirectory ./gal

.EXAMPLE
./gal-vcard-exporter.ps1 -TenantId <tenant-id> -OutputDirectory ./gal -Apply

Requires the delegated Microsoft Graph permission User.Read.All.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$TenantId,

    [Parameter(Mandatory)]
    [string]$OutputDirectory,

    [ValidateRange(0, 100)]
    [int]$MaxRemovalPercent = 20,

    [switch]$Apply
)

$ErrorActionPreference = 'Stop'

$usersUri = 'https://graph.microsoft.com/v1.0/users?$filter=accountEnabled eq true' +
    '&$select=id,displayName,givenName,surname,mail,jobTitle,department,companyName,mobilePhone,businessPhones,userType' +
    '&$top=999'
$exportMarker = 'X-GAL-EXPORT:entra-id'
$outputPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)

Connect-MgGraph -TenantId $TenantId -Scopes 'User.Read.All' -NoWelcome

$directoryUsers = [System.Collections.Generic.List[hashtable]]::new()
$nextUri = $usersUri
while ($nextUri) {
    $page = Invoke-MgGraphRequest -Method GET -Uri $nextUri -OutputType Hashtable
    foreach ($directoryUser in $page['value']) {
        $directoryUsers.Add($directoryUser)
    }
    $nextUri = if ($page.ContainsKey('@odata.nextLink')) { $page['@odata.nextLink'] } else { $null }
}
$null = Disconnect-MgGraph

$galUsers = @($directoryUsers | Where-Object { $_['userType'] -eq 'Member' -and $_['mail'] })
if ($galUsers.Count -eq 0) {
    throw 'Microsoft Graph returned no enabled member users with a mailbox. Refusing to continue.'
}

# REV is left out on purpose: a timestamp would make every card differ on every run.
$desiredCards = @{}
foreach ($galUser in $galUsers) {
    $escapedValues = @{}
    foreach ($field in 'displayName', 'givenName', 'surname', 'mail', 'jobTitle', 'department', 'companyName') {
        $escapedValues[$field] = if ($galUser[$field]) {
            $galUser[$field] -replace '\\', '\\' -replace ';', '\;' -replace ',', '\,' -replace '\r?\n', '\n'
        } else {
            ''
        }
    }

    $cardLines = [System.Collections.Generic.List[string]]::new()
    $cardLines.Add('BEGIN:VCARD')
    $cardLines.Add('VERSION:3.0')
    $cardLines.Add("UID:urn:uuid:$($galUser['id'])")
    $cardLines.Add("FN:$($escapedValues['displayName'])")
    $cardLines.Add("N:$($escapedValues['surname']);$($escapedValues['givenName']);;;")
    $cardLines.Add("EMAIL;TYPE=INTERNET,WORK:$($escapedValues['mail'])")
    if ($escapedValues['companyName'] -or $escapedValues['department']) {
        $cardLines.Add("ORG:$($escapedValues['companyName']);$($escapedValues['department'])")
    }
    if ($escapedValues['jobTitle']) {
        $cardLines.Add("TITLE:$($escapedValues['jobTitle'])")
    }
    if ($galUser['mobilePhone']) {
        $cardLines.Add("TEL;TYPE=CELL,WORK:$($galUser['mobilePhone'])")
    }
    foreach ($businessPhone in $galUser['businessPhones']) {
        $cardLines.Add("TEL;TYPE=WORK,VOICE:$businessPhone")
    }
    $cardLines.Add($exportMarker)
    $cardLines.Add('END:VCARD')

    $desiredCards[$galUser['id']] = ($cardLines -join "`r`n") + "`r`n"
}

$existingFiles = @{}
if (Test-Path -LiteralPath $outputPath) {
    foreach ($file in Get-ChildItem -LiteralPath $outputPath -Filter '*.vcf' -File) {
        if (Select-String -LiteralPath $file.FullName -Pattern $exportMarker -SimpleMatch -Quiet) {
            $existingFiles[$file.BaseName] = $file.FullName
        }
    }
}

$changes = [System.Collections.Generic.List[pscustomobject]]::new()
foreach ($contactId in $desiredCards.Keys) {
    $displayName = ($desiredCards[$contactId] -split "`r`n" | Where-Object { $_ -like 'FN:*' }).Substring(3)
    if (-not $existingFiles.ContainsKey($contactId)) {
        $changes.Add([pscustomobject]@{ Action = 'Add'; ContactId = $contactId; DisplayName = $displayName })
    }
    elseif ((Get-Content -LiteralPath $existingFiles[$contactId] -Raw) -ne $desiredCards[$contactId]) {
        $changes.Add([pscustomobject]@{ Action = 'Update'; ContactId = $contactId; DisplayName = $displayName })
    }
}
foreach ($contactId in $existingFiles.Keys) {
    if (-not $desiredCards.ContainsKey($contactId)) {
        $displayName = (Select-String -LiteralPath $existingFiles[$contactId] -Pattern '^FN:').Line.Substring(3)
        $changes.Add([pscustomobject]@{ Action = 'Remove'; ContactId = $contactId; DisplayName = $displayName })
    }
}

$changes | Sort-Object Action, DisplayName

$removalCount = @($changes | Where-Object Action -eq 'Remove').Count
Write-Information "Directory users: $($desiredCards.Count). Existing files: $($existingFiles.Count). Changes: $($changes.Count) (removals: $removalCount)." -InformationAction Continue

if (-not $Apply) {
    Write-Information 'Report only. Run again with -Apply to write the changes.' -InformationAction Continue
    return
}

if ($existingFiles.Count -gt 0 -and (100 * $removalCount / $existingFiles.Count) -gt $MaxRemovalPercent) {
    throw "Refusing to remove $removalCount of $($existingFiles.Count) files: above the $MaxRemovalPercent percent limit."
}

$null = New-Item -ItemType Directory -Path $outputPath -Force
$utf8WithoutBom = [System.Text.UTF8Encoding]::new($false)
foreach ($change in $changes) {
    $cardPath = Join-Path $outputPath "$($change.ContactId).vcf"
    if ($change.Action -eq 'Remove') {
        Remove-Item -LiteralPath $cardPath
    }
    else {
        [System.IO.File]::WriteAllText($cardPath, $desiredCards[$change.ContactId], $utf8WithoutBom)
    }
}
Write-Information "Applied $($changes.Count) changes in $outputPath." -InformationAction Continue
