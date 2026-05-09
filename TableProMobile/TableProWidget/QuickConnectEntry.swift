import WidgetKit

struct QuickConnectEntry: TimelineEntry {
    let date: Date
    let connections: [WidgetConnectionItem]

    static var placeholder: QuickConnectEntry {
        QuickConnectEntry(
            date: .now,
            connections: [
                WidgetConnectionItem(id: UUID(), name: "Production", type: "PostgreSQL", host: "db.example.com", port: 5432, sortOrder: 0),
                WidgetConnectionItem(id: UUID(), name: "Local MySQL", type: "MySQL", host: "localhost", port: 3306, sortOrder: 1),
                WidgetConnectionItem(id: UUID(), name: "Redis Cache", type: "Redis", host: "cache.local", port: 6379, sortOrder: 2),
                WidgetConnectionItem(id: UUID(), name: "Analytics", type: "ClickHouse", host: "ch.example.com", port: 8123, sortOrder: 3)
            ]
        )
    }
}
