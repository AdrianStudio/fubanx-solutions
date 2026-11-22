<#
.SYNOPSIS
Tears down a named list of VMs on one explicitly specified vCenter, with guards against acting on the wrong vCenter.

.DESCRIPTION
Forces PowerCLI single default server mode for the session and aborts if a connection to any other vCenter
is open. Every PowerCLI call receives the explicit -Server object. Each name in the list must match exactly
one VM, and every matched VM must be in the expected cluster, otherwise nothing is changed.

The default run only reports the VMs that would be affected. With -Apply the script asks for a typed
confirmation token, powers off running VMs (hard power off) and removes them from inventory.
Add -DeletePermanently to also delete their files from the datastore.

Requires the VMware.VimAutomation.Core module. Credentials are requested by Connect-VIServer when no
session to the vCenter exists. No environment variables are read.

.PARAMETER VCenterServer
Exact name of the vCenter to operate on, as it appears in the PowerCLI connection (for example the FQDN).

.PARAMETER VmListPath
Text file with one VM name per line. Blank lines are ignored.

.PARAMETER ExpectedClusterName
Cluster that every listed VM must belong to. Acts as a second check that the right site was targeted.

.PARAMETER DeletePermanently
Delete the VM files from disk instead of only removing the VMs from inventory. Only used with -Apply.

.PARAMETER Apply
Power off and remove the VMs. Without this switch the script only reports.

.EXAMPLE
./vm-teardown-guard.ps1 -VCenterServer vcenter-dr.example.com -VmListPath ./drtest.txt -ExpectedClusterName DR-Cluster

.EXAMPLE
./vm-teardown-guard.ps1 -VCenterServer vcenter-dr.example.com -VmListPath ./drtest.txt -ExpectedClusterName DR-Cluster -DeletePermanently -Apply
#>
#Requires -Version 7.0
#Requires -Modules VMware.VimAutomation.Core
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$VCenterServer,

    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$VmListPath,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ExpectedClusterName,

    [switch]$DeletePermanently,

    [switch]$Apply
)

$ErrorActionPreference = 'Stop'

# Session scope only: the persistent user setting is left untouched.
Set-PowerCLIConfiguration -DefaultVIServerMode Single -Scope Session -Confirm:$false | Out-Null

$foreignConnections = @($global:DefaultVIServers | Where-Object { $_.IsConnected -and $_.Name -ne $VCenterServer })
if ($foreignConnections.Count -gt 0) {
    $foreignNames = $foreignConnections.Name -join ', '
    throw "Connected to other vCenter servers: $foreignNames. Run Disconnect-VIServer for them and start again."
}

$targetVmNames = @(Get-Content -LiteralPath $VmListPath | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
if ($targetVmNames.Count -eq 0) {
    throw "No VM names found in $VmListPath."
}
$duplicateNames = @($targetVmNames | Group-Object | Where-Object Count -gt 1 | Select-Object -ExpandProperty Name)
if ($duplicateNames.Count -gt 0) {
    throw "Duplicate names in $VmListPath : $($duplicateNames -join ', ')"
}

$existingSession = $global:DefaultVIServers | Where-Object { $_.IsConnected -and $_.Name -eq $VCenterServer } | Select-Object -First 1
$connectedByScript = $null -eq $existingSession

try {
    if ($connectedByScript) {
        $viServer = Connect-VIServer -Server $VCenterServer
    }
    else {
        $viServer = $existingSession
    }

    $targetVms = @(Get-VM -Server $viServer | Where-Object { $_.Name -in $targetVmNames })

    $missingVmNames = @($targetVmNames | Where-Object { $_ -notin $targetVms.Name })
    if ($missingVmNames.Count -gt 0) {
        throw "VMs not found on $($viServer.Name): $($missingVmNames -join ', ')"
    }
    if ($targetVms.Count -ne $targetVmNames.Count) {
        throw "Expected $($targetVmNames.Count) VMs but $($targetVms.Count) matched on $($viServer.Name). Some names exist more than once (different folders)."
    }

    $teardownPlan = foreach ($targetVm in $targetVms) {
        [pscustomobject]@{
            Name         = $targetVm.Name
            PowerState   = $targetVm.PowerState
            Cluster      = (Get-Cluster -VM $targetVm -Server $viServer).Name
            VMHost       = $targetVm.VMHost.Name
            VCenter      = $viServer.Name
        }
    }

    $outsideExpectedCluster = @($teardownPlan | Where-Object { $_.Cluster -ne $ExpectedClusterName })
    if ($outsideExpectedCluster.Count -gt 0) {
        $outsideExpectedCluster | Format-Table -AutoSize | Out-String | Write-Host
        throw "$($outsideExpectedCluster.Count) VMs are not in cluster '$ExpectedClusterName'. Nothing was changed."
    }

    $teardownPlan | Format-Table -AutoSize | Out-String | Write-Host

    $removalMode = if ($DeletePermanently) { 'removed from inventory AND deleted from disk' } else { 'removed from inventory' }

    if (-not $Apply) {
        Write-Host "Report only: $($targetVms.Count) VMs on $($viServer.Name) would be powered off and $removalMode. Use -Apply to proceed."
        return
    }

    $confirmationToken = "DELETE $($viServer.Name) $($targetVms.Count)"
    Write-Host "$($targetVms.Count) VMs on $($viServer.Name) will be powered off and $removalMode."
    $typedToken = Read-Host "Type '$confirmationToken' to continue"
    if ($typedToken -cne $confirmationToken) {
        throw 'Confirmation token did not match. Nothing was changed.'
    }

    $poweredOnVms = @($targetVms | Where-Object PowerState -eq 'PoweredOn')
    if ($poweredOnVms.Count -gt 0) {
        Stop-VM -VM $poweredOnVms -Server $viServer -Confirm:$false | Out-Null
    }

    Remove-VM -VM $targetVms -Server $viServer -DeletePermanently:$DeletePermanently -Confirm:$false
    Write-Host "Done: $($targetVms.Count) VMs $removalMode on $($viServer.Name)."
}
finally {
    if ($connectedByScript -and $null -ne $viServer) {
        Disconnect-VIServer -Server $viServer -Confirm:$false
    }
}
