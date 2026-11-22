# VM Teardown Guard

PowerShell 7 script that removes a named list of VMs from one explicitly chosen vCenter, with checks that stop it from touching the wrong environment.

## Problem

PowerCLI can run in multiple default server mode. `Get-VM` without `-Server` then returns VMs from every connected vCenter. When production and DR use the same VM names, a DR teardown script can power off and delete production VMs. Relying on the administrator to remember to disconnect has already caused outages.

## Prerequisites

- PowerShell 7.0 or later.
- VMware PowerCLI module `VMware.VimAutomation.Core`.
- No environment variables are read.
- vCenter account with permission to read inventory, power off VMs and delete VMs (`Virtual machine.Interaction.Power Off`, `Virtual machine.Inventory.Remove`, and `Datastore.Delete file` for `-DeletePermanently`).
- A text file with one VM name per line.
- `-VCenterServer` must match the name PowerCLI reports for the connection exactly.

## Usage

```powershell
# Report only (default): lists the VMs, their cluster and power state
./vm-teardown-guard.ps1 -VCenterServer <vcenter-fqdn> -VmListPath ./drtest.txt -ExpectedClusterName <dr-cluster>

# Power off and remove from inventory, after typing the confirmation token
./vm-teardown-guard.ps1 -VCenterServer <vcenter-fqdn> -VmListPath ./drtest.txt -ExpectedClusterName <dr-cluster> -Apply

# Also delete the files from the datastore
./vm-teardown-guard.ps1 -VCenterServer <vcenter-fqdn> -VmListPath ./drtest.txt -ExpectedClusterName <dr-cluster> -DeletePermanently -Apply
```

The script aborts without changes when:

- A connection to any other vCenter is open.
- A listed name is missing, duplicated in the list, or matches more than one VM.
- Any matched VM is outside the expected cluster.
- The typed token `DELETE <vcenter> <vm count>` does not match (with `-Apply`).
