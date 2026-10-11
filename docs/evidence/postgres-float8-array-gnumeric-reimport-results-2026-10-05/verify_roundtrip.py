from pathlib import Path
from xml.etree import ElementTree as ET
from zipfile import ZipFile

ROOT = Path(__file__).parent
XLSX_NS = "{http://schemas.openxmlformats.org/spreadsheetml/2006/main}"
ODS_NS = {
    "office": "urn:oasis:names:tc:opendocument:xmlns:office:1.0",
    "table": "urn:oasis:names:tc:opendocument:xmlns:table:1.0",
}


def xlsx_a2(path: Path) -> tuple[str, str, bool]:
    with ZipFile(path) as workbook:
        sheet = ET.fromstring(workbook.read("xl/worksheets/sheet1.xml"))
        cell = next(cell for cell in sheet.iter(f"{XLSX_NS}c") if cell.get("r") == "A2")
        assert cell.get("t") in ("s", "inlineStr"), f"A2 is not a string in {path.name}"
        if cell.get("t") == "s":
            strings = ET.fromstring(workbook.read("xl/sharedStrings.xml"))
            text = "".join(strings[int(cell.findtext(f"{XLSX_NS}v"))].itertext())
        else:
            text = "".join(cell.find(f"{XLSX_NS}is").itertext()).strip()
        has_formula = any(sheet.iter(f"{XLSX_NS}f"))
    return text, cell.get("t", ""), has_formula


def ods_a2(path: Path) -> tuple[str, str, bool]:
    with ZipFile(path) as workbook:
        content = ET.fromstring(workbook.read("content.xml"))
    rows = content.findall(".//table:table/table:table-row", ODS_NS)
    cell = rows[1].find("table:table-cell", ODS_NS)
    assert cell is not None
    text = "".join(
        item.text or ""
        for item in cell.iter("{urn:oasis:names:tc:opendocument:xmlns:text:1.0}p")
    )
    has_formula = f"{{{ODS_NS['table']}}}formula" in cell.attrib
    return text, cell.get(f"{{{ODS_NS['office']}}}value-type", ""), has_formula


source_text, source_kind, source_formula = xlsx_a2(ROOT / "source.xlsx")
ods_text, ods_kind, ods_formula = ods_a2(ROOT / "gnumeric-roundtrip.ods")
gnumeric_text, gnumeric_kind, gnumeric_formula = xlsx_a2(ROOT / "gnumeric-roundtrip.xlsx")
assert source_text == ods_text == gnumeric_text
assert source_kind == "s" and gnumeric_kind in ("s", "inlineStr")
assert ods_kind == "string"
assert not (source_formula or ods_formula or gnumeric_formula)
elements = source_text[1:-1].split(",")
assert len(elements) == 7
assert elements[:2] == ['"1.0000000000000002"', '"-0"']
assert elements[2].startswith('"0.') and elements[2].endswith('5"')
assert len(elements[2]) > 100
assert elements[3:] == ['"NaN"', '"Infinity"', '"-Infinity"', "NULL"]
print("float8[] adjacent value, negative zero, minimum subnormal, NaN, infinities and NULL preserved as text; no formulas")
print(source_text)
