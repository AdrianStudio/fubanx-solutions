# Access Group Reconciler

PowerShell script that compares approved ITSM access requests with the members of an Entra ID group and writes an audit log, adding missing users only when `-Apply` is passed.

## Problem
For applications without automated provisioning, access is granted through an Entra ID group and manual steps in the application. IT and IAM teams cannot show that group membership matches the approved tickets. Missing users and members without approval go unnoticed, and the ticket-to-access link is kept by hand.

## Prerequisites
- PowerShell 7.0 or later. No extra modules are needed.
- `GRAPH_ACCESS_TOKEN`: environment variable with a Microsoft Graph bearer token.
- Graph permissions for a report-only run: `GroupMember.Read.All` and `User.Read.All`.
- Additional Graph permission for `-Apply`: `GroupMember.ReadWrite.All`.
- The target group must be assigned (not dynamic) and cloud-managed (not synchronized from on-premises AD).
- Approved requests CSV exported from the ITSM system with the columns `UserPrincipalName` and `TicketId`.

## Usage
```powershell
# Report only: nothing is changed
./access-group-reconciler.ps1 -GroupId <group-object-id> -ApprovedRequestsPath ./approved.csv -AuditLogPath ./audit.csv

# Add approved users that are missing from the group and verify membership
./access-group-reconciler.ps1 -GroupId <group-object-id> -ApprovedRequestsPath ./approved.csv -AuditLogPath ./audit.csv -Apply
```

- Findings: `Aligned`, `ApprovedNotInGroup`, `InGroupNoApproval`.
- Members without an approved request are only reported, never removed.
- The audit CSV contains the timestamp, user, ticket ID, finding, action and verification result.
