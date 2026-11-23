# GAL vCard Exporter

Exports the enabled member users with a mailbox from Entra ID as one vCard 3.0 file each, ready to be served to iOS Contacts by a CardDAV server.

## Problem

Sysadmins who want the company directory in the native iOS Contacts app get duplicates, wrong attributes or 429 errors from scripts that push contacts into mailbox folders. Contacts of departed employees are not removed. Each vCard here uses the Entra object ID as its UID, so the same person always maps to the same contact, and leavers lose their file.

## Prerequisites

- No environment variables are read. The tenant is passed with `-TenantId`.
- PowerShell 7.0 or later.
- Module `Microsoft.Graph.Authentication`.
- Delegated Microsoft Graph permission `User.Read.All`, consented for the signed-in admin.
- Write access to the output directory when `-Apply` is used.
- A CardDAV server and an Intune CardDAV account profile to deliver the files to devices. Both are outside this script.

## Usage

```powershell
# Report only: lists Add, Update and Remove actions, changes nothing
./gal-vcard-exporter.ps1 -TenantId <tenant-id> -OutputDirectory ./gal

# Write new and changed vCards, delete files of users that left
./gal-vcard-exporter.ps1 -TenantId <tenant-id> -OutputDirectory ./gal -Apply

# Allow up to 40 percent of existing files to be removed in one run
./gal-vcard-exporter.ps1 -TenantId <tenant-id> -OutputDirectory ./gal -MaxRemovalPercent 40 -Apply
```

- Only `.vcf` files that contain the `X-GAL-EXPORT:entra-id` marker are compared or deleted.
- `-Apply` aborts when removals exceed `-MaxRemovalPercent` (default 20).
- The script stops when Graph returns no users.
- Guest users, disabled users and users without a `mail` value are skipped.
