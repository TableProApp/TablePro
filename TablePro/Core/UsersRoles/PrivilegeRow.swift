import Foundation
import TableProPluginKit

struct PrivilegeRow: Identifiable, Hashable {
    enum Kind: Hashable {
        case category(PrivilegeCategory)
        case privilege(PluginPrivilegeDescriptor)
    }

    let kind: Kind

    var id: String {
        switch kind {
        case let .category(category): "category:\(category.key)"
        case let .privilege(descriptor): "privilege:\(descriptor.name)"
        }
    }

    var title: String {
        switch kind {
        case let .category(category): category.title
        case let .privilege(descriptor): descriptor.label
        }
    }

    var descriptor: PluginPrivilegeDescriptor? {
        guard case let .privilege(descriptor) = kind else { return nil }
        return descriptor
    }

    var category: PrivilegeCategory? {
        guard case let .category(category) = kind else { return nil }
        return category
    }
}

struct PrivilegeSection: Identifiable {
    let category: PrivilegeCategory
    let headerRow: PrivilegeRow
    let rows: [PrivilegeRow]

    var id: String { category.key }

    init(category: PrivilegeCategory, descriptors: [PluginPrivilegeDescriptor]) {
        self.category = category
        headerRow = PrivilegeRow(kind: .category(category))
        rows = descriptors.map { PrivilegeRow(kind: .privilege($0)) }
    }
}
