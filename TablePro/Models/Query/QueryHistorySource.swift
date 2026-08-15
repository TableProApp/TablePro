import Foundation

enum QueryHistorySource: String, Codable, CaseIterable, Sendable, Identifiable {
    case editor
    case explain
    case tableBrowse = "table_browse"
    case rowEdit = "row_edit"
    case structureDDL = "structure_ddl"
    case dataImport = "import"
    case mcp

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
        }
    }

    static let userAuthored: Set<QueryHistorySource> = [.editor, .explain]
}
