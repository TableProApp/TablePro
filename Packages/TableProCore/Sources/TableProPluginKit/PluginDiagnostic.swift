//
//  PluginDiagnostic.swift
//  TableProPluginKit
//

import Foundation

public struct PluginDiagnostic: Sendable, Equatable {
    public let title: String
    public let message: String
    public let suggestedActions: [String]
    public let diagnosticInfo: [DiagnosticEntry]
    public let supportURL: URL?

    public init(
        title: String,
        message: String,
        suggestedActions: [String] = [],
        diagnosticInfo: [DiagnosticEntry] = [],
        supportURL: URL? = nil
    ) {
        self.title = title
        self.message = message
        self.suggestedActions = suggestedActions
        self.diagnosticInfo = diagnosticInfo
        self.supportURL = supportURL
    }
}

public struct DiagnosticEntry: Sendable, Equatable {
    public let label: String
    public let value: String

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}

public protocol PluginDiagnosticProvider: AnyObject, Sendable {
    func diagnose(error: Error) -> PluginDiagnostic?
}
