//
//  RedisKeyTreeTruncation.swift
//  TablePro
//

import Foundation

/// The key tree stops at a fixed number of keys, and saying so is not the same as saying the
/// namespace is empty, so it gets its own row rather than reusing the empty placeholder.
internal enum RedisKeyTreeTruncation {
    internal static func message(limit: Int) -> String {
        String(format: String(localized: "Showing first %lld keys"), Int64(limit))
    }
}
