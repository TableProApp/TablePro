import SwiftUI
import WidgetKit

struct QuickConnectWidget: Widget {
    let kind = "com.TablePro.QuickConnect"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: QuickConnectProvider()) { entry in
            QuickConnectEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Quick Connect")
        .description("Quickly connect to your databases.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct TableProWidgetBundle: WidgetBundle {
    var body: some Widget {
        QuickConnectWidget()
        QueryLiveActivityWidget()
    }
}
