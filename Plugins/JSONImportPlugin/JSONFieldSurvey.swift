//
//  JSONFieldSurvey.swift
//  JSONImportPlugin
//

import Foundation
import TableProPluginKit

/// Every field any row of the file names, each with the first value it holds and a type that fits
/// every value it holds. It keeps one small record per field rather than the values themselves,
/// so it can read every row of a file of any size.
struct JSONFieldSurvey {
    private var profiles: [String: JSONFieldProfile] = [:]

    mutating func add(_ row: NSDictionary) {
        row.enumerateKeysAndObjects { key, value, _ in
            guard let name = key as? String else { return }
            profiles[name, default: JSONFieldProfile()].add(value)
        }
    }

    var fields: [PluginImportField] {
        profiles.keys.sorted().map { name in
            let profile = profiles[name] ?? JSONFieldProfile()
            return PluginImportField(
                name: name,
                sampleValue: profile.sampleValue,
                inferredType: profile.kinds.inferredType
            )
        }
    }
}

struct JSONFieldProfile {
    private(set) var sampleValue: String?
    private(set) var kinds = JSONValueKinds()

    mutating func add(_ value: Any) {
        let kind = JSONValueKind(of: value)
        guard kind != .null else { return }
        if sampleValue == nil {
            sampleValue = JSONImportParsing.sampleString(value)
        }
        kinds.add(kind)
    }
}

struct JSONValueKinds {
    private var sawValue = false
    private var allNested = true
    private var allBoolean = true
    private var allInteger = true
    private var allNumber = true

    mutating func add(_ kind: JSONValueKind) {
        sawValue = true
        if kind != .nested { allNested = false }
        if kind != .boolean { allBoolean = false }
        if kind != .integer { allInteger = false }
        if kind != .integer, kind != .real { allNumber = false }
    }

    var inferredType: PluginImportFieldType {
        guard sawValue else { return .text }
        if allNested { return .json }
        if allBoolean { return .boolean }
        if allInteger { return .integer }
        if allNumber { return .real }
        return .text
    }
}

/// Reads a parsed JSON value's kind from its Core Foundation type. A survey classifies every value
/// in the file, and a Swift `is` or `as?` cast from `Any` costs about ten times as much.
enum JSONValueKind: Equatable {
    case null
    case nested
    case boolean
    case integer
    case real
    case other

    init(of value: Any) {
        let object = value as AnyObject
        switch CFGetTypeID(object) {
        case CFNullGetTypeID():
            self = .null
        case CFArrayGetTypeID(), CFDictionaryGetTypeID():
            self = .nested
        case CFBooleanGetTypeID():
            self = .boolean
        case CFNumberGetTypeID():
            guard let number = object as? NSNumber else {
                self = .other
                return
            }
            self = CFNumberIsFloatType(number) ? .real : .integer
        default:
            self = .other
        }
    }
}
