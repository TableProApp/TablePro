from pathlib import Path
from zipfile import ZipFile
from xml.etree import ElementTree as ET

BASE = Path(__file__).parent
EXPECTED = (
    '[0:3]={"-32768","0","32767",NULL}',
    '[2:6]={"-2147483648","-16777217","16777217","2147483647",NULL}',
)
NS = {
    "x": "http://schemas.openxmlformats.org/spreadsheetml/2006/main",
    "table": "urn:oasis:names:tc:opendocument:xmlns:table:1.0",
    "office": "urn:oasis:names:tc:opendocument:xmlns:office:1.0",
}

def xlsx_cells(path):
    with ZipFile(path) as archive:
        sheet = ET.fromstring(archive.read("xl/worksheets/sheet1.xml"))
        shared = ET.fromstring(archive.read("xl/sharedStrings.xml"))
        values = []
        for address in ("A2", "B2"):
            cell = sheet.find(f'.//x:c[@r="{address}"]', NS)
            assert cell is not None and cell.get("t") == "s", ET.tostring(sheet)
            assert cell.find("x:f", NS) is None, ET.tostring(cell)
            index = int(cell.findtext("x:v", namespaces=NS))
            values.append("".join(shared.find(f"x:si[{index + 1}]", NS).itertext()))
        return tuple(values)

def ods_cells(path):
    with ZipFile(path) as archive:
        root = ET.fromstring(archive.read("content.xml"))
        rows = root.findall(".//table:table-row", NS)
        cells = rows[1].findall("table:table-cell", NS)
        values = []
        for cell in cells[:2]:
            assert cell.get(f'{{{NS["office"]}}}value-type') == "string", ET.tostring(cell)
            assert cell.get(f'{{{NS["table"]}}}formula') is None, ET.tostring(cell)
            values.append("".join(cell.itertext()))
        return tuple(values)

for name, reader in (("source.xlsx", xlsx_cells), ("calc-roundtrip.ods", ods_cells), ("calc-roundtrip.xlsx", xlsx_cells)):
    actual = reader(BASE / name)
    assert actual == EXPECTED, f"{name}: {actual!r} != {EXPECTED!r}"
    assert all(all(token in value for token in ("[", "NULL")) for value in actual)
print("smallint[]/integer[] boundary text and both lower bounds, string cell kinds, and no-formula checks passed through Calc ODS/XLSX re-save")
