# VMware to Hyper-V Readiness Report

OpenTofu/Terraform module that reads VMs from vCenter and reports which ones can move to Hyper-V and which have blockers.

## Problem
Teams leaving VMware after renewal price increases need to know which VMs migrate cleanly to Hyper-V. Today this is checked by hand, VM by VM, which delays planning of migration waves. Shared disks, 32-bit EFI guests and oversized VMs are found late, during cutover.

## Prerequisites
- `vsphere_server`: vCenter FQDN or IP address.
- `vsphere_user`: vCenter account with the built-in Read-only role on the datacenter and VMs.
- `vsphere_password`: password of that account (sensitive, no default).
- `datacenter_name`: datacenter that contains the VMs.
- `virtual_machine_names`: list of VM inventory names to assess.
- `hyperv_max_vcpus` (optional): vCPU limit, default 240.
- `hyperv_max_memory_mb` (optional): memory limit in MB, default 12582912.
- OpenTofu or Terraform 1.5 or later, provider `hashicorp/vsphere` 2.8 or later.
- Network access from the runner to vCenter over HTTPS with a trusted certificate.

## Usage
```hcl
module "hyperv_readiness" {
  source = "./terraform/cloud/vmware-hyperv-readiness"

  vsphere_server        = "<vcenter-fqdn>"
  vsphere_user          = "<readonly-user>"
  vsphere_password      = var.vsphere_password
  datacenter_name       = "<datacenter>"
  virtual_machine_names = ["<vm-name-1>", "<vm-name-2>"]
}
```

```sh
tofu init
tofu plan
tofu apply
tofu output -json readiness_report
tofu output blocked_virtual_machines
```

## Inputs
- `vsphere_server`, `vsphere_user`, `vsphere_password`, `datacenter_name`, `virtual_machine_names`, `hyperv_max_vcpus`, `hyperv_max_memory_mb`.

## Outputs
- `readiness_report`: per VM guest ID, Hyper-V generation, vCPUs, memory, disk totals and blockers.
- `blocked_virtual_machines`: VMs with blockers.
- `ready_virtual_machines`: VMs without detected blockers.
- `total_disk_gb_to_convert`: total provisioned disk size in GB.
