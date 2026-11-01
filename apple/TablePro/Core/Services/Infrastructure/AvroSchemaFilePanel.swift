//
//  AvroSchemaFilePanel.swift
//  TablePro
//

import AppKit

// Every file is enabled, since schemas come as .avsc, .json or no extension at all. The panel's validate hook
// is the gate: a file that is not a schema shows why and leaves the panel open on it.
@MainActor
internal enum AvroSchemaFilePanel {
    static func chooseSchemaText(in window: NSWindow) async -> String? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = []
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose Schema")
        panel.message = String(localized: "Choose the Avro schema the values in this column were written with.")
        let gate = AvroSchemaFileGate()
        panel.delegate = gate
        let response = await panel.presentAsSheet(for: window)
        return withExtendedLifetime(gate) { response == .OK ? gate.text : nil }
    }
}

@MainActor
private final class AvroSchemaFileGate: NSObject, NSOpenSavePanelDelegate {
    private(set) var text: String?

    func panel(_ sender: Any, validate url: URL) throws {
        let name = url.lastPathComponent
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= AvroSchemaStore.maxFileBytes else { throw AvroSchemaFileError(fileName: name, reason: .tooLarge) }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw AvroSchemaFileError(fileName: name, reason: .notText)
        }
        do {
            _ = try AvroSchema.parse(text)
        } catch let error as AvroSchemaError {
            throw AvroSchemaFileError(fileName: name, reason: .invalid(error.reason))
        }
        self.text = text
    }
}

private struct AvroSchemaFileError: LocalizedError {
    enum Reason {
        case tooLarge
        case notText
        case invalid(String)
    }

    let fileName: String
    let reason: Reason

    var errorDescription: String? {
        String(format: String(localized: "“%@” is not a usable Avro schema."), fileName)
    }

    var recoverySuggestion: String? {
        switch reason {
        case .tooLarge:
            return String(localized: "The file is larger than any Avro schema.")
        case .notText:
            return String(localized: "The file is not UTF-8 text.")
        case .invalid(let reason):
            return reason
        }
    }
}
