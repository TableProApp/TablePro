//! The words each engine will not read as a plain name.
//!
//! PostgreSQL's reserved and type-or-function categories, the reserved
//! words of MySQL 8.4 and MariaDB, the T-SQL reserved keywords and all
//! of SQLite's keywords. ClickHouse reserves nothing, so its list holds
//! the words its parser takes as a clause, an operator or a literal
//! wherever they stand.

use crate::sql_syntax::SqlGrammar;

const POSTGRESQL: &str = "
    ALL ANALYSE ANALYZE AND ANY ARRAY AS ASC ASYMMETRIC AUTHORIZATION BINARY BOTH CASE CAST CHECK COLLATE
    COLLATION COLUMN CONCURRENTLY CONSTRAINT CREATE CROSS CURRENT_CATALOG CURRENT_DATE CURRENT_ROLE
    CURRENT_SCHEMA CURRENT_TIME CURRENT_TIMESTAMP CURRENT_USER DEFAULT DEFERRABLE DESC DISTINCT DO ELSE END
    EXCEPT FALSE FETCH FOR FOREIGN FREEZE FROM FULL GRANT GROUP HAVING ILIKE IN INITIALLY INNER INTERSECT
    INTO IS ISNULL JOIN LATERAL LEADING LEFT LIKE LIMIT LOCALTIME LOCALTIMESTAMP NATURAL NOT NOTNULL NULL
    OFFSET ON ONLY OR ORDER OUTER OVERLAPS PLACING PRIMARY REFERENCES RETURNING RIGHT SELECT SESSION_USER
    SIMILAR SOME SYMMETRIC SYSTEM_USER TABLE TABLESAMPLE THEN TO TRAILING TRUE UNION UNIQUE USER USING
    VARIADIC VERBOSE WHEN WHERE WINDOW WITH
";

const MYSQL: &str = "
    ACCESSIBLE ADD ALL ALTER ANALYZE AND AS ASC ASENSITIVE BEFORE BETWEEN BIGINT BINARY BLOB BOTH BY CALL
    CASCADE CASE CHANGE CHAR CHARACTER CHECK COLLATE COLUMN CONDITION CONSTRAINT CONTINUE CONVERT CREATE
    CROSS CUBE CUME_DIST CURRENT_DATE CURRENT_ROLE CURRENT_TIME CURRENT_TIMESTAMP CURRENT_USER CURSOR
    DATABASE DATABASES DAY_HOUR DAY_MICROSECOND DAY_MINUTE DAY_SECOND DEC DECIMAL DECLARE DEFAULT DELAYED
    DELETE DELETE_DOMAIN_ID DENSE_RANK DESC DESCRIBE DETERMINISTIC DISTINCT DISTINCTROW DIV DOUBLE
    DO_DOMAIN_IDS DROP DUAL EACH ELSE ELSEIF EMPTY ENCLOSED ESCAPED EXCEPT EXISTS EXIT EXPLAIN FALSE FETCH
    FIRST_VALUE FLOAT FLOAT4 FLOAT8 FOR FORCE FOREIGN FROM FULLTEXT FUNCTION GENERAL GENERATED GET GRANT
    GROUP GROUPING GROUPS HAVING HIGH_PRIORITY HOUR_MICROSECOND HOUR_MINUTE HOUR_SECOND IF IGNORE
    IGNORE_DOMAIN_IDS IGNORE_SERVER_IDS IN INDEX INFILE INNER INOUT INSENSITIVE INSERT INT INT1 INT2 INT3
    INT4 INT8 INTEGER INTERSECT INTERVAL INTO IO_AFTER_GTIDS IO_BEFORE_GTIDS IS ITERATE JOIN JSON_TABLE KEY
    KEYS KILL LAG LAST_VALUE LATERAL LEAD LEADING LEAVE LEFT LIKE LIMIT LINEAR LINES LOAD LOCALTIME
    LOCALTIMESTAMP LOCK LONG LONGBLOB LONGTEXT LOOP LOW_PRIORITY MASTER_BIND MASTER_HEARTBEAT_PERIOD
    MASTER_SSL_VERIFY_SERVER_CERT MATCH MAXVALUE MEDIUMBLOB MEDIUMINT MEDIUMTEXT MIDDLEINT
    MINUTE_MICROSECOND MINUTE_SECOND MOD MODIFIES NATURAL NOT NO_WRITE_TO_BINLOG NTH_VALUE NTILE NULL
    NUMERIC OF OFFSET ON OPTIMIZE OPTIMIZER_COSTS OPTION OPTIONALLY OR ORDER OUT OUTER OUTFILE OVER
    PAGE_CHECKSUM PARALLEL PARSE_VCOL_EXPR PARTITION PERCENT_RANK PRECISION PRIMARY PROCEDURE PURGE QUALIFY
    RANGE RANK READ READS READ_WRITE REAL RECURSIVE REFERENCES REF_SYSTEM_ID REGEXP RELEASE RENAME REPEAT
    REPLACE REQUIRE RESIGNAL RESTRICT RETURN RETURNING REVOKE RIGHT RLIKE ROW ROWS ROW_NUMBER SCHEMA SCHEMAS
    SECOND_MICROSECOND SELECT SENSITIVE SEPARATOR SET SHOW SIGNAL SLOW SMALLINT SPATIAL SPECIFIC SQL
    SQLEXCEPTION SQLSTATE SQLWARNING SQL_BIG_RESULT SQL_CALC_FOUND_ROWS SQL_SMALL_RESULT SSL STARTING
    STATS_AUTO_RECALC STATS_PERSISTENT STATS_SAMPLE_PAGES STORED STRAIGHT_JOIN SYSTEM TABLE TABLESAMPLE
    TERMINATED THEN TINYBLOB TINYINT TINYTEXT TO TRAILING TRIGGER TRUE UNDO UNION UNIQUE UNLOCK UNSIGNED
    UPDATE USAGE USE USING UTC_DATE UTC_TIME UTC_TIMESTAMP VALUES VARBINARY VARCHAR VARCHARACTER VARYING
    VIRTUAL WHEN WHERE WHILE WINDOW WITH WRITE XOR YEAR_MONTH ZEROFILL
";

const SQLITE: &str = "
    ABORT ACTION ADD AFTER ALL ALTER ALWAYS ANALYZE AND AS ASC ATTACH AUTOINCREMENT BEFORE BEGIN BETWEEN BY
    CASCADE CASE CAST CHECK COLLATE COLUMN COMMIT CONFLICT CONSTRAINT CREATE CROSS CURRENT CURRENT_DATE
    CURRENT_TIME CURRENT_TIMESTAMP DATABASE DEFAULT DEFERRABLE DEFERRED DELETE DESC DETACH DISTINCT DO DROP
    EACH ELSE END ESCAPE EXCEPT EXCLUDE EXCLUSIVE EXISTS EXPLAIN FAIL FILTER FIRST FOLLOWING FOR FOREIGN
    FROM FULL GENERATED GLOB GROUP GROUPS HAVING IF IGNORE IMMEDIATE IN INDEX INDEXED INITIALLY INNER INSERT
    INSTEAD INTERSECT INTO IS ISNULL JOIN KEY LAST LEFT LIKE LIMIT MATCH MATERIALIZED NATURAL NO NOT NOTHING
    NOTNULL NULL NULLS OF OFFSET ON OR ORDER OTHERS OUTER OVER PARTITION PLAN PRAGMA PRECEDING PRIMARY QUERY
    RAISE RANGE RECURSIVE REFERENCES REGEXP REINDEX RELEASE RENAME REPLACE RESTRICT RETURNING RIGHT ROLLBACK
    ROW ROWS SAVEPOINT SELECT SET TABLE TEMP TEMPORARY THEN TIES TO TRANSACTION TRIGGER UNBOUNDED UNION
    UNIQUE UPDATE USING VACUUM VALUES VIEW VIRTUAL WHEN WHERE WINDOW WITH WITHOUT
";

const MSSQL: &str = "
    ADD ALL ALTER AND ANY AS ASC AUTHORIZATION BACKUP BEGIN BETWEEN BREAK BROWSE BULK BY CASCADE CASE CHECK
    CHECKPOINT CLOSE CLUSTERED COALESCE COLLATE COLUMN COMMIT COMPUTE CONSTRAINT CONTAINS CONTAINSTABLE
    CONTINUE CONVERT CREATE CROSS CURRENT CURRENT_DATE CURRENT_TIME CURRENT_TIMESTAMP CURRENT_USER CURSOR
    DATABASE DBCC DEALLOCATE DECLARE DEFAULT DELETE DENY DESC DISK DISTINCT DISTRIBUTED DOUBLE DROP DUMP
    ELSE END ERRLVL ESCAPE EXCEPT EXEC EXECUTE EXISTS EXIT EXTERNAL FETCH FILE FILLFACTOR FOR FOREIGN
    FREETEXT FREETEXTTABLE FROM FULL FUNCTION GOTO GRANT GROUP HAVING HOLDLOCK IDENTITY IDENTITYCOL
    IDENTITY_INSERT IF IN INDEX INNER INSERT INTERSECT INTO IS JOIN KEY KILL LEFT LIKE LINENO LOAD MERGE
    NATIONAL NOCHECK NONCLUSTERED NOT NULL NULLIF OF OFF OFFSETS ON OPEN OPENDATASOURCE OPENQUERY OPENROWSET
    OPENXML OPTION OR ORDER OUTER OVER PERCENT PIVOT PLAN PRECISION PRIMARY PRINT PROC PROCEDURE PUBLIC
    RAISERROR READ READTEXT RECONFIGURE REFERENCES REPLICATION RESTORE RESTRICT RETURN REVERT REVOKE RIGHT
    ROLLBACK ROWCOUNT ROWGUIDCOL RULE SAVE SCHEMA SECURITYAUDIT SELECT SEMANTICKEYPHRASETABLE
    SEMANTICSIMILARITYDETAILSTABLE SEMANTICSIMILARITYTABLE SESSION_USER SET SETUSER SHUTDOWN SOME STATISTICS
    SYSTEM_USER TABLE TABLESAMPLE TEXTSIZE THEN TO TOP TRAN TRANSACTION TRIGGER TRUNCATE TRY_CONVERT TSEQUAL
    UNION UNIQUE UNPIVOT UPDATE UPDATETEXT USE USER VALUES VARYING VIEW WAITFOR WHEN WHERE WHILE WITH WITHIN
    WRITETEXT
";

const CLICKHOUSE: &str = "
    ALL AND ANTI ANY ARRAY AS ASC ASOF BETWEEN BY CASE CAST CROSS DESC DISTINCT ELSE END EXCEPT EXISTS FALSE
    FINAL FORMAT FROM FULL GLOBAL GROUP HAVING ILIKE IN INF INNER INTERSECT INTERVAL INTO IS JOIN LEFT LIKE
    LIMIT NAN NOT NULL OFFSET ON ONLY OR ORDER OUTER PASTE PREWHERE QUALIFY RIGHT SAMPLE SELECT SEMI
    SETTINGS THEN TO TOP TRUE UNION USING WHEN WHERE WINDOW WITH
";

impl SqlGrammar {
    /// Whether `name` reads as the same identifier written without
    /// quotes.
    ///
    /// PostgreSQL folds an unquoted name to lower case, so a capital
    /// changes the name there.
    pub fn is_bare_identifier(self, name: &str) -> bool {
        let mut chars = name.chars();
        let Some(first) = chars.next() else {
            return false;
        };
        let letter = |c: char| match self {
            Self::ClickHouse => c.is_ascii_alphabetic(),
            _ => c.is_alphabetic(),
        };
        let start = letter(first) || first == '_' || (self == Self::MsSql && first == '#');
        let part = |c: char| {
            letter(c)
                || c.is_ascii_digit()
                || c == '_'
                || (c == '$' && self != Self::ClickHouse)
                || (self == Self::MsSql && matches!(c, '#' | '@'))
        };
        let folds = self == Self::PostgreSql && name.chars().any(char::is_uppercase);
        start && chars.all(part) && !folds && !self.is_reserved(name)
    }

    fn is_reserved(self, word: &str) -> bool {
        self.reserved_words()
            .split_ascii_whitespace()
            .any(|reserved| reserved.eq_ignore_ascii_case(word))
    }

    fn reserved_words(self) -> &'static str {
        match self {
            Self::PostgreSql => POSTGRESQL,
            Self::MySql => MYSQL,
            Self::Sqlite => SQLITE,
            Self::MsSql => MSSQL,
            Self::ClickHouse => CLICKHOUSE,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn each_list_is_upper_case_sorted_and_listed_once() {
        for grammar in SqlGrammar::ALL {
            let words: Vec<&str> = grammar.reserved_words().split_ascii_whitespace().collect();
            for pair in words.windows(2) {
                assert!(pair[0] < pair[1], "{} before {} for {grammar:?}", pair[0], pair[1]);
            }
            for word in words {
                assert_eq!(word, word.to_ascii_uppercase(), "{grammar:?}");
            }
        }
    }

    #[test]
    fn plain_names_stay_bare() {
        for grammar in SqlGrammar::ALL {
            assert!(grammar.is_bare_identifier("users"), "{grammar:?}");
            assert!(grammar.is_bare_identifier("order_items_2"), "{grammar:?}");
            assert!(grammar.is_bare_identifier("_draft"), "{grammar:?}");
        }
        assert!(SqlGrammar::PostgreSql.is_bare_identifier("đơn_hàng"));
        assert!(SqlGrammar::MySql.is_bare_identifier("Users"));
        assert!(SqlGrammar::MsSql.is_bare_identifier("#scratch"));
    }

    #[test]
    fn a_function_name_the_editor_completes_stays_bare() {
        for grammar in [SqlGrammar::PostgreSql, SqlGrammar::MySql, SqlGrammar::ClickHouse] {
            assert!(grammar.is_bare_identifier("count"), "{grammar:?}");
        }
        assert!(SqlGrammar::ClickHouse.is_bare_identifier("engine"));
    }

    #[test]
    fn names_that_read_differently_bare_need_quotes() {
        for grammar in SqlGrammar::ALL {
            assert!(!grammar.is_bare_identifier(""), "{grammar:?}");
            assert!(!grammar.is_bare_identifier("order items"), "{grammar:?}");
            assert!(!grammar.is_bare_identifier("2fa"), "{grammar:?}");
            assert!(!grammar.is_bare_identifier("order"), "{grammar:?}");
            assert!(!grammar.is_bare_identifier("a-b"), "{grammar:?}");
        }
        assert!(!SqlGrammar::PostgreSql.is_bare_identifier("Users"));
        assert!(!SqlGrammar::ClickHouse.is_bare_identifier("đơn"));
        assert!(!SqlGrammar::ClickHouse.is_bare_identifier("a$b"));
    }

    #[test]
    fn reserved_words_the_editor_does_not_complete_need_quotes() {
        for grammar in SqlGrammar::ALL {
            assert!(!grammar.is_bare_identifier("to"), "{grammar:?}");
            assert!(!grammar.is_bare_identifier("TO"), "{grammar:?}");
        }
        assert!(!SqlGrammar::MsSql.is_bare_identifier("user"));
        assert!(!SqlGrammar::PostgreSql.is_bare_identifier("user"));
        assert!(!SqlGrammar::PostgreSql.is_bare_identifier("current_date"));
        for word in ["rank", "range", "interval", "condition", "groups", "rows", "system"] {
            assert!(!SqlGrammar::MySql.is_bare_identifier(word), "{word}");
        }
        assert!(!SqlGrammar::Sqlite.is_bare_identifier("current_timestamp"));
        assert!(!SqlGrammar::ClickHouse.is_bare_identifier("nan"));
    }
}
