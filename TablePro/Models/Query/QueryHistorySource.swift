import Foundation

enum QueryHistorySource: String, Codable, CaseIterable, Sendable, Identifiable {
    case editor
    case explain
    case tableBrowse = "table_browse"
    case rowEdit = "row_edit"
    case structureDDL = "structure_ddl"
    case dataImport = "import"
    case mcp
    case script

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .editor: return String(localized: "Editor")
        case .explain: return String(localized: "Explain")
        case .tableBrowse: return String(localized: "Table Browsing")
        case .rowEdit: return String(localized: "Row Edits")
        case .structureDDL: return String(localized: "Structure Changes")
        case .dataImport: return String(localized: "Imports")
        case .mcp: return String(localized: "AI and MCP")
        case .script: return String(localized: "AppleScript")
        }
    }

    var symbolName: String {
        switch self {
        case .editor: return "text.cursor"
        case .explain: return "list.bullet.indent"
        case .tableBrowse: return "tablecells"
        case .rowEdit: return "square.and.pencil"
        case .structureDDL: return "hammer"
        case .dataImport: return "square.and.arrow.down"
        case .mcp: return "sparkles"
        case .script: return "applescript"
        }
    }

    static let userAuthored: Set<QueryHistorySource> = [.editor, .explain]

    /// The full set as it stood before `script` was added.
    ///
    /// A stored filter holding exactly these was the user choosing **Everything**, and decoding it
    /// verbatim would silently drop the new source: their filter would start hiding scripted queries
    /// and the toolbar would change from "Everything" to a count. Widening only this exact set leaves
    /// a genuinely custom selection alone.
    private static let allBeforeScript: Set<QueryHistorySource> = [
        .editor, .explain, .tableBrowse, .rowEdit, .structureDDL, .dataImport, .mcp
    ]

    static func migratingStoredSelection(_ stored: Set<QueryHistorySource>) -> Set<QueryHistorySource> {
        stored == allBeforeScript ? Set(allCases) : stored
    }
}
