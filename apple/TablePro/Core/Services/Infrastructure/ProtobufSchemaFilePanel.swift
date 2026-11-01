//
//  ProtobufSchemaFilePanel.swift
//  TablePro
//

import AppKit

internal struct ProtobufSchemaChoice {
    let contents: Data
    let message: String
}

// Any extension: a descriptor set has none of its own, so the validate hook refuses a file that is not a schema.
@MainActor
internal enum ProtobufSchemaFilePanel {
    static func chooseSchema(in window: NSWindow) async -> ProtobufSchemaChoice? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = []
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose Schema")
        panel.message = String(localized: "Choose the .proto file or descriptor set the values in this column were written with.")
        let gate = ProtobufSchemaFileGate()
        panel.delegate = gate
        let response = await panel.presentAsSheet(for: window)
        guard response == .OK, let contents = gate.contents, let schema = gate.schema else { return nil }
        guard let message = await chooseMessage(in: schema, window: window) else { return nil }
        return ProtobufSchemaChoice(contents: contents, message: message)
    }

    private static func chooseMessage(in schema: ProtobufSchema, window: NSWindow) async -> String? {
        let names = schema.messageNames
        guard names.count > 1 else { return names.first }
        let alert = NSAlert()
        alert.messageText = String(localized: "Which message are the values?")
        alert.informativeText = String(localized: "The file defines more than one message. Choose the one this column holds.")
        let popUp = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 26), pullsDown: false)
        popUp.addItems(withTitles: names)
        if let first = schema.rootMessages.first { popUp.selectItem(withTitle: first) }
        alert.accessoryView = popUp
        alert.addButton(withTitle: String(localized: "Choose"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        let response = await alert.beginSheetModal(for: window)
        return response == .alertFirstButtonReturn ? popUp.titleOfSelectedItem : nil
    }
}

@MainActor
private final class ProtobufSchemaFileGate: NSObject, NSOpenSavePanelDelegate {
    private(set) var contents: Data?
    private(set) var schema: ProtobufSchema?

    func panel(_ sender: Any, validate url: URL) throws {
        let name = url.lastPathComponent
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= ProtobufSchemaStore.maxFileBytes, let data = try? Data(contentsOf: url) else {
            throw ProtobufSchemaFileError(fileName: name, reason: String(localized: "The file is larger than any schema."))
        }
        do {
            schema = try ProtobufSchema.parse(data)
        } catch {
            throw ProtobufSchemaFileError(fileName: name, reason: ((error as? ProtobufSchemaError) ?? .notASchema).reason)
        }
        contents = data
    }
}

private struct ProtobufSchemaFileError: LocalizedError {
    let fileName: String
    let reason: String

    var errorDescription: String? {
        String(format: String(localized: "“%@” is not a usable Protobuf schema."), fileName)
    }

    var recoverySuggestion: String? {
        reason
    }
}
