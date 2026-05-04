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
                    Text(String(format: String(localized: "The %@ plugin is not installed. Would you like to download it from the plugin marketplace?"), conn.type.rawValue))
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

    func pluginInstallPromptForType(
        type: Binding<DatabaseType?>,
        onInstalled: @escaping (DatabaseType) -> Void
    ) -> some View {
        modifier(PluginInstallTypeModifier(type: type, onInstalled: onInstalled))
    }
}

struct PluginInstallTypeModifier: ViewModifier {
    private static let logger = Logger(subsystem: "com.TablePro", category: "PluginInstallTypeModifier")

    @Binding var type: DatabaseType?
    @State private var installFailed: String?
    var onInstalled: (DatabaseType) -> Void

    func body(content: Content) -> some View {
        content
            .alert(
                String(localized: "Plugin Not Installed"),
                isPresented: Binding(
                    get: { type != nil },
                    set: { if !$0 { type = nil } }
                )
            ) {
                Button(String(localized: "Install")) {
                    if let t = type {
                        type = nil
                        install(t)
                    }
                }
                Button(String(localized: "Cancel"), role: .cancel) {
                    type = nil
                }
            } message: {
                if let t = type {
                    Text(String(format: String(localized: "The %@ plugin is not installed. Would you like to download it from the plugin marketplace?"), t.rawValue))
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

    private func install(_ t: DatabaseType) {
        Task {
            do {
                try await PluginManager.shared.installMissingPlugin(for: t) { _ in }
                Self.logger.info("Installed plugin for \(t.rawValue), opening connection form")
                onInstalled(t)
            } catch {
                installFailed = error.localizedDescription
            }
        }
    }
}
