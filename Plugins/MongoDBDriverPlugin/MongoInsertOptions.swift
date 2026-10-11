//
//  MongoInsertOptions.swift
//  MongoDBDriverPlugin
//

import Foundation

/// The options every insert hands libmongoc: Insert Document's, and those behind a script's
/// `insertOne`, `insertMany`, `insert` and `save`, which is also how the grid writes a new row.
///
/// libmongoc checks a document's keys before it sends an insert, and its default check refuses a
/// field named "" at any depth with "invalid document for insert: empty key". The server stores
/// such a field, and mongosh writes one. `validate` is that default without the empty-name flag,
/// libbson's `BSON_VALIDATE_UTF8` and `BSON_VALIDATE_UTF8_ALLOW_NULL`, so a key that is not UTF-8
/// is still refused. It is never `false` or 0, which turns every check off, and for a replace that
/// includes the one keeping an update operator out of the replacement.
enum MongoInsertOptions {
    static let validation = 1 | 8

    static let json = #"{"validate":\#(validation)}"#
}
