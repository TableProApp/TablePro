from pathlib import Path
from zipfile import ZipFile
from xml.etree import ElementTree as ET

BASE = Path(__file__).parent
XLSX = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
TABLE = "urn:oasis:names:tc:opendocument:xmlns:table:1.0"
OFFICE = "urn:oasis:names:tc:opendocument:xmlns:office:1.0"
NS = {"x": XLSX, "t": TABLE, "o": OFFICE}

EXPECTED = {
    "date": '{"0002-12-31 BC","10000-01-01","infinity","-infinity",NULL}',
    "timestamp": '{"0002-12-31 23:59:59.999999 BC","10000-01-01 00:00:00","294276-12-31 23:59:59.999999","infinity","-infinity",NULL}',
    "time": '{"00:00:00","12:34:56.123456","23:59:59.999999","24:00:00",NULL}',
    "timetz": '{"00:00:00+15:59:00","23:59:59.999999-15:59:00","12:34:56.123456+05:30:00","12:34:56.123456-05:30:00",NULL}',
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
        assert root.find(".//*[@table:formula]", {"table": TABLE}) is None, f"formula in {path.name}"
        rows = root.findall(".//t:table-row", NS)
        cell = rows[1].find("t:table-cell", NS)
        assert cell is not None and cell.get(f"{{{OFFICE}}}value-type") == "string", path.name
        return "".join(cell.itertext()).strip()


for name, expected in EXPECTED.items():
    for suffix, reader in (
        ("source.xlsx", xlsx_cell),
        ("gnumeric.ods", ods_cell),
        ("gnumeric.xlsx", xlsx_cell),
    ):
        path = BASE / f"{name}.{suffix}"
        actual = reader(path)
        assert actual == expected, f"{path.name}: {actual!r} != {expected!r}"

print("All four temporal arrays retain exact text and string cell types across XLSX/ODS/XLSX; no formulas found.")
