//
//  BeancountPluginDriver+PythonScript.swift
//  BeancountDriverPlugin
//

import Foundation

extension BeancountPluginDriver {
    static let pythonProjectionScript = """
import json
import sys
from collections import defaultdict
from decimal import Decimal

from beancount import loader

def date_value(value):
    return value.isoformat() if value is not None else None

def decimal_value(value):
    return str(value) if value is not None else None

def amount_value(amount):
    if amount is None:
        return None
    return {
        "number": decimal_value(getattr(amount, "number", None)),
        "currency": getattr(amount, "currency", None),
    }

entries, errors, options_map = loader.load_file(sys.argv[1])
if errors:
    for error in errors:
        print(str(error), file=sys.stderr)
    sys.exit(1)

rows = {
    "transactions_and_postings": [],
    "accounts": [],
    "prices": [],
    "balances": [],
    "balance_assertions": [],
}
balances = defaultdict(Decimal)
transaction_id = 0

for entry in entries:
    entry_type = type(entry).__name__
    if entry_type == "Transaction":
        transaction_id += 1
        for posting in entry.postings:
            units = getattr(posting, "units", None)
            cost = getattr(posting, "cost", None)
            if units is not None and getattr(units, "number", None) is not None and getattr(units, "currency", None):
                balances[(posting.account, units.currency)] += units.number
            rows["transactions_and_postings"].append({
                "id": transaction_id,
                "date": date_value(entry.date),
                "flag": str(entry.flag),
                "payee": entry.payee,
                "narration": entry.narration,
                "account": posting.account,
                "number": decimal_value(getattr(units, "number", None)) if units is not None else None,
                "currency": getattr(units, "currency", None) if units is not None else None,
                "cost_number": decimal_value(getattr(cost, "number", None)) if cost is not None else None,
                "cost_currency": getattr(cost, "currency", None) if cost is not None else None,
            })
    elif entry_type == "Open":
        rows["accounts"].append({
            "account": entry.account,
            "open": date_value(entry.date),
            "currencies": list(entry.currencies or []),
        })
    elif entry_type == "Price":
        rows["prices"].append({
            "date": date_value(entry.date),
            "currency": entry.currency,
            "amount": amount_value(entry.amount),
        })
    elif entry_type == "Balance":
        rows["balance_assertions"].append({
            "date": date_value(entry.date),
            "account": entry.account,
            "amount": amount_value(entry.amount),
        })

for (account, currency), number in sorted(balances.items()):
    if number == 0:
        continue
    rows["balances"].append({
        "account": account,
        "balance": {
            "positions": [{
                "number": decimal_value(number),
                "currency": currency,
            }]
        },
    })

print(json.dumps(rows, separators=(",", ":")))
"""
}
