from pathlib import Path
from zipfile import ZipFile
from xml.etree import ElementTree as ET

BASE = Path(__file__).parent
EXPECTED = '{"NULL","","東京","a,b","a\\"b","<tag>&","=1+1","slash\\\\path",NULL}'
NS = {
    "x": "http://schemas.openxmlformats.org/spreadsheetml/2006/main",
    "table": "urn:oasis:names:tc:opendocument:xmlns:table:1.0",
    "office": "urn:oasis:names:tc:opendocument:xmlns:office:1.0",
}


def xlsx_cell(path):
    with ZipFile(path) as archive:
        sheet = ET.fromstring(archive.read("xl/worksheets/sheet1.xml"))
        assert sheet.find(".//x:f", NS) is None, f"formula in {path.name}"
        cell = sheet.find('.//x:c[@r="A2"]', NS)
        assert cell is not None and cell.get("t") in ("s", "inlineStr"), path.name
        if cell.get("t") == "inlineStr":
            return "".join(cell.find("x:is", NS).itertext()).strip()
        shared = ET.fromstring(archive.read("xl/sharedStrings.xml"))
        index = int(cell.findtext("x:v", namespaces=NS))
        return "".join(shared.find(f"x:si[{index + 1}]", NS).itertext())


def ods_cell(path):
    with ZipFile(path) as archive:
        root = ET.fromstring(archive.read("content.xml"))
        assert root.find(".//*[@table:formula]", {"table": NS["table"]}) is None
        rows = root.findall(".//table:table-row", NS)
        cell = rows[1].find("table:table-cell", NS)
        assert cell is not None
        assert cell.get(f"{{{NS['office']}}}value-type") == "string", path.name
        return "".join(cell.itertext()).strip()


for name, reader in (
    ("source.xlsx", xlsx_cell),
    ("gnumeric-roundtrip.ods", ods_cell),
    ("gnumeric-roundtrip.xlsx", xlsx_cell),
):
    actual = reader(BASE / name)
    assert actual == EXPECTED, f"{name}: {actual!r} != {EXPECTED!r}"

assert '"=1+1"' in EXPECTED
assert ',NULL}' in EXPECTED
print("Gnumeric preserved enum[] text, including formula-shaped label and escaped values, as text without formulas.")
