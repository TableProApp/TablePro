//
//  AccessibleControlNameTests.swift
//  TableProTests
//

import AppKit
import Foundation
@testable import TablePro
import Testing

/// `NSTableView.sortDescriptors` paints the header arrow but reaches no accessibility client
/// (measured), so a sorted column is announced only when its header cell is told directly.
@MainActor
struct QueryPlanSortDirectionTests {
    @Test("The sorted column publishes its direction and the others publish none")
    func sortedColumnPublishesItsDirection() {
        let outlineView = NSOutlineView()
        let coordinator = QueryPlanOutlineCoordinator()
        coordinator.outlineView = outlineView
        coordinator.configureColumns(on: outlineView)

        let sortedKey = try? #require(outlineView.tableColumns.first?.identifier.rawValue)
        let key = sortedKey ?? ""
        outlineView.sortDescriptors = [NSSortDescriptor(key: key, ascending: false)]
        coordinator.publishSortDirection()

        for column in outlineView.tableColumns {
            let published = column.headerCell.accessibilitySortDirection()
            if column.identifier.rawValue == key {
                #expect(published == .descending, "the sorted column published \(published.rawValue)")
            } else {
                #expect(published == .unknown, "\(column.identifier.rawValue) published \(published.rawValue)")
            }
        }
    }

    @Test("Clearing the sort clears every column's direction")
    func clearingTheSortClearsEveryDirection() {
        let outlineView = NSOutlineView()
        let coordinator = QueryPlanOutlineCoordinator()
        coordinator.outlineView = outlineView
        coordinator.configureColumns(on: outlineView)

        guard let first = outlineView.tableColumns.first else { return }
        outlineView.sortDescriptors = [NSSortDescriptor(key: first.identifier.rawValue, ascending: true)]
        coordinator.publishSortDirection()
        #expect(first.headerCell.accessibilitySortDirection() == .ascending)

        outlineView.sortDescriptors = []
        coordinator.publishSortDirection()

        for column in outlineView.tableColumns {
            #expect(column.headerCell.accessibilitySortDirection() == .unknown)
        }
    }
}
