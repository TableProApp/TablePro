from pathlib import Path
from xml.etree import ElementTree as ET
from zipfile import ZipFile

ROOT = Path(__file__).parent
EXPECTED = r'{"NULL",""," leading","trailing ","東京","a,b","a\"b","<tag>&","=1+1","slash\\path",NULL}'
X = {"x": "http://schemas.openxmlformats.org/spreadsheetml/2006/main"}
O = {
    "office": "urn:oasis:names:tc:opendocument:xmlns:office:1.0",
    "table": "urn:oasis:names:tc:opendocument:xmlns:table:1.0",
}


def xlsx(path):
    with ZipFile(path) as archive:
        sheet = ET.fromstring(archive.read("xl/worksheets/sheet1.xml"))
        assert sheet.find(".//x:f", X) is None, f"formula in {path.name}"
        cell = sheet.find('.//x:c[@r="A2"]', X)
        assert cell is not None and cell.get("t") in ("s", "inlineStr"), path.name
        if cell.get("t") == "inlineStr":
            return "".join(cell.find("x:is", X).itertext()).strip()
        shared = ET.fromstring(archive.read("xl/sharedStrings.xml"))
        index = int(cell.findtext("x:v", namespaces=X))
        return "".join(shared[index].itertext()).strip()


def ods(path):
    with ZipFile(path) as archive:
        content = ET.fromstring(archive.read("content.xml"))
    assert content.find(".//*[@table:formula]", O) is None, f"formula in {path.name}"
    rows = content.findall(".//table:table-row", O)
    cell = rows[1].find("table:table-cell", O)
    assert cell is not None
    assert cell.get(f"{{{O['office']}}}value-type") == "string", path.name
    return "".join(cell.itertext()).strip()


artifacts = {
    "BookiE XLSX": xlsx(ROOT / "source.xlsx"),
    "Calc ODS": ods(ROOT / "source.ods"),
    "Calc re-saved XLSX": xlsx(ROOT / "recheck/source.xlsx"),
    "Gnumeric ODS": ods(ROOT / "gnumeric-roundtrip.ods"),
    "Gnumeric re-saved XLSX": xlsx(ROOT / "gnumeric-roundtrip.xlsx"),
}
for name, text in artifacts.items():
    assert text == EXPECTED, f"{name}: {text!r} != {EXPECTED!r}"
print(f"All {len(artifacts)} workbook stages preserved the exact enum[] text as a string without formulas.")
