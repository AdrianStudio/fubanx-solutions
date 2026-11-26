# AI Router Auditor

Reports devices that connect to AI router services through Microsoft Defender for Endpoint and can submit block indicators for the domains it finds.

## Problem
Third-party AI tools often send prompts through AI routers such as OpenRouter instead of calling the model vendor directly. Each hop decrypts the prompt and can log it, including pasted credentials, and zero data retention flags are not reliably honoured. MSPs and IT teams have no inventory of which devices and processes use these routers.

## Prerequisites
- Python 3.12 and the `requests` package.
- `AZURE_TENANT_ID`: Entra ID tenant that hosts the Defender for Endpoint instance.
- `AZURE_CLIENT_ID`: application (client) ID of an app registration.
- `AZURE_CLIENT_SECRET`: client secret of that app registration.
- `AI_ROUTER_EXTRA_DOMAINS` (optional): comma separated extra router domains to audit, for example `router.example.com`.
- App registration API permission `AdvancedQuery.Read.All` (WindowsDefenderATP) for the report.
- App registration API permission `Ti.ReadWrite.All` (WindowsDefenderATP) only for `--apply`.
- Network Protection must be enabled on endpoints for domain block indicators to take effect.

## Usage
```
python ai_router_auditor.py --days 7
python ai_router_auditor.py --days 7 --apply
```
- The default run only prints connections and the domains it would block.
- `--apply` submits a Block indicator with an alert for each observed router domain.

## Unverified
- The built-in AI router domain list is curated by hand and may be incomplete or include domains that your policy allows. Review it before using `--apply`.
