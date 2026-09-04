//
//  AgentSessionStatus.swift
//  TablePro
//

import Foundation

/// What a session is doing, in the vocabulary the rail lists it under.
///
/// Stored on the session rather than computed where it is read. The rail lists sessions the user is
/// not looking at, and two of the inputs are outside the observation graph: `ToolApprovalCenter` is
/// a plain `@MainActor` class and `ProviderStreamLease` holds its queue in a dictionary, so a body
/// that asked either of them a question would render once and never invalidate.
internal enum AgentSessionStatus: String, Codable, Sendable, CaseIterable {
    case idle
    case running
    case waitingOnYou
    case queued
    case stopped
    case failed

    /// A status the session does not leave until it is asked to work again. `stopped` and `failed`
    /// are both records of something that already finished, so a status refresh driven by the
    /// engine's own state must not overwrite them: a stopped session's engine reads `.idle`, which
    /// is exactly the value that would erase the fact that a window closed on it.
    internal var isTerminal: Bool {
        switch self {
        case .stopped, .failed:
            return true
        case .idle, .running, .waitingOnYou, .queued:
            return false
        }
    }

    internal var localizedTitle: String {
        switch self {
        case .idle: return String(localized: "Ready")
        case .running: return String(localized: "Working")
        case .waitingOnYou: return String(localized: "Waiting on you")
        case .queued: return String(localized: "Queued")
        case .stopped: return String(localized: "Stopped")
        case .failed: return String(localized: "Failed")
        }
    }

    internal var icon: String {
        switch self {
        case .idle: return "bubble.left.and.text.bubble.right"
        case .running: return "circle.dotted"
        case .waitingOnYou: return "hand.raised"
        case .queued: return "clock"
        case .stopped: return "stop.circle"
        case .failed: return "exclamationmark.triangle"
        }
    }
}
