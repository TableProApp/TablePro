//
//  AdvancedPaneViewModelTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@Suite("Advanced pane external access")
@MainActor
struct AdvancedPaneViewModelTests {
    @Test("Loads external access from the connection")
    func loadsExternalAccessFromConnection() {
        let connection = DatabaseConnection(name: "Test", externalAccess: .readWrite)
        let viewModel = AdvancedPaneViewModel()

        viewModel.load(from: connection)

        #expect(viewModel.externalAccess == .readWrite)
    }

    @Test("Does not leak external access into plugin additional fields")
    func doesNotWriteExternalAccessIntoAdditionalFields() {
        let viewModel = AdvancedPaneViewModel()
        viewModel.externalAccess = .readWrite

        var fields: [String: String] = [:]
        viewModel.write(into: &fields)

        #expect(fields["externalAccess"] == nil)
    }
}
