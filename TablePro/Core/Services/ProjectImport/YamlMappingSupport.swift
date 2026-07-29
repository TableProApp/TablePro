//
//  YamlMappingSupport.swift
//  TablePro
//

import Foundation
import Yams

enum YamlMappingSupport {
    static func loadMapping(_ contents: String) -> [String: Any]? {
        guard let object = try? Yams.load(yaml: contents) else {
            return nil
        }
        guard let mapping = object as? [String: Any] else {
            return nil
        }
        return expandingMergeKeys(mapping)
    }

    static func loadDocuments(_ contents: String) -> [[String: Any]] {
        guard let objects = try? Yams.load_all(yaml: contents) else {
            return []
        }
        return objects.compactMap { $0 as? [String: Any] }.map(expandingMergeKeys)
    }

    static func expandingMergeKeys(_ mapping: [String: Any]) -> [String: Any] {
        var own: [String: Any] = [:]
        var inherited: [String: Any] = [:]
        for (key, value) in mapping {
            guard key == "<<" else {
                own[key] = expand(value)
                continue
            }
            for source in mergeSources(value) where !source.isEmpty {
                for (mergeKey, mergeValue) in source where inherited[mergeKey] == nil {
                    inherited[mergeKey] = mergeValue
                }
            }
        }
        var result = inherited
        for (key, value) in own {
            result[key] = value
        }
        return result
    }

    static func mapping(_ value: Any?) -> [String: Any]? {
        guard let mapping = value as? [String: Any] else {
            return nil
        }
        return expandingMergeKeys(mapping)
    }

    static func string(_ value: Any?) -> String? {
        switch value {
        case let text as String:
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : trimmed
        case let number as Int:
            return String(number)
        case let flag as Bool:
            return flag ? "true" : "false"
        default:
            return nil
        }
    }

    static func int(_ value: Any?) -> Int? {
        if let number = value as? Int {
            return number
        }
        guard let text = string(value) else {
            return nil
        }
        return Int(text)
    }

    private static func expand(_ value: Any) -> Any {
        if let mapping = value as? [String: Any] {
            return expandingMergeKeys(mapping)
        }
        if let list = value as? [Any] {
            return list.map(expand)
        }
        return value
    }

    private static func mergeSources(_ value: Any) -> [[String: Any]] {
        if let mapping = value as? [String: Any] {
            return [expandingMergeKeys(mapping)]
        }
        if let list = value as? [Any] {
            return list.compactMap { $0 as? [String: Any] }.map(expandingMergeKeys)
        }
        return []
    }
}
