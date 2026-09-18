import Foundation

/// What a partition row and a partitioned table's row say, kept out of the views so the sidebar,
/// its accessibility label and the tests all read one rule.
internal enum SidebarPartitionRow {
    internal static let iconName = "rectangle.split.3x1.fill"

    internal static var kindLabel: String { String(localized: "Partition") }

    /// The count a collapsed partitioned table shows. A table the engine says nothing about shows
    /// nothing, which is not the same as a partitioned table that holds none: that one says zero.
    internal static func countLabel(partitionCount: Int?) -> String? {
        guard let partitionCount else { return nil }
        return String(partitionCount)
    }

    /// The caption beside a partition's name. A bound is the useful half of a partition's identity
    /// and comes first; an engine that states no bound falls back to the position, which is the
    /// only thing ordering its partitions.
    internal static func caption(bound: String?, ordinalPosition: Int?) -> String? {
        if let bound = bound?.trimmingCharacters(in: .whitespacesAndNewlines), !bound.isEmpty {
            return bound
        }
        guard let ordinalPosition else { return nil }
        return String(format: String(localized: "Partition %d"), ordinalPosition)
    }

    internal static func accessibilityLabel(name: String, bound: String?, ordinalPosition: Int?) -> String {
        let base = String(format: String(localized: "%@: %@"), kindLabel, name)
        guard let caption = caption(bound: bound, ordinalPosition: ordinalPosition) else { return base }
        return base + ", " + caption
    }

    internal static func tableAccessibilitySuffix(partitionCount: Int?) -> String? {
        guard let partitionCount else { return nil }
        return String(
            format: String(localized: "%lld partitions"),
            Int64(partitionCount)
        )
    }
}
