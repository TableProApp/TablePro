//
//  CodableListPreferenceStore.swift
//  TablePro
//

import Foundation

final class CodableListPreferenceStore<Element: Codable & Identifiable>: @unchecked Sendable {
    private let key: JSONDefaultsKey<[Element]>
    private let store: KeyValueStore

    init(key: JSONDefaultsKey<[Element]>, store: KeyValueStore) {
        self.key = key
        self.store = store
    }

    func load() -> [Element] {
        store.read(key).value ?? []
    }

    func save(_ elements: [Element]) {
        try? store.write(elements, to: key)
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
