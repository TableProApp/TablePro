//
//  DotenvConnectionExtractor.swift
//  TablePro
//

import Foundation

enum DotenvConnectionExtractor {
    struct Context {
        let document: DotenvDocument
        let relativePath: String
        let tier: ScannedConnectionTier
        let directoryURL: URL
    }

    private static let relationalURLKeys = [
        "DATABASE_URL_UNPOOLED",
        "POSTGRES_URL_NON_POOLING",
        "DATABASE_PUBLIC_URL",
        "DATABASE_URL",
        "DIRECT_URL",
        "DIRECT_DATABASE_URL",
        "POSTGRES_URL",
        "POSTGRES_PRISMA_URL",
        "SUPABASE_DB_URL",
        "MYSQL_PUBLIC_URL",
        "MYSQL_URL",
        "JAWSDB_MARIA_URL",
        "JAWSDB_URL",
        "CLEARDB_DATABASE_URL",
        "JDBC_DATABASE_URL",
        "SPRING_DATASOURCE_URL",
        "DB_URL",
    ]

    private static let mongoURLKeys = ["MONGODB_URI", "MONGO_URL", "MONGODB_URL", "MONGO_URI"]
    private static let redisURLKeys = ["REDIS_URL", "REDIS_TLS_URL"]
    private static let tursoURLKeys = ["TURSO_DATABASE_URL", "TURSO_CONNECTION_URL", "TURSO_URL"]

    static func extract(
        document: DotenvDocument,
        relativePath: String,
        tier: ScannedConnectionTier,
        directoryURL: URL
    ) -> [ScannedConnectionCandidate] {
        let context = Context(
            document: document,
            relativePath: relativePath,
            tier: tier,
            directoryURL: directoryURL
        )
        var candidates: [ScannedConnectionCandidate] = []
        if let relational = relationalCandidate(context) {
            candidates.append(relational)
        }
        if let mongo = mongoCandidate(context) {
            candidates.append(mongo)
        }
        if let redis = redisCandidate(context) {
            candidates.append(redis)
        }
        if let turso = firstURLCandidate(context, keys: tursoURLKeys) {
            candidates.append(turso)
        }
        return candidates
    }

    static func firstURLCandidate(_ context: Context, keys: [String]) -> ScannedConnectionCandidate? {
        for key in keys {
            guard let value = context.document[key] else {
                continue
            }
            let candidate = ScannedConnectionURLBuilder.candidate(
                fromURL: value,
                key: key,
                relativePath: context.relativePath,
                kind: .dotenv,
                tier: context.tier
            )
            if let candidate {
                return candidate
            }
        }
        return nil
    }

    private static func relationalCandidate(_ context: Context) -> ScannedConnectionCandidate? {
        if let fromURL = firstURLCandidate(context, keys: relationalURLKeys) {
            return fromURL
        }
        if let laravel = laravelCandidate(context) {
            return laravel
        }
        if let docker = dockerRelationalCandidate(context) {
            return docker
        }
        return libpqCandidate(context)
    }

    private static func mongoCandidate(_ context: Context) -> ScannedConnectionCandidate? {
        firstURLCandidate(context, keys: mongoURLKeys) ?? mongoDiscreteCandidate(context)
    }

    private static func redisCandidate(_ context: Context) -> ScannedConnectionCandidate? {
        firstURLCandidate(context, keys: redisURLKeys) ?? redisDiscreteCandidate(context)
    }

    static func candidate(
        _ context: Context,
        fields: ScannedConnectionFields,
        key: String,
        warnings: [String] = []
    ) -> ScannedConnectionCandidate {
        ScannedConnectionCandidate(
            parsedURL: fields.toParsedConnectionURL(),
            sourceRelativePath: context.relativePath,
            sourceKey: key,
            kind: .dotenv,
            tier: context.tier,
            warnings: warnings
        )
    }
}
