<#
.SYNOPSIS
Detects a missing SIM or missing mobile broadband adapter and optionally restarts the WWAN stack.

.DESCRIPTION
Checks the Wireless WAN network adapter and the SIM state reported by netsh mbn.
Each run appends one JSON line to ReportPath so failure patterns can be analysed across a fleet.
By default the script only reports. With -Apply it restarts the WwanSvc service and the
mobile broadband adapter (or rescans devices when the adapter is absent), waits, and checks again.
The exit code is 1 when the final state is not healthy, so a scheduler or RMM can raise an alert.
The COMPUTERNAME environment variable, set by Windows, identifies the host in the report and messages.

.PARAMETER ReportPath
File that receives one JSON line per run. The parent directory must exist.

.PARAMETER RecheckSeconds
Seconds to wait after remediation before the state is checked again (5 to 300).

.PARAMETER Apply
Restart WwanSvc and the adapter when a fault is detected. Requires an elevated session.

.EXAMPLE
./wwan-sim-watchdog.ps1 -ReportPath C:\ProgramData\WwanWatchdog\report.jsonl -RecheckSeconds 30

.EXAMPLE
./wwan-sim-watchdog.ps1 -ReportPath C:\ProgramData\WwanWatchdog\report.jsonl -RecheckSeconds 30 -Apply
#>
#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ReportPath,

    [Parameter(Mandatory)]
    [ValidateRange(5, 300)]
    [int]$RecheckSeconds,

    [switch]$Apply
)

$ErrorActionPreference = 'Stop'

$wwanMediaType = 'Wireless WAN'
$wwanServiceName = 'WwanSvc'
$noSimPattern = 'sim\s+not\s+inserted|not\s+inserted|no\s+sim|sim\s+(is\s+)?(missing|removed)'

$currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$isElevated = ([Security.Principal.WindowsPrincipal]$currentIdentity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($Apply -and -not $isElevated) {
    throw '-Apply requires an elevated PowerShell session.'
}

$checks = @()
$actions = @()

for ($pass = 0; $pass -le 1; $pass++) {
    $wwanAdapter = Get-NetAdapter -Physical |
        Where-Object { $_.PhysicalMediaType -eq $wwanMediaType } |
        Select-Object -First 1

    $mbnInterfaceText = (netsh mbn show interfaces) -join "`n"
    $mbnReadyInfoText = (netsh mbn show readyinfo '*') -join "`n"

    if ($null -eq $wwanAdapter) {
        $state = 'AdapterMissing'
    }
    elseif ("$mbnInterfaceText`n$mbnReadyInfoText" -match $noSimPattern) {
        $state = 'NoSim'
    }
    else {
        $state = 'Healthy'
    }

    $checks += [ordered]@{
        Pass            = $pass
        State           = $state
        AdapterName     = if ($null -eq $wwanAdapter) { $null } else { $wwanAdapter.Name }
        AdapterStatus   = if ($null -eq $wwanAdapter) { $null } else { [string]$wwanAdapter.Status }
        DriverVersion   = if ($null -eq $wwanAdapter) { $null } else { $wwanAdapter.DriverVersionString }
        MbnInterfaces   = $mbnInterfaceText
        MbnReadyInfo    = $mbnReadyInfoText
    }

    if ($state -eq 'Healthy' -or -not $Apply -or $pass -eq 1) {
        break
    }

    Restart-Service -Name $wwanServiceName -Force
    $actions += "Restarted service $wwanServiceName"

    if ($null -eq $wwanAdapter) {
        pnputil /scan-devices | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "pnputil /scan-devices failed with exit code $LASTEXITCODE."
        }
        $actions += 'Rescanned devices with pnputil'
    }
    else {
        Restart-NetAdapter -Name $wwanAdapter.Name
        $actions += "Restarted adapter $($wwanAdapter.Name)"
    }

    Start-Sleep -Seconds $RecheckSeconds
}

$stateBefore = $checks[0].State
$stateAfter = $checks[-1].State

$reportEntry = [ordered]@{
    Timestamp    = (Get-Date).ToUniversalTime().ToString('o')
    ComputerName = $env:COMPUTERNAME
    ApplyMode    = [bool]$Apply
    StateBefore  = $stateBefore
    StateAfter   = $stateAfter
    Actions      = $actions
    Checks       = $checks
}

Add-Content -Path $ReportPath -Value ($reportEntry | ConvertTo-Json -Compress -Depth 5) -Encoding utf8

if ($stateBefore -eq 'Healthy') {
    Write-Output "$env:COMPUTERNAME: cellular adapter and SIM look healthy."
    exit 0
}

if (-not $Apply) {
    Write-Warning "$env:COMPUTERNAME: state is $stateBefore. Run with -Apply to restart $wwanServiceName and the adapter."
    exit 1
}

if ($stateAfter -eq 'Healthy') {
    Write-Output "$env:COMPUTERNAME: recovered from $stateBefore after restarting the WWAN stack."
    exit 0
}

Write-Warning "$env:COMPUTERNAME: still $stateAfter after remediation. Physical reseating or hardware service is likely needed."
exit 1
