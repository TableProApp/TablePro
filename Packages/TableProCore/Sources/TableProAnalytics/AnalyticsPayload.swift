//
//  AnalyticsPayload.swift
//  TableProAnalytics
//

import Foundation

/// Anonymous heartbeat payload sent to the analytics API every 24 hours.
/// Encoded with snake_case keys to match backend expectations.
public struct AnalyticsPayload: Encodable, Sendable {
    public let machineId: String
    public let platform: String
    public let appVersion: String?
    public let osVersion: String
    public let architecture: String
    public let locale: String
    public let databaseTypes: [String]?
    public let connectionCount: Int
    public let hasLicense: Bool
    public let connectionAttemptedAt: Date?
    public let connectionSucceededAt: Date?
    public let firstQueryExecutedAt: Date?

    public init(
        machineId: String,
        platform: String,
        appVersion: String?,
        osVersion: String,
        architecture: String,
        locale: String,
        databaseTypes: [String]?,
        connectionCount: Int,
        hasLicense: Bool,
        connectionAttemptedAt: Date? = nil,
        connectionSucceededAt: Date? = nil,
        firstQueryExecutedAt: Date? = nil
    ) {
        self.machineId = machineId
        self.platform = platform
        self.appVersion = appVersion
        self.osVersion = osVersion
        self.architecture = architecture
        self.locale = locale
        self.databaseTypes = databaseTypes
        self.connectionCount = connectionCount
        self.hasLicense = hasLicense
        self.connectionAttemptedAt = connectionAttemptedAt
        self.connectionSucceededAt = connectionSucceededAt
        self.firstQueryExecutedAt = firstQueryExecutedAt
    }
}
