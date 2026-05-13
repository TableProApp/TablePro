import SwiftUI
import WidgetKit

struct SmallWidgetView: View {
    let connections: [WidgetConnectionItem]

    var body: some View {
        if let connection = connections.first {
            VStack(alignment: .leading, spacing: 8) {
                DatabaseTypeStyle.iconImage(for: connection.type, size: 20)
                    .foregroundStyle(DatabaseTypeStyle.iconColor(for: connection.type))
                    .frame(width: 36, height: 36)
                    .background(DatabaseTypeStyle.iconColor(for: connection.type).opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                Spacer()

                VStack(alignment: .leading, spacing: 2) {
                    Text(connection.name)
                        .font(.headline)
                        .lineLimit(1)

                    Text(verbatim: "\(connection.host):\(connection.port)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .widgetURL(URL(string: "tablepro://connect/\(connection.id.uuidString)"))
        } else {
            VStack(spacing: 8) {
                Image(systemName: "server.rack")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("Add a connection in TablePro")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
