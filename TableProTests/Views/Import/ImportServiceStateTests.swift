//
//  ImportServiceStateTests.swift
//  TableProTests
//
//  Tests for ImportServiceState wrapper that delegates to ImportService.
//

import Foundation
@testable import TablePro
import Testing

@MainActor
@Suite("ImportServiceState")
struct ImportServiceStateTests {
    // MARK: - Default Values (No Service)

    @Test("Default values when no service is set")
    func defaultValuesNoService() {
        let state = ImportServiceState()

        #expect(state.service == nil)
        #expect(state.isImporting == false)
        #expect(state.processedStatements == 0)
        #expect(state.estimatedTotalStatements == 0)
        #expect(state.statusMessage == "")
    }

    // MARK: - Service Delegation

    @Test("Properties delegate to service state after setting service")
    func propertiesDelegateToService() {
        let state = ImportServiceState()
        let connection = DatabaseConnection(name: "Test", type: .sqlite)
        let service = ImportService(connection: connection)

        service.state = ImportState(
            isImporting: true,
            processedStatements: 3,
            estimatedTotalStatements: 10,
            statusMessage: "Importing..."
        )

        state.setService(service)

        #expect(state.isImporting == true)
        #expect(state.processedStatements == 3)
        #expect(state.estimatedTotalStatements == 10)
        #expect(state.statusMessage == "Importing...")
    }

    // MARK: - State Mutation

    @Test("Wrapper reflects changes after mutating service state")
    func wrapperReflectsServiceStateMutation() {
        let state = ImportServiceState()
        let connection = DatabaseConnection(name: "Test", type: .sqlite)
        let service = ImportService(connection: connection)

        state.setService(service)

        #expect(state.isImporting == false)

        service.state.isImporting = true
        service.state.processedStatements = 7
        service.state.estimatedTotalStatements = 20
        service.state.statusMessage = "Processing statements..."

        #expect(state.isImporting == true)
        #expect(state.processedStatements == 7)
        #expect(state.estimatedTotalStatements == 20)
        #expect(state.statusMessage == "Processing statements...")
    }
}
