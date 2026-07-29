//
//  OperationCaller.swift
//  TablePro
//

import Foundation

internal enum OperationCaller: Sendable, Equatable {
    case userInterface
    case mcpClient(label: String?)
    case aiAssistant(sessionId: String?)
    case importPipeline
    case backgroundMaintenance
}

internal struct CallerCapabilities: OptionSet, Sendable {
    let rawValue: Int

    static let mayWrite = CallerCapabilities(rawValue: 1 << 0)
    static let mayRunDestructive = CallerCapabilities(rawValue: 1 << 1)
    static let mayRunMultiStatement = CallerCapabilities(rawValue: 1 << 2)
    static let preCleared = CallerCapabilities(rawValue: 1 << 3)
    static let cannotPrompt = CallerCapabilities(rawValue: 1 << 4)
    static let confirmationPreCleared = CallerCapabilities(rawValue: 1 << 5)

    static let interactiveUser: CallerCapabilities = [.mayWrite, .mayRunDestructive, .mayRunMultiStatement]
}
