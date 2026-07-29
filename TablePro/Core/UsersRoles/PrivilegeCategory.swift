import Foundation
import TableProPluginKit

struct PrivilegeCategory: Hashable, Identifiable {
    let key: String
    let title: String
    let sortOrder: Int
    let isCollapsedByDefault: Bool

    var id: String { key }

    static let other = PrivilegeCategory(
        key: "other",
        title: String(localized: "Other"),
        sortOrder: 4,
        isCollapsedByDefault: false
    )

    static func resolve(_ key: String?) -> PrivilegeCategory {
        guard let key, !key.isEmpty else { return .other }

        switch key {
        case PluginPrivilegeCategoryKey.data:
            return PrivilegeCategory(
                key: key,
                title: String(localized: "Data"),
                sortOrder: 0,
                isCollapsedByDefault: false
            )
        case PluginPrivilegeCategoryKey.structure:
            return PrivilegeCategory(
                key: key,
                title: String(localized: "Structure"),
                sortOrder: 1,
                isCollapsedByDefault: false
            )
        case PluginPrivilegeCategoryKey.administration:
            return PrivilegeCategory(
                key: key,
                title: String(localized: "Administration"),
                sortOrder: 2,
                isCollapsedByDefault: true
            )
        case PluginPrivilegeCategoryKey.dynamic:
            return PrivilegeCategory(
                key: key,
                title: String(localized: "Dynamic"),
                sortOrder: 3,
                isCollapsedByDefault: true
            )
        default:
            return PrivilegeCategory(
                key: key,
                title: key,
                sortOrder: 5,
                isCollapsedByDefault: true
            )
        }
    }

    static func group(
        _ descriptors: [PluginPrivilegeDescriptor]
    ) -> [(category: PrivilegeCategory, descriptors: [PluginPrivilegeDescriptor])] {
        var order: [PrivilegeCategory] = []
        var buckets: [PrivilegeCategory: [PluginPrivilegeDescriptor]] = [:]

        for descriptor in descriptors {
            let category = resolve(descriptor.category)
            if buckets[category] == nil {
                order.append(category)
            }
            buckets[category, default: []].append(descriptor)
        }

        return order
            .sorted { $0.sortOrder < $1.sortOrder }
            .compactMap { category in
                guard let descriptors = buckets[category] else { return nil }
                return (category, descriptors)
            }
    }
}
