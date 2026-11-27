enum VimMode: Equatable {
    case normal
    case insert
    case replace
    case visual(linewise: Bool)
    case commandLine(buffer: String)

    var displayLabel: String {
        switch self {
        case .normal: return "NORMAL"
        case .insert: return "INSERT"
        case .replace: return "REPLACE"
        case .visual(let linewise): return linewise ? "VISUAL LINE" : "VISUAL"
        case .commandLine(let buffer): return buffer
        }
    }

    // Insert and Replace leave typed text to the text view.
    var isInsert: Bool {
        switch self {
        case .insert, .replace: return true
        default: return false
        }
    }

    var isVisual: Bool {
        if case .visual = self { return true }
        return false
    }

    var isVisualLinewise: Bool {
        if case .visual(let linewise) = self { return linewise }
        return false
    }

    var isCommandLine: Bool {
        if case .commandLine = self { return true }
        return false
    }
}
