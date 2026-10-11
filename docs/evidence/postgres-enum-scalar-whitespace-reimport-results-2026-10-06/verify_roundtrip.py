from pathlib import Path
from xml.etree import ElementTree as ET
from zipfile import ZipFile

ROOT = Path(__file__).parent
EXPECTED = {
    "B2": "NULL",
    "B3": "東京",
    "B4": "<tag>&amp;",
    "B5": "=1+1",
    "B6": " leading",
    "B7": "trailing ",
    "B8": None,
}
X = {"x": "http://schemas.openxmlformats.org/spreadsheetml/2006/main"}
O = {
    "office": "urn:oasis:names:tc:opendocument:xmlns:office:1.0",
    "table": "urn:oasis:names:tc:opendocument:xmlns:table:1.0",
    "text": "urn:oasis:names:tc:opendocument:xmlns:text:1.0",
}


def xlsx(path):
    with ZipFile(path) as archive:
        sheet = ET.fromstring(archive.read("xl/worksheets/sheet1.xml"))
        assert sheet.find(".//x:f", X) is None, f"formula in {path.name}"
        shared = (
            ET.fromstring(archive.read("xl/sharedStrings.xml"))
            if "xl/sharedStrings.xml" in archive.namelist()
            else None
        )
        cells = {cell.get("r"): cell for cell in sheet.findall(".//x:c", X)}
        values = {}
        for address, expected in EXPECTED.items():
            cell = cells.get(address)
            if cell is None or cell.get("t") not in ("s", "inlineStr"):
                values[address] = None
                continue
            if cell.get("t") == "inlineStr":
                values[address] = cell.findtext("x:is/x:t", namespaces=X)
            else:
                index = int(cell.findtext("x:v", namespaces=X))
                values[address] = "".join(shared[index].itertext())
            assert expected is not None, f"{address} should be blank"
        return values


def cell_text(cell):
    parts = []

    def append(node):
        if node.text:
            parts.append(node.text)
        for child in node:
            if child.tag == f"{{{O['text']}}}s":
                parts.append(" " * int(child.get(f"{{{O['text']}}}c", "1")))
            elif child.tag == f"{{{O['text']}}}tab":
                parts.append("\t")
            elif child.tag == f"{{{O['text']}}}line-break":
                parts.append("\n")
            else:
                append(child)
            if child.tail:
                parts.append(child.tail)

    append(cell)
    return "".join(parts)


def ods(path):
    with ZipFile(path) as archive:
        root = ET.fromstring(archive.read("content.xml"))
    assert root.find(".//*[@table:formula]", O) is None, f"formula in {path.name}"
    rows = root.findall(".//table:table-row", O)
    values = {}
    for row_number, (address, expected) in enumerate(EXPECTED.items(), start=1):
        cells = rows[row_number].findall("table:table-cell", O)
        cell = cells[1]
        kind = cell.get(f"{{{O['office']}}}value-type")
        if expected is None:
            assert kind is None, f"{address} should be blank"
            values[address] = None
        else:
            assert kind == "string", f"{address} is not text"
            values[address] = cell_text(cell)
    return values


stages = {
    "BookiE XLSX": xlsx(ROOT / "source.xlsx"),
    "Calc ODS": ods(ROOT / "source.ods"),
    "Calc re-saved XLSX": xlsx(ROOT / "recheck/source.xlsx"),
    "Gnumeric ODS": ods(ROOT / "gnumeric-roundtrip.ods"),
    "Gnumeric re-saved XLSX": xlsx(ROOT / "gnumeric-roundtrip.xlsx"),
}
for name, values in stages.items():
    assert values == EXPECTED, f"{name}: {values!r} != {EXPECTED!r}"
print(f"All {len(stages)} workbook stages preserved exact scalar enum labels, blank SQL NULL, and no formulas.")
