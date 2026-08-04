//
//  MongoDBTimeoutPolicy.swift
//  MongoDBDriverPlugin
//

import Foundation

enum MongoDBServerErrorCode {
    static let badValue: UInt32 = 2
    static let indexNotFound: UInt32 = 27
    static let maxTimeMSExpired: UInt32 = 50
    static let cursorKilled: UInt32 = 237
}

enum MongoDBTimeoutPolicy {
    static let backgroundMaxTimeMS: Int32 = 5_000

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
        let seconds = max(1, Int((Double(maxTimeMS) / 1_000).rounded()))
        return String(
            format: String(
                localized: """
                The query timed out after %d seconds. Sorting or filtering on a field with no index \
                makes MongoDB read the whole collection, even when you only ask for one page. \
                Add an index for that field, or raise the query timeout in Settings.
                """
            ),
            seconds
        )
    }
}
