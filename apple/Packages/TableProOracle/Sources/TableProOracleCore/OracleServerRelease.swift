import Foundation

// From the login reply (`AUTH_VERSION_NO`), so no query reads it. A dictionary column the release lacks fails the whole
// statement with ORA-00904, so a catalog read is written per release.
public struct OracleServerRelease: Sendable, Equatable {
    public let major: Int
    // The second field of `23.4.0.24.05`: some 23ai dictionary columns came with an update (26ai reports `23.26`).
    public let update: Int

    public init(major: Int, update: Int = 0) {
        self.major = major
        self.update = update
    }

    // 12.1 brought identity, `DEFAULT ON NULL` and invisible columns, with `ALL_TAB_COLS.IDENTITY_COLUMN`,
    // `DEFAULT_ON_NULL` and `USER_GENERATED`. 11g has none of the three.
    public var hasIdentityColumns: Bool {
        major >= 12
    }

    // 23ai brought `DEFAULT ON NULL FOR INSERT AND UPDATE` and the `DEFAULT_ON_NULL_UPD` column that reports it.
    public var hasDefaultOnNullForUpdate: Bool {
        major >= 23
    }

    // `VECTOR_INFO` came with the `VECTOR` type in 23.4. The 23.2 and 23.3 developer releases are 23 too, so the major
    // alone would name the column on a server that may not have it.
    public var hasVectorInfo: Bool {
        major > 23 || (major == 23 && update >= 4)
    }

    // 12.1 added `ALL_CONSTRAINTS.SEARCH_CONDITION_VC`. Before it a check's text is only in the LONG `SEARCH_CONDITION`.
    public var hasSearchConditionText: Bool {
        major >= 12
    }

    // 23ai brought SQL's BOOLEAN type. Before it `TRUE` and `FALSE` are names, and a statement using one fails ORA-00904.
    public var hasBooleanType: Bool {
        major >= 23
    }

    // 23ai brought `IF EXISTS` on `DROP`. Before it the clause does not parse.
    public var hasDropIfExists: Bool {
        major >= 23
    }
}
