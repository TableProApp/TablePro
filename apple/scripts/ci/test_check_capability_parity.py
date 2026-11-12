#!/usr/bin/env python3
"""Fixture tests for check-capability-parity.py."""

import contextlib
import importlib.util
import io
import tempfile
import unittest
from pathlib import Path

SPEC = importlib.util.spec_from_file_location(
    "check_capability_parity", Path(__file__).with_name("check-capability-parity.py")
)
check = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(check)

DRIVER_PLUGIN = """public protocol DriverPlugin: TableProPlugin {
    static var databaseTypeId: String { get }
    static var supportsHealthMonitor: Bool { get }
}

public extension DriverPlugin {
    static var additionalDatabaseTypeIds: [String] { [] }
    static var containerEntityName: String { "Database" }
    static var supportsHealthMonitor: Bool { true }
    static var supportsForeignKeyDisable: Bool { true }
    static var supportsSSH: Bool { true }
    static var supportsSSL: Bool { true }
}
"""

PLIST = '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0">\n<dict/>\n</plist>\n'


def capabilities(ssh="true", ssl="true", fk="true", extra=""):
    return f"""PluginMetadataSnapshot.CapabilityFlags(
                    supportsSchemaSwitching: false,
                    supportsImport: true,
                    supportsExport: true,
                    supportsSSH: {ssh},
                    supportsSSL: {ssl},
                    supportsCascadeDrop: false,
                    supportsForeignKeyDisable: {fk},{extra}
                    supportsReadOnlyMode: true,
                    supportsQueryProgress: false,
                    requiresReconnectForDatabaseSwitch: false,
                    supportsDropDatabase: false
                )"""


def schema(container='"Database"'):
    return f"""PluginMetadataSnapshot.SchemaInfo(
                    defaultSchemaName: "public",
                    defaultGroupName: "main",
                    tableEntityName: "Tables",
                    containerEntityName: {container},
                    defaultPrimaryKeyColumn: nil,
                    immutableColumns: [],
                    systemDatabaseNames: [],
                    systemSchemaNames: [],
                    fileExtensions: [],
                    databaseGroupingStrategy: .byDatabase,
                    structureColumnFields: [.name, .type]
                )"""


def snapshot(health="true", caps=None, info=None, tail=""):
    return f"""PluginMetadataSnapshot(
                displayName: "Example", iconName: "cylinder", defaultPort: 1_234,
                requiresAuthentication: true, supportsForeignKeys: true, supportsSchemaEditing: true,
                isDownloadable: true, primaryUrlScheme: "example", parameterStyle: .questionMark,
                navigationModel: .standard, explainVariants: [], pathFieldRole: .database,
                supportsHealthMonitor: {health}, urlSchemes: ["example"], postConnectActions: [],
                brandColorHex: "#123456", queryLanguageName: "SQL", editorLanguage: .sql,
                connectionMode: .network, supportsDatabaseSwitching: true,
                capabilities: {caps or capabilities()},
                schema: {info or schema()},
                editor: PluginMetadataSnapshot.EditorConfig(
                    sqlDialect: nil, statementCompletions: [], columnTypesByCategory: ["Text": ["TEXT"]]
                ),
                connection: PluginMetadataSnapshot.ConnectionConfig(
                    category: .relational, tagline: String(localized: "Example (\\(1 + 1)) \\"engine\\"")
                )
            ){tail}"""


def registry(*entries, helpers=""):
    listed = ",\n".join(f'            ("{type_id}", {body})' for type_id, body in entries)
    return f"""import Foundation

extension PluginMetadataRegistry {{
    func examplePluginDefaults() -> [(typeId: String, snapshot: PluginMetadataSnapshot)] {{
        [
{listed}
        ]
    }}
{helpers}
}}
"""


def plugin_class(name, type_id, *statics, extra=""):
    lines = "".join(f"    {line}\n" for line in statics)
    return f"""import Foundation
import TableProPluginKit

final class {name}: NSObject, TableProPlugin, DriverPlugin {{
    static let pluginName = "{name}"
    static let databaseTypeId = "{type_id}"
{lines}
    func createDriver(config: DriverConnectionConfig) -> any PluginDatabaseDriver {{
        ExampleDriver(config: config)
    }}
}}
{extra}"""


class CheckCapabilityParityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.apple = Path(self.temp.name)
        kit = self.apple / "Plugins" / "TableProPluginKit"
        kit.mkdir(parents=True)
        (kit / "DriverPlugin.swift").write_text(DRIVER_PLUGIN, encoding="utf-8")
        (self.apple / "TablePro" / "Core" / "Plugins").mkdir(parents=True)

    def tearDown(self):
        self.temp.cleanup()

    def curated(self, text, name="PluginMetadataRegistry+ExampleDefaults.swift"):
        (self.apple / "TablePro" / "Core" / "Plugins" / name).write_text(text, encoding="utf-8")

    def plugin(self, folder, swift, name="ExamplePlugin.swift"):
        directory = self.apple / "Plugins" / folder
        directory.mkdir(parents=True, exist_ok=True)
        (directory / "Info.plist").write_text(PLIST, encoding="utf-8")
        (directory / name).write_text(swift, encoding="utf-8")
        return directory

    def problems(self):
        unreadable, mismatches, _ = check.problems_in(self.apple)
        return unreadable, mismatches

    def run_main(self):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = check.main(["--apple", str(self.apple)])
        return code, out.getvalue(), err.getvalue()

    def test_a_plugin_that_keeps_the_defaults_the_entry_states_passes(self):
        self.curated(registry(("Example", snapshot())))
        self.plugin("ExampleDriverPlugin", plugin_class("ExamplePlugin", "Example"))
        code, out, err = self.run_main()
        self.assertEqual(code, 0, err)
        self.assertIn("1 driver plugins agree", out)

    def test_a_curated_health_monitor_opt_out_the_plugin_does_not_repeat_fails(self):
        # #2700: the plugin's default `true` replaced the curated opt-out and the app pinged the connection.
        self.curated(registry(("SQLite", snapshot(health="false"))))
        self.plugin("SQLiteDriverPlugin", plugin_class("SQLitePlugin", "SQLite"))
        unreadable, mismatches = self.problems()
        self.assertEqual(unreadable, [])
        self.assertEqual(len(mismatches), 1)
        self.assertIn("SQLite supportsHealthMonitor: curated false", mismatches[0])
        self.assertIn("plugin true (PluginKit default, Plugins/TableProPluginKit/DriverPlugin.swift:9)", mismatches[0])

        self.plugin("SQLiteDriverPlugin", plugin_class("SQLitePlugin", "SQLite", "static let supportsHealthMonitor = false"))
        self.assertEqual(self.problems(), ([], []))

    def test_a_plugin_opt_out_the_curated_entry_does_not_repeat_fails(self):
        self.curated(registry(("Example", snapshot())))
        self.plugin("ExampleDriverPlugin", plugin_class("ExamplePlugin", "Example", "static let supportsHealthMonitor = false"))
        _, mismatches = self.problems()
        self.assertEqual(len(mismatches), 1)
        self.assertIn("curated true", mismatches[0])
        self.assertIn("plugin false (Plugins/ExampleDriverPlugin/ExamplePlugin.swift:7)", mismatches[0])

    def test_a_duckdb_style_transport_flip_fails_until_both_sides_agree(self):
        self.curated(registry(("DuckDB", snapshot(caps=capabilities(ssh="false", ssl="false")))))
        self.plugin("DuckDBDriverPlugin", plugin_class("DuckDBPlugin", "DuckDB"))
        _, mismatches = self.problems()
        self.assertEqual(
            [line.split(":")[0] for line in mismatches], ["DuckDB supportsSSH", "DuckDB supportsSSL"]
        )

        self.curated(registry(("DuckDB", snapshot(caps=capabilities(ssh="true", ssl="false")))))
        self.plugin(
            "DuckDBDriverPlugin",
            plugin_class("DuckDBPlugin", "DuckDB", "static let supportsSSH = true", "static let supportsSSL: Bool = false"),
        )
        self.assertEqual(self.problems(), ([], []))

    def test_a_container_name_and_a_foreign_key_flag_the_plugin_does_not_restate_fail(self):
        self.curated(registry(("Beancount", snapshot(caps=capabilities(fk="false"), info=schema('"Ledger"')))))
        self.plugin("BeancountDriverPlugin", plugin_class("BeancountPlugin", "Beancount"))
        _, mismatches = self.problems()
        self.assertEqual(len(mismatches), 2)
        self.assertIn('Beancount containerEntityName: curated "Ledger"', mismatches[1])
        self.assertIn('plugin "Database"', mismatches[1])

        statics = ("static let supportsForeignKeyDisable = false", 'static var containerEntityName: String { "Ledger" }')
        self.plugin("BeancountDriverPlugin", plugin_class("BeancountPlugin", "Beancount", *statics))
        self.assertEqual(self.problems(), ([], []))

    def test_references_to_literals_are_followed_on_both_sides(self):
        helpers = """
    static let exampleSchemaInfo = PluginMetadataSnapshot.SchemaInfo(
        defaultSchemaName: "", defaultGroupName: "main", tableEntityName: "Tables", containerEntityName: "Schema",
        defaultPrimaryKeyColumn: nil, immutableColumns: [], systemDatabaseNames: [], systemSchemaNames: [],
        fileExtensions: [], databaseGroupingStrategy: .bySchema, structureColumnFields: [.name]
    )

    private func exampleCapabilities(lite: Bool) -> PluginMetadataSnapshot.CapabilityFlags {
        """ + capabilities(ssh="false", extra="\n                    exactRowCountIsFullScan: lite,") + """
    }
"""
        self.curated(registry(
            ("Example", snapshot(caps="exampleCapabilities(lite: false)", info="Self.exampleSchemaInfo")),
            helpers=helpers,
        ))
        metadata = 'enum ExampleMetadata {\n    static let containerEntityName = "Schema"\n}\n'
        self.plugin(
            "ExampleDriverPlugin",
            plugin_class(
                "ExamplePlugin", "Example",
                "static let containerEntityName = ExampleMetadata.containerEntityName",
                "static let supportsSSH = Self.remoteTransport",
                "static let remoteTransport = false",
            ),
        )
        (self.apple / "Plugins" / "ExampleDriverPlugin" / "ExampleMetadata.swift").write_text(metadata, encoding="utf-8")
        self.assertEqual(self.problems(), ([], []))

    def test_a_snapshot_parameter_named_after_a_type_reads_that_entry_and_test_doubles_do_not_count(self):
        fork = """PluginMetadataSnapshot(
                displayName: "Fork", iconName: "cylinder", defaultPort: 1,
                requiresAuthentication: true, supportsForeignKeys: true, supportsSchemaEditing: true,
                isDownloadable: true, primaryUrlScheme: "fork", parameterStyle: .dollar,
                navigationModel: .standard, explainVariants: [], pathFieldRole: .database,
                supportsHealthMonitor: example.supportsHealthMonitor, urlSchemes: ["fork"], postConnectActions: [],
                brandColorHex: "#000000", queryLanguageName: "SQL", editorLanguage: .sql,
                connectionMode: .network, supportsDatabaseSwitching: true,
                capabilities: example.capabilities, schema: example.schema, editor: example.editor,
                connection: example.connection
            ).withSystemNames(databases: [], schemas: ["sys"])"""
        helpers = f"""
    static func forkDefaults(example: PluginMetadataSnapshot) -> [(typeId: String, snapshot: PluginMetadataSnapshot)] {{
        [("Fork", {fork})]
    }}
"""
        self.curated(registry(("Example", snapshot(caps=capabilities(fk="false"))), helpers=helpers))
        self.plugin("ExampleDriverPlugin", plugin_class("ExamplePlugin", "Example", "static let supportsForeignKeyDisable = false"))
        self.plugin(
            "ForkDriverPlugin",
            plugin_class("ForkPlugin", "Fork", "static let supportsForeignKeyDisable = ExamplePlugin.supportsForeignKeyDisable"),
            name="ForkPlugin.swift",
        )
        # A test bundle's double of the same name must not make the reference ambiguous.
        tests = self.apple / "Plugins" / "ExampleDriverTests"
        tests.mkdir()
        doubled = plugin_class("ExamplePlugin", "Example", "static let supportsForeignKeyDisable = true")
        (tests / "Doubles.swift").write_text(doubled, encoding="utf-8")
        self.assertEqual(self.problems(), ([], []))

        self.plugin("ForkDriverPlugin", plugin_class("ForkPlugin", "Fork"), name="ForkPlugin.swift")
        _, mismatches = self.problems()
        self.assertEqual([line.split(":")[0] for line in mismatches], ["Fork supportsForeignKeyDisable"])

    def test_a_reference_to_an_undeclared_static_falls_back_to_the_default_only_on_a_driver(self):
        self.curated(registry(("Example", snapshot()), ("Fork", snapshot())))
        self.plugin("ExampleDriverPlugin", plugin_class("ExamplePlugin", "Example"))
        self.plugin(
            "ForkDriverPlugin",
            plugin_class(
                "ForkPlugin", "Fork",
                "static let supportsSSH = ExamplePlugin.supportsSSH",
                "static let supportsSSL = ForkMetadata.supportsSSL",
                extra="enum ForkMetadata {}\n",
            ),
            name="ForkPlugin.swift",
        )
        unreadable, mismatches = self.problems()
        self.assertEqual(mismatches, [])
        self.assertEqual(len(unreadable), 1)
        self.assertIn("Fork supportsSSL", unreadable[0])
        self.assertIn("ForkMetadata declares no static supportsSSL", unreadable[0])

    def test_an_expression_that_is_not_a_literal_is_a_failure_not_a_skip(self):
        self.curated(registry(("Example", snapshot(caps=capabilities(ssh="!isEmbedded")))))
        statics = ("static let supportsSSL = isRemote && true", 'static let containerEntityName = "\\(prefix)base"')
        self.plugin("ExampleDriverPlugin", plugin_class("ExamplePlugin", "Example", *statics))
        unreadable, mismatches = self.problems()
        self.assertEqual(mismatches, [])
        self.assertEqual(
            [line.split(":")[0] for line in unreadable],
            ["Example supportsSSH", "Example supportsSSL", "Example containerEntityName"],
        )
        self.assertTrue(all("as a literal" in line for line in unreadable), unreadable)

        code, _, err = self.run_main()
        self.assertEqual(code, 1)
        self.assertIn("::error::Example supportsSSH", err)
        self.assertNotIn("declare the same value", err)

    def test_an_argument_the_entry_does_not_pass_is_a_failure(self):
        caps = capabilities().replace("                    supportsSSL: true,\n", "")
        self.curated(registry(("Example", snapshot(caps=caps))))
        self.plugin("ExampleDriverPlugin", plugin_class("ExamplePlugin", "Example"))
        unreadable, _ = self.problems()
        self.assertEqual(len(unreadable), 1)
        self.assertIn("CapabilityFlags(...) passes no supportsSSL", unreadable[0])

    def test_a_plugin_with_no_curated_entry_or_two_is_a_failure(self):
        self.curated(registry(("Other", snapshot())))
        self.plugin("ExampleDriverPlugin", plugin_class("ExamplePlugin", "Example"))
        unreadable, _ = self.problems()
        self.assertEqual(unreadable, ['ExampleDriverPlugin: 0 curated entries for "Example" in ' + check.REGISTRY_GLOB])

        self.curated(registry(("Example", snapshot()), ("Example", snapshot())))
        unreadable, _ = self.problems()
        self.assertEqual(len(unreadable), 1)
        self.assertIn('2 curated entries for "Example"', unreadable[0])

    def test_a_static_declared_twice_is_a_failure(self):
        self.curated(registry(("Example", snapshot())))
        self.plugin(
            "ExampleDriverPlugin",
            plugin_class("ExamplePlugin", "Example", "static let supportsSSH = true",
                         extra="extension ExamplePlugin {\n    static let supportsSSH = false\n}\n"),
        )
        unreadable, _ = self.problems()
        self.assertEqual(len(unreadable), 1)
        self.assertIn("ExamplePlugin declares supportsSSH 2 times", unreadable[0])

    def test_a_conformance_declared_in_an_extension_counts(self):
        self.curated(registry(("Example", snapshot(health="false"))))
        swift = plugin_class("ExamplePlugin", "Example").replace(", DriverPlugin {", " {")
        swift += "\nextension ExamplePlugin: DriverPlugin {\n    static let supportsHealthMonitor = false\n}\n"
        self.plugin("ExampleDriverPlugin", swift)
        code, out, err = self.run_main()
        self.assertEqual(code, 0, err)
        self.assertIn("1 driver plugins agree", out)

    def test_a_static_in_an_extension_counts(self):
        self.curated(registry(("Example", snapshot(health="false"))))
        self.plugin("ExampleDriverPlugin", plugin_class("ExamplePlugin", "Example"))
        (self.apple / "Plugins" / "ExampleDriverPlugin" / "ExamplePlugin+Health.swift").write_text(
            "extension ExamplePlugin {\n    static var supportsHealthMonitor: Bool {\n        return false\n    }\n}\n",
            encoding="utf-8",
        )
        self.assertEqual(self.problems(), ([], []))

    def test_comments_strings_and_nested_types_do_not_count(self):
        self.curated(registry(("Example", snapshot(
            caps=capabilities(ssh="false /* supportsSSL: false, */"),
            info=schema('"Data\\"base\\" (main)"'),
        ))))
        swift = plugin_class(
            "ExamplePlugin", "Example",
            "// static let supportsSSL = false",
            'static let note = "static let supportsHealthMonitor = false"',
            'static let raw = #"static let supportsForeignKeyDisable = "no""#',
            "static let supportsSSH = false // true until Remote mode dialed a server",
            'static let containerEntityName = "Data\\"base\\" (main)"',
            "enum Inner {\n        static let supportsSSH = true\n    }",
        )
        self.plugin("ExampleDriverPlugin", swift)
        self.assertEqual(self.problems(), ([], []))

    def test_a_modifier_that_may_change_a_compared_capability_is_a_failure(self):
        safe = snapshot(tail='.withSystemNames(databases: ["sys"], schemas: [])\n                .withIconName("icon")')
        self.curated(registry(("Example", safe)))
        self.plugin("ExampleDriverPlugin", plugin_class("ExamplePlugin", "Example"))
        self.assertEqual(self.problems(), ([], []))

        self.curated(registry(("Example", snapshot(tail=".withSwitchRouting(from: other)"))))
        unreadable, _ = self.problems()
        self.assertEqual(len(unreadable), 5)
        self.assertIn("withSwitchRouting(from: other)` may change a capability", unreadable[0])

    def test_a_variant_keeps_its_curated_entry_and_is_not_compared(self):
        self.curated(registry(("Example", snapshot()), ("ExampleLite", snapshot(health="false"))))
        self.plugin(
            "ExampleDriverPlugin",
            plugin_class("ExamplePlugin", "Example", 'static let additionalDatabaseTypeIds = ["ExampleLite"]'),
        )
        self.assertEqual(self.problems(), ([], []))

    def test_a_call_that_is_not_an_entry_is_not_read_as_one(self):
        helpers = """
    static let templates = [requestTemplate("Example", #"{"TableName": ""}"#)]
"""
        self.curated(registry(("Example", snapshot()), helpers=helpers))
        self.plugin("ExampleDriverPlugin", plugin_class("ExamplePlugin", "Example"))
        self.assertEqual(self.problems(), ([], []))

    def test_folders_without_a_driver_plugin_are_not_compared(self):
        self.curated(registry(("Example", snapshot())))
        self.plugin("ExampleDriverPlugin", plugin_class("ExamplePlugin", "Example"))
        self.plugin("CSVExportPlugin", 'final class CSVExportPlugin: ExportFormatPlugin {\n    static let formatId = "csv"\n}\n')
        code, out, _ = self.run_main()
        self.assertEqual(code, 0)
        self.assertIn("1 driver plugins agree", out)

    def test_an_empty_plugins_folder_fails(self):
        self.curated(registry(("Example", snapshot())))
        code, _, err = self.run_main()
        self.assertEqual(code, 1)
        self.assertIn("no driver plugin", err)


if __name__ == "__main__":
    unittest.main()
