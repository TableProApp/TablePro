//
//  ConnectionEndpointLabel.swift
//  TablePro
//

import SwiftUI

internal struct ConnectionEndpointLabel: View {
    internal let connection: DatabaseConnection

    @ViewBuilder
    internal var body: some View {
        let endpoint = connection.connectionSubtitle
        if !endpoint.isEmpty {
            Text(endpoint)
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}
