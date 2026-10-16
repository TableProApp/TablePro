import Foundation

/// Reads the two things TablePro needs out of `@@VERSION`.
///
/// `@@VERSION` is a multi-line banner: a first line naming the product and its build, then the
/// build date, the copyright and the host OS, each on its own tab-indented line. Only the first
/// line carries the `major.minor.build.revision` the feature gates read, and only the first line is
/// worth showing a user.
///
/// Truncating the banner to a fixed prefix does not work, and shipped as a silent regression: 50
/// characters of a patched SQL Server 2022 is
/// `Microsoft SQL Server 2022 (RTM-CU26-GDR) (KB512276`, which cuts the build off mid-KB-number and
/// leaves no `major.minor.build` to match. The major version then read as unknown on every patched
/// server, so `CREATE OR ALTER` was never used even on servers that have had it since 2016. The
/// cumulative-update suffix grows with every patch, so the prefix that fitted when it was written
/// stops fitting later.
public enum MSSQLServerBanner {
    /// The product line, without the build date, copyright and host OS lines under it.
    public static func displayText(from banner: String) -> String {
        let firstLine = banner.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)[0]
        return firstLine.trimmingCharacters(in: .whitespaces)
    }

    /// Matches against the whole banner rather than the first line alone, so a future layout that
    /// moves the build number cannot silently return nil the way the fixed prefix did.
    public static func server(from banner: String?) -> MSSQLServerBuild? {
        guard let banner else { return nil }
        guard let regex = try? NSRegularExpression(pattern: #"(\d+)\.(\d+)\.(\d+)"#),
              let match = regex.firstMatch(in: banner, range: NSRange(banner.startIndex..., in: banner))
        else {
            return nil
        }
        let parts = (1...3).compactMap { index in
            Range(match.range(at: index), in: banner).flatMap { Int(banner[$0]) }
        }
        guard parts.count == 3 else { return nil }
        return MSSQLServerBuild(
            major: parts[0],
            minor: parts[1],
            build: parts[2],
            isAzureSQL: banner.hasPrefix("Microsoft SQL Azure")
        )
    }
}

/// Azure SQL Database and Managed Instance report `12.0.2000.x` whatever engine they run, so their
/// features cannot be read off the number.
public struct MSSQLServerBuild: Sendable, Equatable {
    public let major: Int
    public let minor: Int
    public let build: Int
    public let isAzureSQL: Bool

    /// `CREATE OR ALTER` applies to "Azure SQL Database and SQL Server (starting with SQL Server
    /// 2016 (13.x) SP1)" (CREATE VIEW, Microsoft Learn). 13.0.4001 is 2016 SP1; RTM is 13.0.1601.
    public var hasCreateOrAlter: Bool {
        isAzureSQL || (major, minor, build) >= (13, 0, 4_001)
    }
}
