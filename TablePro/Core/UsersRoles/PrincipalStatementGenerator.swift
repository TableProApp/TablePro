import Foundation
import TableProPluginKit

struct PrincipalStatementGenerator {
    private let driver: any PluginPrincipalManagement

    init(driver: any PluginPrincipalManagement) {
        self.driver = driver
    }

    func generate(changes: [PrincipalChange]) throws -> [SchemaStatement] {
        try changes
            .sorted { $0.executionRank < $1.executionRank }
            .flatMap { try statements(for: $0) }
    }

    private func statements(for change: PrincipalChange) throws -> [SchemaStatement] {
        switch change {
        case let .create(definition):
            try wrap(
                driver.generateCreatePrincipalSQL(definition: definition),
                description: String(
                    format: String(localized: "Create %@"),
                    definition.ref.displayName
                ),
                isDestructive: false,
                carriesCredentials: !(definition.password ?? "").isEmpty
            )

        case let .alter(old, new):
            try wrap(
                driver.generateAlterPrincipalSQL(old: old, new: new),
                description: String(
                    format: String(localized: "Update %@"),
                    old.ref.displayName
                ),
                isDestructive: false,
                carriesCredentials: !(new.password ?? "").isEmpty
            )

        case let .setPassword(ref, password):
            try wrap(
                driver.generateSetPasswordSQL(principal: ref, password: password),
                description: String(
                    format: String(localized: "Change password for %@"),
                    ref.displayName
                ),
                isDestructive: false,
                carriesCredentials: true
            )

        case let .modifyGrants(changeSet):
            try grantStatements(changeSet)

        case let .drop(ref, options):
            try wrap(
                driver.generateDropPrincipalSQL(principal: ref, options: options),
                description: String(
                    format: String(localized: "Drop %@"),
                    ref.displayName
                ),
                isDestructive: true
            )
        }
    }

    private func grantStatements(_ changeSet: PluginPrincipalChangeSet) throws -> [SchemaStatement] {
        var statements: [SchemaStatement] = []

        if !changeSet.grantsToRemove.isEmpty {
            statements += try wrap(
                driver.generateRevokeSQL(changeSet: changeSet),
                description: String(
                    format: String(localized: "Revoke privileges from %@"),
                    changeSet.principal.displayName
                ),
                isDestructive: true
            )
        }
        if !changeSet.grantsToAdd.isEmpty {
            statements += try wrap(
                driver.generateGrantSQL(changeSet: changeSet),
                description: String(
                    format: String(localized: "Grant privileges to %@"),
                    changeSet.principal.displayName
                ),
                isDestructive: false
            )
        }
        return statements
    }

    private func wrap(
        _ sql: [String]?,
        description: String,
        isDestructive: Bool,
        carriesCredentials: Bool = false
    ) throws -> [SchemaStatement] {
        guard let sql else {
            throw DatabaseError.unsupportedOperation
        }
        return sql.map {
            SchemaStatement(
                sql: $0,
                description: description,
                isDestructive: isDestructive,
                carriesCredentials: carriesCredentials
            )
        }
    }
}
