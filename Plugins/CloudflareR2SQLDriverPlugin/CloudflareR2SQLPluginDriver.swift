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
    private var namespace: String?
    private var isConnected = false
    private let queryTimeout = HttpQueryTimeoutBox()

    let transport: R2SQLTransport
    let connectionConfig: R2SQLConnectionConfig

    init(
        config: DriverConnectionConfig,
        transport: R2SQLTransport = URLSessionR2SQLTransport(resourceTimeout: HttpQueryTimeout.sessionResourceTimeout)
    ) {
        self.connectionConfig = R2SQLConnectionConfig(
            accountId: config.additionalFields[CloudflareR2SQLMetadata.accountIdFieldId] ?? "",
            bucket: config.additionalFields[CloudflareR2SQLMetadata.bucketFieldId] ?? "",
            token: config.password
        )
        self.transport = transport
    }

    var capabilities: PluginCapabilities { [.cancelQuery] }
    var supportsSchemas: Bool { true }
    var supportsTransactions: Bool { false }
    var serverVersion: String? { nil }

    var currentSchema: String? {
        lock.withLock { namespace }
    }

    func switchSchema(to schema: String) async throws {
        lock.withLock { namespace = schema.isEmpty ? nil : schema }
    }

    func namespace(for schema: String?) throws -> String {
        if let schema, !schema.isEmpty { return schema }
        guard let current = currentSchema else {
            throw R2SQLError.configuration("Choose a namespace first.")
        }
        return current
    }

    // MARK: - Lifecycle

    func connect() async throws {
        _ = try connectionConfig.validated()
        lock.withLock { isConnected = true }
        do {
            _ = try await run(sql: R2SQLIntrospectionSQL.showNamespaces)
        } catch {
            lock.withLock { isConnected = false }
            throw error
        }
    }

    func disconnect() {
        lock.withLock { isConnected = false }
        transport.cancelAll()
    }

    func ping() async throws {
        _ = try await run(sql: R2SQLIntrospectionSQL.showNamespaces)
    }

    func cancelQuery() throws {
        transport.cancelAll()
    }

    func applyQueryTimeout(_ seconds: Int) async throws {
        queryTimeout.set(serverTimeoutSeconds: seconds)
    }

    // MARK: - Transport

    func run(sql: String) async throws -> R2SQLResult {
        guard lock.withLock({ isConnected }) else { throw R2SQLError.notConnected }
        let request = try R2SQLRequestBuilder.queryRequest(
            config: connectionConfig,
            sql: sql,
            timeoutInterval: queryTimeout.requestTimeoutInterval
        )
        let response = try await transport.send(request)
        return try R2SQLResponseDecoder.decode(response)
    }
}
