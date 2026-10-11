from pathlib import Path
from zipfile import ZipFile
from xml.etree import ElementTree as ET

BASE = Path(__file__).parent
EXPECTED = {
    "B2": "NULL",
    "B3": "東京",
    "B4": "<tag>&amp;",
    "B5": "=1+1",
    "B6": None,
}
NS = {
    "x": "http://schemas.openxmlformats.org/spreadsheetml/2006/main",
    "table": "urn:oasis:names:tc:opendocument:xmlns:table:1.0",
    "office": "urn:oasis:names:tc:opendocument:xmlns:office:1.0",
}


def xlsx_cells(path):
    with ZipFile(path) as archive:
        sheet = ET.fromstring(archive.read("xl/worksheets/sheet1.xml"))
        shared = (
            ET.fromstring(archive.read("xl/sharedStrings.xml"))
            if "xl/sharedStrings.xml" in archive.namelist()
            else None
        )
        assert sheet.find(".//x:f", NS) is None, ET.tostring(sheet)
        values = {}
        for cell_name, expected in EXPECTED.items():
            cell = sheet.find(f'.//x:c[@r="{cell_name}"]', NS)
            if cell is None:
                values[cell_name] = None
                continue
            kind = cell.get("t")
            if expected is not None:
                assert kind in ("s", "inlineStr"), ET.tostring(cell)
            if kind == "inlineStr":
                values[cell_name] = cell.findtext("x:is/x:t", namespaces=NS)
            elif kind == "s":
                index = int(cell.findtext("x:v", namespaces=NS))
                values[cell_name] = "".join(shared.find(f"x:si[{index + 1}]", NS).itertext())
            else:
                values[cell_name] = None
        return values


def ods_cells(path):
    with ZipFile(path) as archive:
        root = ET.fromstring(archive.read("content.xml"))
        assert root.find(f'.//*[@table:formula]', NS) is None, ET.tostring(root)
        rows = root.findall(".//table:table-row", NS)
        values = {}
        for row_number, cell_name in enumerate(EXPECTED, start=2):
            row = rows[row_number - 1]
            cells = row.findall("table:table-cell", NS)
            cell = cells[1]
            if cell_name == "B6":
                assert cell.get(f'{{{NS["office"]}}}value-type') is None
                assert cell.get(f'{{{NS["table"]}}}formula') is None
                values[cell_name] = None
            else:
                assert cell.get(f'{{{NS["office"]}}}value-type') == "string", ET.tostring(cell)
                assert cell.get(f'{{{NS["table"]}}}formula') is None, ET.tostring(cell)
                values[cell_name] = "".join(cell.itertext())
        return values


for name, reader in (
    ("source.xlsx", xlsx_cells),
    ("gnumeric-roundtrip.ods", ods_cells),
    ("gnumeric-roundtrip.xlsx", xlsx_cells),
):
    actual = reader(BASE / name)
    assert actual == EXPECTED, f"{name}: {actual!r} != {EXPECTED!r}"

print("Gnumeric preserved enum literal NULL, Unicode, markup and =1+1 as string cells; SQL NULL stayed blank and no formula was created")
