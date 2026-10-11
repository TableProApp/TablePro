#!/usr/bin/env python3
"""Check SQLite ANY value kinds in BookiE XLSX and LibreOffice round trips."""

from pathlib import Path
from xml.etree import ElementTree as ET
from zipfile import ZipFile

ROOT = Path(__file__).resolve().parent
MAIN = "{http://schemas.openxmlformats.org/spreadsheetml/2006/main}"
TABLE = "{urn:oasis:names:tc:opendocument:xmlns:table:1.0}"
OFFICE = "{urn:oasis:names:tc:opendocument:xmlns:office:1.0}"
TEXT = "{urn:oasis:names:tc:opendocument:xmlns:text:1.0}"


def xlsx_values(path):
    with ZipFile(path) as book:
        shared = ET.fromstring(book.read("xl/sharedStrings.xml"))
        strings = ["".join(item.itertext()) for item in shared.findall(f"{MAIN}si")]
        sheet = ET.fromstring(book.read("xl/worksheets/sheet1.xml"))
        cells = {
            cell.attrib["r"]: cell
            for cell in sheet.iter(f"{MAIN}c")
        }
        values = {}
        for address, cell in cells.items():
            kind = cell.get("t", "n")
            value = cell.find(f"{MAIN}v")
            if kind == "s":
                values[address] = strings[int(value.text)]
            elif value is not None:
                values[address] = value.text
        formulas = [cell.attrib["r"] for cell in sheet.iter(f"{MAIN}f")]
    return values, formulas, set(cells)


def ods_values(path):
    with ZipFile(path) as book:
        content = ET.fromstring(book.read("content.xml"))
    rows = content.find(f".//{TABLE}table").findall(f"{TABLE}table-row")
    values = {}
    for row_number, row in enumerate(rows, 1):
        column = 1
        for cell in row.findall(f"{TABLE}table-cell"):
            count = int(cell.get(f"{TABLE}number-columns-repeated", "1"))
            value_type = cell.get(f"{OFFICE}value-type")
            value = cell.get(f"{OFFICE}value")
            text = "".join(item.text or "" for item in cell.iter(f"{TEXT}p"))
            for _ in range(count):
                if row_number <= 6 and column <= 3:
                    values[f"{chr(64 + column)}{row_number}"] = (value_type, value, text, f"{TABLE}formula" in cell.attrib)
                column += 1
    return values


expected = {
    "B2": "42",
    "B3": "42",
    "B5": "=1+1",
    "B6": "'=1+1",
    "C2": "integer",
    "C3": "text",
    "C4": "null",
    "C5": "text",
    "C6": "text",
}

for filename in ("source.xlsx", "calc-roundtrip.xlsx"):
    values, formulas, cells = xlsx_values(ROOT / filename)
    assert all(values.get(key) == value for key, value in expected.items()), (filename, values)
    assert "B4" not in cells, (filename, cells)
    assert not formulas, (filename, formulas)
    print(f"{filename}: expected values preserved; B4 blank; no formula cells")

table_expected = {
    "B2": "42",
    "B4": "42",
    "B5": "=1+1",
    "B6": "'=1+1",
    "C2": "integer",
    "C3": "null",
    "C4": "text",
    "C5": "text",
    "C6": "text",
}
for filename in ("table-source.xlsx", "table-calc-roundtrip.xlsx"):
    values, formulas, cells = xlsx_values(ROOT / filename)
    assert all(values.get(key) == value for key, value in table_expected.items()), (filename, values)
    assert "B3" not in cells, (filename, cells)
    assert not formulas, (filename, formulas)
    print(f"{filename}: declared ANY column values preserved; B3 blank; no formula cells")

ods = ods_values(ROOT / "calc-roundtrip.ods")
for cell, value in (("B3", "42"), ("B5", "=1+1"), ("B6", "'=1+1")):
    value_type, numeric_value, text, has_formula = ods[cell]
    assert value_type == "string" and text == value and not has_formula, (cell, ods[cell])
assert ods["B2"][0] == "float" and ods["B2"][1] == "42", ods["B2"]
assert ods["B4"][0] is None and ods["B4"][2] == "", ods["B4"]
for row, kind in ((2, "integer"), (3, "text"), (4, "null"), (5, "text"), (6, "text")):
    assert ods[f"C{row}"][2] == kind, ods[f"C{row}"]
assert not any(cell[3] for cell in ods.values()), ods
print("calc-roundtrip.ods: numeric/text/blank kinds and formula-shaped strings preserved; no formulas")

table_ods = ods_values(ROOT / "table-calc-roundtrip.ods")
for cell, value in (("B4", "42"), ("B5", "=1+1"), ("B6", "'=1+1")):
    value_type, numeric_value, text, has_formula = table_ods[cell]
    assert value_type == "string" and text == value and not has_formula, (cell, table_ods[cell])
assert table_ods["B2"][0] == "float" and table_ods["B2"][1] == "42", table_ods["B2"]
assert table_ods["B3"][0] is None and table_ods["B3"][2] == "", table_ods["B3"]
for row, kind in ((2, "integer"), (3, "null"), (4, "text"), (5, "text"), (6, "text")):
    assert table_ods[f"C{row}"][2] == kind, table_ods[f"C{row}"]
assert not any(cell[3] for cell in table_ods.values()), table_ods
print("table-calc-roundtrip.ods: declared ANY values and formula-shaped text preserved; no formulas")
