# Exchange Online Health Probe

Reads Exchange Online service health from Microsoft Graph, times a mailbox read and optionally measures EXO to EXO delivery delay with a canary message.

## Problem
During incidents such as MO1550821 the Exchange servers stay reachable while the user access layer or delivery into Exchange Online degrades. Gateway continuity modules do not see internal EXO to EXO mail and do not fail over automatically in this case. Operators have no user-side evidence to decide on a manual failover.

## Prerequisites
- Python 3.12 and `requests`.
- `AZURE_TENANT_ID`: Entra ID tenant ID.
- `AZURE_CLIENT_ID`: application (client) ID of an app registration.
- `AZURE_CLIENT_SECRET`: client secret of that app registration.
- `PROBE_SENDER_UPN`: UPN of the dedicated mailbox that sends the canary message.
- `PROBE_RECIPIENT_UPN`: UPN of the dedicated mailbox that receives the canary message.
- Graph application permissions with admin consent:
  - `ServiceHealth.Read.All` for service health issues.
  - `Mail.Read` for the mailbox read and canary lookup.
  - `Mail.Send` only for `--apply`.
- Restrict the mail permissions to the two probe mailboxes with an Exchange application access policy or RBAC for Applications.
- Canary messages stay in the recipient inbox. Use a dedicated mailbox with a retention rule.
- Exit code is 1 when an open issue, a slow read or a missed delivery is found.

## Usage
```
export AZURE_TENANT_ID=<tenant-id>
export AZURE_CLIENT_ID=<client-id>
export AZURE_CLIENT_SECRET=<client-secret>
export PROBE_SENDER_UPN=<probe-sender@example.com>
export PROBE_RECIPIENT_UPN=<probe-recipient@example.com>

python exo_health_probe.py
python exo_health_probe.py --apply --delivery-timeout 300
```
