//
//  ConnectionTreeScopedID.swift
//  TablePro
//

import Foundation

/// Namespaces a database tree node id by the connection it belongs to.
///
/// One outline view now carries every connection's objects, and the per-connection id builders were
/// written when a list held one connection: two connections with a `public` schema produce the same
/// id. `NSOutlineView` tracks rows by object identity, so a collision costs nothing there, but
/// every id-keyed store around it collides for real, expansion state and selection restore among
/// them.
///
/// The connection id is a fixed 36 characters, so the split never depends on the separator being
/// absent from the rest. A database called `a/b` is why that matters.
internal enum ConnectionTreeScopedID {
    private static let separator: Character = "/"
    private static let uuidLength = 36

    internal static func make(connectionId: UUID, inner: String) -> String {
        "\(connectionId.uuidString)\(separator)\(inner)"
    }

    internal static func connectionId(of scoped: String) -> UUID? {
        guard scoped.count > uuidLength else { return nil }
        let boundary = scoped.index(scoped.startIndex, offsetBy: uuidLength)
        guard scoped[boundary] == separator else { return nil }
        return UUID(uuidString: String(scoped[scoped.startIndex ..< boundary]))
    }

    internal static func inner(of scoped: String) -> String? {
        guard scoped.count > uuidLength else { return nil }
        let boundary = scoped.index(scoped.startIndex, offsetBy: uuidLength)
        guard scoped[boundary] == separator else { return nil }
        return String(scoped[scoped.index(after: boundary)...])
    }
}
