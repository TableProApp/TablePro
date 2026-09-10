import Foundation

public enum ConnectionColor: String, CaseIterable, Identifiable, Codable, Sendable {
    case none = "None"
    case red = "Red"
    case orange = "Orange"
    case yellow = "Yellow"
    case green = "Green"
    case blue = "Blue"
    case purple = "Purple"
    case pink = "Pink"
    case gray = "Gray"

    public var id: String { rawValue }
    public var isDefault: Bool { self == .none }

    /// Reads a colour that was stored as a hex string.
    ///
    /// iOS held a connection's colour as free-form hex while macOS held this enum, so the two
    /// synced on separate CloudKit fields and neither device ever showed the other's colour.
    /// Everything converges on the enum; this is what carries the values already written as hex.
    public init(hex: String, default fallback: ConnectionColor = .gray) {
        let normalized = hex.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        switch normalized {
        case "ff0000", "ff3b30", "cc0000": self = .red
        case "ff9500", "ff8c00", "ffa500": self = .orange
        case "ffcc00", "ffff00", "ffd700": self = .yellow
        case "34c759", "28cd41", "00ff00", "008000": self = .green
        case "007aff", "0000ff", "5856d6": self = .blue
        case "af52de", "800080", "9b59b6": self = .purple
        case "ff2d55", "ff69b4", "ffc0cb": self = .pink
        default: self = fallback
        }
    }

    /// Reads a colour written either as this enum's own name or as hex, which is what a value
    /// stored before the two platforms converged can be.
    public init(storedValue: String, default fallback: ConnectionColor = .none) {
        if let named = ConnectionColor(rawValue: storedValue) {
            self = named
            return
        }
        if let named = ConnectionColor.allCases.first(where: {
            $0.rawValue.caseInsensitiveCompare(storedValue) == .orderedSame
        }) {
            self = named
            return
        }
        self = ConnectionColor(hex: storedValue, default: fallback)
    }
}
