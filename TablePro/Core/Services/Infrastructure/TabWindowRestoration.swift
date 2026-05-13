//
//  TabWindowRestoration.swift
//  TablePro
//

import AppKit
import os

@MainActor
final class TabWindowRestoration: NSObject, NSWindowRestoration {
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "WindowRestoration")
    nonisolated static let connectionIdKey = "TablePro.connectionId"

    nonisolated static func restoreWindow(
        withIdentifier identifier: NSUserInterfaceItemIdentifier,
        state: NSCoder,
        completionHandler: @escaping (NSWindow?, Error?) -> Void
    ) {
        let uuidString = state.decodeObject(of: NSString.self, forKey: connectionIdKey) as String?

        Task { @MainActor in
            guard let uuidString,
                  let connectionId = UUID(uuidString: uuidString) else {
                logger.warning("[restore] Missing or invalid connectionId in state")
                completionHandler(nil, restorationError(.missingConnectionId))
                return
            }

            let connections = ConnectionStorage.shared.loadConnections()
            guard let connection = connections.first(where: { $0.id == connectionId }) else {
                logger.warning("[restore] Connection \(uuidString, privacy: .public) no longer exists")
                completionHandler(nil, restorationError(.connectionNotFound))
                return
            }

            let payload = EditorTabPayload(connectionId: connection.id, intent: .restoreOrDefault)
            WindowManager.shared.openTab(payload: payload)

            let restored = NSApp.windows.first { candidate in
                guard candidate.isVisible,
                      let controller = candidate.windowController as? TabWindowController
                else { return false }
                return controller.payload.connectionId == connection.id
            }

            if let restored {
                logger.info(
                    "[restore] connId=\(connection.id, privacy: .public) name=\(connection.name, privacy: .public)"
                )
                completionHandler(restored, nil)

                Task {
                    do {
                        try await DatabaseManager.shared.ensureConnected(connection)
                    } catch {
                        logger.error(
                            "[restore] connect failed for \(connection.id, privacy: .public): \(error.localizedDescription, privacy: .public)"
                        )
                    }
                }
            } else {
                logger.error("[restore] WindowManager opened tab but no window found")
                completionHandler(nil, restorationError(.windowNotCreated))
            }
        }
    }

    private enum RestorationFailure: Int {
        case missingConnectionId = 1
        case connectionNotFound = 2
        case windowNotCreated = 3
    }

    nonisolated private static func restorationError(_ failure: RestorationFailure) -> NSError {
        NSError(
            domain: "com.TablePro.WindowRestoration",
            code: failure.rawValue,
            userInfo: [NSLocalizedDescriptionKey: "Window restoration failed (\(failure))"]
        )
    }
}
