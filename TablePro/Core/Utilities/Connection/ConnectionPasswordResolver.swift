//
//  ConnectionPasswordResolver.swift
//  TablePro
//

import Foundation

/// Runs a connection's password source, answering from `ResolvedPasswordCache` while an earlier
/// answer is still good.
///
/// The cache is keyed here rather than inside `PasswordSourceResolver` because only a connection
/// can key one: the resolver is handed a source, and two connections can declare the same source
/// and still want separate entries once a shared template fills it in differently.
enum ConnectionPasswordResolver {
    static func resolve(
        _ source: PasswordSource,
        for connection: DatabaseConnection,
        settings: SecretManagerSettings = AppSettingsStorage.shared.loadSecretManager()
    ) async throws -> String {
        let context = PasswordCommandTemplate.Context(connection: connection)

        /// A file and an environment variable are free to read again, and caching either would
        /// only put a stale copy in front of a value the user can already change in place. Only a
        /// source that spawns a process is worth holding, and the command it runs is its
        /// fingerprint: editing the shared template drops every entry the old one filled, with
        /// nothing having to remember to invalidate them.
        let template = settings.trimmedDefaultCommand
        guard let fingerprint = PasswordSourceResolver.effectiveCommand(
            for: source,
            context: context,
            sharedTemplate: template
        ) else {
            return try await PasswordSourceResolver.resolve(source, context: context, sharedTemplate: template)
        }

        if let cached = await ResolvedPasswordCache.shared.value(
            for: connection.id,
            fingerprint: fingerprint
        ) {
            return cached
        }

        let password = try await PasswordSourceResolver.resolve(
            source,
            context: context,
            sharedTemplate: template
        )
        await ResolvedPasswordCache.shared.store(
            password,
            for: connection.id,
            fingerprint: fingerprint,
            lifetime: settings.cacheLifetime.seconds
        )
        return password
    }
}
