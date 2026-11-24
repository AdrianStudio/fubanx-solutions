# Card Exposure Reporter

Groups card statement charges by card and software vendor so finance can see which company cards to replace after the Cleverbridge breach.

## Problem
Cleverbridge is merchant of record for many software and SaaS vendors, so statement descriptors often show the vendor name instead of Cleverbridge. Finance and IT teams must find which company cards paid licences and renewals, trace each back to its first saved purchase, and then request replacements. Doing this by reading statements by hand is slow and easy to get wrong.

## Prerequisites
- Python 3.12 and the `requests` package.
- A CSV export of card transactions with a header row. Default columns: `Date`, `Description`, `Amount`, `Card Last4`. Override them with `--date-column`, `--description-column`, `--amount-column` and `--card-column`.
- Dates must match `--date-format` (default `%Y-%m-%d`). Amounts must be plain numbers such as `1234.50`. A missing column or malformed value stops the run with an error.
- A vendor file with one vendor name per line. The term `cleverbridge` is always matched in addition.
- `REPORT_WEBHOOK_URL` (optional, needed only with `--apply`): incoming webhook URL that accepts a JSON body `{"text": "..."}`, for example a Slack incoming webhook. No other permissions are required.
- Amounts are summed per card without currency conversion.

## Usage
```
python card_exposure_reporter.py --statement <statement.csv> --vendors <vendors.txt> --since 2024-01-01

export REPORT_WEBHOOK_URL=<webhook-url>
python card_exposure_reporter.py --statement <statement.csv> --vendors <vendors.txt> --since 2024-01-01 --apply
```
