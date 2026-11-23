<#
.SYNOPSIS
Audits Azure API Management instances and the Key Vaults of the same subscriptions.

.DESCRIPTION
Reports classic tier APIM instances, whether the direct management API (tenant/access) is enabled,
the managed identity type, secret named values stored inside APIM instead of Key Vault, and
Key Vaults that have no audit log diagnostic setting or that allow public network traffic by default.
The script is read-only unless -Apply is passed. With -Apply it disables the direct management API
on classic tier instances where it is enabled. It does not delete or rotate anything.

Requires a signed-in Az session (Connect-AzAccount). Reader on each subscription is enough for the
report. -Apply additionally needs the Microsoft.ApiManagement/service/tenant/write permission
(API Management Service Contributor).

.PARAMETER SubscriptionId
One or more subscription IDs to audit.

.PARAMETER Apply
Disables the direct management API on classic tier APIM instances where it is enabled.

.EXAMPLE
./apim-security-audit.ps1 -SubscriptionId '<subscription-id>'

.EXAMPLE
./apim-security-audit.ps1 -SubscriptionId '<subscription-id-1>','<subscription-id-2>' -Apply
#>
#Requires -Version 7.0
#Requires -Modules Az.Accounts
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string[]]$SubscriptionId,

    [switch]$Apply
)

$ErrorActionPreference = 'Stop'

$ArmEndpoint = 'https://management.azure.com'
$ApimApiVersion = '2022-08-01'
$KeyVaultApiVersion = '2023-07-01'
$DiagnosticSettingsApiVersion = '2021-05-01-preview'
$ClassicTierNames = @('Developer', 'Basic', 'Standard', 'Premium')
$AuditLogCategoryGroups = @('audit', 'allLogs')

function Get-ArmCollection {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][hashtable]$Headers
    )

    $pageUri = $Uri
    while ($pageUri) {
        $response = Invoke-WebRequest -Uri $pageUri -Headers $Headers -Method Get -TimeoutSec 60
        $page = $response.Content | ConvertFrom-Json -AsHashtable
        $page['value']
        if ($page.ContainsKey('nextLink') -and $page['nextLink']) {
            $pageUri = $page['nextLink']
        }
        else {
            $pageUri = $null
        }
    }
}

$accessToken = Get-AzAccessToken -ResourceUrl $ArmEndpoint -AsSecureString
$bearerToken = ConvertFrom-SecureString -SecureString $accessToken.Token -AsPlainText
$requestHeaders = @{ Authorization = "Bearer $bearerToken" }

$findings = [System.Collections.Generic.List[object]]::new()

foreach ($subscription in $SubscriptionId) {
    $apimListUri = "$ArmEndpoint/subscriptions/$subscription/providers/Microsoft.ApiManagement/service?api-version=$ApimApiVersion"
    $apimServices = @(Get-ArmCollection -Uri $apimListUri -Headers $requestHeaders)

    foreach ($apimService in $apimServices) {
        $serviceId = $apimService['id']
        $tierName = $apimService['sku']['name']
        $isClassicTier = $ClassicTierNames -contains $tierName
        $serviceProperties = $apimService['properties']

        if ($isClassicTier) {
            $findings.Add([pscustomobject]@{
                Resource = $serviceId
                Check    = 'ClassicTier'
                Severity = 'Medium'
                Detail   = "Tier $tierName is a classic tier instance covered by the advisory"
                Action   = 'Reported'
            })
        }

        if ($apimService.ContainsKey('identity')) {
            $identityType = $apimService['identity']['type']
            $findings.Add([pscustomobject]@{
                Resource = $serviceId
                Check    = 'ManagedIdentity'
                Severity = 'Info'
                Detail   = "Identity type $identityType: review the Key Vault access granted to this identity"
                Action   = 'Reported'
            })
        }

        if ($serviceProperties.ContainsKey('publicNetworkAccess') -and $serviceProperties['publicNetworkAccess'] -eq 'Enabled') {
            $findings.Add([pscustomobject]@{
                Resource = $serviceId
                Check    = 'PublicNetworkAccess'
                Severity = 'Low'
                Detail   = 'Public network access is enabled'
                Action   = 'Reported'
            })
        }

        if ($isClassicTier) {
            $tenantAccessUri = "$ArmEndpoint$serviceId/tenant/access?api-version=$ApimApiVersion"
            $tenantAccessResponse = Invoke-WebRequest -Uri $tenantAccessUri -Headers $requestHeaders -Method Get -TimeoutSec 60
            $tenantAccess = $tenantAccessResponse.Content | ConvertFrom-Json -AsHashtable

            if ($tenantAccess['properties']['enabled']) {
                $remediationAction = 'Reported'
                if ($Apply) {
                    $patchHeaders = $requestHeaders + @{ 'If-Match' = '*' }
                    $disableBody = @{ properties = @{ enabled = $false } } | ConvertTo-Json -Depth 3
                    Invoke-WebRequest -Uri $tenantAccessUri -Headers $patchHeaders -Method Patch -Body $disableBody -ContentType 'application/json' -TimeoutSec 60 | Out-Null
                    $remediationAction = 'DirectManagementApiDisabled'
                }
                $findings.Add([pscustomobject]@{
                    Resource = $serviceId
                    Check    = 'DirectManagementApiEnabled'
                    Severity = 'High'
                    Detail   = 'The direct management API (tenant/access) is enabled'
                    Action   = $remediationAction
                })
            }
        }

        $namedValuesUri = "$ArmEndpoint$serviceId/namedValues?api-version=$ApimApiVersion"
        $namedValues = @(Get-ArmCollection -Uri $namedValuesUri -Headers $requestHeaders)
        foreach ($namedValue in $namedValues) {
            $namedValueProperties = $namedValue['properties']
            $isSecret = $namedValueProperties.ContainsKey('secret') -and $namedValueProperties['secret']
            $isKeyVaultReference = $namedValueProperties.ContainsKey('keyVault')
            if ($isSecret -and -not $isKeyVaultReference) {
                $findings.Add([pscustomobject]@{
                    Resource = $namedValue['id']
                    Check    = 'SecretStoredInApim'
                    Severity = 'High'
                    Detail   = "Secret named value '$($namedValueProperties['displayName'])' is stored in APIM, rotate it and move it to Key Vault"
                    Action   = 'Reported'
                })
            }
        }
    }

    $vaultListUri = "$ArmEndpoint/subscriptions/$subscription/providers/Microsoft.KeyVault/vaults?api-version=$KeyVaultApiVersion"
    $keyVaults = @(Get-ArmCollection -Uri $vaultListUri -Headers $requestHeaders)

    foreach ($keyVault in $keyVaults) {
        $vaultId = $keyVault['id']
        $diagnosticSettingsUri = "$ArmEndpoint$vaultId/providers/microsoft.insights/diagnosticSettings?api-version=$DiagnosticSettingsApiVersion"
        $diagnosticSettings = @(Get-ArmCollection -Uri $diagnosticSettingsUri -Headers $requestHeaders)

        $auditLoggingEnabled = $false
        foreach ($diagnosticSetting in $diagnosticSettings) {
            $settingProperties = $diagnosticSetting['properties']
            if (-not $settingProperties.ContainsKey('logs')) {
                continue
            }
            foreach ($logSetting in $settingProperties['logs']) {
                $isCategoryAudit = $logSetting.ContainsKey('category') -and $logSetting['category'] -eq 'AuditEvent'
                $isGroupAudit = $logSetting.ContainsKey('categoryGroup') -and ($AuditLogCategoryGroups -contains $logSetting['categoryGroup'])
                if ($logSetting['enabled'] -and ($isCategoryAudit -or $isGroupAudit)) {
                    $auditLoggingEnabled = $true
                }
            }
        }

        if (-not $auditLoggingEnabled) {
            $findings.Add([pscustomobject]@{
                Resource = $vaultId
                Check    = 'KeyVaultAuditLoggingDisabled'
                Severity = 'High'
                Detail   = 'No diagnostic setting sends AuditEvent logs, vault access cannot be reviewed'
                Action   = 'Reported'
            })
        }

        $vaultProperties = $keyVault['properties']
        if ($vaultProperties.ContainsKey('networkAcls') -and $vaultProperties['networkAcls']['defaultAction'] -eq 'Allow') {
            $findings.Add([pscustomobject]@{
                Resource = $vaultId
                Check    = 'KeyVaultNetworkDefaultAllow'
                Severity = 'Medium'
                Detail   = 'The network ACL default action is Allow'
                Action   = 'Reported'
            })
        }
    }
}

if (-not $Apply) {
    Write-Warning 'Report-only run. Pass -Apply to disable the direct management API on classic tier instances.'
}

$findings
