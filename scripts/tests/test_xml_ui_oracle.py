import importlib.util
from pathlib import Path
import unittest
import xml.etree.ElementTree as ET

SOURCE = Path(__file__).resolve().parents[2] / "crates/app/tests/gtk_xml.py"
spec = importlib.util.spec_from_file_location("xml_scenarios", SOURCE)
scenarios = importlib.util.module_from_spec(spec)
spec.loader.exec_module(scenarios)

FIXTURE = """<rows><row><id>1</id><note>a&#13;b&#13;
c
\t&amp;#13; &lt;tag&gt; &amp; &quot;quotes&quot; 東京 😀</note></row>
<row><id>2</id><note></note></row><row><id>3</id><note null="true"/></row></rows>"""


class XmlOracleTests(unittest.TestCase):
    def test_exact_parser_round_trip(self):
        scenarios.assert_xml(ET.fromstring(FIXTURE))

    def test_normalized_carriage_returns_are_rejected(self):
        parsed = ET.fromstring(FIXTURE.replace("&#13;", "\r"))
        with self.assertRaises(AssertionError):
            scenarios.assert_xml(parsed)

    def test_empty_text_cannot_be_reported_as_null(self):
        parsed = ET.fromstring(FIXTURE.replace("<note></note>", '<note null="true"/>'))
        with self.assertRaises(AssertionError):
            scenarios.assert_xml(parsed)

    def test_malformed_xml_is_a_parser_error(self):
        with self.assertRaises(ET.ParseError):
            ET.fromstring("<rows><row></rows>")

    def test_scenarios_are_registered_by_default(self):
        cases = scenarios.scenarios(object())
        self.assertEqual([case.__name__ for case in cases], [
            "xml_export_preserves_line_endings_and_null_distinctions",
            "xml_export_refuses_illegal_text_without_publishing",
        ])
        self.assertTrue(all(case.environment == "local" for case in cases))
        self.assertIn("scenarios.extend(gtk_xml.scenarios(sys.modules[__name__]))", SOURCE.with_name("gtk_safety.py").read_text())


if __name__ == "__main__":
    unittest.main()
