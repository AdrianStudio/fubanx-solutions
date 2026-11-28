<#
.SYNOPSIS
Diagnoses why Windows Pro devices do not step up to Enterprise through subscription activation.

.DESCRIPTION
Connects to each device with PowerShell remoting and reports the edition, Windows license status,
firmware (OEM) key description, Entra and domain join state, recent Store event log errors and the
state of the subscription license scheduled tasks. Each device gets a list of findings that point to
the likely cause. The run is read-only. With -Apply, devices that are not yet Enterprise get their
subscription license tasks enabled (if disabled) and started.

Requires PowerShell 7 on the admin machine, WinRM enabled on the targets and local administrator
rights on each target. No environment variables are read.

.PARAMETER ComputerName
One or more device names to check.

.PARAMETER EventLogDays
Days of Store event log history to scan for Critical and Error events.

.PARAMETER Apply
Enable and start the subscription license tasks. Without this switch nothing is changed.

.EXAMPLE
./e3-activation-checker.ps1 -ComputerName LAPTOP-0001, LAPTOP-0002

.EXAMPLE
./e3-activation-checker.ps1 -ComputerName LAPTOP-0001 -Apply
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string[]]$ComputerName,

    [ValidateRange(1, 90)]
    [int]$EventLogDays = 14,

    [switch]$Apply
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$subscriptionTaskPath = '\Microsoft\Windows\Subscription\'
$storeLogName = 'Microsoft-Windows-Store/Operational'
$windowsApplicationId = '55c92734-d682-4d71-983e-d6ec3f16059f'

# Runs on the target and must stay compatible with the Windows PowerShell 5.1 remoting endpoint.
$deviceDiagnostic = {
    param([int]$EventLogDays, [bool]$ApplyChanges, [string]$TaskPath, [string]$StoreLogName, [string]$WindowsApplicationId)

    $ErrorActionPreference = 'Stop'
    $findings = [System.Collections.Generic.List[string]]::new()
    $actions = [System.Collections.Generic.List[string]]::new()

    $editionId = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').EditionID
    $isEnterprise = $editionId -eq 'Enterprise'

    $installedLicenses = @(Get-CimInstance -ClassName SoftwareLicensingProduct -Filter "ApplicationId='$WindowsApplicationId' AND PartialProductKey IS NOT NULL")
    $licenseSummaries = @($installedLicenses | ForEach-Object {
            "$($_.Name) | channel=$($_.ProductKeyChannel) | licenseStatus=$($_.LicenseStatus)"
        })

    $firmwareKeyDescription = (Get-CimInstance -ClassName SoftwareLicensingService).OA3xOriginalProductKeyDescription

    $joinLines = & dsregcmd.exe /status
    $azureAdJoined = ($joinLines | Select-String -Pattern '^\s*AzureAdJoined\s*:\s*(\w+)' | Select-Object -First 1).Matches[0].Groups[1].Value
    $domainJoined = ($joinLines | Select-String -Pattern '^\s*DomainJoined\s*:\s*(\w+)' | Select-Object -First 1).Matches[0].Groups[1].Value

    # EventLogReader returns null when nothing matches, while Get-WinEvent raises an error in that case.
    $retentionMilliseconds = [long]$EventLogDays * 86400000
    $storeQueryFilter = "*[System[(Level=1 or Level=2) and TimeCreated[timediff(@SystemTime) <= $retentionMilliseconds]]]"
    $storeQuery = [System.Diagnostics.Eventing.Reader.EventLogQuery]::new($StoreLogName, [System.Diagnostics.Eventing.Reader.PathType]::LogName, $storeQueryFilter)
    $storeQuery.ReverseDirection = $true
    $storeReader = [System.Diagnostics.Eventing.Reader.EventLogReader]::new($storeQuery)
    $storeErrorCount = 0
    $recentStoreErrors = [System.Collections.Generic.List[string]]::new()
    while ($null -ne ($storeEvent = $storeReader.ReadEvent())) {
        $storeErrorCount++
        if ($recentStoreErrors.Count -lt 10) {
            $recentStoreErrors.Add("$($storeEvent.TimeCreated.ToString('s')) id=$($storeEvent.Id) $($storeEvent.FormatDescription())")
        }
        $storeEvent.Dispose()
    }
    $storeReader.Dispose()

    $subscriptionTasks = @(Get-ScheduledTask -TaskPath $TaskPath)
    $taskSummaries = @($subscriptionTasks | ForEach-Object {
            $taskInfo = Get-ScheduledTaskInfo -TaskName $_.TaskName -TaskPath $_.TaskPath
            "$($_.TaskName) | state=$($_.State) | lastRun=$($taskInfo.LastRunTime) | lastResult=$($taskInfo.LastTaskResult)"
        })

    if (-not $isEnterprise) {
        if ($azureAdJoined -ne 'YES') {
            $findings.Add("Device is not Entra joined (AzureAdJoined=$azureAdJoined, DomainJoined=$domainJoined). Microsoft documents subscription activation for Entra joined or hybrid joined devices.")
        }
        if ($installedLicenses.Count -eq 0) {
            $findings.Add('No Windows license with a partial product key is installed.')
        }
        foreach ($installedLicense in $installedLicenses) {
            if ($installedLicense.LicenseStatus -ne 1) {
                $findings.Add("Windows license '$($installedLicense.Name)' is not activated (licenseStatus=$($installedLicense.LicenseStatus)). The Pro base license must be activated first.")
            }
        }
        if ([string]::IsNullOrEmpty($firmwareKeyDescription)) {
            $findings.Add('No firmware (OEM) key is present. Subscription activation needs a genuine Pro base license.')
        }
        elseif ($firmwareKeyDescription -notmatch 'Windows (10|11)' -or $firmwareKeyDescription -match 'Home|Core') {
            $findings.Add("Firmware key is '$firmwareKeyDescription', which is not a Windows 10/11 Pro key. Common after a motherboard replacement.")
        }
        if ($storeErrorCount -gt 0) {
            $findings.Add("Store log has $storeErrorCount Critical or Error events in the last $EventLogDays days.")
        }
        if ($subscriptionTasks.Count -eq 0) {
            $findings.Add("No scheduled tasks found under $TaskPath.")
        }

        foreach ($subscriptionTask in $subscriptionTasks) {
            $taskInfo = Get-ScheduledTaskInfo -TaskName $subscriptionTask.TaskName -TaskPath $subscriptionTask.TaskPath
            if ($subscriptionTask.State -eq 'Disabled') {
                $findings.Add("Task $($subscriptionTask.TaskName) is disabled.")
                $actions.Add("Enable task $($subscriptionTask.TaskName)")
                if ($ApplyChanges) {
                    Enable-ScheduledTask -TaskName $subscriptionTask.TaskName -TaskPath $subscriptionTask.TaskPath | Out-Null
                }
            }
            elseif ($taskInfo.LastTaskResult -notin 0, 267011) {
                $findings.Add("Task $($subscriptionTask.TaskName) last result is $($taskInfo.LastTaskResult).")
            }
            $actions.Add("Start task $($subscriptionTask.TaskName)")
            if ($ApplyChanges) {
                Start-ScheduledTask -TaskName $subscriptionTask.TaskName -TaskPath $subscriptionTask.TaskPath
            }
        }

        if ($findings.Count -eq 0) {
            $findings.Add('No cause found locally. Check the E3 assignment and that the user signs in with the licensed work account.')
        }
    }

    [pscustomobject]@{
        EditionId         = $editionId
        AzureAdJoined     = $azureAdJoined
        DomainJoined      = $domainJoined
        Licenses          = $licenseSummaries
        FirmwareKey       = $firmwareKeyDescription
        StoreErrorCount   = $storeErrorCount
        RecentStoreErrors = $recentStoreErrors.ToArray()
        SubscriptionTasks = $taskSummaries
        Findings          = $findings.ToArray()
        Actions           = $actions.ToArray()
        Applied           = $ApplyChanges
    }
}

foreach ($deviceName in $ComputerName) {
    Invoke-Command -ComputerName $deviceName -ScriptBlock $deviceDiagnostic -ArgumentList $EventLogDays, $Apply.IsPresent, $subscriptionTaskPath, $storeLogName, $windowsApplicationId
}
