//
//  RedisSentinelResolver.swift
//  RedisDriverPlugin
//
//  Resolves the current Redis master address by querying a list of Sentinel nodes.
//  Pure Swift; transport I/O is abstracted behind SentinelTransport so the resolution
//  algorithm is unit-testable without hiredis.
//

import Foundation

struct SentinelHostPort: Equatable, Sendable, Hashable {
    let host: String
    let port: Int
}

enum SentinelMasterReply: Equatable, Sendable {
    case masterUnknown
    case address(SentinelHostPort)
}

enum RedisSentinelResolutionError: Error, Equatable {
    case noSentinelsConfigured
    case emptyMasterName
    case masterUnknown(masterName: String, triedSentinels: [SentinelHostPort])
    case allSentinelsUnreachable(attempts: [SentinelHostPort])
    case malformedReply(SentinelHostPort, detail: String)
}

protocol SentinelTransport: Sendable {
    func queryMasterAddress(
        masterName: String,
        at sentinel: SentinelHostPort,
        sentinelUsername: String?,
        sentinelPassword: String?
    ) async throws -> SentinelMasterReply
}

final class RedisSentinelResolver: @unchecked Sendable {
    private let sentinels: [SentinelHostPort]
    private let masterName: String
    private let sentinelUsername: String?
    private let sentinelPassword: String?
    private let transport: SentinelTransport

    init(
        sentinels: [SentinelHostPort],
        masterName: String,
        sentinelUsername: String?,
        sentinelPassword: String?,
        transport: SentinelTransport
    ) {
        self.sentinels = sentinels
        self.masterName = masterName
        self.sentinelUsername = sentinelUsername
        self.sentinelPassword = sentinelPassword
        self.transport = transport
    }

    func resolveMaster() async throws -> SentinelHostPort {
        guard !sentinels.isEmpty else {
            throw RedisSentinelResolutionError.noSentinelsConfigured
        }
        guard !masterName.isEmpty else {
            throw RedisSentinelResolutionError.emptyMasterName
        }

        var unreachable: [SentinelHostPort] = []
        var saidUnknown: [SentinelHostPort] = []

        for sentinel in sentinels {
            do {
                let reply = try await transport.queryMasterAddress(
                    masterName: masterName,
                    at: sentinel,
                    sentinelUsername: sentinelUsername,
                    sentinelPassword: sentinelPassword
                )
                switch reply {
                case .address(let address):
                    return address
                case .masterUnknown:
                    saidUnknown.append(sentinel)
                }
            } catch {
                unreachable.append(sentinel)
            }
        }

        if !saidUnknown.isEmpty {
            throw RedisSentinelResolutionError.masterUnknown(
                masterName: masterName,
                triedSentinels: saidUnknown
            )
        }
        throw RedisSentinelResolutionError.allSentinelsUnreachable(attempts: unreachable)
    }

    static func parseMasterReplyTokens(
        _ tokens: [String?]?,
        from sentinel: SentinelHostPort
    ) throws -> SentinelMasterReply {
        guard let tokens else {
            return .masterUnknown
        }
        guard tokens.count == 2 else {
            throw RedisSentinelResolutionError.malformedReply(
                sentinel,
                detail: "expected 2-element array, got \(tokens.count)"
            )
        }
        guard let host = tokens[0], !host.isEmpty else {
            throw RedisSentinelResolutionError.malformedReply(sentinel, detail: "missing host")
        }
        guard let portString = tokens[1], let port = parsePort(portString) else {
            throw RedisSentinelResolutionError.malformedReply(
                sentinel,
                detail: "invalid port \(tokens[1] ?? "nil")"
            )
        }
        return .address(SentinelHostPort(host: host, port: port))
    }

    static func parseSentinelHostList(_ raw: String, defaultPort: Int) -> [SentinelHostPort] {
        raw.split(separator: ",").compactMap { part in
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            return parseSingleHost(trimmed, defaultPort: defaultPort)
        }
    }

    private static func parsePort(_ string: String) -> Int? {
        guard let port = Int(string), (1...65_535).contains(port) else { return nil }
        return port
    }

    private static func parseSingleHost(_ entry: String, defaultPort: Int) -> SentinelHostPort? {
        if entry.hasPrefix("[") {
            guard let closing = entry.firstIndex(of: "]") else { return nil }
            let host = String(entry[entry.index(after: entry.startIndex)..<closing])
            guard !host.isEmpty else { return nil }
            let afterBracket = entry.index(after: closing)
            if afterBracket == entry.endIndex {
                return SentinelHostPort(host: host, port: defaultPort)
            }
            guard entry[afterBracket] == ":" else { return nil }
            let portString = String(entry[entry.index(after: afterBracket)...])
            guard let port = parsePort(portString) else { return nil }
            return SentinelHostPort(host: host, port: port)
        }
        if let lastColon = entry.lastIndex(of: ":"), !entry[..<lastColon].contains(":") {
            let host = String(entry[..<lastColon])
            let portString = String(entry[entry.index(after: lastColon)...])
            guard !host.isEmpty, let port = parsePort(portString) else { return nil }
            return SentinelHostPort(host: host, port: port)
        }
        return SentinelHostPort(host: entry, port: defaultPort)
    }
}
