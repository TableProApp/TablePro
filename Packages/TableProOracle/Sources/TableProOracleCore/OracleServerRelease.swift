import Foundation

/// The release of the server a session is on, which decides the dictionary columns a query may name.
///
/// It comes from the login reply (`AUTH_VERSION_NO`), so every connected session has it without a query. A dictionary
/// column the release does not have fails the whole statement with ORA-00904, so a catalog read written for a newer
/// dictionary has to be written differently for an older one rather than sent and forgiven.
public struct OracleServerRelease: Sendable, Equatable {
    public let major: Int
    /// The release update, the second field of `23.4.0.24.05`. 23ai kept its major through every update, and some of
    /// its dictionary columns arrived in an update rather than with the major (26ai still reports `23.26`).
    public let update: Int

    public init(major: Int, update: Int = 0) {
        self.major = major
        self.update = update
    }

    /// 12.1 brought identity columns, `DEFAULT ON NULL` and invisible columns, and with them the `IDENTITY_COLUMN`,
    /// `DEFAULT_ON_NULL` and `USER_GENERATED` columns of `ALL_TAB_COLS`. 11g has none of the three.
    public var hasIdentityColumns: Bool {
        major >= 12
    }

    /// 23ai brought `DEFAULT ON NULL FOR INSERT AND UPDATE` and the `DEFAULT_ON_NULL_UPD` column that reports it.
    public var hasDefaultOnNullForUpdate: Bool {
        major >= 23
    }

    /// `VECTOR_INFO` came with the `VECTOR` type in 23.4, the first release with AI Vector Search. The 23.2 and 23.3
    /// developer releases are 23 too, so the major alone would name the column on a server that may not have it.
    public var hasVectorInfo: Bool {
        major > 23 || (major == 23 && update >= 4)
    }
}
