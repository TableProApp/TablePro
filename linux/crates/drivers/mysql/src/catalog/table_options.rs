use tablepro_core::ddl::TableOptions;

use crate::flavour::MySqlFlavour;

/// A table's options as one structure read finds them.
#[derive(Debug, Clone, Copy)]
pub(crate) struct ListedOptions<'a> {
    /// TABLES.TABLE_COLLATION, which is live and `None` for a view.
    pub collation: Option<&'a str>,
    /// TABLES.AUTO_INCREMENT.
    pub auto_increment: Option<u64>,
    pub create_statement: &'a str,
    /// Whether a column of the table numbers itself.
    pub numbered: bool,
}

/// The counter comes from SHOW CREATE TABLE on MySQL, whose TABLES value
/// is cached, and from TABLES on MariaDB, whose SHOW CREATE TABLE drops
/// the options line under NO_TABLE_OPTIONS. SHOW CREATE TABLE leaves it
/// out while it is 1.
pub(crate) fn table_options(listed: ListedOptions<'_>, flavour: MySqlFlavour) -> Option<TableOptions> {
    let collation = listed.collation?;
    let counter = match flavour {
        MySqlFlavour::MySql => printed_auto_increment(listed.create_statement),
        MySqlFlavour::MariaDb => listed
            .auto_increment
            .or_else(|| printed_auto_increment(listed.create_statement)),
    };
    Some(TableOptions {
        character_set: Some(character_set_of(collation).to_owned()),
        collation: Some(collation.to_owned()),
        next_auto_increment: listed.numbered.then_some(counter.unwrap_or(1)),
    })
}

/// A collation's name starts with its character set's, and no character
/// set's name has an underscore. MariaDB lists its UCA 14 collations in
/// COLLATIONS with no character set, so a join there finds none.
fn character_set_of(collation: &str) -> &str {
    collation.split('_').next().unwrap_or(collation)
}

/// AUTO_INCREMENT= on the options line. The server prints it before any
/// quoted option, so a table COMMENT that holds the same text is never read.
fn printed_auto_increment(create_statement: &str) -> Option<u64> {
    let line = options_line(create_statement)?;
    let unquoted = line.split('\'').next().unwrap_or_default();
    let (_, rest) = unquoted.split_once(" AUTO_INCREMENT=")?;
    let digits: String = rest.chars().take_while(char::is_ascii_digit).collect();
    digits.parse().ok()
}

/// The rest of the line that closes the column list. A quoted name or
/// default can hold a newline and a `)`, so the list is walked with its
/// quotes rather than by lines.
fn options_line(create_statement: &str) -> Option<&str> {
    let mut depth = 0usize;
    let mut quote: Option<char> = None;
    let mut chars = create_statement.char_indices().peekable();
    while let Some((index, c)) = chars.next() {
        if let Some(open) = quote {
            if c == '\\' && open == '\'' {
                chars.next();
            } else if c == open {
                match chars.peek() {
                    Some((_, next)) if *next == open => {
                        chars.next();
                    }
                    _ => quote = None,
                }
            }
            continue;
        }
        match c {
            '`' | '\'' | '"' => quote = Some(c),
            '(' => depth += 1,
            ')' => {
                depth = depth.checked_sub(1)?;
                if depth == 0 {
                    let rest = create_statement.get(index + 1..)?;
                    return rest.split('\n').next();
                }
            }
            _ => {}
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    const COUNTED: &str = "CREATE TABLE `t` (\n  `id` int NOT NULL AUTO_INCREMENT COMMENT ') AUTO_INCREMENT=7',\n  \
                           PRIMARY KEY (`id`)\n) ENGINE=InnoDB AUTO_INCREMENT=42 DEFAULT CHARSET=latin1 \
                           COMMENT=' AUTO_INCREMENT=99'\n/*!50100 PARTITION BY HASH (`id`)\nPARTITIONS 2 */";

    fn listed(create_statement: &str, numbered: bool) -> ListedOptions<'_> {
        ListedOptions {
            collation: Some("latin1_swedish_ci"),
            auto_increment: Some(4),
            create_statement,
            numbered,
        }
    }

    #[test]
    fn a_quoted_name_that_holds_a_closing_line_is_not_the_options_line() {
        let statement = "CREATE TABLE `t` (\n  `id` int NOT NULL AUTO_INCREMENT,\n  `note\n) AUTO_INCREMENT=999` int,\n  \
                         PRIMARY KEY (`id`)\n) ENGINE=InnoDB AUTO_INCREMENT=42 DEFAULT CHARSET=latin1";
        assert_eq!(printed_auto_increment(statement), Some(42));
    }

    #[test]
    fn the_counter_is_read_from_the_options_line_only() {
        assert_eq!(printed_auto_increment(COUNTED), Some(42));
        assert_eq!(
            printed_auto_increment("CREATE TABLE `t` (\n  `id` int\n) ENGINE=InnoDB COMMENT=' AUTO_INCREMENT=99'"),
            None
        );
    }

    #[test]
    fn mysql_reads_the_printed_counter_and_mariadb_the_listed_one() {
        let mysql = table_options(listed(COUNTED, true), MySqlFlavour::MySql);
        let mariadb = table_options(listed(COUNTED, true), MySqlFlavour::MariaDb);

        assert_eq!(
            mysql,
            Some(TableOptions {
                character_set: Some("latin1".to_owned()),
                collation: Some("latin1_swedish_ci".to_owned()),
                next_auto_increment: Some(42),
            })
        );
        assert_eq!(mariadb.and_then(|options| options.next_auto_increment), Some(4));
    }

    #[test]
    fn a_numbered_table_without_a_printed_counter_is_at_one_and_others_have_none() {
        let fresh = "CREATE TABLE `t` (\n  `id` int NOT NULL AUTO_INCREMENT,\n  PRIMARY KEY (`id`)\n) ENGINE=InnoDB";

        let numbered = table_options(listed(fresh, true), MySqlFlavour::MySql);
        let plain = table_options(listed(fresh, false), MySqlFlavour::MariaDb);
        let view = table_options(
            ListedOptions {
                collation: None,
                ..listed(fresh, false)
            },
            MySqlFlavour::MySql,
        );

        assert_eq!(numbered.and_then(|options| options.next_auto_increment), Some(1));
        assert_eq!(plain.map(|options| options.next_auto_increment), Some(None));
        assert_eq!(view, None);
    }

    #[test]
    fn the_character_set_is_the_collations_first_word() {
        assert_eq!(character_set_of("utf8mb4_uca1400_ai_ci"), "utf8mb4");
        assert_eq!(character_set_of("utf8mb3_general_ci"), "utf8mb3");
        assert_eq!(character_set_of("binary"), "binary");
    }
}
