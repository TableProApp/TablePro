import Foundation

/// The major release of the server a session is on, which decides the dictionary columns a query may name.
///
/// It comes from the login reply (`AUTH_VERSION_NO`), so every connected session has it without a query. A dictionary
/// column the release does not have fails the whole statement with ORA-00904, so a catalog read written for a newer
/// dictionary has to be written differently for an older one rather than sent and forgiven.
public struct OracleServerRelease: Sendable, Equatable {
    public let major: Int

    public init(major: Int) {
        self.major = major
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
}
