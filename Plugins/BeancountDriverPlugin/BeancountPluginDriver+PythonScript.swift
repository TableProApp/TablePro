//
//  BeancountPluginDriver+PythonScript.swift
//  BeancountDriverPlugin
//

import Foundation

extension BeancountPluginDriver {
    static let pythonProjectionScript = """
import json
import os
import sys
import tempfile
from collections import defaultdict
from decimal import Decimal

cache_directory = tempfile.TemporaryDirectory(prefix="tablepro-beancount-")
os.environ["BEANCOUNT_DISABLE_LOAD_CACHE"] = "1"
os.environ["BEANCOUNT_LOAD_CACHE_FILENAME"] = os.path.join(cache_directory.name, "disabled.picklecache")

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

META_INTERNAL_KEYS = ("filename", "lineno", "__automatic__", "__residual__", "__tolerances__")

def source_file(meta):
    if not meta:
        return None
    value = meta.get("filename")
    return str(value) if value is not None else None

def source_line(meta):
    if not meta:
        return None
    value = meta.get("lineno")
    return int(value) if value is not None else None

def source_location(meta):
    path = source_file(meta)
    line = source_line(meta)
    if path is None or line is None:
        return None
    return path + ":" + str(line)

def user_meta(meta):
    if not meta:
        return None
    pairs = {}
    for key, value in meta.items():
        if key in META_INTERNAL_KEYS or key.startswith("__"):
            continue
        if value is None:
            pairs[key] = None
        elif isinstance(value, (str, bool, int, float)):
            pairs[key] = value
        elif isinstance(value, Decimal):
            pairs[key] = decimal_value(value)
        else:
            pairs[key] = str(value)
    return pairs or None

def name_list(values):
    return sorted(str(value) for value in (values or []))

entries, errors, options_map = loader.load_file(sys.argv[1])
if errors:
    for error in errors:
        print(str(error), file=sys.stderr)
    sys.exit(1)

rows = {
    "transactions": [],
    "postings": [],
    "accounts": [],
    "prices": [],
    "balances": [],
    "balance_assertions": [],
    "commodities": [],
    "documents": [],
    "notes": [],
    "events": [],
    "closes": [],
}
balances = defaultdict(Decimal)
transaction_id = 0

for entry in entries:
    entry_type = type(entry).__name__
    if entry_type == "Transaction":
        transaction_id += 1
        entry_meta = user_meta(entry.meta)
        tags = name_list(entry.tags)
        links = name_list(entry.links)
        rows["transactions"].append({
            "id": transaction_id,
            "date": date_value(entry.date),
            "flag": str(entry.flag),
            "payee": entry.payee,
            "narration": entry.narration,
            "filename": source_file(entry.meta),
            "lineno": source_line(entry.meta),
            "location": source_location(entry.meta),
            "tags": tags,
            "links": links,
            "_entry_meta": entry_meta,
        })
        for posting in entry.postings:
            units = getattr(posting, "units", None)
            cost = getattr(posting, "cost", None)
            posting_meta = getattr(posting, "meta", None)
            if units is not None and getattr(units, "number", None) is not None and getattr(units, "currency", None):
                balances[(posting.account, units.currency)] += units.number
            rows["postings"].append({
                "transaction_id": transaction_id,
                "date": date_value(entry.date),
                "account": posting.account,
                "number": decimal_value(getattr(units, "number", None)) if units is not None else None,
                "currency": getattr(units, "currency", None) if units is not None else None,
                "cost_number": decimal_value(getattr(cost, "number", None)) if cost is not None else None,
                "cost_currency": getattr(cost, "currency", None) if cost is not None else None,
                "filename": source_file(posting_meta) or source_file(entry.meta),
                "lineno": source_line(posting_meta) or source_line(entry.meta),
                "location": source_location(posting_meta) or source_location(entry.meta),
                "_posting_meta": user_meta(posting_meta),
            })
    elif entry_type == "Commodity":
        rows["commodities"].append({
            "date": date_value(entry.date),
            "name": entry.currency,
        })
    elif entry_type == "Document":
        rows["documents"].append({
            "date": date_value(entry.date),
            "account": entry.account,
            "filename": entry.filename,
            "tags": name_list(getattr(entry, "tags", None)),
            "links": name_list(getattr(entry, "links", None)),
        })
    elif entry_type == "Note":
        rows["notes"].append({
            "date": date_value(entry.date),
            "account": entry.account,
            "comment": entry.comment,
        })
    elif entry_type == "Event":
        rows["events"].append({
            "date": date_value(entry.date),
            "type": entry.type,
            "description": entry.description,
        })
    elif entry_type == "Close":
        rows["closes"].append({
            "account": entry.account,
            "close": date_value(entry.date),
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
