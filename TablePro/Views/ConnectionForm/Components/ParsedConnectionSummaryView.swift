//
//  ParsedConnectionSummaryView.swift
//  TablePro
//

import SwiftUI
import TableProPluginKit

struct ParsedConnectionSummaryView: View {
    let parsed: ParsedConnectionURL
    var showsBackground = true

    var body: some View {
        let snapshot = PluginMetadataRegistry.shared.snapshot(forTypeId: parsed.type.rawValue)
        let mode = snapshot?.connectionMode ?? .network

        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(parsed.type.iconName)
                    .resizable()
                    .frame(width: 16, height: 16)
                Text(snapshot?.displayName ?? parsed.type.rawValue)
                    .font(.caption)
                    .fontWeight(.medium)
            }

            switch mode {
            case .fileBased:
                if !parsed.database.isEmpty {
                    ParsedConnectionSummaryRow(label: String(localized: "Path"), value: parsed.database)
                }
            case .apiOnly:
                if !parsed.host.isEmpty {
                    ParsedConnectionSummaryRow(label: String(localized: "Host"), value: parsed.host)
                }
            case .network:
                networkRows
            }
        }
        .padding(showsBackground ? 8 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
    }

    @ViewBuilder
    private var networkRows: some View {
        if let multiHost = parsed.multiHost, multiHost.contains(",") {
            ParsedConnectionSummaryRow(label: String(localized: "Hosts"), value: multiHost)
        } else if !parsed.host.isEmpty {
            let portSuffix = parsed.port.map { ":\($0)" } ?? ""
            ParsedConnectionSummaryRow(label: String(localized: "Host"), value: parsed.host + portSuffix)
        }
        if !parsed.username.isEmpty {
            ParsedConnectionSummaryRow(label: String(localized: "User"), value: parsed.username)
        }
        if !parsed.database.isEmpty {
            ParsedConnectionSummaryRow(label: String(localized: "Database"), value: parsed.database)
        }
        if let service = parsed.oracleServiceName, !service.isEmpty {
            ParsedConnectionSummaryRow(label: String(localized: "Service"), value: service)
        }
        if let sshHost = parsed.sshHost {
            ParsedConnectionSummaryRow(label: "SSH", value: sshHost)
        }
    }

    @ViewBuilder
    private var background: some View {
        if showsBackground {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .controlBackgroundColor))
        }
    }
}

struct ParsedConnectionSummaryRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.caption2)
                .selectionAwareForeground(Color(nsColor: .tertiaryLabelColor), emphasizedOpacity: 0.6)
                .frame(width: 58, alignment: .trailing)
            Text(value)
                .font(.caption)
                .selectionAwareForeground(Color(nsColor: .secondaryLabelColor), emphasizedOpacity: 0.85)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}
