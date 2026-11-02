#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import Foundation

// Launch Services opens a file: path, an smb: share or any app's scheme as readily as a web page,
// so a URL a server or a plugin names is opened only when it is one.
public enum WebPageOpener {
    public enum Scope: Sendable {
        case https
        case httpsOrLoopbackHTTP
    }

    public static func page(_ value: String, scope: Scope) -> URL? {
        guard let url = URL(string: value), let origin = HTTPOrigin(url) else { return nil }
        switch scope {
        case .https:
            return origin.scheme == "https" ? url : nil
        case .httpsOrLoopbackHTTP:
            return origin.scheme == "https" || origin.isLoopback ? url : nil
        }
    }

    @MainActor
    @discardableResult
    public static func open(_ url: URL, scope: Scope) -> Bool {
        guard let page = page(url.absoluteString, scope: scope) else { return false }
        #if canImport(AppKit)
        return NSWorkspace.shared.open(page)
        #elseif canImport(UIKit)
        UIApplication.shared.open(page)
        return true
        #else
        return false
        #endif
    }
}
