//
//  MongoDBTimeoutPolicy.swift
//  MongoDBDriverPlugin
//

import Foundation

struct MongoDBConnectTimeout: Equatable, Sendable {
    static let defaultMilliseconds = 10_000
    static let maximumMilliseconds = 3_600_000

    let milliseconds: Int32

    init(additionalFields: [String: String]) {
        milliseconds = Int32(Self.resolve(additionalFields: additionalFields))
    }

    init(milliseconds: Int) {
        self.milliseconds = Int32(min(max(milliseconds, 1), Self.maximumMilliseconds))
    }

    var uriParameters: [String] {
        [
            "connectTimeoutMS=\(milliseconds)",
            "serverSelectionTimeoutMS=\(milliseconds)"
        ]
    }

    private static func resolve(additionalFields: [String: String]) -> Int {
        if let rawMilliseconds = additionalFields["connectTimeoutMilliseconds"],
           let parsedMilliseconds = Int64(rawMilliseconds.trimmingCharacters(in: .whitespaces)) {
            return clamp(parsedMilliseconds)
        }
        if let rawSeconds = additionalFields["connectTimeoutSeconds"],
           let parsedSeconds = Int64(rawSeconds.trimmingCharacters(in: .whitespaces)) {
            let multiplied = parsedSeconds.multipliedReportingOverflow(by: 1_000)
            return clamp(multiplied.overflow ? Int64.max : multiplied.partialValue)
        }
        return defaultMilliseconds
    }

    private static func clamp(_ milliseconds: Int64) -> Int {
        Int(min(max(milliseconds, 1), Int64(maximumMilliseconds)))
    }
}

enum MongoDBServerErrorCode {
    static let badValue: UInt32 = 2
    static let indexNotFound: UInt32 = 27
    static let maxTimeMSExpired: UInt32 = 50
    static let commandNotSupportedOnView: UInt32 = 166
    static let cursorKilled: UInt32 = 237

    /// Every code in the server's `Interruption` category on each release branch from 4.0 through
    /// 9.0, read from its `src/mongo/base/error_codes.yml` (`error_codes.err` before 4.4). The
    /// server fails a whole write batch with `ok: 0` for these, keeping the documents it already
    /// wrote. `scripts/probes/check-mongodb-interruption-codes.sh` diffs the set against every branch.
    static let interruptionCategory: Set<UInt32> = [
        24, maxTimeMSExpired, cursorKilled, 262, 279, 281, 282, 290, 355, 453, 471, 473, 485, 509,
        11_600, 11_601, 11_602, 46_841, 91_331, 10_045_600
    ]
}

enum MongoDBTimeoutPolicy {
    static let backgroundMaxTimeMS: Int32 = 5_000

    static func queryTimeoutMilliseconds(seconds: Int) -> Int32 {
        PluginQueryTimeout.int32Milliseconds(seconds)
    }

    static func resolveMaxTimeMS(ambientMS: Int32, background: Bool) -> Int32? {
        guard background else {
            return ambientMS > 0 ? ambientMS : nil
        }
        guard ambientMS > 0 else {
            return backgroundMaxTimeMS
        }
        return min(ambientMS, backgroundMaxTimeMS)
    }

    static func shouldRetryWithoutHint(errorCode: UInt32) -> Bool {
        errorCode == MongoDBServerErrorCode.badValue || errorCode == MongoDBServerErrorCode.indexNotFound
    }

    static func isTimeoutCode(_ errorCode: UInt32) -> Bool {
        errorCode == MongoDBServerErrorCode.maxTimeMSExpired
    }

    static func timeoutMessage(maxTimeMS: Int32) -> String {
        String(
            format: String(
                localized: """
                The query timed out after %d seconds. Sorting or filtering on a field with no index \
                makes MongoDB read the whole collection, even when you only ask for one page. \
                Add an index for that field, or raise this connection's query timeout in Options.
                """
            ),
            seconds(maxTimeMS)
        )
    }

    static func writeTimeoutMessage(maxTimeMS: Int32) -> String {
        String(
            format: String(
                localized: "The write did not finish within %d seconds, so MongoDB stopped it. Raise this connection's query timeout in Options if it needs longer."
            ),
            seconds(maxTimeMS)
        )
    }

    private static func seconds(_ maxTimeMS: Int32) -> Int {
        max(1, Int((Double(maxTimeMS) / 1_000).rounded()))
    }
}
