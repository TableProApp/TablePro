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
        #expect(MSSQLServerBanner.server(from: Self.sqlServer2022)
            == MSSQLServerBuild(major: 16, minor: 0, build: 4_275, isAzureSQL: false))
    }

    @Test("A fixed 50-character prefix would have lost it")
    func fixedPrefixLosesTheBuild() {
        #expect(MSSQLServerBanner.server(from: String(Self.sqlServer2022.prefix(50))) == nil)
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
        #expect(MSSQLServerBanner.server(from: banner)
            == MSSQLServerBuild(major: 12, minor: 0, build: 2_000, isAzureSQL: true))
        #expect(MSSQLServerBanner.displayText(from: banner) == "Microsoft SQL Azure (RTM) - 12.0.2000.8")
    }

    @Test("A banner with no build number reports no version rather than a wrong one")
    func unparsableBanner() {
        #expect(MSSQLServerBanner.server(from: "Microsoft SQL Server") == nil)
        #expect(MSSQLServerBanner.server(from: nil) == nil)
    }

    @Test(
        "CREATE OR ALTER needs SQL Server 2016 SP1 or Azure SQL",
        arguments: [
            ("Microsoft SQL Server 2016 (RTM) - 13.0.1601.5 (X64)", false),
            ("Microsoft SQL Server 2016 (SP1) (KB3182545) - 13.0.4001.0 (X64)", true),
            ("Microsoft SQL Server 2014 (SP3) (KB4022619) - 12.0.6024.0 (X64)", false),
            ("Microsoft SQL Server 2019 (RTM-CU18) (KB5017593) - 15.0.4261.1 (X64)", true),
            ("Microsoft SQL Azure (RTM) - 12.0.2000.8", true),
        ]
    )
    func createOrAlterGate(banner: String, expected: Bool) {
        #expect(MSSQLServerBanner.server(from: banner)?.hasCreateOrAlter == expected)
    }

    @Test("A single-line banner is returned whole")
    func singleLineBanner() {
        #expect(MSSQLServerBanner.displayText(from: "Microsoft SQL Server 2019 - 15.0.1.1") == "Microsoft SQL Server 2019 - 15.0.1.1")
    }
}
