from pathlib import Path
from zipfile import ZipFile
from xml.etree import ElementTree as ET

BASE = Path(__file__).parent
EXPECTED = '{"t","f",NULL,"t","f"}'
NS = {
    "x": "http://schemas.openxmlformats.org/spreadsheetml/2006/main",
    "table": "urn:oasis:names:tc:opendocument:xmlns:table:1.0",
    "office": "urn:oasis:names:tc:opendocument:xmlns:office:1.0",
}

def xlsx_cell(path):
    with ZipFile(path) as archive:
        sheet = ET.fromstring(archive.read("xl/worksheets/sheet1.xml"))
        shared = ET.fromstring(archive.read("xl/sharedStrings.xml"))
        cell = sheet.find('.//x:c[@r="A2"]', NS)
        assert cell is not None and cell.get("t") == "s", ET.tostring(sheet)
        assert cell.find("x:f", NS) is None, ET.tostring(cell)
        index = int(cell.findtext("x:v", namespaces=NS))
        return "".join(shared.find(f"x:si[{index + 1}]", NS).itertext())

def ods_cell(path):
    with ZipFile(path) as archive:
        root = ET.fromstring(archive.read("content.xml"))
        rows = root.findall(".//table:table-row", NS)
        cell = rows[1].find("table:table-cell", NS)
        assert cell is not None and cell.get(f'{{{NS["office"]}}}value-type') == "string", ET.tostring(cell)
        assert cell.get(f'{{{NS["table"]}}}formula') is None, ET.tostring(cell)
        return "".join(cell.itertext())

for name, reader in (("source.xlsx", xlsx_cell), ("calc-roundtrip.ods", ods_cell), ("calc-roundtrip.xlsx", xlsx_cell)):
    actual = reader(BASE / name)
    assert actual == EXPECTED, f"{name}: {actual!r} != {EXPECTED!r}"
    assert all(token in actual for token in ('"t"', '"f"', "NULL"))
print(f"boolean[] text ({len(EXPECTED)} characters), string cell kinds and no-formula checks passed through Calc ODS/XLSX re-save")
