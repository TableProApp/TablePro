//
//  TableFolderDropResolverTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct TableFolderDropResolverTests {
    private let connectionId = UUID()

    private var publicScope: DatabaseScope {
        DatabaseScope(connectionId: connectionId, database: "shop", schema: "public")
    }

    private var auditScope: DatabaseScope {
        DatabaseScope(connectionId: connectionId, database: "shop", schema: "audit")
    }

    @Test("Dropping objects on a folder files the ones not already in it")
    func dropOnFolderFiles() {
        let billing = TableFolder(scope: publicScope, name: "Billing")
        let items = [
            TableFolderDragItem(name: "orders", scope: publicScope, folderId: nil),
            TableFolderDragItem(name: "invoices", scope: publicScope, folderId: billing.id)
        ]

        let operation = TableFolderDropResolver.resolve(items: items, target: .folder(billing))

        #expect(operation == .file(names: ["orders"], scope: publicScope, folderId: billing.id))
    }

    @Test("Dropping objects back on the folder they are in does nothing")
    func dropOnOwnFolderIsRefused() {
        let billing = TableFolder(scope: publicScope, name: "Billing")
        let items = [TableFolderDragItem(name: "invoices", scope: publicScope, folderId: billing.id)]

        #expect(TableFolderDropResolver.resolve(items: items, target: .folder(billing)) == nil)
    }

    @Test("A drag that reaches into another schema is refused whole")
    func crossScopeDragIsRefused() {
        let billing = TableFolder(scope: publicScope, name: "Billing")
        let items = [
            TableFolderDragItem(name: "orders", scope: publicScope, folderId: nil),
            TableFolderDragItem(name: "events", scope: auditScope, folderId: nil)
        ]

        #expect(TableFolderDropResolver.resolve(items: items, target: .folder(billing)) == nil)
    }

    @Test("Dropping on a section takes filed objects out of their folders")
    func dropOnSectionUnfiles() {
        let billing = TableFolder(scope: publicScope, name: "Billing")
        let items = [
            TableFolderDragItem(name: "orders", scope: publicScope, folderId: nil),
            TableFolderDragItem(name: "invoices", scope: publicScope, folderId: billing.id)
        ]

        let operation = TableFolderDropResolver.resolve(items: items, target: .unfiled(publicScope))

        #expect(operation == .unfile(names: ["invoices"], scope: publicScope))
    }

    @Test("Dropping loose objects on their own section does nothing")
    func dropLooseOnSectionIsRefused() {
        let items = [TableFolderDragItem(name: "orders", scope: publicScope, folderId: nil)]

        #expect(TableFolderDropResolver.resolve(items: items, target: .unfiled(publicScope)) == nil)
        #expect(TableFolderDropResolver.resolve(items: [], target: .unfiled(publicScope)) == nil)
    }
}
