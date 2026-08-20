//
//  RedisSentinelResolver.swift
//  RedisDriverPlugin
//
//  Finds the current primary by asking the Sentinel quorum. Pure: the I/O sits behind
//  RedisSentinelTransport so the iteration rules can be tested without hiredis.
//

import Foundation

enum RedisSentinelReply: Equatable, Sendable {
    case primaryUnknown
    case address(RedisNodeAddress)
}

enum RedisSentinelError: Error, Equatable {
    case noSentinelsConfigured
    case emptyPrimaryGroupName
    case primaryUnknown(group: String, tried: [RedisNodeAddress], monitored: [String])
    case allSentinelsUnreachable(tried: [RedisNodeAddress])
    case malformedReply(RedisNodeAddress, detail: String)
    case refused(RedisNodeAddress, detail: String)
    case deadlineExceeded(tried: [RedisNodeAddress])
}

protocol RedisSentinelTransport: Sendable {
    func primaryAddress(group: String, at sentinel: RedisNodeAddress) async throws -> RedisSentinelReply
    func peerSentinels(group: String, at sentinel: RedisNodeAddress) async throws -> [RedisNodeAddress]
    func monitoredGroups(at sentinel: RedisNodeAddress) async throws -> [String]
}

extension RedisSentinelTransport {
    func peerSentinels(group: String, at sentinel: RedisNodeAddress) async throws -> [RedisNodeAddress] { [] }
    func monitoredGroups(at sentinel: RedisNodeAddress) async throws -> [String] { [] }
}

struct RedisSentinelResolution: Equatable, Sendable {
    let primary: RedisNodeAddress
    let answeredBy: RedisNodeAddress
    /// The quorum's own view of its membership, so a later re-resolve can reach a sentinel the
    /// user never listed.
    let knownSentinels: [RedisNodeAddress]
}

final class RedisSentinelResolver: @unchecked Sendable {
    private let configuredSentinels: [RedisNodeAddress]
    private let group: String
    private let transport: RedisSentinelTransport
    private let deadline: TimeInterval

    private let lock = NSLock()
    private var discovered: [RedisNodeAddress] = []

    init(
        sentinels: [RedisNodeAddress],
        group: String,
        transport: RedisSentinelTransport,
        deadline: TimeInterval = 15
    ) {
        self.configuredSentinels = sentinels
        self.group = group.trimmingCharacters(in: .whitespaces)
        self.transport = transport
        self.deadline = deadline
    }

    /// The configured sentinels first, then any the quorum told us about on an earlier resolve.
    var candidates: [RedisNodeAddress] {
        lock.lock()
        defer { lock.unlock() }
        var seen = Set(configuredSentinels)
        return configuredSentinels + discovered.filter { seen.insert($0).inserted }
    }

    func resolvePrimary() async throws -> RedisSentinelResolution {
        guard !configuredSentinels.isEmpty else { throw RedisSentinelError.noSentinelsConfigured }
        guard !group.isEmpty else { throw RedisSentinelError.emptyPrimaryGroupName }

        let started = Date()
        var unreachable: [RedisNodeAddress] = []
        var refusals: [(RedisNodeAddress, String)] = []
        var unaware: [RedisNodeAddress] = []
        var monitored: [String] = []
        var attempted: [RedisNodeAddress] = []

        for sentinel in candidates {
            guard Date().timeIntervalSince(started) < deadline else {
                throw RedisSentinelError.deadlineExceeded(tried: attempted)
            }
            attempted.append(sentinel)
            do {
                switch try await transport.primaryAddress(group: group, at: sentinel) {
                case .address(let address):
                    let peers = (try? await transport.peerSentinels(group: group, at: sentinel)) ?? []
                    remember(peers)
                    return RedisSentinelResolution(
                        primary: address,
                        answeredBy: sentinel,
                        knownSentinels: candidates
                    )
                case .primaryUnknown:
                    unaware.append(sentinel)
                    if monitored.isEmpty {
                        monitored = (try? await transport.monitoredGroups(at: sentinel)) ?? []
                    }
                }
            } catch let error as RedisSentinelError {
                switch error {
                case .malformedReply:
                    throw error
                case .refused(_, let detail):
                    // A Sentinel that answered and said no is a configuration problem, not a
                    // network one, and reporting it as unreachable sends the user to the wrong field.
                    refusals.append((sentinel, detail))
                default:
                    unreachable.append(sentinel)
                }
            } catch {
                unreachable.append(sentinel)
            }
        }

        if !unaware.isEmpty {
            throw RedisSentinelError.primaryUnknown(group: group, tried: unaware, monitored: monitored)
        }
        if let refusal = refusals.first {
            throw RedisSentinelError.refused(refusal.0, detail: refusal.1)
        }
        throw RedisSentinelError.allSentinelsUnreachable(tried: unreachable)
    }

    private func remember(_ peers: [RedisNodeAddress]) {
        guard !peers.isEmpty else { return }
        lock.lock()
        var seen = Set(configuredSentinels).union(discovered)
        discovered.append(contentsOf: peers.filter { seen.insert($0).inserted })
        lock.unlock()
    }

    /// `SENTINEL get-master-addr-by-name` answers with a two-element array, or nil when it does not
    /// monitor that group.
    static func parseAddressReply(
        _ tokens: [String?]?,
        from sentinel: RedisNodeAddress
    ) throws -> RedisSentinelReply {
        guard let tokens else { return .primaryUnknown }
        guard tokens.count == 2 else {
            throw RedisSentinelError.malformedReply(
                sentinel,
                detail: "expected a 2-element array, got \(tokens.count)"
            )
        }
        guard let host = tokens[0], !host.isEmpty else {
            throw RedisSentinelError.malformedReply(sentinel, detail: "missing host")
        }
        guard let portText = tokens[1], let port = RedisHostListParser.parsePort(portText) else {
            throw RedisSentinelError.malformedReply(sentinel, detail: "invalid port \(tokens[1] ?? "nil")")
        }
        return .address(RedisNodeAddress(host: host, port: port))
    }

    /// `SENTINEL sentinels <group>` and `SENTINEL replicas <group>` both answer with an array of
    /// flat key/value maps carrying `ip` and `port`.
    static func parseNodeMaps(_ reply: RedisReply) -> [RedisNodeAddress] {
        guard case .array(let entries) = reply else { return [] }
        return entries.compactMap { entry in
            guard case .array(let fields) = entry, fields.count % 2 == 0 else { return nil }
            var host: String?
            var port: Int?
            for index in stride(from: 0, to: fields.count, by: 2) {
                switch fields[index].stringValue {
                case "ip": host = fields[index + 1].stringValue
                case "port": port = fields[index + 1].stringValue.flatMap(RedisHostListParser.parsePort)
                default: continue
                }
            }
            guard let host, !host.isEmpty, let port else { return nil }
            return RedisNodeAddress(host: host, port: port)
        }
    }

    /// `SENTINEL masters` answers with the same map shape, keyed by `name`.
    static func parseGroupNames(_ reply: RedisReply) -> [String] {
        guard case .array(let entries) = reply else { return [] }
        return entries.compactMap { entry in
            guard case .array(let fields) = entry, fields.count % 2 == 0 else { return nil }
            for index in stride(from: 0, to: fields.count, by: 2) where fields[index].stringValue == "name" {
                return fields[index + 1].stringValue
            }
            return nil
        }
    }
}

enum RedisSentinelErrorPresenter {
    static func pluginError(_ error: RedisSentinelError) -> RedisPluginError {
        RedisPluginError(code: 0, message: message(for: error))
    }

    static func message(for error: RedisSentinelError) -> String {
        switch error {
        case .noSentinelsConfigured:
            return String(localized: "Sentinel mode needs at least one Sentinel node.")
        case .emptyPrimaryGroupName:
            return String(localized: "Sentinel mode needs a primary group name, such as mymaster.")
        case .primaryUnknown(let group, let tried, let monitored):
            let triedList = list(tried)
            if monitored.isEmpty {
                let template = String(localized: "No Sentinel monitors a primary group named \"%@\". Tried %@.")
                return String(format: template, group, triedList)
            }
            let template = String(
                localized: "No Sentinel monitors a primary group named \"%@\". Tried %@, which monitor %@."
            )
            return String(format: template, group, triedList, monitored.joined(separator: ", "))
        case .allSentinelsUnreachable(let tried):
            let template = String(localized: "Could not reach any Sentinel. Tried %@.")
            return String(format: template, list(tried))
        case .malformedReply(let sentinel, let detail):
            let template = String(localized: "Sentinel %@ sent a reply TablePro could not read (%@).")
            return String(format: template, sentinel.identifier, detail)
        case .refused(let sentinel, let detail):
            let template = String(localized: "Sentinel %@ refused the request: %@")
            return String(format: template, sentinel.identifier, detail)
        case .deadlineExceeded(let tried):
            let template = String(localized: "Timed out asking the Sentinels for the primary. Tried %@.")
            return String(format: template, list(tried))
        }
    }

    private static func list(_ addresses: [RedisNodeAddress]) -> String {
        addresses.map(\.identifier).joined(separator: ", ")
    }
}
