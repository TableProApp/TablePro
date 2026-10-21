//
//  DatabaseTreeMenuSpecTests+Sequences.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

extension DatabaseTreeMenuSpecTests {
    private var sequenceSupport: DatabaseObjectToolEligibility.Support {
        DatabaseObjectToolEligibility.Support(canSetSequenceValues: true, canAlterSequences: true)
    }

    @Test("A sequence row offers Set Next Value and Edit Sequence where the driver writes them")
    func sequenceCommandsFollowDriverSupport() {
        let sequence = tableRef("orders_id_seq", type: .sequence)
        let issued = commands(DatabaseTreeMenuSpec.sections(
            for: context(clicked: .table(sequence), objectToolSupport: sequenceSupport)
        ))

        #expect(issued.contains(.setSequenceNextValue(sequence)))
        #expect(issued.contains(.editSequence(sequence)))
        #expect(!commands(DatabaseTreeMenuSpec.sections(for: context(clicked: .table(sequence))))
            .contains(.setSequenceNextValue(sequence)))
    }

    @Test("A read-only connection offers no sequence change")
    func sequenceCommandsNeedWriteAccess() {
        let sequence = tableRef("orders_id_seq", type: .sequence)
        let issued = commands(DatabaseTreeMenuSpec.sections(
            for: context(clicked: .table(sequence), isReadOnly: true, objectToolSupport: sequenceSupport)
        ))

        #expect(!issued.contains(.setSequenceNextValue(sequence)))
        #expect(!issued.contains(.editSequence(sequence)))
    }

    @Test("Only a sequence offers the sequence commands")
    func sequenceCommandsAreSequenceOnly() {
        let table = tableRef("orders")
        let issued = commands(DatabaseTreeMenuSpec.sections(
            for: context(clicked: .table(table), objectToolSupport: sequenceSupport)
        ))

        #expect(!issued.contains(.setSequenceNextValue(table)))
        #expect(!issued.contains(.editSequence(table)))
    }

    @Test("New Sequence is offered where the driver has a template for one")
    func newSequenceFollowsTheTemplate() {
        #expect(commands(DatabaseTreeMenuSpec.sections(for: context(clicked: nil, canCreateSequence: true)))
            .contains(.createSequence))
        #expect(!commands(DatabaseTreeMenuSpec.sections(for: context(clicked: nil)))
            .contains(.createSequence))
        #expect(!commands(DatabaseTreeMenuSpec.sections(
            for: context(clicked: nil, isReadOnly: true, canCreateSequence: true)
        )).contains(.createSequence))
    }
}
