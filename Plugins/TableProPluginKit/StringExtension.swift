import Foundation

public extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
