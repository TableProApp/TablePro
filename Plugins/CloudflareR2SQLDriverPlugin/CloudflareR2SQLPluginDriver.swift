//
//  CloudflareR2SQLPluginDriver.swift
//  TablePro
//

import Foundation
import os
import TableProPluginKit
import TableProR2SQLCore

final class CloudflareR2SQLPluginDriver: PluginDatabaseDriver, @unchecked Sendable {
    static let logger = Logger(subsystem: "com.TablePro", category: "CloudflareR2SQL")

    private let lock = NSLock()
    private var connectionConfig: R2SQLConnectionConfig?
    private var namespace: String?
    private var isConnected = false

    let transport: R2SQLTransport
    let config: DriverConnectionConfig

    init(config: DriverConnectionConfig, transport: R2SQLTransport? = nil) {
        self.config = config
        self.transport = transport ?? URLSessionR2SQLTransport()
    }

    // MARK: - Capabilities

    var capabilities: PluginCapabilities {
        [.cancelQuery]
    }

    var supportsSchemas: Bool { true }

    var supportsTransactions: Bool { false }

    var serverVersion: String? { nil }

    // MARK: - Connection State

    var resolvedConfig: R2SQLConnectionConfig? {
        lock.withLock { connectionConfig }
    }

    var currentSchema: String? {
        lock.withLock { namespace }
    }

    func switchSchema(to schema: String) async throws {
        lock.withLock { namespace = schema }
    }

    func resolveNamespace(_ schema: String?) -> String? {
        if let schema, !schema.isEmpty { return schema }
        let current = currentSchema
        if let current, !current.isEmpty { return current }
        return nil
    }

    // MARK: - Lifecycle

    func connect() async throws {
        let resolved = Self.buildConfig(from: config)
        if let error = resolved.validate() {
            throw error
        }
        lock.withLock {
            connectionConfig = resolved
            if namespace == nil {
                namespace = resolved.defaultNamespace.isEmpty ? nil : resolved.defaultNamespace
            }
            isConnected = true
        }
        _ = try await run(sql: R2SQLIntrospectionSQL.showNamespaces())
    }

    func disconnect() {
        lock.withLock {
            connectionConfig = nil
            isConnected = false
        }
    }

    func ping() async throws {
        _ = try await run(sql: R2SQLIntrospectionSQL.showNamespaces())
    }

    func cancelQuery() throws {
        (transport as? URLSessionR2SQLTransport)?.cancelInFlight()
    }

    // MARK: - Transport

    func run(sql: String) async throws -> R2SQLResult {
        guard let resolved = resolvedConfig else {
            throw R2SQLError.notConnected
        }
        let request = try R2SQLRequestBuilder.queryRequest(config: resolved, sql: sql)
        let response = try await transport.send(request)
        switch R2SQLErrorClassifier.decode(response) {
        case .success(let result):
            return result
        case .failure(let error):
            throw error
        }
    }

    private static func buildConfig(from config: DriverConnectionConfig) -> R2SQLConnectionConfig {
        R2SQLConnectionConfig(
            accountId: config.additionalFields["r2AccountId"] ?? "",
            bucket: config.additionalFields["r2Bucket"] ?? "",
            token: config.password,
            defaultNamespace: config.additionalFields["r2Namespace"] ?? "",
            timeoutSeconds: 60
        )
    }
}
