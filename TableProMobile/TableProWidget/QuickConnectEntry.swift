import WidgetKit

struct QuickConnectEntry: TimelineEntry {
    let date: Date
    let connections: [WidgetConnectionItem]

    static var placeholder: QuickConnectEntry {
        QuickConnectEntry(
            date: .now,
            connections: [
                WidgetConnectionItem(id: UUID(), name: "Production", type: "PostgreSQL", sortOrder: 0),
                WidgetConnectionItem(id: UUID(), name: "Local MySQL", type: "MySQL", sortOrder: 1),
                WidgetConnectionItem(id: UUID(), name: "Redis Cache", type: "Redis", sortOrder: 2),
                WidgetConnectionItem(id: UUID(), name: "Analytics", type: "ClickHouse", sortOrder: 3)
            ]
        )
    }
}
