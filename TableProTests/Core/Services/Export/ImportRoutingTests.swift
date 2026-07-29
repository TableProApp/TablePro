//
//  ImportRoutingTests.swift
//  TableProTests
//

@testable import TablePro
import Testing

struct ImportRoutingTests {
    @Test("Statement-based formats route to the SQL import dialog")
    func statementFormatRoutesToImportDialog() {
        #expect(ImportRouting.route(formatId: "sql", requiresTargetTable: false) == .statement(formatId: "sql"))
    }

    @Test("Row-based formats route to the row-mapping sheet")
    func rowFormatRoutesToRowMapping() {
        #expect(ImportRouting.route(formatId: "json", requiresTargetTable: true) == .rowMapping(formatId: "json"))
    }

    @Test("Routing carries the chosen format id through unchanged")
    func routingPreservesFormatId() {
        #expect(ImportRouting.route(formatId: "ndjson", requiresTargetTable: true) == .rowMapping(formatId: "ndjson"))
        #expect(ImportRouting.route(formatId: "csv", requiresTargetTable: false) == .statement(formatId: "csv"))
    }

    @Test("Submenu label reads From <format>")
    func submenuLabelFormat() {
        let option = ImportFormatOption(id: "sql", name: "SQL")
        #expect(option.submenuLabel == "From SQL\u{2026}")
    }

    @Test("Standalone label reads Import <format>")
    func standaloneLabelFormat() {
        let option = ImportFormatOption(id: "json", name: "JSON")
        #expect(option.standaloneLabel == "Import JSON\u{2026}")
    }
}
