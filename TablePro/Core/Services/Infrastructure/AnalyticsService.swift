//
//  AnalyticsService.swift
//  TablePro
//
//  Lightweight heartbeat analytics — sends anonymous usage data to help improve TablePro
//

import CryptoKit
import Foundation
import os

/// Sends periodic anonymous usage heartbeats to the TablePro analytics API
@MainActor
final class AnalyticsService {
    static let shared = AnalyticsService()

    private static let logger = Logger(subsystem: "com.TablePro", category: "AnalyticsService")

    // swiftlint:disable:next force_unwrapping
    private let analyticsURL = URL(string: "https://api.tablepro.app/v1/analytics")!

    /// Heartbeat interval: 24 hours
    private let heartbeatInterval: TimeInterval = 24 * 60 * 60

    /// Initial delay before first heartbeat (let connections establish)
    private let initialDelay: TimeInterval = 10

    /// HMAC-SHA256 shared secret for analytics request signing (injected via Info.plist build setting)
    private let hmacSecret: String? = {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "AnalyticsHMACSecret") as? String,
              !value.isEmpty,
              !value.hasPrefix("$(") else {
            return nil
        }
        return value
    }()

    private var heartbeatTask: Task<Void, Never>?

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.waitsForConnectivity = true
        return URLSession(configuration: config)
    }()

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }()

    private init() {}

    deinit {
        heartbeatTask?.cancel()
    }

    // MARK: - Public API

    /// Start periodic heartbeat. Call from AppDelegate.applicationDidFinishLaunching.
    func startPeriodicHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            // Initial delay before first heartbeat (let connections establish)
            try? await Task.sleep(for: .seconds(self?.initialDelay ?? 10))

            while !Task.isCancelled {
                await self?.sendHeartbeat()
                try? await Task.sleep(for: .seconds(self?.heartbeatInterval ?? 86_400))
            }
        }
    }

    // MARK: - Private

    private func sendHeartbeat() async {
        // Check opt-out setting
        guard AppSettingsStorage.shared.loadGeneral().shareAnalytics else {
            Self.logger.trace("Analytics disabled by user, skipping heartbeat")
            return
        }

        let payload = buildPayload()

        do {
            var request = URLRequest(url: analyticsURL)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try encoder.encode(payload)

            // Sign request body with HMAC-SHA256 (secret injected at build time)
            if let body = request.httpBody,
               let secret = hmacSecret, !secret.isEmpty {
                let key = SymmetricKey(data: Data(secret.utf8))
                let signature = HMAC<SHA256>.authenticationCode(for: body, using: key)
                let signatureHex = signature.map { String(format: "%02x", $0) }.joined()
                request.setValue(signatureHex, forHTTPHeaderField: "X-Signature")
            }

            let (_, response) = try await session.data(for: request)

            if let httpResponse = response as? HTTPURLResponse {
                Self.logger.trace("Analytics heartbeat sent, status: \(httpResponse.statusCode)")
            }
        } catch {
            Self.logger.trace("Analytics heartbeat failed: \(error.localizedDescription)")
        }
    }

    private func buildPayload() -> AnalyticsPayload {
        let appVersion = Bundle.main.appVersion

        let osVersion: String = {
            let version = ProcessInfo.processInfo.operatingSystemVersion
            return "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        }()

        let architecture: String = {
            #if arch(arm64)
            return "arm64"
            #else
            return "x86_64"
            #endif
        }()

        let generalSettings = AppSettingsStorage.shared.loadGeneral()
        let locale = generalSettings.language.rawValue

        let sessions = DatabaseManager.shared.activeSessions
        let databaseTypes = Array(Set(sessions.values.compactMap { $0.connection.type.rawValue }))
        let connectionCount = sessions.count

        let licenseKey = LicenseStorage.shared.loadLicenseKey()

        return AnalyticsPayload(
            machineId: LicenseStorage.shared.machineId,
            appVersion: appVersion,
            osVersion: osVersion,
            architecture: architecture,
            locale: locale,
            databaseTypes: databaseTypes.isEmpty ? nil : databaseTypes,
            connectionCount: connectionCount,
            licenseKey: licenseKey
        )
    }
}

// MARK: - Payload

private struct AnalyticsPayload: Encodable {
    let machineId: String
    let appVersion: String?
    let osVersion: String
    let architecture: String
    let locale: String
    let databaseTypes: [String]?
    let connectionCount: Int
    let licenseKey: String?
}
