import SwiftUI
import WidgetKit

struct QuickConnectEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: QuickConnectEntry

    var body: some View {
        switch family {
        case .systemSmall:
            SmallWidgetView(connections: entry.connections)
        case .systemMedium:
            MediumWidgetView(connections: entry.connections)
        default:
            SmallWidgetView(connections: entry.connections)
        }
    }
}
