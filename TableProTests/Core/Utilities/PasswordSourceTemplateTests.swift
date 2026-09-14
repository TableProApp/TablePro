//
//  PasswordSourceTemplateTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("PasswordSource shared template", .serialized)
struct PasswordSourceTemplateTests {
    private let context = PasswordCommandTemplate.Context(
        name: "prod",
        host: "db.example.com",
        port: 5432,
        username: "app",
        database: "shop",
        typeId: "PostgreSQL"
    )

    @Test("Runs the shared command with this connection's values filled in")
    func resolvesSharedTemplate() async throws {
        let password = try await PasswordSourceResolver.resolve(
            .sharedTemplate,
            context: context,
            sharedTemplate: "printf '%s' {name}-{user}"
        )
        #expect(password == "prod-app")
    }

    @Test("Says so when no shared command is set rather than running an empty shell")
    func missingTemplateThrows() async {
        await #expect(throws: PasswordSourceResolver.ResolutionError.self) {
            try await PasswordSourceResolver.resolve(.sharedTemplate, context: context, sharedTemplate: "   ")
        }
    }

    @Test("Refuses the shared command with no connection to fill it in")
    func missingContextThrows() async {
        await #expect(throws: PasswordSourceResolver.ResolutionError.self) {
            try await PasswordSourceResolver.resolve(
                .sharedTemplate,
                context: nil,
                sharedTemplate: "printf secret"
            )
        }
    }

    @Test("A per-connection command takes placeholders too")
    func expandsPerConnectionCommand() async throws {
        let password = try await PasswordSourceResolver.resolve(
            .command(shell: "printf '%s' {database}"),
            context: context
        )
        #expect(password == "shop")
    }

    @Test("A per-connection command with no connection runs as written")
    func perConnectionCommandWithoutContext() async throws {
        let password = try await PasswordSourceResolver.resolve(.command(shell: "printf plain"), context: nil)
        #expect(password == "plain")
    }

    @Test("The preview is the command that will run")
    func previewsEffectiveCommand() {
        let command = PasswordSourceResolver.effectiveCommand(
            for: .sharedTemplate,
            context: context,
            sharedTemplate: "op read op://vault/{name}/password"
        )
        #expect(command == "op read op://vault/'prod'/password")
    }

    @Test("A source that reads no process previews no command, so nothing caches it")
    func localSourcesHaveNoCommand() {
        #expect(PasswordSourceResolver.effectiveCommand(for: .file(path: "~/x"), context: context) == nil)
        #expect(PasswordSourceResolver.effectiveCommand(for: .env(variable: "X"), context: context) == nil)
    }

    @Test("A CLI-backed source previews its own tool's command")
    func cliSourcesPreviewTheirCommand() {
        let command = PasswordSourceResolver.effectiveCommand(
            for: .vault(path: "secret/data/db", field: "password"),
            context: context
        )
        #expect(command == "vault kv get -field='password' 'secret/data/db'")
    }

    @Test("The AWS command names the profile, so one machine can reach several accounts")
    func awsCommandCarriesProfileAndRegion() {
        let command = PasswordSourceResolver.effectiveCommand(
            for: .awsSecretsManager(
                secretId: "/ops/product/aurora/product-team-6/productadmin",
                jsonKey: "password",
                profile: "hms-product",
                region: "ap-southeast-1"
            ),
            context: context
        )
        #expect(command == "aws secretsmanager get-secret-value "
            + "--secret-id '/ops/product/aurora/product-team-6/productadmin' "
            + "--query SecretString --output text --profile 'hms-product' --region 'ap-southeast-1'")
    }

    @Test("No profile leaves the command as the environment's own")
    func awsCommandWithoutProfile() {
        let command = PasswordSourceResolver.effectiveCommand(
            for: .awsSecretsManager(secretId: "prod/db", jsonKey: nil, profile: nil, region: nil),
            context: context
        )
        #expect(command == "aws secretsmanager get-secret-value --secret-id 'prod/db' "
            + "--query SecretString --output text")
    }

    @Test("The shared template survives a trip through connections.json")
    func codableRoundTrip() throws {
        let data = try JSONEncoder().encode(PasswordSource.sharedTemplate)
        #expect(try JSONDecoder().decode(PasswordSource.self, from: data) == .sharedTemplate)
    }

    @Test("An unknown kind is still refused, so a typo does not become a silent Keychain fallback")
    func unknownKindThrows() {
        let data = Data(#"{"kind":"nonsense"}"#.utf8)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(PasswordSource.self, from: data)
        }
    }
}
