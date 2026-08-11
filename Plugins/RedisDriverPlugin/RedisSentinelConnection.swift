//
//  RedisSentinelConnection.swift
//  RedisDriverPlugin
//
//  Redis Sentinel connection support for HA deployments.
//  Provides master discovery and automatic failover.
//

#if canImport(CRedis)
import CRedis
#endif
import Foundation
import OSLog
import TableProPluginKit

private let sentinelLogger = Logger(subsystem: "com.TablePro.RedisDriver", category: "RedisSentinel")

// MARK: - Sentinel Configuration

struct SentinelConfiguration: Codable, Equatable {
    /// List of Sentinel node addresses (host:port format)
    var sentinelNodes: [String]

    /// Name of the master to monitor
    var masterName: String

    /// Optional Sentinel password (Redis 6.2+)
    var sentinelPassword: String?

    /// Optional username for Sentinel auth
    var sentinelUsername: String?

    /// Whether to prefer read from replica
    var preferReplica: Bool = false

    /// Connection timeout for Sentinel queries
    var connectTimeout: Int = 5

    /// Number of retries before giving up
    var maxRetries: Int = 3

    /// Parse host:port string into components
    static func parseAddress(_ address: String) -> (host: String, port: Int)? {
        let parts = address.split(separator: ":", maxSplits: 1)
        guard parts.count == 2,
              let port = Int(parts[1]) else {
            return nil
        }
        return (String(parts[0]), port)
    }
}

// MARK: - Sentinel Errors

enum SentinelError: Error, LocalizedError {
    case noSentinelNodes
    case allSentinelsUnreachable
    case masterNotFound(String)
    case invalidConfiguration(String)
    case connectionFailed(String)

    var errorDescription: String? {
        switch self {
        case .noSentinelNodes:
            return "No Sentinel nodes configured"
        case .allSentinelsUnreachable:
            return "All Sentinel nodes are unreachable"
        case .masterNotFound(let name):
            return "Master '\(name)' not found in Sentinel configuration"
        case .invalidConfiguration(let message):
            return "Invalid Sentinel configuration: \(message)"
        case .connectionFailed(let message):
            return "Sentinel connection failed: \(message)"
        }
    }
}

// MARK: - Sentinel Connection

/// Handles Redis Sentinel operations for HA deployments.
/// Discovers master/replica addresses from Sentinel nodes.
final class RedisSentinelConnection: @unchecked Sendable {

    // MARK: - Properties

    #if canImport(CRedis)
    private var sentinelContexts: [String: UnsafeMutablePointer<redisContext>] = [:]
    #endif

    private let config: SentinelConfiguration
    private let sentinelAuth: (username: String?, password: String?)?
    private let queue = DispatchQueue(label: "com.TablePro.redis.sentinel", qos: .userInitiated)
    private let stateLock = NSLock()

    private var _cachedMasterAddress: (host: String, port: Int)?
    private var _lastResolutionTime: Date?

    // Cache TTL - re-resolve after this interval
    private let cacheTTL: TimeInterval = 30

    // MARK: - Initialization

    init(config: SentinelConfiguration, sentinelAuth: (username: String?, password: String?)? = nil) {
        self.config = config
        self.sentinelAuth = sentinelAuth

        guard !config.sentinelNodes.isEmpty else {
            sentinelLogger.error("No Sentinel nodes configured")
            return
        }
    }

    deinit {
        #if canImport(CRedis)
        stateLock.lock()
        for (_, ctx) in sentinelContexts {
            redisFree(ctx)
        }
        sentinelContexts.removeAll()
        stateLock.unlock()
        #endif
    }

    // MARK: - Public API

    /// Discover the master address from Sentinel nodes.
    /// Returns (host, port) tuple on success.
    func discoverMaster() async throws -> (host: String, port: Int) {
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [weak self] in
                guard let self = self else {
                    continuation.resume(throwing: SentinelError.connectionFailed("Connection closed"))
                    return
                }

                do {
                    let address = try self.discoverMasterSync()
                    continuation.resume(returning: address)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Discover replica addresses for read scaling.
    func discoverReplicas() async throws -> [(host: String, port: Int)] {
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [weak self] in
                guard let self = self else {
                    continuation.resume(throwing: SentinelError.connectionFailed("Connection closed"))
                    return
                }

                do {
                    let replicas = try self.discoverReplicasSync()
                    continuation.resume(returning: replicas)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Get cached master address if still valid.
    /// Returns nil if cache is stale or empty.
    func getCachedMaster() -> (host: String, port: Int)? {
        stateLock.lock()
        defer { stateLock.unlock() }

        guard let cached = _cachedMasterAddress,
              let lastTime = _lastResolutionTime,
              Date().timeIntervalSince(lastTime) < cacheTTL else {
            return nil
        }

        return cached
    }

    /// Invalidate cached master address (force re-resolution).
    func invalidateCache() {
        stateLock.lock()
        _cachedMasterAddress = nil
        _lastResolutionTime = nil
        stateLock.unlock()
    }

    // MARK: - Synchronous Sentinel Operations (must be called on serial queue)

    #if canImport(CRedis)

    private func discoverMasterSync() throws -> (host: String, port: Int) {
        // Try each Sentinel node until one responds
        for nodeAddress in config.sentinelNodes {
            sentinelLogger.debug("Trying Sentinel node: \(nodeAddress)")

            do {
                if let address = try queryMasterFromSentinel(nodeAddress) {
                    stateLock.lock()
                    _cachedMasterAddress = address
                    _lastResolutionTime = Date()
                    stateLock.unlock()

                    sentinelLogger.info("Discovered master at \(address.host):\(address.port) via Sentinel \(nodeAddress)")
                    return address
                }
            } catch {
                sentinelLogger.warning("Sentinel \(nodeAddress) failed: \(error.localizedDescription)")
                continue
            }
        }

        throw SentinelError.allSentinelsUnreachable
    }

    private func discoverReplicasSync() throws -> [(host: String, port: Int)] {
        var replicas: [(host: String, port: Int)] = []

        for nodeAddress in config.sentinelNodes {
            sentinelLogger.debug("Querying replicas from Sentinel: \(nodeAddress)")

            do {
                if let discovered = try queryReplicasFromSentinel(nodeAddress) {
                    replicas.append(contentsOf: discovered)
                    break // One working Sentinel is enough
                }
            } catch {
                sentinelLogger.warning("Failed to query replicas from \(nodeAddress): \(error.localizedDescription)")
                continue
            }
        }

        return replicas
    }

    private func queryMasterFromSentinel(_ nodeAddress: String) throws -> (host: String, port: Int)? {
        guard let parsed = SentinelConfiguration.parseAddress(nodeAddress) else {
            throw SentinelError.invalidConfiguration("Invalid Sentinel address: \(nodeAddress)")
        }

        let timeout = timeval(tv_sec: Int32(config.connectTimeout), tv_usec: 0)
        guard let ctx = redisConnectWithTimeout(parsed.host, Int32(parsed.port), timeout) else {
            throw SentinelError.connectionFailed("Cannot connect to Sentinel \(nodeAddress)")
        }

        defer {
            redisFree(ctx)
        }

        // Authenticate to Sentinel if needed
        if let auth = sentinelAuth, let password = auth.password, !password.isEmpty {
            let authCmd = auth.username != nil
                ? ["AUTH", auth.username!, password]
                : ["AUTH", password]

            let reply = executeSentinelCommand(ctx, args: authCmd)
            if case .error(let msg) = reply {
                sentinelLogger.warning("Sentinel AUTH failed: \(msg)")
            }
        }

        // Query master address: SENTINEL get-master-addr-by-name <master-name>
        let reply = executeSentinelCommand(ctx, args: ["SENTINEL", "get-master-addr-by-name", config.masterName])

        switch reply {
        case .array(let items):
            guard items.count >= 2,
                  let host = items[0].stringValue,
                  let portStr = items[1].stringValue,
                  let port = Int(portStr) else {
                throw SentinelError.masterNotFound(config.masterName)
            }
            return (host, port)

        case .null, .error:
            throw SentinelError.masterNotFound(config.masterName)

        default:
            throw SentinelError.masterNotFound(config.masterName)
        }
    }

    private func queryReplicasFromSentinel(_ nodeAddress: String) throws -> [(host: String, port: Int)]? {
        guard let parsed = SentinelConfiguration.parseAddress(nodeAddress) else {
            throw SentinelError.invalidConfiguration("Invalid Sentinel address: \(nodeAddress)")
        }

        let timeout = timeval(tv_sec: Int32(config.connectTimeout), tv_usec: 0)
        guard let ctx = redisConnectWithTimeout(parsed.host, Int32(parsed.port), timeout) else {
            throw SentinelError.connectionFailed("Cannot connect to Sentinel \(nodeAddress)")
        }

        defer {
            redisFree(ctx)
        }

        // Authenticate to Sentinel if needed
        if let auth = sentinelAuth, let password = auth.password, !password.isEmpty {
            let authCmd = auth.username != nil
                ? ["AUTH", auth.username!, password]
                : ["AUTH", password]

            let reply = executeSentinelCommand(ctx, args: authCmd)
            if case .error(let msg) = reply {
                sentinelLogger.warning("Sentinel AUTH failed: \(msg)")
            }
        }

        // Query replicas: SENTINEL replicas <master-name>
        let reply = executeSentinelCommand(ctx, args: ["SENTINEL", "replicas", config.masterName])

        var replicas: [(host: String, port: Int)] = []

        if case .array(let items) = reply {
            for item in items {
                if case .array(let info) = item {
                    // Parse IP and PORT from replica info
                    if let ip = findInReplicaInfo(info, key: "ip"),
                       let portStr = findInReplicaInfo(info, key: "port"),
                       let port = Int(portStr) {
                        replicas.append((ip, port))
                    }
                }
            }
        }

        return replicas
    }

    private func findInReplicaInfo(_ info: [RedisReply], key: String) -> String? {
        // Replica info is an array of ["key", "value"] pairs
        for i in stride(from: 0, to: info.count - 1, by: 2) {
            if info[i].stringValue == key {
                return info[i + 1].stringValue
            }
        }
        return nil
    }

    private func executeSentinelCommand(_ ctx: UnsafeMutablePointer<redisContext>, args: [String]) -> RedisReply {
        let argc = Int32(args.count)

        let buffers: [UnsafeMutablePointer<CChar>] = args.map { arg in
            let ptr = UnsafeMutablePointer<CChar>.allocate(capacity: arg.count + 1)
            arg.withCString { cStr in
                ptr.initialize(from: cStr, count: arg.count)
            }
            ptr[arg.count] = 0
            return ptr
        }
        defer { buffers.forEach { $0.deallocate() } }

        let argv = UnsafeMutablePointer<UnsafePointer<CChar>?>.allocate(capacity: argc)
        let argvlen = UnsafeMutablePointer<Int>.allocate(capacity: Int(argc))
        defer {
            argv.deallocate()
            argvlen.deallocate()
        }

        for i in 0..<Int(argc) {
            argv[i] = buffers[i]
            argvlen[i] = args[i].count
        }

        guard let rawReply = redisCommandArgv(ctx, argc, argv, argvlen) else {
            return .error(String(cString: ctx.pointee.errstr))
        }

        defer { freeReplyObject(rawReply) }

        return parseSentinelReply(rawReply)
    }

    private func parseSentinelReply(_ reply: UnsafeMutableRawPointer?) -> RedisReply {
        guard let reply = reply else { return .null }

        let replyPtr = reply.assumingMemoryBound(to: redisReply.self)
        let type = replyPtr.pointee.type

        switch type {
        case REDIS_REPLY_STRING:
            if let str = replyPtr.pointee.str {
                let len = replyPtr.pointee.len
                return .string(String(cString: str, length: len))
            }
            return .null

        case REDIS_REPLY_INTEGER:
            return .integer(replyPtr.pointee.integer)

        case REDIS_REPLY_ARRAY:
            let count = replyPtr.pointee.elements
            guard count > 0, let elements = replyPtr.pointee.element else {
                return .array([])
            }
            var items: [RedisReply] = []
            for i in 0..<count {
                if let element = elements[i] {
                    items.append(parseSentinelReply(element))
                } else {
                    items.append(.null)
                }
            }
            return .array(items)

        case REDIS_REPLY_NIL:
            return .null

        case REDIS_REPLY_ERROR:
            if let str = replyPtr.pointee.str {
                let len = replyPtr.pointee.len
                return .error(String(cString: str, length: len))
            }
            return .error("Unknown error")

        default:
            return .null
        }
    }

    #else

    private func discoverMasterSync() throws -> (host: String, port: Int) {
        throw SentinelError.connectionFailed("CRedis module not available")
    }

    private func discoverReplicasSync() throws -> [(host: String, port: Int)] {
        throw SentinelError.connectionFailed("CRedis module not available")
    }

    #endif
}

// MARK: - Sentinel Mode Enum

enum RedisConnectionMode: String, Codable, CaseIterable {
    case single = "single"
    case sentinel = "sentinel"
    case cluster = "cluster"

    var displayName: String {
        switch self {
        case .single: return "Single Node"
        case .sentinel: return "Sentinel (HA)"
        case .cluster: return "Cluster (Sharded)"
        }
    }
}
