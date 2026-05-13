//
//  LaunchPhase.swift
//  TablePro
//

import Foundation

internal enum LaunchPhase: Equatable, Sendable {
    case launching
    case collectingIntents(deadline: Date)
    case routing
    case ready

    internal var isAcceptingIntents: Bool {
        switch self {
        case .launching, .collectingIntents:
            return true
        case .routing, .ready:
            return false
        }
    }

    internal var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}
