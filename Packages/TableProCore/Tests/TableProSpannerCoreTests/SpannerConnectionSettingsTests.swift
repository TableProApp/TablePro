import Foundation
import Testing

@testable import TableProSpannerCore

@Suite("SpannerConnectionSettings")
struct SpannerConnectionSettingsTests {
    private typealias Key = SpannerConnectionSettings.FieldKey

    private func fields(
        project: String = "proj",
        instance: String = "inst",
        database: String = "gdb",
        endpoint: String? = nil,
        method: String? = nil
    ) -> [String: String] {
        var fields = [Key.projectId: project, Key.instanceId: instance, Key.databaseId: database]
        fields[Key.endpoint] = endpoint
        fields[Key.authMethod] = method
        return fields
    }

    @Test("Defaults to the service account method and the production endpoint")
    func defaults() throws {
        let settings = try SpannerConnectionSettings.parse(fields: fields())
        #expect(settings.authMethod == .serviceAccount)
        #expect(settings.endpoint == SpannerConnectionSettings.productionEndpoint)
        #expect(settings.endpoint.absoluteString == "https://spanner.googleapis.com")
        #expect(settings.databasePath == "projects/proj/instances/inst/databases/gdb")
    }

    @Test("Identifiers are trimmed")
    func trimsIdentifiers() throws {
        let settings = try SpannerConnectionSettings.parse(fields: fields(project: "  proj \n", database: "\tgdb "))
        #expect(settings.projectId == "proj")
        #expect(settings.databaseId == "gdb")
    }

    @Test("Domain-scoped project ids with a colon and dots are accepted")
    func domainScopedProject() throws {
        let settings = try SpannerConnectionSettings.parse(fields: fields(project: "example.com:my-project_1"))
        #expect(settings.projectId == "example.com:my-project_1")
    }

    @Test("Every auth method raw value parses", arguments: SpannerAuthMethod.allCases)
    func authMethods(method: SpannerAuthMethod) throws {
        let endpoint = method == .emulator ? "http://localhost:9020" : nil
        let settings = try SpannerConnectionSettings.parse(fields: fields(endpoint: endpoint, method: method.rawValue))
        #expect(settings.authMethod == method)
    }

    @Test("The adc raw value names application default credentials")
    func adcRawValue() throws {
        let settings = try SpannerConnectionSettings.parse(fields: fields(method: "adc"))
        #expect(settings.authMethod == .applicationDefault)
    }

    @Test("An unknown auth method is rejected")
    func unknownMethod() {
        #expect(throws: SpannerConfigurationError.unknownAuthMethod("kerberos")) {
            try SpannerConnectionSettings.parse(fields: fields(method: "kerberos"))
        }
    }

    @Test("Missing identifiers name their field", arguments: [Key.projectId, Key.instanceId, Key.databaseId])
    func missingIdentifier(key: String) {
        var values = fields()
        values[key] = "   "
        #expect(throws: SpannerConfigurationError.missingField(key)) {
            try SpannerConnectionSettings.parse(fields: values)
        }
    }

    @Test(
        "Identifiers that could escape their path segment are rejected",
        arguments: ["a/b", "..", "a..b", "db?x=1", "db#frag", "-lead", ".lead", "a b", "db%2F", "ü", "a\\b"]
    )
    func rejectsUnsafeIdentifiers(value: String) {
        #expect(throws: SpannerConfigurationError.invalidIdentifier(Key.databaseId)) {
            try SpannerConnectionSettings.parse(fields: fields(database: value))
        }
        #expect(throws: SpannerConfigurationError.invalidIdentifier(Key.projectId)) {
            try SpannerConnectionSettings.parse(fields: fields(project: value))
        }
    }

    @Test("A regional Google endpoint is trusted", arguments: [
        "https://spanner.us-central1.rep.googleapis.com",
        "https://SPANNER.GOOGLEAPIS.COM/",
        "spanner.googleapis.com"
    ])
    func trustedEndpoints(endpoint: String) throws {
        let settings = try SpannerConnectionSettings.parse(fields: fields(endpoint: endpoint))
        #expect(settings.endpoint.scheme == "https")
    }

    @Test("Production auth refuses endpoints that are not https googleapis.com", arguments: [
        "http://spanner.googleapis.com",
        "https://spanner.googleapis.com.evil.example",
        "https://evilgoogleapis.com",
        "https://localhost:9020",
        "http://localhost:9020"
    ])
    func untrustedEndpoints(endpoint: String) {
        #expect(throws: SpannerConfigurationError.untrustedEndpoint) {
            try SpannerConnectionSettings.parse(fields: fields(endpoint: endpoint, method: "oauth"))
        }
    }

    @Test("Credentials, queries, fragments and paths in the endpoint are refused", arguments: [
        "https://user:pw@spanner.googleapis.com",
        "https://spanner.googleapis.com?x=1",
        "https://spanner.googleapis.com#x",
        "https://spanner.googleapis.com/v1/projects",
        "ftp://spanner.googleapis.com",
        "https://"
    ])
    func malformedEndpoints(endpoint: String) {
        #expect(throws: SpannerConfigurationError.invalidEndpoint) {
            try SpannerConnectionSettings.parse(fields: fields(endpoint: endpoint))
        }
    }

    @Test("The emulator accepts loopback endpoints over http or https", arguments: [
        "http://localhost:9020",
        "https://127.0.0.1:9020",
        "http://[::1]:9020",
        "localhost:9020"
    ])
    func emulatorLoopback(endpoint: String) throws {
        let settings = try SpannerConnectionSettings.parse(fields: fields(endpoint: endpoint, method: "emulator"))
        #expect(settings.authMethod == .emulator)
        #expect(settings.endpoint.host == "localhost" || settings.endpoint.host == "127.0.0.1" || settings.endpoint.host == "::1")
    }

    @Test("The emulator refuses a remote endpoint", arguments: [
        "https://spanner.googleapis.com",
        "http://10.0.0.5:9020",
        "http://localhost.evil.example:9020"
    ])
    func emulatorRemote(endpoint: String) {
        #expect(throws: SpannerConfigurationError.emulatorRequiresLoopback) {
            try SpannerConnectionSettings.parse(fields: fields(endpoint: endpoint, method: "emulator"))
        }
    }

    @Test("The emulator needs an endpoint")
    func emulatorNeedsEndpoint() {
        #expect(throws: SpannerConfigurationError.missingField(Key.endpoint)) {
            try SpannerConnectionSettings.parse(fields: fields(method: "emulator"))
        }
    }

    @Test("Resource URLs percent-encode each segment and keep the custom verb")
    func resourceURLs() throws {
        let settings = try SpannerConnectionSettings.parse(fields: fields(project: "example.com:proj"))
        let database = try settings.databaseURL(suffix: "sessions")
        #expect(database.absoluteString
            == "https://spanner.googleapis.com/v1/projects/example.com%3Aproj/instances/inst/databases/gdb/sessions")
        let session = try settings.resourceURL("projects/p/instances/i/databases/d/sessions/a b", verb: "executeSql")
        #expect(session.absoluteString
            == "https://spanner.googleapis.com/v1/projects/p/instances/i/databases/d/sessions/a%20b:executeSql")
    }

    @Test("Server resource names with dot segments or empty segments are refused", arguments: [
        "projects/p/../x", "projects/p/./x", "projects//p", "", "/projects/p"
    ])
    func rejectsDotSegments(name: String) throws {
        let settings = try SpannerConnectionSettings.parse(fields: fields())
        #expect(throws: SpannerTransportError.invalidResponse) {
            try settings.resourceURL(name)
        }
    }
}
