//
//  MongoWriteConcern.swift
//  MongoDBDriverPlugin
//

import Foundation

/// The write concern a connection's URI sets: the Write Concern setting as `w`, and `journal` and
/// `wtimeoutMS` from an imported connection string.
///
/// A command sent through `mongoc_client_command_simple` takes no write concern from the client, so
/// the statements a Structure save writes name it themselves, where SQL Preview shows it.
struct MongoWriteConcern: Equatable, Sendable {
    enum Acknowledgement: Equatable, Sendable {
        case members(Int32)
        case majority
        case tag(String)
    }

    let acknowledgement: Acknowledgement?
    let journal: Bool?
    let timeoutMS: Int64?

    static let serverDefault = MongoWriteConcern(acknowledgement: nil, journal: nil, timeoutMS: nil)

    /// The `writeConcern` document, or nil when the URI sets none and the server's own default
    /// applies.
    ///
    /// A save has to hear the server's answer to know whether it finished, and with `w: 0` and no
    /// `j: true` the server answers `n: 0` whatever the write changed and reports no error, measured
    /// on MongoDB 7.0.43. Such a concern is raised to `w: 1`, keeping the rest of it.
    var schemaChangeJson: String? {
        var members: [String] = []
        switch acknowledgement {
        case .members(let count):
            let acknowledged = count > 0 || journal == true
            members.append("\"w\": \(acknowledged ? count : 1)")
        case .majority:
            members.append("\"w\": \"majority\"")
        case .tag(let tag):
            members.append("\"w\": \(MongoScriptJson.jsonString(tag))")
        case nil:
            break
        }
        if let journal {
            members.append("\"j\": \(journal)")
        }
        if let timeoutMS, timeoutMS > 0 {
            members.append("\"wtimeout\": \(timeoutMS)")
        }
        return members.isEmpty ? nil : "{\(members.joined(separator: ", "))}"
    }
}
