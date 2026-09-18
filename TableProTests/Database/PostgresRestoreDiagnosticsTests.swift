import Foundation
import Testing

@testable import TablePro

@Suite("PostgresRestoreDiagnostics")
struct PostgresRestoreDiagnosticsTests {
    private static let pgRestore17IntoServer92 = """
        pg_restore: error: could not execute query: ERROR:  unrecognized configuration parameter "lock_timeout"
        Command was: SET lock_timeout = 0;
        pg_restore: error: could not execute query: ERROR:  unrecognized configuration parameter "idle_in_transaction_session_timeout"
        Command was: SET idle_in_transaction_session_timeout = 0;
        pg_restore: error: could not execute query: ERROR:  unrecognized configuration parameter "transaction_timeout"
        Command was: SET transaction_timeout = 0;
        pg_restore: error: could not execute query: ERROR:  unrecognized configuration parameter "row_security"
        Command was: SET row_security = off;
        pg_restore: warning: errors ignored on restore: 4
        """

    private static let pgRestore17IntoServer12 = """
        pg_restore: error: could not execute query: ERROR:  unrecognized configuration parameter "transaction_timeout"
        Command was: SET transaction_timeout = 0;
        pg_restore: warning: errors ignored on restore: 1
        """

    private static let pgRestore17ArchiveFrom17IntoServer96 = """
        pg_restore: error: could not execute query: ERROR:  unrecognized configuration parameter "transaction_timeout"
        Command was: SET transaction_timeout = 0;
        pg_restore: error: could not set "default_table_access_method": ERROR:  unrecognized configuration parameter "default_table_access_method"
        pg_restore: warning: errors ignored on restore: 2
        """

    private static let pgRestore17SequenceDumpIntoServer96 = """
        pg_restore: error: could not execute query: ERROR:  unrecognized configuration parameter "transaction_timeout"
        Command was: SET transaction_timeout = 0;
        pg_restore: error: could not set "default_table_access_method": ERROR:  unrecognized configuration parameter "default_table_access_method"
        pg_restore: error: could not execute query: ERROR:  syntax error at or near "AS"
        LINE 2:     AS integer
                    ^
        Command was: CREATE SEQUENCE public.t_id_seq
            AS integer
            START WITH 1
            INCREMENT BY 1
            NO MINVALUE
            NO MAXVALUE
            CACHE 1;


        pg_restore: error: could not execute query: ERROR:  relation "public.t_id_seq" does not exist
        Command was: ALTER SEQUENCE public.t_id_seq OWNED BY public.t.id;


        pg_restore: error: could not execute query: ERROR:  relation "public.t_id_seq" does not exist
        Command was: ALTER TABLE ONLY public.t ALTER COLUMN id SET DEFAULT nextval('public.t_id_seq'::regclass);


        pg_restore: error: could not execute query: ERROR:  relation "public.t_id_seq" does not exist
        LINE 1: SELECT pg_catalog.setval('public.t_id_seq', 3, true);
                                         ^
        Command was: SELECT pg_catalog.setval('public.t_id_seq', 3, true);


        pg_restore: warning: errors ignored on restore: 6
        """

    private static let pgRestore12InitializingIntoServer93 = """
        pg_restore: while INITIALIZING:
        pg_restore: error: could not execute query: ERROR:  unrecognized configuration parameter "idle_in_transaction_session_timeout"
        Command was: SET idle_in_transaction_session_timeout = 0;
        pg_restore: error: could not execute query: ERROR:  unrecognized configuration parameter "row_security"
        Command was: SET row_security = off;
        pg_restore: warning: errors ignored on restore: 2
        """

    private static let pgRestore12ProcessingTocIntoServer96 = """
        pg_restore: while PROCESSING TOC:
        pg_restore: from TOC entry 202; 1259 19993 TABLE t postgres
        pg_restore: error: could not set default_table_access_method: ERROR:  unrecognized configuration parameter "default_table_access_method"
        pg_restore: warning: errors ignored on restore: 1
        """

    private static let pgRestore12BothPhasesIntoServer93 = """
        pg_restore: while INITIALIZING:
        pg_restore: error: could not execute query: ERROR:  unrecognized configuration parameter "idle_in_transaction_session_timeout"
        Command was: SET idle_in_transaction_session_timeout = 0;
        pg_restore: error: could not execute query: ERROR:  unrecognized configuration parameter "row_security"
        Command was: SET row_security = off;
        pg_restore: while PROCESSING TOC:
        pg_restore: from TOC entry 202; 1259 19993 TABLE t postgres
        pg_restore: error: could not set default_table_access_method: ERROR:  unrecognized configuration parameter "default_table_access_method"
        pg_restore: warning: errors ignored on restore: 3
        """

    private static let pgRestore11IntoServer93 = """
        pg_restore: [archiver (db)] Error while INITIALIZING:
        pg_restore: [archiver (db)] could not execute query: ERROR:  unrecognized configuration parameter "idle_in_transaction_session_timeout"
            Command was: SET idle_in_transaction_session_timeout = 0;

        pg_restore: [archiver (db)] could not execute query: ERROR:  unrecognized configuration parameter "row_security"
            Command was: SET row_security = off;

        WARNING: errors ignored on restore: 2
        """

    private static let pgRestore17FrenchLocaleIntoServer12 = """
        pg_restore: erreur : could not execute query: ERROR:  unrecognized configuration parameter "transaction_timeout"
        La commande était : SET transaction_timeout = 0;
        pg_restore: attention : erreurs ignorées lors de la restauration : 1
        """

    private static func skipped(_ stderr: String, exitCode: Int32 = 1) -> [String]? {
        PostgresRestoreDiagnostics.skippedSessionSettings(exitCode: exitCode, stderr: stderr)
    }

    @Test("A same-server round trip with pg_restore 17 on 9.2 skips four settings")
    func roundTripOnServer92() {
        #expect(Self.skipped(Self.pgRestore17IntoServer92) == [
            "lock_timeout", "idle_in_transaction_session_timeout", "transaction_timeout", "row_security"
        ])
    }

    @Test("pg_restore 17 on a 12 server skips transaction_timeout alone")
    func roundTripOnServer12() {
        #expect(Self.skipped(Self.pgRestore17IntoServer12) == ["transaction_timeout"])
    }

    @Test("pg_restore 17's quoted could not set form counts as a skipped setting")
    func quotedCouldNotSetForm() {
        #expect(Self.skipped(Self.pgRestore17ArchiveFrom17IntoServer96) == [
            "transaction_timeout", "default_table_access_method"
        ])
    }

    @Test("pg_restore 12 prefixes the preamble with a while INITIALIZING context line")
    func pgRestore12InitializingContext() {
        #expect(Self.skipped(Self.pgRestore12InitializingIntoServer93) == [
            "idle_in_transaction_session_timeout", "row_security"
        ])
    }

    @Test("pg_restore 12 sets the table access method per TOC entry, unquoted")
    func pgRestore12ProcessingTocContext() {
        #expect(Self.skipped(Self.pgRestore12ProcessingTocIntoServer96) == ["default_table_access_method"])
    }

    @Test("pg_restore 12 with errors in both phases")
    func pgRestore12BothPhases() {
        #expect(Self.skipped(Self.pgRestore12BothPhasesIntoServer93) == [
            "idle_in_transaction_session_timeout", "row_security", "default_table_access_method"
        ])
    }

    @Test("pg_restore 11 and older use another format and are not second-guessed")
    func pgRestore11FailsSafe() {
        #expect(Self.skipped(Self.pgRestore11IntoServer93) == nil)
    }

    @Test("Translated client messages are not second-guessed")
    func translatedClientMessages() {
        #expect(Self.skipped(Self.pgRestore17FrenchLocaleIntoServer12) == nil)
    }

    @Test("A real object error among skipped settings is still a failure")
    func realErrorAmongSkippedSettings() {
        #expect(Self.skipped(Self.pgRestore17SequenceDumpIntoServer96) == nil)
    }

    @Test("Empty output with a failing exit is a failure")
    func emptyStderr() {
        #expect(Self.skipped("") == nil)
    }

    @Test("Only exit code 1, the errors-ignored code, is ever tolerated")
    func otherExitCodes() {
        #expect(Self.skipped(Self.pgRestore17IntoServer12, exitCode: 0) == nil)
        #expect(Self.skipped(Self.pgRestore17IntoServer12, exitCode: 2) == nil)
    }

    @Test("A count that disagrees with the errors shown means output was lost")
    func truncatedOutput() {
        let lines = Self.pgRestore17IntoServer92.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(Self.skipped(lines.dropFirst(2).joined(separator: "\n")) == nil)
    }

    @Test("A missing errors-ignored summary is a failure")
    func missingSummary() {
        let lines = Self.pgRestore17IntoServer12.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(Self.skipped(lines.dropLast().joined(separator: "\n")) == nil)
    }

    @Test("Anything after the summary is a failure, context lines included")
    func outputAfterSummary() {
        #expect(Self.skipped(Self.pgRestore17IntoServer12 + "\npg_restore: error: could not execute query: ERROR:  boom") == nil)
        #expect(Self.skipped(Self.pgRestore17IntoServer12 + "\npg_restore: while INITIALIZING:") == nil)
    }

    @Test("The same setting rejected twice is named once")
    func duplicateSettingNamedOnce() {
        let stderr = """
            pg_restore: error: could not execute query: ERROR:  unrecognized configuration parameter "transaction_timeout"
            Command was: SET transaction_timeout = 0;
            pg_restore: error: could not execute query: ERROR:  unrecognized configuration parameter "transaction_timeout"
            Command was: SET transaction_timeout = 0;
            pg_restore: warning: errors ignored on restore: 2
            """
        #expect(Self.skipped(stderr) == ["transaction_timeout"])
    }

    @Test("A rejected SET naming a different parameter than the error is a failure")
    func mismatchedSetParameter() {
        let stderr = """
            pg_restore: error: could not execute query: ERROR:  unrecognized configuration parameter "row_security"
            Command was: SET transaction_timeout = 0;
            pg_restore: warning: errors ignored on restore: 1
            """
        #expect(Self.skipped(stderr) == nil)
    }

    @Test("A could not set line naming a different parameter than the error is a failure")
    func mismatchedCouldNotSetParameter() {
        let quoted = """
            pg_restore: error: could not set "default_table_access_method": ERROR:  unrecognized configuration parameter "row_security"
            pg_restore: warning: errors ignored on restore: 1
            """
        let unquoted = """
            pg_restore: error: could not set default_table_access_method: ERROR:  unrecognized configuration parameter "row_security"
            pg_restore: warning: errors ignored on restore: 1
            """
        #expect(Self.skipped(quoted) == nil)
        #expect(Self.skipped(unquoted) == nil)
    }

    @Test("A command carrying a second statement is not a skipped setting")
    func multiStatementCommand() {
        let stderr = """
            pg_restore: error: could not execute query: ERROR:  unrecognized configuration parameter "bogus"
            Command was: SET bogus = 1; CREATE TABLE t(id int);
            pg_restore: warning: errors ignored on restore: 1
            """
        #expect(Self.skipped(stderr) == nil)
    }

    @Test("A quoted value is one value, and a quote that ends early is not")
    func quotedValues() {
        let quoted = """
            pg_restore: error: could not execute query: ERROR:  unrecognized configuration parameter "bogus"
            Command was: SET bogus = 'it''s fine';
            pg_restore: warning: errors ignored on restore: 1
            """
        let escaping = """
            pg_restore: error: could not execute query: ERROR:  unrecognized configuration parameter "bogus"
            Command was: SET bogus = 'a'; DROP TABLE t; SELECT 'b';
            pg_restore: warning: errors ignored on restore: 1
            """
        #expect(Self.skipped(quoted) == ["bogus"])
        #expect(Self.skipped(escaping) == nil)
    }

    @Test("A SET rejected for a bad value rather than an unknown parameter is a failure")
    func invalidValue() {
        let stderr = """
            pg_restore: error: could not execute query: ERROR:  invalid value for parameter "client_encoding": "LATIN9X"
            Command was: SET client_encoding = 'LATIN9X';
            pg_restore: warning: errors ignored on restore: 1
            """
        #expect(Self.skipped(stderr) == nil)
    }

    @Test("A connection failure is a failure")
    func connectionFailure() {
        let stderr = """
            pg_restore: error: connection to server at "127.0.0.1", port 5432 failed: Connection refused
            \tIs the server running on that host and accepting TCP/IP connections?
            """
        #expect(Self.skipped(stderr) == nil)
    }

    @Test("A server that reports errors in another language is not second-guessed")
    func localizedServerMessage() {
        let stderr = """
            pg_restore: error: could not execute query: ERROR:  paramètre de configuration « transaction_timeout » non reconnu
            Command was: SET transaction_timeout = 0;
            pg_restore: warning: errors ignored on restore: 1
            """
        #expect(Self.skipped(stderr) == nil)
    }
}
