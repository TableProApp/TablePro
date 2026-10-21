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
    case commandLine = "command_line"

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
        case .commandLine: return String(localized: "Command Line")
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
        case .commandLine: return "terminal"
        }
    }

    static let userAuthored: Set<QueryHistorySource> = [.editor, .explain]

    // The whole list before each later source was added: a stored filter equal to one of these meant Everything.
    private static let earlierAllSources: [Set<QueryHistorySource>] = [
        [.editor, .explain, .tableBrowse, .rowEdit, .structureDDL, .dataImport, .mcp],
        [.editor, .explain, .tableBrowse, .rowEdit, .structureDDL, .dataImport, .mcp, .script]
    ]

    static func migratingStoredSelection(_ stored: Set<QueryHistorySource>) -> Set<QueryHistorySource> {
        earlierAllSources.contains(stored) ? Set(allCases) : stored
    }
}
