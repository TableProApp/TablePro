//
//  PluginSchemaChangeReview.swift
//  TableProPluginKit
//

import Foundation

/// A driver's answer to a whole Structure save, given once it has read what the save depends on.
public struct PluginSchemaChangeReview: Sendable, Equatable {
    /// Why the save cannot run as it stands, worded for the user, or nil when it can.
    public var refusal: String?
    /// Statements that run before the save's own, in order. Shown in SQL Preview and run on Save.
    public var leadingStatements: [String]
    /// What the driver read to compose this answer, in a form only the driver reads. The app keeps
    /// it with the save and hands it back before and after writing, so the driver can refuse a save
    /// the server has moved on from and check what the statements did against what they were
    /// composed from.
    public var basis: String?

    public init(refusal: String? = nil, leadingStatements: [String] = [], basis: String? = nil) {
        self.refusal = refusal
        self.leadingStatements = leadingStatements
        self.basis = basis
    }
}
