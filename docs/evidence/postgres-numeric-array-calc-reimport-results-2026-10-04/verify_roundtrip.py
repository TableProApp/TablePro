from pathlib import Path
from xml.etree import ElementTree as ET
from zipfile import ZipFile

ROOT = Path(__file__).parent
XLSX_NS = "{http://schemas.openxmlformats.org/spreadsheetml/2006/main}"
ODS_NS = {
    "office": "urn:oasis:names:tc:opendocument:xmlns:office:1.0",
    "table": "urn:oasis:names:tc:opendocument:xmlns:table:1.0",
}
EXPECTED = (
    r'{"1234567890123456789012345678901234567890",'
    r'"0.123456789012345678901234567891","1.2300",'
    r'"NaN","Infinity","-Infinity",NULL}'
)

def xlsx_a2(path: Path) -> tuple[str, str, bool]:
    with ZipFile(path) as workbook:
        sheet = ET.fromstring(workbook.read("xl/worksheets/sheet1.xml"))
        cell = next(cell for cell in sheet.iter(f"{XLSX_NS}c") if cell.get("r") == "A2")
        assert cell.get("t") == "s", f"A2 is not a shared string in {path.name}"
        strings = ET.fromstring(workbook.read("xl/sharedStrings.xml"))
        text = "".join(strings[int(cell.findtext(f"{XLSX_NS}v"))].itertext())
        has_formula = any(sheet.iter(f"{XLSX_NS}f"))
    return text, cell.get("t", ""), has_formula

def ods_a2(path: Path) -> tuple[str, str, bool]:
    with ZipFile(path) as workbook:
        content = ET.fromstring(workbook.read("content.xml"))
    rows = content.findall(".//table:table/table:table-row", ODS_NS)
    cell = rows[1].find("table:table-cell", ODS_NS)
    assert cell is not None
    text = "".join(item.text or "" for item in cell.iter("{urn:oasis:names:tc:opendocument:xmlns:text:1.0}p"))
    has_formula = f"{{{ODS_NS['table']}}}formula" in cell.attrib
    return text, cell.get(f"{{{ODS_NS['office']}}}value-type", ""), has_formula

source_text, source_kind, source_formula = xlsx_a2(ROOT / "source.xlsx")
ods_text, ods_kind, ods_formula = ods_a2(ROOT / "calc-roundtrip.ods")
calc_text, calc_kind, calc_formula = xlsx_a2(ROOT / "calc-roundtrip.xlsx")
assert source_text == EXPECTED
assert source_text == ods_text == calc_text
assert source_kind == calc_kind == "s"
assert ods_kind == "string"
assert not (source_formula or ods_formula or calc_formula)
print("numeric[] precision, scale, NaN, infinities and SQL NULL are unchanged in XLSX, ODS and Calc re-saved XLSX; no formulas")
print(source_text)
