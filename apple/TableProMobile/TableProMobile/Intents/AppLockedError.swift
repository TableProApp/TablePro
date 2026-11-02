import Foundation

nonisolated struct AppLockedError: Error, CustomLocalizedStringResourceConvertible {
    var localizedStringResource: LocalizedStringResource {
        "TablePro is locked. Open TablePro and unlock it, then try again."
    }
}
