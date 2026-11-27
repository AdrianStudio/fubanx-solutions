<#
.SYNOPSIS
Audits MFA readiness of Entra ID break-glass accounts and optionally removes weak second factors.

.DESCRIPTION
Reads every user in the break-glass group and reports: cloud-only status, enabled state,
number of registered FIDO2 keys, SMS/phone methods, software OATH methods (shared TOTP seeds)
and whether an enabled Conditional Access policy with an authentication strength targets the account.

Report-only by default. With -Apply, phone and software OATH methods are removed, but only from
accounts that already hold at least MinimumFido2Keys FIDO2 keys, so the account cannot be locked out
by this script. Group membership is evaluated for the given group only, nested groups are not expanded.

Requires an interactive Microsoft Graph sign-in. Delegated scopes: GroupMember.Read.All,
User.Read.All, Policy.Read.All, UserAuthenticationMethod.Read.All (ReadWrite.All with -Apply).
The signed-in admin needs the Authentication Administrator or Privileged Authentication
Administrator role to remove methods.

.PARAMETER BreakGlassGroupId
Object ID of the group that contains the break-glass user accounts.

.PARAMETER MinimumFido2Keys
Minimum number of FIDO2 keys each account must hold (2 to 10).

.PARAMETER Apply
Remove phone and software OATH methods from compliant accounts. Without it nothing is changed.

.EXAMPLE
./breakglass-mfa-auditor.ps1 -BreakGlassGroupId <group-object-id> -MinimumFido2Keys 3

.EXAMPLE
./breakglass-mfa-auditor.ps1 -BreakGlassGroupId <group-object-id> -MinimumFido2Keys 3 -Apply
#>
#Requires -Version 7.0
#Requires -Modules Microsoft.Graph.Authentication, Microsoft.Graph.Groups, Microsoft.Graph.Identity.SignIns
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$BreakGlassGroupId,

    [Parameter(Mandatory)]
    [ValidateRange(2, 10)]
    [int]$MinimumFido2Keys,

    [switch]$Apply
)

$ErrorActionPreference = 'Stop'

$fido2MethodType = '#microsoft.graph.fido2AuthenticationMethod'
$phoneMethodType = '#microsoft.graph.phoneAuthenticationMethod'
$softwareOathMethodType = '#microsoft.graph.softwareOathAuthenticationMethod'

$authenticationMethodScope = 'UserAuthenticationMethod.Read.All'
if ($Apply) {
    $authenticationMethodScope = 'UserAuthenticationMethod.ReadWrite.All'
}
Connect-MgGraph -Scopes @('GroupMember.Read.All', 'User.Read.All', 'Policy.Read.All', $authenticationMethodScope) -NoWelcome

$breakGlassAccounts = @(Get-MgGroupMemberAsUser -GroupId $BreakGlassGroupId -All -Property 'id,userPrincipalName,accountEnabled,onPremisesSyncEnabled')
if ($breakGlassAccounts.Count -eq 0) {
    throw "Group $BreakGlassGroupId has no user members."
}

$enabledPolicies = @(Get-MgIdentityConditionalAccessPolicy -All | Where-Object { $_.State -eq 'enabled' })

$accountReports = foreach ($account in $breakGlassAccounts) {
    $authenticationMethods = @(Get-MgUserAuthenticationMethod -UserId $account.Id)
    $fido2Methods = @($authenticationMethods | Where-Object { $_.AdditionalProperties['@odata.type'] -eq $fido2MethodType })
    $phoneMethods = @($authenticationMethods | Where-Object { $_.AdditionalProperties['@odata.type'] -eq $phoneMethodType })
    $softwareOathMethods = @($authenticationMethods | Where-Object { $_.AdditionalProperties['@odata.type'] -eq $softwareOathMethodType })

    $authenticationStrengthPolicies = @($enabledPolicies | Where-Object {
        $targetedUsers = $_.Conditions.Users
        $isIncluded = ($targetedUsers.IncludeUsers -contains 'All') -or ($targetedUsers.IncludeUsers -contains $account.Id) -or ($targetedUsers.IncludeGroups -contains $BreakGlassGroupId)
        $isExcluded = ($targetedUsers.ExcludeUsers -contains $account.Id) -or ($targetedUsers.ExcludeGroups -contains $BreakGlassGroupId)
        $isIncluded -and -not $isExcluded -and ($null -ne $_.GrantControls) -and ($null -ne $_.GrantControls.AuthenticationStrength)
    })

    $findings = [System.Collections.Generic.List[string]]::new()
    if (-not $account.AccountEnabled) { $findings.Add('AccountDisabled') }
    if ($account.OnPremisesSyncEnabled -eq $true) { $findings.Add('SyncedFromOnPremises') }
    if ($fido2Methods.Count -lt $MinimumFido2Keys) { $findings.Add("FewerThan$($MinimumFido2Keys)Fido2Keys") }
    if ($phoneMethods.Count -gt 0) { $findings.Add('PhoneMethodRegistered') }
    if ($softwareOathMethods.Count -gt 0) { $findings.Add('SoftwareOathMethodRegistered') }
    if ($authenticationStrengthPolicies.Count -eq 0) { $findings.Add('NoAuthenticationStrengthPolicy') }

    $weakMethodAction = 'None'
    $weakMethodCount = $phoneMethods.Count + $softwareOathMethods.Count
    if ($weakMethodCount -gt 0) {
        if ($fido2Methods.Count -lt $MinimumFido2Keys) {
            $weakMethodAction = 'SkippedNotEnoughFido2Keys'
            Write-Warning "$($account.UserPrincipalName): weak methods kept because only $($fido2Methods.Count) FIDO2 key(s) are registered."
        }
        elseif ($Apply) {
            foreach ($phoneMethod in $phoneMethods) {
                Remove-MgUserAuthenticationPhoneMethod -UserId $account.Id -PhoneAuthenticationMethodId $phoneMethod.Id
            }
            foreach ($softwareOathMethod in $softwareOathMethods) {
                Remove-MgUserAuthenticationSoftwareOathMethod -UserId $account.Id -SoftwareOathAuthenticationMethodId $softwareOathMethod.Id
            }
            $weakMethodAction = 'Removed'
        }
        else {
            $weakMethodAction = 'WouldRemove'
        }
    }

    [pscustomobject]@{
        UserPrincipalName = $account.UserPrincipalName
        Fido2Keys         = $fido2Methods.Count
        PhoneMethods      = $phoneMethods.Count
        SoftwareOath      = $softwareOathMethods.Count
        WeakMethodAction  = $weakMethodAction
        Findings          = $findings -join ';'
    }
}

$accountReports

Disconnect-MgGraph | Out-Null
