//
//  MediumWidgetView.swift
//  TableProWidget
//

import SwiftUI

struct MediumWidgetView: View {
    let connections: [WidgetConnectionItem]

    private var displayedConnections: [WidgetConnectionItem] {
        Array(connections.prefix(4))
    }

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8)
    ]

    var body: some View {
        if connections.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "server.rack")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("Add a connection in TablePro")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(displayedConnections) { connection in
                    if let url = URL(string: "tablepro://connect/\(connection.id.uuidString)") {
                        Link(destination: url) {
                            HStack(spacing: 8) {
                                DatabaseTypeStyle.iconImage(for: connection.type, size: 14)
                                    .foregroundStyle(DatabaseTypeStyle.iconColor(for: connection.type))
                                    .frame(width: 28, height: 28)
                                    .background(DatabaseTypeStyle.iconColor(for: connection.type).opacity(0.15))
                                    .clipShape(RoundedRectangle(cornerRadius: 6))

                                Text(connection.name)
                                    .font(.caption)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)

                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(.fill.quaternary)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }
        }
    }
}
