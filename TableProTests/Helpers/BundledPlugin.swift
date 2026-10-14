//
//  BundledPlugin.swift
//  TableProTests
//

import Foundation
import TableProPluginKit

// The unit host never loads plugins, so a test that reads what a bundled plugin declares loads it here.
internal enum BundledPlugin {
    internal enum LoadError: Error {
        case notEmbedded(String)
        case notADriver(String)
    }

    internal static func driver(_ name: String) throws -> any DriverPlugin.Type {
        guard let plugIns = Bundle.main.builtInPlugInsURL,
              let bundle = Bundle(url: plugIns.appendingPathComponent("\(name).tableplugin")) else {
            throw LoadError.notEmbedded(name)
        }
        guard let driver = bundle.principalClass as? any DriverPlugin.Type else {
            throw LoadError.notADriver(name)
        }
        return driver
    }
}
