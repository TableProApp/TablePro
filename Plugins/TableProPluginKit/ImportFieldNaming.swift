//
//  ImportFieldNaming.swift
//  TableProPluginKit
//

import Foundation

/// Headers the file spells out keep their names first; blanks and repeats are named afterwards, so a
/// placeholder can never take a name a later header spells literally.
public enum ImportFieldNaming {
    public static func uniqueNames(for header: [String?], placeholder: (Int) -> String) -> [String] {
        let trimmed = header.map { ($0 ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        var used = Set<String>()
        var names = [String?](repeating: nil, count: trimmed.count)

        for (index, name) in trimmed.enumerated() where !name.isEmpty && used.insert(name).inserted {
            names[index] = name
        }

        for index in names.indices where names[index] == nil {
            let base = trimmed[index].isEmpty ? placeholder(index) : trimmed[index]
            var unique = base
            var suffix = 2
            while !used.insert(unique).inserted {
                unique = "\(base) \(suffix)"
                suffix += 1
            }
            names[index] = unique
        }

        return names.map { $0 ?? "" }
    }
}
