import Foundation
import Testing

@testable import TableProMSSQLCore

@Suite("MSSQL Session Options")
struct MSSQLSessionOptionsTests {
    /// Dropping any one leaves the server refusing every XML data type method and every write to a
    /// table with a filtered or computed-column index, which is what emptied the procedure and
    /// function lists.
    @Test("Every option SQL Server requires on is turned on")
    func requiredOnOptionsAreSet() {
        let sql = MSSQLSessionOptions.ansiDefaults
        for option in [
            "ANSI_NULLS", "ANSI_PADDING", "ANSI_WARNINGS",
            "ARITHABORT", "CONCAT_NULL_YIELDS_NULL", "QUOTED_IDENTIFIER"
        ] {
            #expect(sql.contains("SET \(option) ON"))
        }
        #expect(MSSQLSessionOptions.optionsRequiredOn.count == 6)
    }

    /// Measured on SQL Server 2022: with all six on and this one also on, the write still fails
    /// with Msg 1934 naming NUMERIC_ROUNDABORT alone. It arrives off, so this only matters when a
    /// database or a login carries it on, which is exactly the case nothing else would catch.
    @Test("NUMERIC_ROUNDABORT is turned off, not on")
    func roundabortIsTurnedOff() {
        #expect(MSSQLSessionOptions.ansiDefaults.contains("SET NUMERIC_ROUNDABORT OFF"))
        #expect(!MSSQLSessionOptions.ansiDefaults.contains("SET NUMERIC_ROUNDABORT ON"))
        #expect(MSSQLSessionOptions.optionsRequiredOff == ["NUMERIC_ROUNDABORT"])
    }

    @Test("The profile is seven options and no option appears in both lists")
    func profileIsSevenDistinctOptions() {
        let values = MSSQLSessionOptions.requiredValues
        #expect(values.count == 7)
        #expect(Set(values.map(\.name)).count == 7)
        #expect(values.filter { !$0.isOn }.map(\.name) == ["NUMERIC_ROUNDABORT"])
    }

    /// db-lib defaults TEXTSIZE to 4096 bytes, which truncates a large value mid-character and
    /// reads as damaged data rather than as a limit.
    @Test("Text size is raised to the protocol maximum")
    func textSizeIsRaised() {
        #expect(MSSQLSessionOptions.maxTextSize == "SET TEXTSIZE \(Int32.max)")
    }

    /// One statement per element, so a server that refuses one still receives the rest.
    @Test("Establishment sends the ANSI options before the text size")
    func establishmentOrder() {
        #expect(MSSQLSessionOptions.establishment == [
            MSSQLSessionOptions.ansiDefaults,
            MSSQLSessionOptions.maxTextSize
        ])
    }
}

@Suite("MSSQL Server Banner")
struct MSSQLServerBannerTests {
    /// Measured from a live SQL Server 2022 CU26. The 50-character prefix this replaced cut the
    /// build off mid-KB-number, so every version gate read the server as unknown.
    static let sqlServer2022 = """
        Microsoft SQL Server 2022 (RTM-CU26-GDR) (KB5122768) - 16.0.4275.2 (X64) \n\t\
        Aug 20 2026 00:33:45 \n\t\
        Copyright (C) 2022 Microsoft Corporation\n\t\
        Developer Edition (64-bit) on Linux (Ubuntu 22.04.5 LTS) <X64>
        """

    @Test("A patched server's major version survives the banner")
    func patchedServerParses() {
        #expect(MSSQLServerBanner.majorVersion(from: Self.sqlServer2022) == 16)
    }

    @Test("A fixed 50-character prefix would have lost it")
    func fixedPrefixLosesTheBuild() {
        #expect(MSSQLServerBanner.majorVersion(from: String(Self.sqlServer2022.prefix(50))) == nil)
    }

    @Test("Display text is the product line alone")
    func displayTextIsOneLine() {
        let text = MSSQLServerBanner.displayText(from: Self.sqlServer2022)
        #expect(text == "Microsoft SQL Server 2022 (RTM-CU26-GDR) (KB5122768) - 16.0.4275.2 (X64)")
        #expect(!text.contains("\n"))
        #expect(!text.contains("Copyright"))
    }

    @Test("Azure SQL Database reports its version on the first line too")
    func azureParses() {
        let banner = "Microsoft SQL Azure (RTM) - 12.0.2000.8 \n\tOct 18 2025 12:00:00 \n\tCopyright (C) 2025 Microsoft Corporation"
        #expect(MSSQLServerBanner.majorVersion(from: banner) == 12)
        #expect(MSSQLServerBanner.displayText(from: banner) == "Microsoft SQL Azure (RTM) - 12.0.2000.8")
    }

    @Test("A banner with no build number reports no version rather than a wrong one")
    func unparsableBanner() {
        #expect(MSSQLServerBanner.majorVersion(from: "Microsoft SQL Server") == nil)
        #expect(MSSQLServerBanner.majorVersion(from: nil) == nil)
    }

    @Test("A single-line banner is returned whole")
    func singleLineBanner() {
        #expect(MSSQLServerBanner.displayText(from: "Microsoft SQL Server 2019 - 15.0.1.1") == "Microsoft SQL Server 2019 - 15.0.1.1")
    }
}
