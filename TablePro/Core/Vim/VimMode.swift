//
//  VimMode.swift
//  TablePro
//
//  Vim editing modes for the SQL editor
//

/// Vim editing modes
enum VimMode: Equatable {
    case normal
    case insert
    case replace
    case visual(linewise: Bool)
    case commandLine(buffer: String)

    /// Display label for the mode indicator
    var displayLabel: String {
        switch self {
        case .normal: return "NORMAL"
        case .insert: return "INSERT"
        case .replace: return "REPLACE"
        case .visual(let linewise): return linewise ? "VISUAL LINE" : "VISUAL"
        case .commandLine(let buffer): return buffer
        }
    }

    /// Whether this mode passes text input through to the text view (insert or replace)
    var isInsert: Bool {
        switch self {
        case .insert, .replace: return true
        default: return false
        }
    }

    /// Whether this mode is a visual selection mode
    var isVisual: Bool {
        if case .visual = self { return true }
        return false
    }
}
