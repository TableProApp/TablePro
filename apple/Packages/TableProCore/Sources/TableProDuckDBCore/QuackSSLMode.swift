import Foundation

/// The SSL Mode a remote DuckDB connection stores in its own field.
///
/// Not the shared SSL Mode: that one is keyed to the built-in Host, which DuckDB never dials, and every
/// connection saved before this field existed stores Disabled while Quack reaches any host but a local
/// one over HTTPS. These are the outcomes quack and httpfs can give a client, and nothing more: there is
/// no client certificate and no CA check without the host name check.
public enum QuackSSLMode: String, CaseIterable, Sendable {
    case automatic
    case disabled
    case required
    case verifyIdentity
    case verifyFingerprint

    /// A connection saved before the field existed has no value, and Automatic is what it did then.
    public init(fieldValue: String?) {
        self = fieldValue.flatMap { Self(rawValue: $0) } ?? .automatic
    }
}
