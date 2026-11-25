# GenAI Install Reporter

Reports which Intune-managed devices have generative AI apps such as ChatGPT or Claude installed, and optionally adds the affected users to a review group.

## Problem

Clients install generative AI apps on work machines and the MSP has no inventory of where or by whom. Without it, nobody can plan a sanctioned business tier, a pilot group, staff training or the blocking of consumer logins. This matters most for healthcare clients where PHI could be pasted into an unapproved tool.

## Prerequisites

- PowerShell 7 and the `Microsoft.Graph.Authentication` module.
- No environment variables are read. The tenant is passed with `-TenantId`.
- Delegated Graph permission `DeviceManagementManagedDevices.Read.All` for the report.
- Delegated Graph permission `GroupMember.ReadWrite.All` for `-Apply`.
- An Entra ID role that can consent to those scopes and read Intune inventory, for example Intune Administrator.
- For `-Apply`: an existing assigned (not dynamic) security group, passed as `-ReviewGroupId`.
- Devices enrolled in Intune with app discovery reporting data.

## Usage

```powershell
# Report only, optional CSV export
./genai-install-reporter.ps1 -TenantId <tenant-id> -ReportPath ./ai-apps.csv

# Add primary users of affected devices to the review group
./genai-install-reporter.ps1 -TenantId <tenant-id> -Apply -ReviewGroupId <group-object-id>
```

- `-AiAppPattern` overrides the default name fragments (ChatGPT, OpenAI, Claude, Anthropic, Perplexity).
- Devices without a primary user are reported but cannot be added to the group.
- The script does not inspect pasted content. DLP controls, a written acceptable use policy and vendor BAA checks are separate work.

## Unverified

- The `managedDevices` relationship under `/deviceManagement/detectedApps/{id}` and the `userId` field on its devices follow the Graph v1.0 model but were not confirmed against a live tenant. The path is held in `$detectedAppDevicesPath`.
