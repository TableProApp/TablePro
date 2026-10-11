//
//  GitOutputParsers.swift
//  TablePro
//

import Foundation

internal struct GitStatusRecord: Equatable, Sendable {
    let path: String
    let originalPath: String?
    let status: GitFileStatus
}

internal struct GitRepositoryInfo: Equatable, Sendable {
    let topLevel: URL
    let gitDirectory: URL
    let prefix: String
}

internal struct GitCommitRecord: Equatable, Sendable {
    let hash: String
    let author: String
    let date: Date?
    let subject: String
    let path: String?
}

internal enum GitStatusParser {
    static func parse(_ data: Data) -> [GitStatusRecord] {
        let tokens = GitOutputTokens.split(data, separator: 0)
        var records: [GitStatusRecord] = []
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            index += 1
            guard let kind = token.first else { continue }
            switch kind {
            case "1":
                if let record = trackedRecord(token, fieldCount: 8) { records.append(record) }
            case "2":
                let originalPath = index < tokens.count ? tokens[index] : nil
                index += 1
                if let record = trackedRecord(token, fieldCount: 9, originalPath: originalPath) {
                    records.append(record)
                }
            case "u":
                if let record = trackedRecord(token, fieldCount: 10, isUnmergedEntry: true) { records.append(record) }
            case "?":
                let path = String(token.dropFirst(2))
                guard !path.isEmpty else { continue }
                records.append(GitStatusRecord(path: path, originalPath: nil, status: .untracked))
            default:
                continue
            }
        }
        return records
    }

    private static func trackedRecord(
        _ token: String,
        fieldCount: Int,
        originalPath: String? = nil,
        isUnmergedEntry: Bool = false
    ) -> GitStatusRecord? {
        let fields = token.split(separator: " ", maxSplits: fieldCount, omittingEmptySubsequences: false)
        guard fields.count == fieldCount + 1 else { return nil }
        let path = String(fields[fieldCount])
        guard !path.isEmpty else { return nil }
        return GitStatusRecord(
            path: path,
            originalPath: originalPath,
            status: GitFileStatus(code: fields[1], isUnmergedEntry: isUnmergedEntry)
        )
    }
}

internal enum GitRepositoryInfoParser {
    static func parse(_ data: Data) -> GitRepositoryInfo? {
        let lines = (String(bytes: data, encoding: .utf8) ?? "")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        guard lines.count >= 2, !lines[0].isEmpty, !lines[1].isEmpty else { return nil }
        return GitRepositoryInfo(
            topLevel: URL(fileURLWithPath: lines[0], isDirectory: true),
            gitDirectory: URL(fileURLWithPath: lines[1], isDirectory: true),
            prefix: lines.count > 2 ? lines[2] : ""
        )
    }
}

internal enum GitLogParser {
    private static let recordSeparator: Character = "\u{1E}"
    private static let fieldSeparator: Character = "\u{1F}"

    static func parse(_ data: Data) -> [GitCommitRecord] {
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime]
        var commits: [GitCommitRecord] = []
        var header: [Substring]?
        var paths: [String] = []
        var changeStatus = ""
        var expectsStatus = false

        func flush() {
            guard let header, header.count >= 3, isCommitHash(header[0]), !changeStatus.hasPrefix("D") else { return }
            commits.append(GitCommitRecord(
                hash: String(header[0]),
                author: String(header[1]),
                date: dateFormatter.date(from: String(header[2])),
                subject: header.count > 3 ? String(header[3]) : "",
                path: paths.last
            ))
        }

        for token in GitOutputTokens.split(data, separator: 0) {
            if token.first == recordSeparator {
                flush()
                header = token.dropFirst().split(separator: fieldSeparator, maxSplits: 3, omittingEmptySubsequences: false)
                paths = []
                changeStatus = ""
                expectsStatus = true
                continue
            }
            let trimmed = token.trimmingCharacters(in: .newlines)
            guard !trimmed.isEmpty else { continue }
            if expectsStatus {
                expectsStatus = false
                changeStatus = trimmed
                continue
            }
            paths.append(trimmed)
        }
        flush()
        return commits
    }

    static func isCommitHash(_ value: Substring) -> Bool {
        guard value.count == 40 || value.count == 64 else { return false }
        return value.allSatisfy(\.isHexDigit)
    }
}

internal enum GitOutputTokens {
    static func split(_ data: Data, separator: UInt8) -> [String] {
        data.split(separator: separator, omittingEmptySubsequences: false).map { bytes in
            String(bytes: bytes, encoding: .utf8) ?? String(bytes: bytes, encoding: .isoLatin1) ?? ""
        }
    }
}
