//
//  CodableListPreferenceStore.swift
//  TablePro
//

import Foundation
import os

final class CodableListPreferenceStore<Element: Codable & Identifiable>: @unchecked Sendable {
    private static var logger: Logger {
        Logger(subsystem: "com.TablePro", category: "CodableListPreferenceStore")
    }

    private let key: DefaultsKey<[Element]>
    private let store: KeyValueStore

    init(key: DefaultsKey<[Element]>, store: KeyValueStore) {
        self.key = key
        self.store = store
    }

    func load() -> [Element] {
        guard let data = store.dataValue(forKey: key.name) else { return [] }
        do {
            return try JSONDecoder().decode([Element].self, from: data)
        } catch {
            Self.logger.error("Failed to decode \(self.key.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    func save(_ elements: [Element]) {
        do {
            let data = try JSONEncoder().encode(elements)
            store.setDataValue(data, forKey: key.name)
        } catch {
            Self.logger.error("Failed to encode \(self.key.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    func add(_ element: Element) {
        var elements = load()
        elements.append(element)
        save(elements)
    }

    func remove(id: Element.ID) {
        var elements = load()
        elements.removeAll { $0.id == id }
        save(elements)
    }

    func update(_ element: Element) {
        var elements = load()
        guard let index = elements.firstIndex(where: { $0.id == element.id }) else { return }
        elements[index] = element
        save(elements)
    }
}
