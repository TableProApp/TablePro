import AppKit
import Foundation

public enum InspectorWindowFactory {
    @MainActor public static var make: ((NSDocument) -> NSWindowController?)?
}

public protocol DocumentInspectorPlugin: TableProPlugin {
    static var inspectorId: String { get }
    static var displayName: String { get }
    static var supportedUTIs: [String] { get }
    static var supportedFileExtensions: [String] { get }
    static var canEdit: Bool { get }
    static var iconName: String { get }

    static var documentClass: AnyClass { get }
}

public extension DocumentInspectorPlugin {
    static var canEdit: Bool { true }
    static var iconName: String { "doc.text" }
}

public enum InspectorColumnType: String, Sendable, Equatable, CaseIterable {
    case text
    case integer
    case real
    case boolean
    case date
}

public extension Notification.Name {
    static let inspectorDocumentDidRevert = Notification.Name("com.TablePro.InspectorDocumentDidRevert")
}

public protocol InspectorDataSnapshot: Sendable {
    var rowCount: Int { get }
    func cells(at row: Int) -> [String]
    func field(at row: Int, column: Int) -> String
}

@MainActor
public protocol InspectorDocument: AnyObject {
    var rowCount: Int { get }
    var columnNames: [String] { get }
    func value(row: Int, column: Int) -> String
    func pageRows(offset: Int, limit: Int) -> [[String]]
    func snapshot() -> any InspectorDataSnapshot
    func displayedType(forColumn index: Int) -> InspectorColumnType
    func setCell(row: Int, column: Int, to value: String)
    func appendRow()
    func insertRow(at index: Int)
    func removeRow(at index: Int)
    func removeRows(at indices: IndexSet)
    func appendColumn(name: String)
    func insertColumn(at index: Int, name: String)
    func removeColumn(at index: Int)
    func renameColumn(at index: Int, to name: String)
    func setTypeOverride(_ type: InspectorColumnType?, forColumn index: Int)
    var onChange: (() -> Void)? { get set }
}
