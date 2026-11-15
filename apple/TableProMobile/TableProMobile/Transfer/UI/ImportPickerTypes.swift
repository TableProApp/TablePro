import Foundation
import TableProPluginKit
import UniformTypeIdentifiers

// What the file picker dims and lights. Not the gate: the picked file's extension decides the format again.
nonisolated enum ImportPickerTypes {
    static func contentTypes(for plugins: [any ImportFormatPlugin]) -> [UTType] {
        var seen = Set<String>()
        var types: [UTType] = []
        for plugin in plugins {
            for fileExtension in type(of: plugin).acceptedFileExtensions {
                guard let type = UTType(filenameExtension: fileExtension.lowercased()),
                      seen.insert(type.identifier).inserted else { continue }
                types.append(type)
            }
        }
        return types
    }
}
