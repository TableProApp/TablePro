//
//  TransferDialogStorage.swift
//  TablePro
//

import Foundation

final class TransferDialogStorage {
    static let shared = TransferDialogStorage()

    private let defaults: UserDefaults

    private enum Keys {
        static let lastExportFormatId = "com.TablePro.export.dialog.lastFormatId"
        static let lastImportEncoding = "com.TablePro.import.dialog.lastEncoding"
    }

    init(userDefaults: UserDefaults = .standard) {
        self.defaults = userDefaults
    }

    func loadLastExportFormatId() -> String? {
        defaults.string(forKey: Keys.lastExportFormatId)
    }

    func saveLastExportFormatId(_ formatId: String) {
        defaults.set(formatId, forKey: Keys.lastExportFormatId)
    }

    func loadLastImportEncoding() -> ImportEncoding {
        guard let rawValue = defaults.string(forKey: Keys.lastImportEncoding),
              let encoding = ImportEncoding(rawValue: rawValue) else {
            return .utf8
        }
        return encoding
    }

    func saveLastImportEncoding(_ encoding: ImportEncoding) {
        defaults.set(encoding.rawValue, forKey: Keys.lastImportEncoding)
    }
}
