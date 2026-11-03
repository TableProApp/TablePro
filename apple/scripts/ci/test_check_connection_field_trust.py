#!/usr/bin/env python3
"""Fixture tests for check-connection-field-trust.py."""

import contextlib
import importlib.util
import io
import tempfile
import unittest
from pathlib import Path

SPEC = importlib.util.spec_from_file_location(
    "check_connection_field_trust", Path(__file__).with_name("check-connection-field-trust.py")
)
check = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(check)

CATALOG = '''public enum ConnectionFieldCatalog {
    static let trustByKey: [String: ConnectionFieldTrust] = [
        "esHosts": .destination,
        "esApiKey": .secret,
        "kafkaBootstrapServers": .destination,
        "mssqlAuthMethod": .localCredential(plainValues: ["sql"]),
    ]
}
'''

PLUGIN = '''enum MSSQLKey {
    static let authMethod = "mssqlAuthMethod"
}

enum KafkaConnectionField {
    static let bootstrapServers = "kafkaBootstrapServers"

    static func fields() -> [ConnectionField] {
        [
            ConnectionField(id: bootstrapServers, label: String(localized: "Servers"), fieldType: .hostList),
            ConnectionField(id: MSSQLKey.authMethod, label: "Authentication"),
            // ConnectionField(id: "commentedOut", label: "x"),
            ConnectionField(
                id: "esHosts",
                label: String(localized: "Hosts (\\(count))"),
                fieldType: .hostList
            ),
            ConnectionField(id: "esApiKey", label: "API Key", fieldType: .secure),
        ]
    }
}
'''

REPORTED = '''enum QdrantFields {
    static let all: [ConnectionField] = [
        ConnectionField(id: "qdApiKey", label: "API Key", fieldType: .secure),
        ConnectionField(id: "esHosts", label: "Hosts", fieldType: .secure),
        ConnectionField(id: QdrantKey.missing, label: "Missing"),
    ]
}
'''


class CheckConnectionFieldTrustTests(unittest.TestCase):
    def run_check(self, catalog, sources):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            catalog_path = root / "ConnectionFieldTrust.swift"
            catalog_path.write_text(catalog, encoding="utf-8")
            plugins = root / "Plugins"
            plugins.mkdir()
            for name, source in sources.items():
                (plugins / name).write_text(source, encoding="utf-8")
            saved = check.CATALOG, check.DECLARATION_ROOTS
            check.CATALOG, check.DECLARATION_ROOTS = catalog_path, [plugins]
            output = io.StringIO()
            try:
                with contextlib.redirect_stdout(output):
                    status = check.main([str(plugins)])
            finally:
                check.CATALOG, check.DECLARATION_ROOTS = saved
            return status, output.getvalue()

    def test_classified_literals_and_constants_pass(self):
        status, output = self.run_check(CATALOG, {"KafkaFields.swift": PLUGIN})
        self.assertEqual(status, 0, output)

    def test_a_new_id_a_misclassed_secret_and_an_unresolved_constant_fail(self):
        status, output = self.run_check(CATALOG, {"QdrantFields.swift": REPORTED})
        self.assertEqual(status, 1)
        self.assertIn("QdrantFields.swift:3: qdApiKey has no class", output)
        self.assertIn("QdrantFields.swift:4: esHosts is a secure field but its class is .destination", output)
        self.assertIn("QdrantFields.swift:5: cannot resolve QdrantKey.missing", output)

    def test_a_key_listed_twice_fails(self):
        catalog = CATALOG.replace('"esApiKey": .secret,', '"esApiKey": .secret,\n        "esHosts": .setting,')
        status, output = self.run_check(catalog, {"KafkaFields.swift": PLUGIN})
        self.assertEqual(status, 1)
        self.assertIn("esHosts is listed twice", output)

    def test_a_constant_declared_with_two_values_fails(self):
        other = 'enum MSSQLKey {\n    static let authMethod = "sqlServerAuth"\n}\n'
        source = PLUGIN.replace('enum MSSQLKey {\n    static let authMethod = "mssqlAuthMethod"\n}\n', "")
        status, output = self.run_check(
            CATALOG,
            {"KafkaFields.swift": source, "A.swift": 'enum MSSQLKey {\n    static let authMethod = "mssqlAuthMethod"\n}\n', "B.swift": other},
        )
        self.assertEqual(status, 1)
        self.assertIn("MSSQLKey.authMethod is declared with more than one value", output)

    def test_the_tree_passes(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            status = check.main([])
        self.assertEqual(status, 0, output.getvalue())


if __name__ == "__main__":
    unittest.main()
