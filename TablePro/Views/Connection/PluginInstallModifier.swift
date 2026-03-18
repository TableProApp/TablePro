//
//  PluginInstallModifier.swift
//  TablePro
//

import os
import SwiftUI

struct PluginInstallModifier: ViewModifier {
    private static let logger = Logger(subsystem: "com.TablePro", category: "PluginInstallModifier")

    @Binding var connection: DatabaseConnection?
    @State private var installFailed: String?
    var onInstalled: (DatabaseConnection) -> Void

    func body(content: Content) -> some View {
        content
            .alert(
                String(localized: "Plugin Not Installed"),
                isPresented: Binding(
                    get: { connection != nil },
                    set: { if !$0 { connection = nil } }
                )
            ) {
                Button(String(localized: "Install")) {
                    if let conn = connection {
                        connection = nil
                        install(conn)
                    }
                }
                Button(String(localized: "Cancel"), role: .cancel) {
                    connection = nil
                }
            } message: {
                if let conn = connection {
                    Text(String(localized: "The \(conn.type.rawValue) plugin is not installed. Would you like to download it from the plugin marketplace?"))
                }
            }
            .alert(
                String(localized: "Plugin Installation Failed"),
                isPresented: Binding(
                    get: { installFailed != nil },
                    set: { if !$0 { installFailed = nil } }
                )
            ) {
                Button("OK", role: .cancel) {
                    installFailed = nil
                }
            } message: {
                if let message = installFailed {
                    Text(message)
                }
            }
    }

    private func install(_ conn: DatabaseConnection) {
        Task {
            do {
                try await PluginManager.shared.installMissingPlugin(for: conn.type) { _ in }
                Self.logger.info("Installed plugin for \(conn.type.rawValue), retrying connection")
                onInstalled(conn)
            } catch {
                installFailed = error.localizedDescription
            }
        }
    }
}

extension View {
    func pluginInstallPrompt(
        connection: Binding<DatabaseConnection?>,
        onInstalled: @escaping (DatabaseConnection) -> Void
    ) -> some View {
        modifier(PluginInstallModifier(connection: connection, onInstalled: onInstalled))
    }
}
