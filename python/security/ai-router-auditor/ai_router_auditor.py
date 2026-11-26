"""Report and optionally block AI router traffic seen by Microsoft Defender for Endpoint.

Required environment variables: AZURE_TENANT_ID, AZURE_CLIENT_ID, AZURE_CLIENT_SECRET.
Optional environment variable: AI_ROUTER_EXTRA_DOMAINS (comma separated domains).

Usage:
    python ai_router_auditor.py [--days 7]
    python ai_router_auditor.py [--days 7] --apply
"""

import argparse
import os
import re

import requests

TOKEN_ENDPOINT_TEMPLATE = "https://login.microsoftonline.com/{tenant_id}/oauth2/v2.0/token"
DEFENDER_API_SCOPE = "https://api.security.microsoft.com/.default"
ADVANCED_HUNTING_ENDPOINT = "https://api.security.microsoft.com/api/advancedqueries/run"
INDICATORS_ENDPOINT = "https://api.security.microsoft.com/api/indicators"
REQUEST_TIMEOUT_SECONDS = 60

AI_ROUTER_DOMAINS = (
    "openrouter.ai",
    "portkey.ai",
    "requesty.ai",
    "withmartian.com",
    "unify.ai",
    "nano-gpt.com",
    "aimlapi.com",
    "edenai.run",
)

DOMAIN_PATTERN = re.compile(r"^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$")


def load_router_domains() -> list[str]:
    router_domains = list(AI_ROUTER_DOMAINS)
    if "AI_ROUTER_EXTRA_DOMAINS" in os.environ:
        extra_domains = os.environ["AI_ROUTER_EXTRA_DOMAINS"].split(",")
        router_domains.extend(domain.strip().lower() for domain in extra_domains if domain.strip())
    for domain in router_domains:
        # The domains are interpolated into a KQL query, so reject anything that is not a plain hostname.
        if not DOMAIN_PATTERN.match(domain):
            raise ValueError(f"Invalid AI router domain: {domain!r}")
    return sorted(set(router_domains))


def get_access_token() -> str:
    token_endpoint = TOKEN_ENDPOINT_TEMPLATE.format(tenant_id=os.environ["AZURE_TENANT_ID"])
    response = requests.post(
        token_endpoint,
        data={
            "grant_type": "client_credentials",
            "client_id": os.environ["AZURE_CLIENT_ID"],
            "client_secret": os.environ["AZURE_CLIENT_SECRET"],
            "scope": DEFENDER_API_SCOPE,
        },
        timeout=REQUEST_TIMEOUT_SECONDS,
    )
    response.raise_for_status()
    return response.json()["access_token"]


def find_router_connections(auth_headers: dict, router_domains: list[str], lookback_days: int) -> list[dict]:
    quoted_domains = ", ".join(f'"{domain}"' for domain in router_domains)
    hunting_query = "\n".join(
        [
            "DeviceNetworkEvents",
            f"| where Timestamp > ago({lookback_days}d)",
            f"| where RemoteUrl has_any ({quoted_domains})",
            "| summarize Connections = count(), LastSeen = max(Timestamp)"
            " by DeviceName, InitiatingProcessFileName, RemoteUrl",
            "| order by Connections desc",
        ]
    )
    response = requests.post(
        ADVANCED_HUNTING_ENDPOINT,
        headers=auth_headers,
        json={"Query": hunting_query},
        timeout=REQUEST_TIMEOUT_SECONDS,
    )
    response.raise_for_status()
    return response.json()["Results"]


def block_router_domains(auth_headers: dict, observed_domains: list[str]) -> None:
    for domain in observed_domains:
        response = requests.post(
            INDICATORS_ENDPOINT,
            headers=auth_headers,
            json={
                "indicatorValue": domain,
                "indicatorType": "DomainName",
                "action": "Block",
                "title": f"AI router blocked: {domain}",
                "description": "AI routers decrypt and may log prompts, including credentials and sensitive data.",
                "severity": "Medium",
                "generateAlert": True,
            },
            timeout=REQUEST_TIMEOUT_SECONDS,
        )
        response.raise_for_status()
        print(f"Submitted block indicator for {domain}")


def main() -> None:
    parser = argparse.ArgumentParser(description="Find devices talking to AI routers via Defender for Endpoint.")
    parser.add_argument("--days", type=int, default=7, help="Lookback window in days")
    parser.add_argument("--apply", action="store_true", help="Submit Block indicators for observed router domains")
    arguments = parser.parse_args()

    router_domains = load_router_domains()
    auth_headers = {"Authorization": f"Bearer {get_access_token()}"}
    router_connections = find_router_connections(auth_headers, router_domains, arguments.days)

    if not router_connections:
        print(f"No AI router connections in the last {arguments.days} days.")
        return

    for connection in router_connections:
        print(
            f"{connection['DeviceName']}\t{connection['InitiatingProcessFileName']}\t"
            f"{connection['RemoteUrl']}\t{connection['Connections']} connections\t"
            f"last seen {connection['LastSeen']}"
        )

    observed_domains = sorted(
        {domain for connection in router_connections for domain in router_domains if domain in connection["RemoteUrl"]}
    )
    if not arguments.apply:
        print(f"Report only. Would block: {', '.join(observed_domains)}. Re-run with --apply to submit indicators.")
        return

    block_router_domains(auth_headers, observed_domains)


if __name__ == "__main__":
    main()
