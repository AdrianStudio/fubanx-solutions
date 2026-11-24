"""Group card statement charges by card and software vendor after the Cleverbridge breach.

Cleverbridge is merchant of record, so statement descriptors often carry the
vendor name instead of "Cleverbridge". Charges are matched against a vendor
list plus the literal "cleverbridge".

Inputs:
    --statement  CSV export of card transactions (one header row, plain numeric amounts)
    --vendors    text file with one vendor name per line

Environment variables:
    REPORT_WEBHOOK_URL  incoming webhook accepting {"text": ...}; required only with --apply

Usage:
    python card_exposure_reporter.py --statement card.csv --vendors vendors.txt
    python card_exposure_reporter.py --statement card.csv --vendors vendors.txt --apply
"""

import argparse
import csv
import os
from collections import defaultdict
from datetime import date, datetime
from decimal import Decimal

import requests

PAYMENT_PROCESSOR_TERM = "cleverbridge"
WEBHOOK_TIMEOUT_SECONDS = 30


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--statement", required=True, help="card transactions CSV export")
    parser.add_argument("--vendors", required=True, help="file with one vendor name per line")
    parser.add_argument("--since", type=date.fromisoformat, help="ignore charges before this date (YYYY-MM-DD)")
    parser.add_argument("--date-format", default="%Y-%m-%d", help="strptime format of the date column")
    parser.add_argument("--date-column", default="Date")
    parser.add_argument("--description-column", default="Description")
    parser.add_argument("--amount-column", default="Amount")
    parser.add_argument("--card-column", default="Card Last4")
    parser.add_argument("--apply", action="store_true", help="post the report to REPORT_WEBHOOK_URL")
    return parser.parse_args()


def load_vendor_terms(vendors_path: str) -> list[str]:
    with open(vendors_path, encoding="utf-8") as vendors_file:
        vendor_names = [line.strip().lower() for line in vendors_file if line.strip()]
    return vendor_names + [PAYMENT_PROCESSOR_TERM]


def find_matching_charges(arguments: argparse.Namespace, vendor_terms: list[str]) -> list[dict]:
    matching_charges = []
    with open(arguments.statement, newline="", encoding="utf-8-sig") as statement_file:
        for row in csv.DictReader(statement_file):
            charge_date = datetime.strptime(row[arguments.date_column], arguments.date_format).date()
            if arguments.since is not None and charge_date < arguments.since:
                continue
            description = row[arguments.description_column].lower()
            matched_term = next((term for term in vendor_terms if term in description), None)
            if matched_term is None:
                continue
            matching_charges.append(
                {
                    "card": row[arguments.card_column],
                    "vendor": matched_term,
                    "date": charge_date,
                    "amount": Decimal(row[arguments.amount_column]),
                }
            )
    return matching_charges


def render_report(matching_charges: list[dict]) -> str:
    if not matching_charges:
        return "No charges matched the vendor list."

    charges_by_card = defaultdict(lambda: defaultdict(list))
    for charge in matching_charges:
        charges_by_card[charge["card"]][charge["vendor"]].append(charge)

    report_lines = [f"{len(matching_charges)} matching charges on {len(charges_by_card)} card(s)"]
    for card in sorted(charges_by_card):
        card_charges = [charge for vendor_charges in charges_by_card[card].values() for charge in vendor_charges]
        card_total = sum(charge["amount"] for charge in card_charges)
        report_lines.append(f"Card ending {card}: {len(card_charges)} charges, total {card_total}")
        for vendor in sorted(charges_by_card[card]):
            vendor_charges = charges_by_card[card][vendor]
            first_charge = min(charge["date"] for charge in vendor_charges)
            last_charge = max(charge["date"] for charge in vendor_charges)
            report_lines.append(
                f"  {vendor}: {len(vendor_charges)} charges, first {first_charge.isoformat()}, last {last_charge.isoformat()}"
            )
    return "\n".join(report_lines)


def post_report(report: str) -> None:
    webhook_url = os.environ["REPORT_WEBHOOK_URL"]
    response = requests.post(webhook_url, json={"text": report}, timeout=WEBHOOK_TIMEOUT_SECONDS)
    response.raise_for_status()


def main() -> None:
    arguments = parse_arguments()
    vendor_terms = load_vendor_terms(arguments.vendors)
    matching_charges = find_matching_charges(arguments, vendor_terms)
    report = render_report(matching_charges)
    print(report)
    if arguments.apply:
        post_report(report)
        print("Report posted to webhook.")
    else:
        print("Report only. Use --apply to post it to REPORT_WEBHOOK_URL.")


if __name__ == "__main__":
    main()
