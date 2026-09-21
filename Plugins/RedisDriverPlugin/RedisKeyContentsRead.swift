//
//  RedisKeyContentsRead.swift
//  RedisDriverPlugin
//

import Foundation
import TableProPluginKit

/// What the server said about one key. Either half is nil when the server would not say, which
/// an ACL user whose key patterns do not cover the key gets for both, while `SCAN` still lists it.
struct RedisKeyDescription: Equatable, Sendable {
    let typeName: String?
    let ttlSeconds: Int?

    var kind: RedisKeyKind? {
        typeName.flatMap(RedisKeyKind.init(typeName:))
    }

    var typeCell: PluginCellValue {
        .fromOptional(typeName?.uppercased())
    }

    var ttlCell: PluginCellValue {
        .fromOptional(ttlSeconds.map(String.init))
    }
}

struct RedisKeyContents {
    let kind: RedisKeyKind
    let length: Int?
    let preview: RedisReply?

    var lengthCell: PluginCellValue {
        .fromOptional(length.map(String.init))
    }
}

extension RedisCommandChannel {
    func keyTypeNames(_ keys: [String]) async throws -> [String?] {
        try await runMetadataReads(keys.map { ["TYPE", $0] }).map { $0?.stringValue }
    }

    func describeKeys(_ keys: [String]) async throws -> [RedisKeyDescription] {
        let answers = try await runMetadataReads(keys.flatMap { [["TYPE", $0], ["TTL", $0]] })
        return stride(from: 0, to: answers.count - 1, by: 2).map { index in
            RedisKeyDescription(typeName: answers[index]?.stringValue, ttlSeconds: answers[index + 1]?.intValue)
        }
    }

    /// A key whose type is unknown gets no probe at all, because the length and preview commands
    /// are chosen by type.
    func readContents(
        of keys: [String],
        describedAs descriptions: [RedisKeyDescription]
    ) async throws -> [RedisKeyContents?] {
        let kinds = zip(keys, descriptions).map { (key: $0, kind: $1.kind) }
        var commands: [[String]] = []
        commands.reserveCapacity(kinds.count * 2)
        for entry in kinds {
            guard let kind = entry.kind else { continue }
            commands.append(RedisKeySummary.lengthCommand(for: kind, key: entry.key))
            commands.append(RedisKeySummary.previewCommand(for: kind, key: entry.key))
        }
        let answers = try await runMetadataReads(commands)

        var contents: [RedisKeyContents?] = []
        contents.reserveCapacity(kinds.count)
        var next = answers.startIndex
        for entry in kinds {
            guard let kind = entry.kind, next + 1 < answers.endIndex else {
                contents.append(nil)
                continue
            }
            contents.append(RedisKeyContents(kind: kind, length: answers[next]?.intValue, preview: answers[next + 1]))
            next += 2
        }
        return contents
    }
}
