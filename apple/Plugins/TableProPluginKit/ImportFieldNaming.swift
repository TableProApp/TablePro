//
//  ImportFieldNaming.swift
//  TableProPluginKit
//

import Foundation

// Literal headers claim their names first, so a placeholder never takes a name a later header spells out.
public enum ImportFieldNaming {
    public static func uniqueNames(for header: [String?], placeholder: (Int) -> String) -> [String] {
        let trimmed = header.map { ($0 ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        var used = Set<String>()
        var names = [String?](repeating: nil, count: trimmed.count)

        for (index, name) in trimmed.enumerated() where !name.isEmpty && used.insert(name).inserted {
            names[index] = name
        }

        // Resuming each base where it last stopped keeps a header of one repeated name linear.
        var nextOrdinal: [String: Int] = [:]
        for index in names.indices where names[index] == nil {
            let base = trimmed[index].isEmpty ? placeholder(index) : trimmed[index]
            var ordinal = nextOrdinal[base, default: 1]
            var unique = ordinal == 1 ? base : "\(base) \(ordinal)"
            while !used.insert(unique).inserted {
                ordinal += 1
                unique = "\(base) \(ordinal)"
            }
            nextOrdinal[base] = ordinal + 1
            names[index] = unique
        }

        return names.map { $0 ?? "" }
    }
}
