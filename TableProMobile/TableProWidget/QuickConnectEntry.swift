import WidgetKit

struct QuickConnectEntry: TimelineEntry {
    let date: Date
    let connections: [WidgetConnectionItem]

    static var placeholder: QuickConnectEntry {
        QuickConnectEntry(
            date: .now,
            connections: [
                placeholderItem("Production", type: "PostgreSQL", asset: "postgresql-icon", sortOrder: 0),
                placeholderItem("Local MySQL", type: "MySQL", asset: "mysql-icon", sortOrder: 1),
                placeholderItem("Redis Cache", type: "Redis", asset: "redis-icon", sortOrder: 2),
                placeholderItem("Analytics", type: "ClickHouse", asset: "clickhouse-icon", sortOrder: 3)
            ]
        )
    }

    private static func placeholderItem(_ name: String, type: String, asset: String, sortOrder: Int) -> WidgetConnectionItem {
        WidgetConnectionItem(
            id: UUID(),
            name: name,
            type: type,
            sortOrder: sortOrder,
            glyph: ConnectionGlyph(source: .asset, name: asset)
        )
    }
}
