import AppKit
import os
import SwiftUI
import UniformTypeIdentifiers

// Save and Copy for the ER and query plan diagrams, so both export the same way.
enum DiagramExporter {
    private static let logger = Logger(subsystem: "com.TablePro", category: "DiagramExporter")
    static let renderScale: CGFloat = 2.0

    @MainActor
    static func image(of view: some View) -> NSImage? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = renderScale
        return renderer.nsImage
    }

    @MainActor
    static func export(_ view: some View, defaultFileName: String, title: String) {
        save(pngData(image(of: view)), contentType: .png, formatName: "PNG", defaultFileName: defaultFileName, title: title)
    }

    static func pngData(_ image: NSImage?) -> Data? {
        // A bitmap the image already holds encodes as it is, without a TIFF copy and a second decode.
        if let rep = image?.representations.first(where: { $0 is NSBitmapImageRep }) as? NSBitmapImageRep {
            return rep.representation(using: .png, properties: [:])
        }
        guard let tiffData = image?.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData)
        else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    // `data` is nil when the diagram could not be rendered in that format.
    @MainActor
    static func save(_ data: Data?, contentType: UTType, formatName: String, defaultFileName: String, title: String) {
        guard let window = AlertHelper.resolveWindow(nil) else { return }
        guard let data else {
            logger.error("Failed to render the diagram as \(formatName, privacy: .public)")
            AlertHelper.showErrorSheet(
                title: String(localized: "Export Failed"),
                message: String(format: String(localized: "The diagram could not be rendered as %@."), formatName),
                window: window
            )
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [contentType]
        panel.nameFieldStringValue = defaultFileName
        panel.title = title
        panel.message = String(format: String(localized: "Choose a location to save the diagram as %@."), formatName)

        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                logger.error("Failed to write the diagram: \(error.localizedDescription)")
                AlertHelper.showErrorSheet(
                    title: String(localized: "Could not export the diagram"),
                    message: error.localizedDescription,
                    window: window
                )
            }
        }
    }
}
