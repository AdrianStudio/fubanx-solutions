# Breakglass MFA Auditor

A PowerShell 7 script that audits the MFA setup of Entra ID break-glass accounts and, on request, removes SMS and shared TOTP methods from them.

## Problem
Break-glass accounts are often protected with an SMS number or a TOTP seed shared by several admins, because hardware keys are hard to reach in an emergency. Nobody verifies how many FIDO2 keys are really enrolled or whether a Conditional Access policy requires phishing-resistant authentication for these accounts. The weak methods stay registered unnoticed.

## Prerequisites
- PowerShell 7.0 or later.
- Modules: `Microsoft.Graph.Authentication`, `Microsoft.Graph.Groups`, `Microsoft.Graph.Identity.SignIns`.
- No environment variables. The script signs in interactively with `Connect-MgGraph`.
- Delegated Graph scopes: `GroupMember.Read.All`, `User.Read.All`, `Policy.Read.All`, `UserAuthenticationMethod.Read.All`.
- With `-Apply`: `UserAuthenticationMethod.ReadWrite.All` and the Authentication Administrator or Privileged Authentication Administrator role.
- A dedicated group that contains only the break-glass user accounts. Nested groups are not expanded.

## Usage
```powershell
# Report only, nothing is changed
./breakglass-mfa-auditor.ps1 -BreakGlassGroupId <group-object-id> -MinimumFido2Keys 3

# Remove phone and software OATH methods from accounts that already hold enough FIDO2 keys
./breakglass-mfa-auditor.ps1 -BreakGlassGroupId <group-object-id> -MinimumFido2Keys 3 -Apply
```

The script outputs one object per account with these findings:
- `AccountDisabled`, `SyncedFromOnPremises`
- `FewerThanNFido2Keys`
- `PhoneMethodRegistered`, `SoftwareOathMethodRegistered`
- `NoAuthenticationStrengthPolicy`: no enabled Conditional Access policy with an authentication strength targets the account

Accounts with fewer FIDO2 keys than required keep their weak methods, even with `-Apply`.
