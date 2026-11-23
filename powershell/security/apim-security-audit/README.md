# APIM Security Audit

PowerShell script that audits Azure API Management instances and Key Vaults for exposure left open by the classic tier advisory.

## Problem

Administrators of classic tier APIM instances were told to assume stored secrets were exposed, with no logs showing what was accessed. They have no quick way to list which instances still expose legacy management access, which secrets live inside APIM, or which Key Vaults record no audit events. This script gives that inventory per subscription.

## Prerequisites

- PowerShell 7.0 or later.
- Az.Accounts module, with an active session from `Connect-AzAccount`. The script reads no environment variables and takes its credentials from that session.
- Reader role on each audited subscription for the report.
- API Management Service Contributor (permission `Microsoft.ApiManagement/service/tenant/write`) on the instances, only for `-Apply`.

## Usage

```powershell
Connect-AzAccount

# Report only
./apim-security-audit.ps1 -SubscriptionId '<subscription-id>'

# Disable the direct management API on classic tier instances where it is enabled
./apim-security-audit.ps1 -SubscriptionId '<subscription-id-1>','<subscription-id-2>' -Apply
```

The script writes one finding object per issue (Resource, Check, Severity, Detail, Action). Pipe it to `Export-Csv` to keep the report.

- It does not detect use of the exploited legacy API, which has no logs.
- It does not rotate secrets. Rotation of every secret held in APIM remains manual.

## Unverified

- `ClassicTierNames` (Developer, Basic, Standard, Premium) is the assumed meaning of classic tier. Microsoft's advisory text was not available.
- Treating `tenant/access` (direct management API) as the relevant legacy surface is an assumption. The advisory does not name the API.
- `If-Match: *` on the `tenant/access` PATCH is used instead of a fetched ETag.
