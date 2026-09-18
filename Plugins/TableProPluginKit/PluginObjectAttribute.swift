//
//  PluginObjectAttribute.swift
//  TableProPluginKit
//
//  One labelled property of a database object, supplied by the driver and rendered verbatim.
//

import Foundation

/// A driver names and orders these itself, so per-engine vocabulary (volatility, security,
/// determinism, parallel safety, trigger orientation) never has to be modelled in the app.
public struct PluginObjectAttribute: Codable, Sendable, Hashable {
    public let label: String
    public let value: String

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}
