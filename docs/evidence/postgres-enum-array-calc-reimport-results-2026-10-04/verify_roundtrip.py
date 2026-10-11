from pathlib import Path
from xml.etree import ElementTree as ET
from zipfile import ZipFile

ROOT = Path(__file__).parent
XLSX_NS = {"x": "http://schemas.openxmlformats.org/spreadsheetml/2006/main"}
ODS_NS = {
    "office": "urn:oasis:names:tc:opendocument:xmlns:office:1.0",
    "table": "urn:oasis:names:tc:opendocument:xmlns:table:1.0",
}


def xlsx_a2(path: Path) -> tuple[str, str]:
    with ZipFile(path) as workbook:
        sheet = ET.fromstring(workbook.read("xl/worksheets/sheet1.xml"))
        cell = sheet.find('.//x:c[@r="A2"]', XLSX_NS)
        assert cell is not None
        assert cell.get("t") == "s", f"A2 is not a shared string in {path.name}"
        index = int(cell.findtext("x:v", namespaces=XLSX_NS))
        strings = ET.fromstring(workbook.read("xl/sharedStrings.xml"))
        return "".join(strings[index].itertext()), cell.get("t", "")


def ods_a2(path: Path) -> tuple[str, str]:
    with ZipFile(path) as workbook:
        content = ET.fromstring(workbook.read("content.xml"))
    rows = content.findall(".//table:table/table:table-row", ODS_NS)
    cell = rows[1].find("table:table-cell", ODS_NS)
    assert cell is not None
    return "".join(cell.itertext()), cell.get(f"{{{ODS_NS['office']}}}value-type", "")


source_text, source_kind = xlsx_a2(ROOT / "source.xlsx")
ods_text, ods_kind = ods_a2(ROOT / "recheck/source.ods")
calc_text, calc_kind = xlsx_a2(ROOT / "calc-roundtrip.xlsx")
assert source_kind == calc_kind == "s"
assert ods_kind == "string"
assert source_text == ods_text == calc_text
print(f"source/ODS/Calc-re-saved XLSX preserve one string cell ({len(source_text)} code points)")
print(source_text)
