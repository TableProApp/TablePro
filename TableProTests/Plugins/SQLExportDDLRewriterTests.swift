//
//  SQLExportDDLRewriterTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

/// Every fixture here is the literal output of `SHOW CREATE TABLE` or `SHOW CREATE VIEW` on
/// MariaDB 12.3, or of `SELECT sql FROM sqlite_master` on SQLite, so the rewriter is judged against
/// what a driver really hands the export.
@Suite("SQL export DDL rewriter")
struct SQLExportDDLRewriterTests {
    private static let stripping = SQLExportDDLRewriter(
        dialect: .mysql,
        excludesAutoIncrementValue: true,
        excludesDefiner: true)

    private static let keeping = SQLExportDDLRewriter(
        dialect: .mysql,
        excludesAutoIncrementValue: false,
        excludesDefiner: false)

    private static let createTable = """
        CREATE TABLE `users` (
          `id` int(11) NOT NULL AUTO_INCREMENT,
          `name` varchar(255) DEFAULT NULL COMMENT 'AUTO_INCREMENT=5 and DEFINER=`x`@`y` inside a comment',
          `weird AUTO_INCREMENT=9 col` int(11) DEFAULT NULL,
          PRIMARY KEY (`id`)
        ) ENGINE=InnoDB AUTO_INCREMENT=4 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_uca1400_ai_ci
        """

    private static let createView = "CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`localhost` "
        + "SQL SECURITY DEFINER VIEW `v_users` AS select `users`.`id` AS `id` from `users`"

    @Test("The table's counter goes and the column's attribute stays")
    func tableCounterIsRemoved() {
        let rewritten = Self.stripping.rewrite(Self.createTable)
        #expect(rewritten.contains(") ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_uca1400_ai_ci"))
        #expect(rewritten.contains("`id` int(11) NOT NULL AUTO_INCREMENT,"))
        #expect(!rewritten.contains("AUTO_INCREMENT=4"))
    }

    /// A column COMMENT and a quoted column name are the schema's own data. A pattern that cannot
    /// see quoting rewrites both, and the table comes back with a different column name.
    @Test("Quoted text is left alone")
    func quotedTextIsUntouched() {
        let rewritten = Self.stripping.rewrite(Self.createTable)
        #expect(rewritten.contains("COMMENT 'AUTO_INCREMENT=5 and DEFINER=`x`@`y` inside a comment'"))
        #expect(rewritten.contains("`weird AUTO_INCREMENT=9 col` int(11) DEFAULT NULL"))
    }

    @Test("A view loses its definer and keeps its security clause")
    func viewDefinerIsRemoved() {
        let rewritten = Self.stripping.rewrite(Self.createView)
        #expect(rewritten == "CREATE ALGORITHM=UNDEFINED SQL SECURITY DEFINER VIEW `v_users` "
            + "AS select `users`.`id` AS `id` from `users`")
    }

    /// Dropping SQL SECURITY along with the account, which is what `mysqlpump --skip-definer` does,
    /// turns a view the server runs as its caller into one it runs as its owner.
    @Test("An invoker-rights view stays invoker-rights")
    func invokerSecurityIsPreserved() {
        let ddl = "CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`localhost` "
            + "SQL SECURITY INVOKER VIEW `v_inv` AS select 1"
        #expect(Self.stripping.rewrite(ddl) == "CREATE ALGORITHM=UNDEFINED SQL SECURITY INVOKER VIEW `v_inv` AS select 1")
    }

    @Test("A definer with no host is removed")
    func currentUserDefinerIsRemoved() {
        let ddl = "CREATE DEFINER = CURRENT_USER SQL SECURITY DEFINER VIEW `v` AS select 1"
        #expect(Self.stripping.rewrite(ddl) == "CREATE SQL SECURITY DEFINER VIEW `v` AS select 1")
    }

    @Test("A quoted definer with spaces in it is removed whole")
    func quotedDefinerIsRemoved() {
        let ddl = "CREATE DEFINER='report user'@'10.0.0.%' SQL SECURITY DEFINER VIEW `v` AS select 1"
        #expect(Self.stripping.rewrite(ddl) == "CREATE SQL SECURITY DEFINER VIEW `v` AS select 1")
    }

    @Test("A trigger loses its definer")
    func triggerDefinerIsRemoved() {
        let ddl = "CREATE DEFINER=`root`@`localhost` TRIGGER `tr` BEFORE INSERT ON `users` "
            + "FOR EACH ROW SET NEW.name = NEW.name"
        #expect(Self.stripping.rewrite(ddl) == "CREATE TRIGGER `tr` BEFORE INSERT ON `users` "
            + "FOR EACH ROW SET NEW.name = NEW.name")
    }

    @Test("A clause that ends the statement takes the space before it")
    func trailingClauseLeavesNoGap() {
        #expect(Self.stripping.rewrite("CREATE TABLE `t` (`id` int) ENGINE=InnoDB AUTO_INCREMENT=4;")
            == "CREATE TABLE `t` (`id` int) ENGINE=InnoDB;")
        #expect(Self.stripping.rewrite("CREATE TABLE `t` (`id` int) ENGINE=InnoDB AUTO_INCREMENT=4")
            == "CREATE TABLE `t` (`id` int) ENGINE=InnoDB")
    }

    @Test("Whitespace around the clause is accepted")
    func spacedAssignmentIsRemoved() {
        #expect(Self.stripping.rewrite(") ENGINE=InnoDB AUTO_INCREMENT  =  17 DEFAULT CHARSET=utf8")
            == ") ENGINE=InnoDB DEFAULT CHARSET=utf8")
    }

    @Test("A word that only ends in the keyword is not a clause")
    func longerIdentifiersAreNotClauses() {
        #expect(Self.stripping.rewrite(") ENGINE=InnoDB COMMENT_AUTO_INCREMENT=4")
            == ") ENGINE=InnoDB COMMENT_AUTO_INCREMENT=4")
        #expect(Self.stripping.rewrite("CREATE my_definer=1 VIEW v AS select 1")
            == "CREATE my_definer=1 VIEW v AS select 1")
    }

    @Test("Text inside a comment is copied rather than rewritten")
    func commentTextIsUntouched() {
        let ddl = ") ENGINE=InnoDB -- AUTO_INCREMENT=9\nENGINE=InnoDB AUTO_INCREMENT=9"
        #expect(Self.stripping.rewrite(ddl) == ") ENGINE=InnoDB -- AUTO_INCREMENT=9\nENGINE=InnoDB")
        let block = "/* DEFINER=`a`@`b` */ CREATE DEFINER=`a`@`b` VIEW v AS select 1"
        #expect(Self.stripping.rewrite(block) == "/* DEFINER=`a`@`b` */ CREATE VIEW v AS select 1")
    }

    @Test("Each option only removes its own clause")
    func optionsAreIndependent() {
        let definerOnly = SQLExportDDLRewriter(
            dialect: .mysql, excludesAutoIncrementValue: false, excludesDefiner: true)
        let counterOnly = SQLExportDDLRewriter(
            dialect: .mysql, excludesAutoIncrementValue: true, excludesDefiner: false)
        let ddl = "CREATE DEFINER=`a`@`b` VIEW v AS select 1; ) ENGINE=InnoDB AUTO_INCREMENT=4;"
        #expect(definerOnly.rewrite(ddl) == "CREATE VIEW v AS select 1; ) ENGINE=InnoDB AUTO_INCREMENT=4;")
        #expect(counterOnly.rewrite(ddl) == "CREATE DEFINER=`a`@`b` VIEW v AS select 1; ) ENGINE=InnoDB;")
    }

    @Test("Both options off leaves the statement byte for byte")
    func disabledRewriterIsIdentity() {
        #expect(Self.keeping.rewrite(Self.createTable) == Self.createTable)
        #expect(Self.keeping.rewrite(Self.createView) == Self.createView)
    }

    @Test("An unterminated quote is copied rather than parsed past")
    func unterminatedQuoteIsCopied() {
        let ddl = ") ENGINE=InnoDB COMMENT 'oops AUTO_INCREMENT=4"
        #expect(Self.stripping.rewrite(ddl) == ddl)
    }

    // MARK: - Position

    /// `auto_increment` and `definer` are ordinary identifiers on other engines, and a driver hands
    /// back the catalog's own text. Taking the clause wherever it appears emptied the constraint:
    /// SQLite reported `CHECK (auto_increment = 4)` and the export wrote `CHECK ()`.
    @Test("A counter inside a constraint expression is not a table option")
    func constraintExpressionSurvives() {
        let ddl = "CREATE TABLE t (auto_increment int, CONSTRAINT c CHECK ((auto_increment = 4))) ENGINE=InnoDB AUTO_INCREMENT=7"
        #expect(Self.stripping.rewrite(ddl)
            == "CREATE TABLE t (auto_increment int, CONSTRAINT c CHECK ((auto_increment = 4))) ENGINE=InnoDB")
    }

    @Test("A definer column in a view body is not a definer clause")
    func viewBodyComparisonSurvives() {
        let ddl = "CREATE DEFINER=`root`@`localhost` SQL SECURITY DEFINER VIEW v AS select 1 where definer = CURRENT_USER"
        #expect(Self.stripping.rewrite(ddl)
            == "CREATE SQL SECURITY DEFINER VIEW v AS select 1 where definer = CURRENT_USER")
    }

    @Test("A statement that never opened a CREATE header keeps its definer text")
    func definerOutsideAHeaderSurvives() {
        let ddl = "ALTER TABLE t ADD COLUMN c int; UPDATE t SET definer = 'a'@'b'"
        #expect(Self.stripping.rewrite(ddl) == ddl)
    }

    /// Under `ANSI_QUOTES` the server quotes identifiers with `"` instead of a backtick. It still
    /// writes a literal backslash doubled and an embedded quote doubled, measured on MariaDB 12.3,
    /// so a name carrying a clause spelling reaches the scanner inside a quoted run either way.
    @Test("An ANSI_QUOTES identifier carrying a clause spelling is left alone")
    func ansiQuotedIdentifierSurvives() {
        let ddl = """
            CREATE TABLE "weird" (
              "a\\\\""b AUTO_INCREMENT=5" int(11) DEFAULT NULL
            ) ENGINE=InnoDB AUTO_INCREMENT=3 DEFAULT CHARSET=utf8mb4
            """
        let rewritten = Self.stripping.rewrite(ddl)
        #expect(rewritten.contains(#""a\\""b AUTO_INCREMENT=5" int(11) DEFAULT NULL"#))
        #expect(rewritten.hasSuffix(") ENGINE=InnoDB DEFAULT CHARSET=utf8mb4"))
    }

    // MARK: - Dialect

    /// The clauses are MySQL's spelling. Running the scan on another engine's DDL can only take
    /// something out of a statement that never had one.
    @Test("Another engine's DDL is handed back untouched")
    func otherDialectsArePassedThrough() {
        let sqlite = "CREATE TABLE t (auto_increment INTEGER, definer TEXT, CHECK (auto_increment = 4))"
        let postgres = """
            CREATE TABLE public.users (
                auto_increment integer,
                definer text,
                CONSTRAINT c CHECK ((auto_increment = 4))
            );
            """
        for dialect in [SqlDialect.sqlite, .postgres, .generic] {
            let rewriter = SQLExportDDLRewriter(
                dialect: dialect, excludesAutoIncrementValue: true, excludesDefiner: true)
            #expect(rewriter.rewrite(sqlite) == sqlite)
            #expect(rewriter.rewrite(postgres) == postgres)
        }
    }
}
