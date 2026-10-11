from pathlib import Path
from zipfile import ZipFile
from xml.etree import ElementTree as ET

BASE = Path(__file__).parent
EXPECTED = (
    '{"2024-11-03 05:30:00.123456+00:00",'
    '"2024-11-03 06:30:00.123456+00:00",'
    '"0001-01-01 12:34:56+00:00 BC","infinity","-infinity",NULL}'
)
NS = {
    "x": "http://schemas.openxmlformats.org/spreadsheetml/2006/main",
    "table": "urn:oasis:names:tc:opendocument:xmlns:table:1.0",
    "office": "urn:oasis:names:tc:opendocument:xmlns:office:1.0",
}


def xlsx_cell(path):
    with ZipFile(path) as archive:
        sheet = ET.fromstring(archive.read("xl/worksheets/sheet1.xml"))
        cell = sheet.find('.//x:c[@r="A2"]', NS)
        assert cell is not None and cell.get("t") in ("s", "inlineStr"), ET.tostring(sheet)
        assert cell.find("x:f", NS) is None, ET.tostring(cell)
        if cell.get("t") == "inlineStr":
            return cell.findtext("x:is/x:t", namespaces=NS)
        shared = ET.fromstring(archive.read("xl/sharedStrings.xml"))
        index = int(cell.findtext("x:v", namespaces=NS))
        return "".join(shared.find(f"x:si[{index + 1}]", NS).itertext())


def ods_cell(path):
    with ZipFile(path) as archive:
        root = ET.fromstring(archive.read("content.xml"))
        rows = root.findall(".//table:table-row", NS)
        cell = rows[1].find("table:table-cell", NS)
        assert cell is not None
        assert cell.get(f'{{{NS["office"]}}}value-type') == "string", ET.tostring(cell)
        assert cell.get(f'{{{NS["table"]}}}formula') is None, ET.tostring(cell)
        return "".join(cell.itertext())


for name, reader in (
    ("source.xlsx", xlsx_cell),
    ("calc-roundtrip.ods", ods_cell),
    ("calc-roundtrip.xlsx", xlsx_cell),
    ("gnumeric-roundtrip.ods", ods_cell),
    ("gnumeric-roundtrip.xlsx", xlsx_cell),
):
    actual = reader(BASE / name)
    assert actual == EXPECTED, f"{name}: {actual!r} != {EXPECTED!r}"

assert '05:30:00.123456+00:00' in EXPECTED
assert '06:30:00.123456+00:00' in EXPECTED
assert ",NULL}" in EXPECTED and '"infinity"' in EXPECTED and '"-infinity"' in EXPECTED
print("Canonical UTC timestamptz[] text, string cell types and no-formula checks passed through Calc and Gnumeric XLSX/ODS/XLSX re-saves")
