//
//  YamlMappingSupport.swift
//  TablePro
//

import Foundation
import Yams

enum YamlMappingSupport {
    // The readers below walk loaded values one call per level on the scan's 512 KiB worker stack. No config file
    // nests near this.
    static let maximumNesting = 128

    static func loadMapping(
        _ contents: String,
        budget: ProjectScanExpansionBudget = ProjectScanExpansionBudget()
    ) -> [String: Any]? {
        nonisolated(unsafe) let budget = budget
        return onComposerThread {
            guard let parser = try? Yams.Parser(yaml: contents),
                  let node = try? parser.singleRoot(),
                  isWithinLimits(node, of: parser, budget: budget),
                  let mapping = node.any as? [String: Any] else {
                return nil
            }
            return expandingMergeKeys(mapping)
        }
    }

    static func loadDocuments(
        _ contents: String,
        budget: ProjectScanExpansionBudget = ProjectScanExpansionBudget()
    ) -> [[String: Any]] {
        nonisolated(unsafe) let budget = budget
        return onComposerThread {
            guard let parser = try? Yams.Parser(yaml: contents) else {
                return []
            }
            var documents: [[String: Any]] = []
            while let node = try? parser.nextRoot() {
                guard isWithinLimits(node, of: parser, budget: budget), let mapping = node.any as? [String: Any] else {
                    continue
                }
                documents.append(expandingMergeKeys(mapping))
            }
            return documents
        } ?? []
    }

    // Yams composes one call per level. libyaml allows 1,000 levels, and a 512 KiB worker stack runs out a few
    // hundred levels down.
    private static func onComposerThread<Value>(_ body: @escaping @Sendable () -> Value?) -> Value? {
        nonisolated(unsafe) var value: Value?
        let finished = DispatchSemaphore(value: 0)
        let thread = Thread {
            value = body()
            finished.signal()
        }
        thread.stackSize = 8 << 20
        thread.start()
        finished.wait()
        return value
    }

    // Yams shares an anchored node with every alias to it, so nested aliases cost nothing to compose and grow
    // exponentially once built into values. Every node reached again through an alias is charged before building.
    // `Node.anchor` is weak and only the parser holds the anchors, so the parser stays alive for the walk.
    static func isWithinLimits(_ root: Node, of parser: Yams.Parser, budget: ProjectScanExpansionBudget) -> Bool {
        withExtendedLifetime(parser) {
            var anchors: Set<ObjectIdentifier> = []
            var pending: [(node: Node, nesting: Int, isAliased: Bool)] = [(root, 0, false)]
            while let entry = pending.popLast() {
                let nesting = entry.nesting
                var isAliased = entry.isAliased
                if !isAliased, let anchor = entry.node.anchor {
                    isAliased = !anchors.insert(ObjectIdentifier(anchor)).inserted
                }
                switch entry.node {
                case .scalar(let scalar):
                    guard !isAliased || budget.spend(max(scalar.string.utf8.count, 1)) else { return false }
                    guard !overflowsSexagesimal(scalar) else { return false }
                case .sequence(let sequence):
                    guard nesting < maximumNesting, !isAliased || budget.spend(1) else { return false }
                    for child in sequence.reversed() {
                        pending.append((child, nesting + 1, isAliased))
                    }
                case .mapping(let mapping):
                    guard nesting < maximumNesting, !isAliased || budget.spend(1) else { return false }
                    for (key, value) in mapping.reversed() {
                        // Yams' constructor force-unwraps a key that is not a scalar.
                        guard case .scalar = key else { return false }
                        pending.append((value, nesting + 1, isAliased))
                        pending.append((key, nesting + 1, isAliased))
                    }
                case .alias:
                    // Yams resolves aliases while composing; the constructor traps on one left in the tree.
                    return false
                }
            }
            return true
        }
    }

    // YAML 1.1 reads `1:30` as the base-60 integer 90, and Yams' constructor traps when one overflows Int. At most
    // 18 characters it cannot.
    private static func overflowsSexagesimal(_ scalar: Node.Scalar) -> Bool {
        guard scalar.string.utf8.count > 18, scalar.string.contains(":") else { return false }
        return Node.scalar(scalar).tag == Tag(.int)
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
