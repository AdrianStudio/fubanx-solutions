"""Probe Exchange Online health from the user side through Microsoft Graph.

Reports open Exchange Online service health issues and the latency of a mailbox
read. With --apply it also sends a canary message between two probe mailboxes
and measures EXO to EXO delivery delay.

Required environment variables:
    AZURE_TENANT_ID, AZURE_CLIENT_ID, AZURE_CLIENT_SECRET,
    PROBE_SENDER_UPN, PROBE_RECIPIENT_UPN

Usage:
    python exo_health_probe.py
    python exo_health_probe.py --apply --delivery-timeout 300
"""

import argparse
import os
import sys
import time
import uuid
from datetime import datetime, timezone

import requests

GRAPH_BASE_URL = "https://graph.microsoft.com/v1.0"
TOKEN_URL_TEMPLATE = "https://login.microsoftonline.com/{tenant_id}/oauth2/v2.0/token"
EXCHANGE_SERVICE_NAME = "Exchange Online"
HTTP_TIMEOUT_SECONDS = 30
DELIVERY_POLL_INTERVAL_SECONDS = 10


def acquire_graph_token() -> str:
    token_url = TOKEN_URL_TEMPLATE.format(tenant_id=os.environ["AZURE_TENANT_ID"])
    response = requests.post(
        token_url,
        data={
            "grant_type": "client_credentials",
            "client_id": os.environ["AZURE_CLIENT_ID"],
            "client_secret": os.environ["AZURE_CLIENT_SECRET"],
            "scope": "https://graph.microsoft.com/.default",
        },
        timeout=HTTP_TIMEOUT_SECONDS,
    )
    response.raise_for_status()
    return response.json()["access_token"]


def list_open_exchange_issues(headers: dict) -> list[dict]:
    open_issues = []
    next_url = f"{GRAPH_BASE_URL}/admin/serviceAnnouncement/issues"
    while True:
        response = requests.get(next_url, headers=headers, timeout=HTTP_TIMEOUT_SECONDS)
        response.raise_for_status()
        page = response.json()
        for issue in page["value"]:
            if issue["service"] == EXCHANGE_SERVICE_NAME and not issue["isResolved"]:
                open_issues.append(issue)
        if "@odata.nextLink" not in page:
            return open_issues
        next_url = page["@odata.nextLink"]


def time_mailbox_read(headers: dict, recipient_upn: str) -> float:
    started_at = time.monotonic()
    response = requests.get(
        f"{GRAPH_BASE_URL}/users/{recipient_upn}/mailFolders/inbox",
        headers=headers,
        timeout=HTTP_TIMEOUT_SECONDS,
    )
    response.raise_for_status()
    return time.monotonic() - started_at


def send_canary_and_wait(
    headers: dict, sender_upn: str, recipient_upn: str, delivery_timeout: int
) -> float | None:
    canary_subject = f"exo-health-probe {uuid.uuid4()}"
    sent_at = datetime.now(timezone.utc)
    send_response = requests.post(
        f"{GRAPH_BASE_URL}/users/{sender_upn}/sendMail",
        headers=headers,
        json={
            "message": {
                "subject": canary_subject,
                "body": {"contentType": "Text", "content": "Canary message for delivery latency measurement."},
                "toRecipients": [{"emailAddress": {"address": recipient_upn}}],
            },
            "saveToSentItems": False,
        },
        timeout=HTTP_TIMEOUT_SECONDS,
    )
    send_response.raise_for_status()

    deadline = time.monotonic() + delivery_timeout
    while time.monotonic() < deadline:
        lookup_response = requests.get(
            f"{GRAPH_BASE_URL}/users/{recipient_upn}/mailFolders/inbox/messages",
            headers=headers,
            params={
                "$filter": f"subject eq '{canary_subject}'",
                "$select": "id,receivedDateTime",
            },
            timeout=HTTP_TIMEOUT_SECONDS,
        )
        lookup_response.raise_for_status()
        matching_messages = lookup_response.json()["value"]
        if matching_messages:
            received_at = datetime.fromisoformat(matching_messages[0]["receivedDateTime"])
            return (received_at - sent_at).total_seconds()
        time.sleep(DELIVERY_POLL_INTERVAL_SECONDS)
    return None


def main() -> int:
    parser = argparse.ArgumentParser(description="Probe Exchange Online health through Microsoft Graph.")
    parser.add_argument("--apply", action="store_true", help="send a canary message and measure delivery delay")
    parser.add_argument("--slow-read-seconds", type=float, default=5.0, help="mailbox read latency treated as degraded")
    parser.add_argument("--delivery-timeout", type=int, default=300, help="seconds to wait for the canary message")
    args = parser.parse_args()

    sender_upn = os.environ["PROBE_SENDER_UPN"]
    recipient_upn = os.environ["PROBE_RECIPIENT_UPN"]
    headers = {"Authorization": f"Bearer {acquire_graph_token()}"}
    degraded = False

    open_issues = list_open_exchange_issues(headers)
    for issue in open_issues:
        print(f"OPEN ISSUE {issue['id']} [{issue['classification']}] {issue['title']} (since {issue['startDateTime']})")
    if open_issues:
        degraded = True
    else:
        print("No open Exchange Online service health issues.")

    read_seconds = time_mailbox_read(headers, recipient_upn)
    print(f"Mailbox read of {recipient_upn} took {read_seconds:.2f}s")
    if read_seconds > args.slow_read_seconds:
        degraded = True

    if not args.apply:
        print("Report only: canary message not sent. Use --apply to measure delivery delay.")
        return 1 if degraded else 0

    delivery_seconds = send_canary_and_wait(headers, sender_upn, recipient_upn, args.delivery_timeout)
    if delivery_seconds is None:
        print(f"Canary from {sender_upn} to {recipient_upn} not delivered within {args.delivery_timeout}s")
        degraded = True
    else:
        print(f"Canary from {sender_upn} to {recipient_upn} delivered in {delivery_seconds:.1f}s")
    return 1 if degraded else 0


if __name__ == "__main__":
    sys.exit(main())
