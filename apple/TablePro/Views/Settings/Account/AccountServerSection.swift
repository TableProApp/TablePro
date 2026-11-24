//
//  AccountServerSection.swift
//  TablePro
//

import SwiftUI

// A company server's host, whether the organization manages the choice, and the license installed on it
// (core/docs/decisions/0044-sync-through-one-service-run-by-us-or-on-premises.md, App configuration).
internal struct AccountServerSection: View {
    @ObservedObject var model: AccountSettingsModel
    let content: AccountSettingsContent

    var body: some View {
        if !content.server.isProduction || content.server.isManaged {
            Section {
                LabeledContent {
                    Text(verbatim: content.server.host)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(content.server.apiOrigin.absoluteString)
                        .accessibilityIdentifier("account-server-host")
                } label: {
                    Text("Server")
                    if content.server.isManaged {
                        Text("Managed by your organization")
                            .accessibilityIdentifier("account-server-managed")
                    }
                }

                if let license = content.serverLicense {
                    AccountServerLicenseRow(license: license)
                }
            }
        }
    }
}

private struct AccountServerLicenseRow: View {
    let license: AccountServerLicense

    var body: some View {
        LabeledContent {
            if license.isInGrace {
                NoticeLabel(status)
                    .lineLimit(2)
            } else {
                Text(status)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } label: {
            Text(license.isTrial ? String(localized: "Evaluation license") : String(localized: "License"))
            Text(seats)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("account-server-license")
    }

    private var seats: String {
        license.seats == 1
            ? String(localized: "1 seat")
            : String(format: String(localized: "%d seats"), license.seats)
    }

    private var status: String {
        guard let expiresAt = license.expiresAt else { return String(localized: "No end date") }
        let date = expiresAt.formatted(date: .abbreviated, time: .omitted)
        return license.isInGrace
            ? String(format: String(localized: "Expired on %@. Ask your administrator to renew it."), date)
            : String(format: String(localized: "Valid until %@"), date)
    }
}
