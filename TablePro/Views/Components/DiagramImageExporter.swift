//
//  DiagramImageExporter.swift
//  TablePro
//
//  Renders a diagram to a PNG at its natural scale, for the standard Copy command and for
//  Save. Shared by the ER diagram and the query plan diagram so both export identically.
//

import AppKit
import os
import SwiftUI
import UniformTypeIdentifiers

enum DiagramImageExporter {
    private static let logger = Logger(subsystem: "com.TablePro", category: "DiagramImageExporter")
    private static let renderScale: CGFloat = 2.0

    @MainActor
    static func image(of view: some View) -> NSImage? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = renderScale
        return renderer.nsImage
    }

    /// Feeds the standard Edit > Copy command, so a diagram follows whatever shortcut the user
    /// has bound instead of a hardcoded key handler.
    @MainActor
    static func copyItemProviders(of view: some View) -> [NSItemProvider] {
        guard let image = image(of: view) else { return [] }
        return [NSItemProvider(object: image)]
    }

    @MainActor
    static func export(_ view: some View, defaultFileName: String, title: String) {
        guard let image = image(of: view) else {
            logger.error("Failed to render diagram to image")
            presentFailure()
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = defaultFileName
        panel.title = title
        panel.message = String(localized: "Choose a location to save the diagram as PNG.")

        guard let window = AlertHelper.resolveWindow(nil) else { return }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            guard let tiffData = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiffData),
                  let pngData = bitmap.representation(using: .png, properties: [:])
            else {
                AlertHelper.showErrorSheet(
                    title: String(localized: "Could not export the diagram"),
                    message: String(localized: "The diagram could not be converted to a PNG image."),
                    window: window
                )
                return
            }
            do {
                try pngData.write(to: url)
            } catch {
                logger.error("Failed to write PNG: \(error.localizedDescription)")
                AlertHelper.showErrorSheet(
                    title: String(localized: "Could not export the diagram"),
                    message: error.localizedDescription,
                    window: window
                )
            }
        }
    }

    @MainActor
    private static func presentFailure() {
        let alert = NSAlert()
        alert.messageText = String(localized: "Export Failed")
        alert.informativeText = String(localized: "Failed to render the diagram image.")
        alert.alertStyle = .warning
        if let window = AlertHelper.resolveWindow(nil) {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}
