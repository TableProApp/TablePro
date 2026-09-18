//
//  ScriptTab.swift
//  TablePro
//

import AppKit
import Foundation

/// One open editor tab, as a script sees it.
///
/// `currentResult` and `selection` are computed on read rather than captured, because a script that
/// holds `tab 1 of connection "prod"` expects the rows it asks for now, not the rows that were on
/// screen when the reference was made. Both read through `DisplayedResultReader`, so a script sees
/// exactly the rows the grid is showing: display order, hidden columns left out, and the per-column
/// value filter applied.
@objc(TPScriptTab)
internal final class ScriptTab: NSObject, ScriptCommandReceiving {
    @objc internal let uniqueId: String
    @objc internal let name: String
    @objc internal let kind: FourCharCode
    @objc internal let tableName: String?
    @objc internal let databaseName: String?
    @objc internal let schemaName: String?

    internal let tabId: UUID
    internal let connectionId: UUID

    /// Boxed because a specifier is not `Sendable` and this one has to be readable from
    /// `objectSpecifier`, which Cocoa calls without any isolation of its own.
    private let container: ScriptingBox<NSScriptObjectSpecifier?>

    internal init(tab: QueryTab, connectionId: UUID, container: NSScriptObjectSpecifier?) {
        self.tabId = tab.id
        self.connectionId = connectionId
        self.uniqueId = tab.id.uuidString
        self.name = tab.title
        self.kind = ScriptEnumerations.code(for: tab.tabType)
        self.tableName = tab.tableContext.tableName
        self.databaseName = tab.tableContext.databaseName.isEmpty ? nil : tab.tableContext.databaseName
        self.schemaName = tab.tableContext.schemaName
        self.container = ScriptingBox(container)
        super.init()
    }

    /// Read only on purpose. Prefilling SQL from outside the app already has one route, the URL
    /// scheme's `query` link, and that route confirms the statement with the person first. A
    /// settable property here would be a second route with no confirmation on it, which is how a
    /// script would come to swap the statement under someone about to press Run.
    @objc internal var query: String {
        let tabId = tabId
        let connectionId = connectionId
        return MainActor.assumeIsolated {
            ScriptingSnapshot.query(ofTab: tabId, connectionId: connectionId) ?? ""
        }
    }

    @objc internal var currentResult: [String: Any] {
        result(selectedOnly: false)
    }

    @objc internal var selection: [String: Any] {
        result(selectedOnly: true)
    }

    private func result(selectedOnly: Bool) -> [String: Any] {
        let tabId = tabId
        let connectionId = connectionId
        return MainActor.assumeIsolated {
            ScriptingBox(
                ScriptingSnapshot.result(ofTab: tabId, connectionId: connectionId, selectedOnly: selectedOnly)
            )
        }.value
    }

    @objc internal func handleFocusCommand(_ command: NSScriptCommand) -> Any? {
        beginScriptCommand(command)
    }

    override internal var objectSpecifier: NSScriptObjectSpecifier? {
        let uniqueId = uniqueId
        let container = container
        return MainActor.assumeIsolated {
            ScriptingBox(ScriptingSpecifiers.tab(uniqueId: uniqueId, container: container.value))
        }.value
    }
}
