//
//  WindowHostSelection.swift
//  TablePro
//

import Foundation

/// Which open window an incoming connection belongs in. Kept apart from `WindowManager` because
/// the rule is the single-window model's core promise and every way of getting it wrong shipped a
/// second window: preferring the front window over the one already hosting the connection, or
/// finding no host at all and creating one.
internal enum WindowHostSelection {
    /// Indices are positions in the caller's list of candidate hosts, so this stays free of AppKit.
    /// `nil` means there is no window to adopt into and one has to be created.
    internal static func hostIndex(
        forConnection connectionId: UUID,
        hostedConnections: [[UUID]],
        frontmostIndex: Int?
    ) -> Int? {
        if let owning = hostedConnections.firstIndex(where: { $0.contains(connectionId) }) {
            return owning
        }
        guard let frontmostIndex, hostedConnections.indices.contains(frontmostIndex) else {
            return hostedConnections.isEmpty ? nil : hostedConnections.startIndex
        }
        return frontmostIndex
    }
}
