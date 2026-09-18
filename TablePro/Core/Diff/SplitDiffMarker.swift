//
//  SplitDiffMarker.swift
//  TablePro
//

import Foundation

/// A split diff carries the change kind in the row tint alone, which says nothing to VoiceOver and
/// nothing to a reader who has turned on Differentiate Without Colour. `changed` exists only on the
/// split side and has no unified counterpart, so it gets its own marker rather than being folded
/// into added or removed.
internal enum SplitDiffMarker: Equatable {
    case added
    case removed
    case changed

    internal var glyph: String {
        switch self {
        case .added: return "+"
        case .removed: return "-"
        case .changed: return "~"
        }
    }

    internal var label: String {
        switch self {
        case .added: return String(localized: "Added")
        case .removed: return String(localized: "Removed")
        case .changed: return String(localized: "Changed")
        }
    }

    internal static var unchangedLabel: String {
        String(localized: "Unchanged")
    }

    internal static func resolve(kind: DiffPair.Kind, side: SqlWalkthroughAnchor.Side) -> SplitDiffMarker? {
        switch (kind, side) {
        case (.removed, .before): return .removed
        case (.added, .after): return .added
        case (.changed, .before), (.changed, .after): return .changed
        default: return nil
        }
    }
}
