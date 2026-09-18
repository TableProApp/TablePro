//
//  TableOperationPromptTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("TableOperationPrompt")
struct TableOperationPromptTests {
    private func prompt(
        _ operationType: TableOperationType,
        tableName: String = "users",
        tableCount: Int = 1,
        cascadeSupported: Bool = false,
        foreignKeyDisableSupported: Bool = false
    ) -> TableOperationPrompt {
        TableOperationPrompt(
            operationType: operationType,
            tableName: tableName,
            tableCount: tableCount,
            cascadeSupported: cascadeSupported,
            foreignKeyDisableSupported: foreignKeyDisableSupported
        )
    }

    // MARK: - Message Text

    @Test("Drop single table names the table")
    func dropSingleTableMessage() {
        #expect(prompt(.drop).messageText == "Drop table 'users'")
    }

    @Test("Drop multiple tables counts them")
    func dropMultipleTablesMessage() {
        #expect(prompt(.drop, tableCount: 3).messageText == "Drop 3 tables")
    }

    @Test("Truncate single table names the table")
    func truncateSingleTableMessage() {
        #expect(prompt(.truncate, tableName: "orders").messageText == "Truncate table 'orders'")
    }

    @Test("Truncate multiple tables counts them")
    func truncateMultipleTablesMessage() {
        #expect(prompt(.truncate, tableCount: 5).messageText == "Truncate 5 tables")
    }

    // MARK: - Informative Text

    @Test("Single table has no informative text")
    func singleTableInformativeText() {
        #expect(prompt(.drop).informativeText.isEmpty)
    }

    @Test("Multiple tables explain that options are shared")
    func multipleTablesInformativeText() {
        #expect(prompt(.drop, tableCount: 2).informativeText.isEmpty == false)
    }

    // MARK: - Buttons

    @Test("Confirm button carries the operation verb")
    func confirmButtonTitles() {
        #expect(prompt(.drop).confirmButtonTitle == "Drop")
        #expect(prompt(.truncate).confirmButtonTitle == "Truncate")
    }

    // MARK: - Cascade

    @Test("Cascade is enabled only when the driver supports it")
    func cascadeEnablement() {
        #expect(prompt(.drop, cascadeSupported: true).isCascadeEnabled)
        #expect(prompt(.drop, cascadeSupported: false).isCascadeEnabled == false)
        #expect(prompt(.truncate, cascadeSupported: true).isCascadeEnabled)
        #expect(prompt(.truncate, cascadeSupported: false).isCascadeEnabled == false)
    }

    @Test("Drop cascade description explains the dependency")
    func dropCascadeDescription() {
        #expect(prompt(.drop, cascadeSupported: true).cascadeDescription.contains("depend on this table"))
    }

    @Test("Truncate cascade description explains foreign keys when supported")
    func truncateCascadeDescriptionSupported() {
        #expect(prompt(.truncate, cascadeSupported: true).cascadeDescription.contains("foreign keys"))
    }

    @Test("Truncate cascade description says unsupported when it is")
    func truncateCascadeDescriptionUnsupported() {
        #expect(prompt(.truncate, cascadeSupported: false).cascadeDescription.contains("Not supported"))
    }

    // MARK: - Ignore Foreign Keys

    @Test("Ignore foreign keys is enabled only when the driver supports it")
    func ignoreForeignKeysEnablement() {
        #expect(prompt(.drop, foreignKeyDisableSupported: true).isIgnoreForeignKeysEnabled)
        #expect(prompt(.drop, foreignKeyDisableSupported: false).isIgnoreForeignKeysEnabled == false)
    }

    @Test("Supported drivers show no explanation")
    func ignoreForeignKeysDescriptionSupported() {
        #expect(prompt(.drop, foreignKeyDisableSupported: true).ignoreForeignKeysDescription == nil)
    }

    @Test("Unsupported drivers that cascade point at CASCADE")
    func ignoreForeignKeysDescriptionSuggestsCascade() {
        let description = prompt(.drop, cascadeSupported: true, foreignKeyDisableSupported: false)
            .ignoreForeignKeysDescription
        #expect(description?.contains("CASCADE") == true)
    }

    @Test("Unsupported drivers without cascade say only that")
    func ignoreForeignKeysDescriptionPlain() {
        let description = prompt(.drop, cascadeSupported: false, foreignKeyDisableSupported: false)
            .ignoreForeignKeysDescription
        #expect(description != nil)
        #expect(description?.contains("CASCADE") == false)
    }

    // MARK: - Options Clamping

    @Test("A checked box on an unsupported option never reaches the driver")
    func optionsClampToSupportedCapabilities() {
        let unsupported = prompt(.drop, cascadeSupported: false, foreignKeyDisableSupported: false)
        let options = unsupported.options(ignoreForeignKeys: true, cascade: true)
        #expect(options.ignoreForeignKeys == false)
        #expect(options.cascade == false)
    }

    @Test("Supported options pass through")
    func optionsPassThroughWhenSupported() {
        let supported = prompt(.drop, cascadeSupported: true, foreignKeyDisableSupported: true)
        let options = supported.options(ignoreForeignKeys: true, cascade: true)
        #expect(options.ignoreForeignKeys)
        #expect(options.cascade)
    }

    @Test("Unchecked boxes stay off")
    func optionsRespectUncheckedBoxes() {
        let supported = prompt(.drop, cascadeSupported: true, foreignKeyDisableSupported: true)
        #expect(supported.options(ignoreForeignKeys: false, cascade: false) == TableOperationOptions())
    }

    @Test("Each option is clamped independently")
    func optionsClampIndependently() {
        let cascadeOnly = prompt(.drop, cascadeSupported: true, foreignKeyDisableSupported: false)
        let options = cascadeOnly.options(ignoreForeignKeys: true, cascade: true)
        #expect(options.ignoreForeignKeys == false)
        #expect(options.cascade)
    }

    // MARK: - TableOperationOptions

    @Test("Default options are both off")
    func defaultOptions() {
        let options = TableOperationOptions()
        #expect(options.ignoreForeignKeys == false)
        #expect(options.cascade == false)
    }

    @Test("TableOperationOptions is Equatable")
    func optionsEquatable() {
        let first = TableOperationOptions(ignoreForeignKeys: true, cascade: false)
        let second = TableOperationOptions(ignoreForeignKeys: true, cascade: false)
        let third = TableOperationOptions(ignoreForeignKeys: false, cascade: true)
        #expect(first == second)
        #expect(first != third)
    }

    @Test("TableOperationOptions survives a Codable roundtrip")
    func optionsCodableRoundtrip() throws {
        let original = TableOperationOptions(ignoreForeignKeys: true, cascade: true)
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(TableOperationOptions.self, from: data) == original)
    }

    // MARK: - TableOperationType

    @Test("TableOperationType raw values are stable")
    func operationTypeRawValues() {
        #expect(TableOperationType.truncate.rawValue == "truncate")
        #expect(TableOperationType.drop.rawValue == "drop")
    }

    @Test("TableOperationType survives a Codable roundtrip")
    func operationTypeCodableRoundtrip() throws {
        for operationType in [TableOperationType.truncate, TableOperationType.drop] {
            let data = try JSONEncoder().encode(operationType)
            #expect(try JSONDecoder().decode(TableOperationType.self, from: data) == operationType)
        }
    }
}
