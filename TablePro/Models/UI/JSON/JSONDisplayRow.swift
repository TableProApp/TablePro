//
//  JSONDisplayRow.swift
//  TablePro
//
//  One printed line of the JSON inspector.
//

import Foundation

enum JSONForeignKeyFailure: Equatable, Sendable {
    case notFound
    case cycle
    case depthLimit
    case failed(String)
}

struct JSONForeignKeyStates: Sendable {
    var fetched: [JSONNodePath: JSONRowNode] = [:]
    var loading: Set<JSONNodePath> = []
    var failures: [JSONNodePath: JSONForeignKeyFailure] = [:]
}

struct JSONDisplayRow: Identifiable, Equatable, Sendable {
    enum Token: Equatable, Sendable {
        case scalar(JSONScalar)
        case openObject
        case closeObject
        case openArray
        case closeArray
        case collapsedObject(count: Int)
        case collapsedArray(count: Int)
    }

    enum Status: Equatable, Sendable {
        case none
        case loading
        case failure(JSONForeignKeyFailure)
    }

    let id: String
    let path: JSONNodePath
    let depth: Int
    let key: JSONNodeKey
    let token: Token
    let needsComma: Bool
    /// The node's own value, carried beside the token rather than read out of it. An expanded
    /// foreign key draws as `{`, and taking the value from the token alone took Copy Value and
    /// Open off the line the moment it was opened.
    let scalar: JSONScalar?
    let foreignKey: JSONForeignKeyRef?
    let isExpandable: Bool
    let isExpanded: Bool
    let status: Status

    var showsKey: Bool {
        switch token {
        case .closeObject, .closeArray: false
        default: key.text != nil
        }
    }
}
