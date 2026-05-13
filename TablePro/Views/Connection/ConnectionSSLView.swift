//
//  ConnectionSSLView.swift
//  TablePro
//
//  Created by Ngo Quoc Dat on 31/3/26.
//

import SwiftUI
import TableProPluginKit
import UniformTypeIdentifiers

struct ConnectionSSLView: View {
    let databaseType: DatabaseType
    @Binding var sslMode: SSLMode
    @Binding var sslCaCertPath: String
    @Binding var sslClientCertPath: String
    @Binding var sslClientKeyPath: String

    private var supportsPerConnectionCertPaths: Bool { databaseType != .mssql }

    var body: some View {
        Form {
            Section {
                Picker(String(localized: "SSL Mode"), selection: $sslMode) {
                    ForEach(SSLMode.allCases) { mode in
                        Text(mode.displayLabel).tag(mode)
                    }
                }
            } footer: {
                if sslMode != .disabled {
                    Text(sslMode.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if sslMode != .disabled {
                if !supportsPerConnectionCertPaths {
                    Section {
                        Text(String(localized: """
                            SQL Server connections use the system trust store. Per-connection CA and client certificate \
                            paths are not supported by FreeTDS dblib; configure them in `freetds.conf` if you need a \
                            custom trust anchor.
                            """))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } header: {
                        Text(String(localized: "Certificate Trust"))
                    }
                } else if sslMode == .verifyCa || sslMode == .verifyIdentity {
                    Section(String(localized: "CA Certificate")) {
                        LabeledContent(String(localized: "Certificate")) {
                            HStack {
                                TextField(
                                    "", text: $sslCaCertPath, prompt: Text("/path/to/ca-cert.pem"))
                                Button(String(localized: "Browse")) {
                                    browseForCertificate(binding: $sslCaCertPath)
                                }
                                .controlSize(.small)
                            }
                        }
                    }
                }

                if supportsPerConnectionCertPaths {
                    Section {
                        LabeledContent(String(localized: "Client Certificate")) {
                            HStack {
                                TextField(
                                    "", text: $sslClientCertPath,
                                    prompt: Text(String(localized: "Optional")))
                                Button(String(localized: "Browse")) {
                                    browseForCertificate(binding: $sslClientCertPath)
                                }
                                .controlSize(.small)
                            }
                        }
                        LabeledContent(String(localized: "Client Key")) {
                            HStack {
                                TextField(
                                    "", text: $sslClientKeyPath,
                                    prompt: Text(String(localized: "Optional")))
                                Button(String(localized: "Browse")) {
                                    browseForCertificate(binding: $sslClientKeyPath)
                                }
                                .controlSize(.small)
                            }
                        }
                    } header: {
                        Text(String(localized: "Client Certificates"))
                    } footer: {
                        Text(String(localized: "Required only when the server enforces mutual TLS authentication."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private func browseForCertificate(binding: Binding<String>) {
        guard let window = NSApp.keyWindow else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.data]
        panel.showsHiddenFiles = true
        panel.message = String(localized: "Choose a certificate or key file")

        panel.beginSheetModal(for: window) { response in
            if response == .OK, let url = panel.url {
                binding.wrappedValue = url.path(percentEncoded: false)
            }
        }
    }
}
