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
        let owning = hostedConnections.indices.filter { hostedConnections[$0].contains(connectionId) }
        if owning.count > 1, let frontmostIndex, owning.contains(frontmostIndex) {
            /// A tab moved into its own window leaves the connection hosted twice, and the list
            /// comes from a dictionary, so "the first one that has it" is arbitrary. A Create Table
            /// or an object source opened from the detached window would then append to, and focus,
            /// the window it was not invoked from.
            return frontmostIndex
        }
        if let first = owning.first {
            return first
        }
        guard let frontmostIndex, hostedConnections.indices.contains(frontmostIndex) else {
            return hostedConnections.isEmpty ? nil : hostedConnections.startIndex
        }
        return frontmostIndex
    }
}
