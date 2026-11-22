# Purpose: read-only Hyper-V migration readiness report for VMware VMs.
# Inputs: vsphere_server, vsphere_user, vsphere_password, datacenter_name,
#         virtual_machine_names (optional limits: hyperv_max_vcpus, hyperv_max_memory_mb).
# Usage: tofu init && tofu plan && tofu apply, then tofu output -json readiness_report.
# The module only queries vCenter data sources and creates no infrastructure.

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    vsphere = {
      source  = "hashicorp/vsphere"
      version = "~> 2.8"
    }
  }
}

variable "vsphere_server" {
  description = "vCenter FQDN or IP address."
  type        = string
}

variable "vsphere_user" {
  description = "vCenter account with read-only access to the inventory."
  type        = string
}

variable "vsphere_password" {
  description = "Password of the vCenter account."
  type        = string
  sensitive   = true
}

variable "datacenter_name" {
  description = "vCenter datacenter that contains the virtual machines."
  type        = string
}

variable "virtual_machine_names" {
  description = "Inventory names of the virtual machines to assess."
  type        = list(string)

  validation {
    condition     = length(var.virtual_machine_names) > 0
    error_message = "virtual_machine_names must contain at least one name."
  }
}

variable "hyperv_max_vcpus" {
  description = "Maximum virtual processors per VM on the target Hyper-V generation 2 host."
  type        = number
  default     = 240
}

variable "hyperv_max_memory_mb" {
  description = "Maximum memory per VM in MB on the target Hyper-V generation 2 host (12 TB)."
  type        = number
  default     = 12582912
}

provider "vsphere" {
  vsphere_server = var.vsphere_server
  user           = var.vsphere_user
  password       = var.vsphere_password
}

data "vsphere_datacenter" "source" {
  name = var.datacenter_name
}

data "vsphere_virtual_machine" "source" {
  for_each      = toset(var.virtual_machine_names)
  name          = each.value
  datacenter_id = data.vsphere_datacenter.source.id
}

locals {
  readiness_report = {
    for vm_name, vm in data.vsphere_virtual_machine.source : vm_name => {
      guest_id             = vm.guest_id
      hyperv_generation    = vm.firmware == "efi" ? 2 : 1
      vcpus                = vm.num_cpus
      memory_mb            = vm.memory
      disk_count           = length(vm.disks)
      disk_total_gb        = sum([for disk in vm.disks : disk.size])
      network_adapter_count = length(vm.network_interface_types)
      blockers = compact([
        vm.scsi_bus_sharing != "noSharing" ? "Shared SCSI bus requires shared VHDX or a redesigned guest cluster." : "",
        vm.num_cpus > var.hyperv_max_vcpus ? "vCPU count exceeds the Hyper-V limit." : "",
        vm.memory > var.hyperv_max_memory_mb ? "Memory exceeds the Hyper-V limit." : "",
        vm.firmware == "efi" && !endswith(vm.guest_id, "_64Guest") ? "EFI firmware with a 32-bit guest cannot run as generation 2." : "",
        startswith(vm.guest_id, "otherGuest") ? "Guest OS is not identified in vCenter, verify Hyper-V support manually." : "",
      ])
    }
  }

  blocked_virtual_machines = sort([
    for vm_name, report in local.readiness_report : vm_name if length(report.blockers) > 0
  ])

  ready_virtual_machines = sort([
    for vm_name, report in local.readiness_report : vm_name if length(report.blockers) == 0
  ])
}

output "readiness_report" {
  description = "Per-VM Hyper-V generation, sizing and blockers."
  value       = local.readiness_report
}

output "blocked_virtual_machines" {
  description = "VMs with at least one blocker to resolve before migration."
  value       = local.blocked_virtual_machines
}

output "ready_virtual_machines" {
  description = "VMs without detected blockers."
  value       = local.ready_virtual_machines
}

output "total_disk_gb_to_convert" {
  description = "Sum of provisioned disk size in GB across all assessed VMs."
  value       = sum([for report in local.readiness_report : report.disk_total_gb])
}
