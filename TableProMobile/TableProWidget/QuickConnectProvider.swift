import WidgetKit

struct QuickConnectProvider: TimelineProvider {
    func placeholder(in context: Context) -> QuickConnectEntry {
        .placeholder
    }

    func getSnapshot(in context: Context, completion: @escaping (QuickConnectEntry) -> Void) {
        if context.isPreview {
            completion(.placeholder)
            return
        }
        let connections = SharedConnectionStore.read()
            .sorted { $0.sortOrder < $1.sortOrder }
        completion(QuickConnectEntry(date: .now, connections: connections))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<QuickConnectEntry>) -> Void) {
        let connections = SharedConnectionStore.read()
            .sorted { $0.sortOrder < $1.sortOrder }
        let entry = QuickConnectEntry(date: .now, connections: connections)
        completion(Timeline(entries: [entry], policy: .never))
    }
}
