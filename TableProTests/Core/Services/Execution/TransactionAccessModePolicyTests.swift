//
//  TransactionAccessModePolicyTests.swift
//  TableProTests
//

@testable import TablePro
import TableProPluginKit
import Testing

@Suite("Transaction access mode policy")
struct TransactionAccessModePolicyTests {
    @Test("Read operations never declare write intent")
    func readOperationsInheritServerDefault() {
        #expect(OperationKind.readQuery.transactionAccessMode == .serverDefault)
        #expect(OperationKind.metadataRead.transactionAccessMode == .serverDefault)
    }

    @Test("Every write operation declares write intent")
    func writeOperationsDeclareReadWrite() {
        #expect(OperationKind.writeQuery.transactionAccessMode == .readWrite)
        #expect(OperationKind.destructiveQuery.transactionAccessMode == .readWrite)
        #expect(OperationKind.schemaMutation.transactionAccessMode == .readWrite)
        #expect(OperationKind.importData.transactionAccessMode == .readWrite)
        #expect(OperationKind.maintenance.transactionAccessMode == .readWrite)
    }

    @Test("A script of only reads keeps the server default so replica browsing still works")
    func readOnlyScriptKeepsServerDefault() {
        let statements = ["SELECT * FROM users", "SELECT count(*) FROM orders"]
        let kind = OperationKind.worst(of: statements, databaseType: .mysql)

        #expect(kind.transactionAccessMode == .serverDefault)
    }

    @Test("A script containing one write declares write intent for the whole transaction")
    func mixedScriptDeclaresReadWrite() {
        let statements = ["SELECT * FROM users", "UPDATE users SET name = 'x' WHERE id = 1"]
        let kind = OperationKind.worst(of: statements, databaseType: .mysql)

        #expect(kind.transactionAccessMode == .readWrite)
    }
}
