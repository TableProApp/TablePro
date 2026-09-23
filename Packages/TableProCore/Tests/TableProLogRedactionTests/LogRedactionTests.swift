import Foundation
import Testing

@testable import TableProLogRedaction

@Suite("Log redaction shapes")
struct LogRedactionShapeTests {
    private static let serverText =
        "ERROR: duplicate key value violates unique constraint \"users_email_key\" Key (email)=(a@b.com) already exists."

    private enum DriverError: Error {
        case executionFailed(String)
        case disconnected
    }

    private enum DescribedError: Error, CustomStringConvertible {
        case refused

        var description: String { LogRedactionShapeTests.serverText }
    }

    private enum DebugDescribedError: Error, CustomDebugStringConvertible {
        case refused

        var debugDescription: String { LogRedactionShapeTests.serverText }
    }

    private struct BoxedError: Error {
        let serverText: String
    }

    private enum SafeError: PubliclyLoggableError {
        case readOnlyConnection

        var publicLogDescription: String { "the connection is read-only" }
    }

    @Test("An enum case's payload never reaches the public description")
    func enumPayloadIsDropped() {
        #expect(LogRedaction.publicDescription(of: DriverError.executionFailed(Self.serverText)) == "DriverError.executionFailed")
    }

    @Test("A case with no payload keeps its name")
    func payloadlessCaseKeepsItsName() {
        #expect(LogRedaction.publicDescription(of: DriverError.disconnected) == "DriverError.disconnected")
    }

    @Test("A case whose type writes its own description publishes the type alone")
    func customDescriptionIsNotPublished() {
        #expect(LogRedaction.publicDescription(of: DescribedError.refused) == "DescribedError")
        #expect(LogRedaction.publicDescription(of: DebugDescribedError.refused) == "DebugDescribedError")
    }

    @Test("A struct error publishes its type and bridged code, not its stored text")
    func structErrorPublishesItsShape() {
        let shape = LogRedaction.publicDescription(of: BoxedError(serverText: Self.serverText))

        #expect(shape.hasPrefix("BoxedError("))
        #expect(!shape.contains("a@b.com"))
    }

    @Test("A system error keeps the domain and code a reader can act on")
    func systemDomainIsKept() {
        let shape = LogRedaction.publicDescription(of: NSError(domain: NSPOSIXErrorDomain, code: 61))

        #expect(shape == "NSError(\(NSPOSIXErrorDomain), 61)")
    }

    @Test("A constant domain from another framework is published with its code")
    func constantDomainIsKept() {
        #expect(LogRedaction.publicDescription(of: NSError(domain: "CKErrorDomain", code: 3)) == "NSError(CKErrorDomain, 3)")
        #expect(LogRedaction.publicDescription(of: NSError(domain: "com.example.sync-kit", code: 2)) == "NSError(com.example.sync-kit, 2)")
    }

    @Test("A domain built from text is never published, whatever it holds", arguments: [
        serverText,
        "a@b.com",
        "/Users/someone/Library/db.sqlite",
        "Key(email)",
        String(repeating: "a", count: 65),
        ""
    ])
    func textDomainIsDropped(domain: String) {
        #expect(LogRedaction.publicDescription(of: NSError(domain: domain, code: 7)) == "NSError(7)")
    }

    @Test("An error that declares its description safe is published in full")
    func publiclyLoggableErrorIsPublishedInFull() {
        #expect(LogRedaction.publicDescription(of: SafeError.readOnlyConnection) == "the connection is read-only")
    }
}
