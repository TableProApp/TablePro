use tablepro_core::dump::{DumpDialect, DumpStatement};

use crate::dialect::MySqlDialect;
use crate::flavour::MySqlFlavour;

/// mysqldump 8.4's opening lines: the session's settings saved, then the
/// ones every load needs. Foreign keys go unchecked, so tables load in
/// any order, and `NO_AUTO_VALUE_ON_ZERO` keeps a row whose key is 0.
const HEADER: &str = "\
/*!40101 SET @OLD_CHARACTER_SET_CLIENT=@@CHARACTER_SET_CLIENT */;
/*!40101 SET @OLD_CHARACTER_SET_RESULTS=@@CHARACTER_SET_RESULTS */;
/*!40101 SET @OLD_COLLATION_CONNECTION=@@COLLATION_CONNECTION */;
/*!50503 SET NAMES utf8mb4 */;
/*!40103 SET @OLD_TIME_ZONE=@@TIME_ZONE */;
/*!40103 SET TIME_ZONE='+00:00' */;
/*!40014 SET @OLD_UNIQUE_CHECKS=@@UNIQUE_CHECKS, UNIQUE_CHECKS=0 */;
/*!40014 SET @OLD_FOREIGN_KEY_CHECKS=@@FOREIGN_KEY_CHECKS, FOREIGN_KEY_CHECKS=0 */;
/*!40101 SET @OLD_SQL_MODE=@@SQL_MODE, SQL_MODE='NO_AUTO_VALUE_ON_ZERO' */;
";

const FOOTER: &str = "\
/*!40103 SET TIME_ZONE=@OLD_TIME_ZONE */;

/*!40101 SET SQL_MODE=@OLD_SQL_MODE */;
/*!40014 SET FOREIGN_KEY_CHECKS=@OLD_FOREIGN_KEY_CHECKS */;
/*!40014 SET UNIQUE_CHECKS=@OLD_UNIQUE_CHECKS */;
/*!40101 SET CHARACTER_SET_CLIENT=@OLD_CHARACTER_SET_CLIENT */;
/*!40101 SET CHARACTER_SET_RESULTS=@OLD_CHARACTER_SET_RESULTS */;
/*!40101 SET COLLATION_CONNECTION=@OLD_COLLATION_CONNECTION */;
";

impl MySqlDialect {
    /// mariadb-dump writes `NOTE_VERBOSITY`, which MariaDB 10.6.16 added,
    /// in place of `SQL_NOTES`, in a comment only MariaDB runs.
    fn notes(&self, saving: bool) -> &'static str {
        match (self.flavour(), saving) {
            (MySqlFlavour::MySql, true) => "/*!40111 SET @OLD_SQL_NOTES=@@SQL_NOTES, SQL_NOTES=0 */;\n",
            (MySqlFlavour::MySql, false) => "/*!40111 SET SQL_NOTES=@OLD_SQL_NOTES */;\n",
            (MySqlFlavour::MariaDb, true) => {
                "/*M!100616 SET @OLD_NOTE_VERBOSITY=@@NOTE_VERBOSITY, NOTE_VERBOSITY=0 */;\n"
            }
            (MySqlFlavour::MariaDb, false) => "/*M!100616 SET NOTE_VERBOSITY=@OLD_NOTE_VERBOSITY */;\n",
        }
    }
}

impl DumpDialect for MySqlDialect {
    fn header(&self) -> String {
        format!("\n{HEADER}{}", self.notes(true))
    }

    fn footer(&self) -> String {
        format!("\n{FOOTER}{}", self.notes(false))
    }

    /// A body holds semicolons of its own, which the mysql client reads
    /// as one statement only under another delimiter.
    fn statement(&self, statement: &DumpStatement) -> String {
        match statement.body {
            true => format!("DELIMITER ;;\n{} ;;\nDELIMITER ;\n", statement.sql),
            false => format!("{};\n", statement.sql),
        }
    }
}

#[cfg(test)]
mod tests {
    use tablepro_core::ServerInfo;

    use super::*;

    fn dialect(flavour: MySqlFlavour) -> MySqlDialect {
        MySqlDialect::new(flavour, &ServerInfo::new(flavour.product(), "8.4.3", 8, 4, 3))
    }

    #[test]
    fn mysql_saves_and_restores_its_notes_setting() {
        let mysql = dialect(MySqlFlavour::MySql);

        assert!(mysql.header().starts_with("\n/*!40101 SET @OLD_CHARACTER_SET_CLIENT"));
        assert!(mysql.header().ends_with(
            "SQL_MODE='NO_AUTO_VALUE_ON_ZERO' */;\n/*!40111 SET @OLD_SQL_NOTES=@@SQL_NOTES, SQL_NOTES=0 */;\n"
        ));
        assert!(mysql.footer().ends_with("/*!40111 SET SQL_NOTES=@OLD_SQL_NOTES */;\n"));
        assert!(!mysql.header().contains("NOTE_VERBOSITY"));
    }

    #[test]
    fn mariadb_saves_and_restores_its_note_verbosity_instead() {
        let mariadb = dialect(MySqlFlavour::MariaDb);

        assert!(
            mariadb
                .header()
                .ends_with("/*M!100616 SET @OLD_NOTE_VERBOSITY=@@NOTE_VERBOSITY, NOTE_VERBOSITY=0 */;\n")
        );
        assert!(
            mariadb
                .footer()
                .ends_with("/*M!100616 SET NOTE_VERBOSITY=@OLD_NOTE_VERBOSITY */;\n")
        );
        assert!(!mariadb.header().contains("SQL_NOTES"));
        assert!(!mariadb.header().contains("sandbox"));
    }

    #[test]
    fn a_body_goes_in_a_delimiter_block_and_the_rest_ends_in_a_semicolon() {
        let mysql = dialect(MySqlFlavour::MySql);

        assert_eq!(
            mysql.statement(&DumpStatement::body("CREATE PROCEDURE `p`()\nBEGIN SELECT 1; END")),
            "DELIMITER ;;\nCREATE PROCEDURE `p`()\nBEGIN SELECT 1; END ;;\nDELIMITER ;\n"
        );
        assert_eq!(
            mysql.statement(&DumpStatement::new("SET sql_mode = @saved_sql_mode")),
            "SET sql_mode = @saved_sql_mode;\n"
        );
        assert!(!mysql.transactional_ddl());
    }
}
