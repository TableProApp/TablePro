//
//  PluginResourceRelease.swift
//  TableProPluginKit
//

import Foundation

/// What came of asking a driver to hand back an operating-system resource its session is holding.
///
/// A refusal is not a failure, so it is reported here rather than thrown: a driver must keep the
/// resource whenever re-acquiring it would not restore what the session currently holds, and the
/// person who asked deserves to be told which of those it is. A bare `false` would leave the
/// command with nothing to say beyond "no".
///
/// Deliberately not `@frozen`, so it can gain a field later. Any new field arrives with its own
/// initializer overload; this one keeps its signature, because changing it would replace the
/// mangled symbol every already-built plugin references.
public struct PluginResourceRelease: Sendable, Equatable {
    /// Whether the resource was actually handed back.
    public let didRelease: Bool

    /// Why it was kept, in the user's language, when it was kept for a reason worth reporting.
    /// Nil when the driver released it, and nil when there was nothing to release.
    public let reason: String?

    public init(didRelease: Bool, reason: String? = nil) {
        self.didRelease = didRelease
        self.reason = reason
    }

    public static let released = PluginResourceRelease(didRelease: true)

    /// Nothing was being held, so nothing changed and there is nothing to explain.
    public static let nothingToRelease = PluginResourceRelease(didRelease: false)

    public static func kept(_ reason: String) -> PluginResourceRelease {
        PluginResourceRelease(didRelease: false, reason: reason)
    }
}
