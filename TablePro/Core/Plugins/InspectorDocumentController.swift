//
//  InspectorDocumentController.swift
//  TablePro
//

import AppKit
import os
import TableProPluginKit

@MainActor
final class InspectorDocumentController: NSDocumentController {
    private static let logger = Logger(subsystem: "com.TablePro", category: "CSVInspector")

    override init() {
        super.init()
        InspectorWindowFactory.make = { nsDocument in
            guard let inspector = nsDocument as? any InspectorDocument else {
                Self.logger.error("InspectorWindowFactory - document is not an InspectorDocument (\(String(describing: Swift.type(of: nsDocument)), privacy: .public))")
                return nil
            }
            return InspectorWindowController(nsDocument: nsDocument, inspectorDocument: inspector)
        }
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func documentClass(forType typeName: String) -> AnyClass? {
        if let inspector = PluginManager.shared.inspectorPlugin(forUTI: typeName) {
            return Swift.type(of: inspector).documentClass
        }
        return super.documentClass(forType: typeName)
    }

    override func typeForContents(of url: URL) throws -> String {
        let ext = url.pathExtension.lowercased()
        if PluginManager.shared.allInspectorFileExtensions.contains(ext),
           let plugin = PluginManager.shared.inspectorPlugin(forFileExtension: ext),
           let uti = Swift.type(of: plugin).supportedUTIs.first {
            return uti
        }
        return try super.typeForContents(of: url)
    }
}
