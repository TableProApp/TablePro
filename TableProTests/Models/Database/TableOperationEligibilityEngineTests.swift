//
//  TableOperationEligibilityEngineTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("Table operation eligibility, engine dimension")
struct TableOperationEligibilityEngineTests {
    private func ref(_ name: String, type: TableInfo.TableType = .table) -> DatabaseTreeTableRef {
        DatabaseTreeTableRef(
            database: "app",
            schema: nil,
            table: TableInfo(name: name, type: type, rowCount: nil, schema: nil)
        )
    }

    private func context(
        droppable: [DatabaseTreeTableRef] = [],
        truncatable: [DatabaseTreeTableRef] = [],
        isReadOnly: Bool = false
    ) -> TableOperationEligibility.Context {
        TableOperationEligibility.Context(
            droppable: Set(droppable), truncatable: Set(truncatable), isReadOnly: isReadOnly
        )
    }

    @Test("Delete is offered when the engine has a statement for every target")
    func dropOfferedWhenExpressible() {
        let users = ref("users")
        #expect(TableOperationEligibility.canDrop([users], context: context(droppable: [users])))
    }

    /// The reported bug: Elasticsearch has no statement, so the item must not be offered at all
    /// rather than offered and answered with fabricated SQL.
    @Test("Delete is withheld when the engine has no statement")
    func dropWithheldWhenInexpressible() {
        #expect(!TableOperationEligibility.canDrop([ref("test_index")], context: context()))
    }

    @Test("Delete is all or nothing across a selection")
    func dropRefusesMixedSelection() {
        let good = ref("orders")
        let bad = ref("logs-*")
        #expect(!TableOperationEligibility.canDrop([good, bad], context: context(droppable: [good])))
    }

    @Test("Delete is withheld on an empty selection")
    func dropRefusesEmptySelection() {
        #expect(!TableOperationEligibility.canDrop([DatabaseTreeTableRef](), context: context()))
    }

    @Test("Delete is withheld in read-only mode")
    func dropRefusesReadOnly() {
        let users = ref("users")
        #expect(!TableOperationEligibility.canDrop([users], context: context(droppable: [users], isReadOnly: true)))
    }

    @Test("Truncate still refuses a view even where the engine could express it")
    func truncateRefusesView() {
        let view = ref("active_users", type: .view)
        #expect(!TableOperationEligibility.canTruncate([view], context: context(truncatable: [view])))
    }

    @Test("Truncate is withheld when the engine has no statement")
    func truncateWithheldWhenInexpressible() {
        #expect(!TableOperationEligibility.canTruncate([ref("test_index")], context: context()))
    }

    @Test("Truncate is offered for a table the engine can empty")
    func truncateOfferedWhenExpressible() {
        let users = ref("users")
        #expect(TableOperationEligibility.canTruncate([users], context: context(truncatable: [users])))
    }
}
