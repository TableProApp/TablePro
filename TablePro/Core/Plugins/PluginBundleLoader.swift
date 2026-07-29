//
//  PluginBundleLoader.swift
//  TablePro
//

import Foundation
import os

enum PluginBundleLoader {
    private static let logger = Logger(subsystem: "com.TablePro", category: "PluginBundleLoader")

    static func load(_ bundle: Bundle) throws {
        do {
            try bundle.loadAndReturnError()
        } catch {
            let nsError = error as NSError
            let reason = describeLoadFailure(nsError)
            let detail = nsError.userInfo[NSDebugDescriptionErrorKey] as? String ?? nsError.localizedDescription
            logger.error(
                "Bundle load failed for \(bundle.bundleURL.lastPathComponent, privacy: .public) [\(nsError.domain, privacy: .public) \(nsError.code, privacy: .public)]: \(reason, privacy: .public) [\(detail, privacy: .public)]"
            )
            throw PluginError.invalidBundle(reason)
        }
    }

    static func describeLoadFailure(_ error: NSError) -> String {
        switch error.code {
        case NSFileNoSuchFileError:
            return String(localized: "The plugin's executable file is missing.")
        case NSExecutableNotLoadableError:
            return String(localized: "The plugin's executable couldn't be loaded. It may be damaged or improperly signed.")
        case NSExecutableArchitectureMismatchError:
            return String(localized: "The plugin doesn't include a build for this Mac's processor architecture.")
        case NSExecutableRuntimeMismatchError:
            return String(localized: "The plugin was built for an incompatible runtime.")
        case NSExecutableLoadError:
            return String(localized: "The plugin depends on a component that's missing or incompatible with this Mac.")
        case NSExecutableLinkError:
            return String(localized: "The plugin isn't compatible with this version of TablePro. Update the app or reinstall the plugin.")
        default:
            return error.localizedFailureReason ?? error.localizedDescription
        }
    }
}
