import Foundation

enum SettingsDraftResolution<Value: Equatable>: Equatable {
    case accept(Value)
    case revert
    case reject(String)
}

// Storage sees a value only through commit: typing never writes, and an untouched draft never overwrites a remote change.
struct SettingsTextDraft: Equatable, Sendable {
    var text: String
    private(set) var seed: String
    private(set) var error: String?

    init(_ seed: String) {
        text = seed
        self.seed = seed
    }

    var isEdited: Bool { text != seed }

    mutating func revert() {
        text = seed
        error = nil
    }

    mutating func resync(to value: String) {
        if text == seed {
            text = value
            error = nil
        }
        seed = value
    }

    mutating func settle(to value: String) {
        text = value
        seed = value
        error = nil
    }

    mutating func commit<Value: Equatable>(
        to current: Value,
        resolve: (String) -> SettingsDraftResolution<Value>
    ) -> Value? {
        guard isEdited else {
            error = nil
            return nil
        }
        switch resolve(text) {
        case .accept(let value):
            error = nil
            return value == current ? nil : value
        case .revert:
            revert()
            return nil
        case .reject(let message):
            error = message
            return nil
        }
    }

    mutating func clearError<Value: Equatable>(ifResolvedBy resolve: (String) -> SettingsDraftResolution<Value>) {
        guard error != nil else { return }
        if case .accept = resolve(text) {
            error = nil
        }
    }
}
