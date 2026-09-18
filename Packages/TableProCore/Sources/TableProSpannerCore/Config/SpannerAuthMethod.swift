import Foundation

public enum SpannerAuthMethod: String, Sendable, CaseIterable {
    case serviceAccount
    case applicationDefault = "adc"
    case oauth
    case emulator
}
