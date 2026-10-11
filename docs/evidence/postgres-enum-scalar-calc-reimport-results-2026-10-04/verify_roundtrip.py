from pathlib import Path
from xml.etree import ElementTree as ET
from zipfile import ZipFile

ROOT = Path(__file__).parent
XLSX_NS = {"x": "http://schemas.openxmlformats.org/spreadsheetml/2006/main"}
ODS_NS = {
    "table": "urn:oasis:names:tc:opendocument:xmlns:table:1.0",
    "office": "urn:oasis:names:tc:opendocument:xmlns:office:1.0",
}
EXPECTED = ["NULL", "東京", "<tag>&amp;", "=1+1", None]


def xlsx_labels(path: Path) -> list[str | None]:
    with ZipFile(path) as workbook:
        sheet = ET.fromstring(workbook.read("xl/worksheets/sheet1.xml"))
        assert not sheet.findall(".//x:f", XLSX_NS), f"formula in {path.name}"
        strings = ET.fromstring(workbook.read("xl/sharedStrings.xml"))
        cells = {cell.get("r"): cell for cell in sheet.findall(".//x:c", XLSX_NS)}
        labels = []
        for row in range(2, 7):
            cell = cells.get(f"B{row}")
            if row == 6:
                assert cell is None, f"SQL NULL label became a cell in {path.name}"
                labels.append(None)
                continue
            assert cell is not None and cell.get("t") == "s", f"B{row} is not text in {path.name}"
            index = int(cell.findtext("x:v", namespaces=XLSX_NS))
            labels.append("".join(strings[index].itertext()))
        return labels


def ods_labels(path: Path) -> list[str | None]:
    with ZipFile(path) as workbook:
        content = ET.fromstring(workbook.read("content.xml"))
    rows = content.findall(".//table:table/table:table-row", ODS_NS)
    labels = []
    for row_number, row in enumerate(rows[1:6], start=2):
        cells = row.findall("table:table-cell", ODS_NS)
        cell = cells[1]
        value = "".join(cell.itertext())
        if row_number == 6:
            assert value == "" and cell.get(f"{{{ODS_NS['office']}}}value-type") is None
            labels.append(None)
        else:
            assert cell.get(f"{{{ODS_NS['office']}}}value-type") == "string"
            assert cell.get(f"{{{ODS_NS['table']}}}formula") is None
            labels.append(value)
    return labels


artifacts = {
    "BookiE XLSX": xlsx_labels(ROOT / "source.xlsx"),
    "Calc ODS": ods_labels(ROOT / "recheck/source.ods"),
    "Calc XLSX": xlsx_labels(ROOT / "calc-roundtrip.xlsx"),
}
for name, labels in artifacts.items():
    assert labels == EXPECTED, f"{name}: {labels!r}"
print("Scalar enum labels remain text through XLSX → Calc ODS → XLSX; SQL NULL stays blank.")
print(repr(EXPECTED))
