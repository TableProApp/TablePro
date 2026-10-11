//
//  AgentSessionStatus.swift
//  TablePro
//

import Foundation

/// What a session is doing, in the words the session rail uses.
///
/// Stored on the session rather than computed where it is read. Two of its inputs, the approval
/// centre and the provider lease, sit outside the observation graph, so a row that asked them a
/// question would render once and never update again.
internal enum AgentSessionStatus: String, Codable, Equatable, Sendable, CaseIterable {
    /// Streaming a reply or running a tool call.
    case working
    /// Holding a statement that needs an answer.
    case waitingOnYou
    /// Another session is streaming on the same provider configuration.
    case queued
    /// Waiting for the next message.
    case ready
    /// Its window closed. The transcript is intact and reopening continues it.
    case stopped
    /// The provider returned an error, or the app quit while a reply was arriving.
    case failed

    internal var title: String {
        switch self {
        case .working: return String(localized: "Working")
        case .waitingOnYou: return String(localized: "Waiting on you")
        case .queued: return String(localized: "Queued")
        case .ready: return String(localized: "Ready")
        case .stopped: return String(localized: "Stopped")
        case .failed: return String(localized: "Failed")
        }
    }

    /// Paired with the title everywhere it is drawn. A state carried by colour alone fails the
    /// accessibility rule about conveying information with more than colour.
    internal var symbolName: String {
        switch self {
        case .working: return "circle.dotted"
        case .waitingOnYou: return "hand.raised"
        case .queued: return "hourglass"
        case .ready: return "circle"
        case .stopped: return "pause.circle"
        case .failed: return "exclamationmark.triangle"
        }
    }

    /// Whether the session is doing something the user should not interrupt by accident.
    internal var isBusy: Bool {
        self == .working || self == .waitingOnYou
    }

    /// Whether reopening the session means resuming it rather than continuing it.
    internal var isEnded: Bool {
        self == .stopped || self == .failed
    }
}
