use crate::sql_syntax::SqlGrammar;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct LexicalSettings {
    pub backslash_escapes: bool,
    pub ansi_quotes: bool,
}

impl LexicalSettings {
    pub const ALL: [Self; 4] = [
        Self::new(false, false),
        Self::new(false, true),
        Self::new(true, false),
        Self::new(true, true),
    ];

    const fn new(backslash_escapes: bool, ansi_quotes: bool) -> Self {
        Self {
            backslash_escapes,
            ansi_quotes,
        }
    }

    pub fn default_for(grammar: SqlGrammar) -> Self {
        let backslash_escapes = match grammar {
            SqlGrammar::MySql | SqlGrammar::ClickHouse => true,
            SqlGrammar::PostgreSql | SqlGrammar::Sqlite | SqlGrammar::MsSql => false,
        };
        Self::new(backslash_escapes, false)
    }

    pub fn from_mysql_sql_mode(sql_mode: &str) -> Self {
        let has = |name: &str| sql_mode.split(',').any(|mode| mode.trim().eq_ignore_ascii_case(name));
        Self::new(!has("NO_BACKSLASH_ESCAPES"), has("ANSI_QUOTES") || has("ANSI"))
    }

    pub fn from_postgres_standard_conforming_strings(value: &str) -> Option<Self> {
        match value.trim().to_ascii_lowercase().as_str() {
            "on" => Some(Self::new(false, false)),
            "off" => Some(Self::new(true, false)),
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mysql_sql_mode_is_read_as_a_comma_list_of_exact_names() {
        let read = LexicalSettings::from_mysql_sql_mode;
        assert_eq!(
            read("STRICT_TRANS_TABLES,NO_BACKSLASH_ESCAPES"),
            LexicalSettings::new(false, false)
        );
        assert_eq!(read("ANSI_QUOTES"), LexicalSettings::new(true, true));
        assert_eq!(
            read("REAL_AS_FLOAT,PIPES_AS_CONCAT,ANSI,ONLY_FULL_GROUP_BY"),
            LexicalSettings::new(true, true)
        );
        assert_eq!(read(""), LexicalSettings::default_for(SqlGrammar::MySql));
        assert_eq!(
            read("NO_BACKSLASH_ESCAPES_X,ANSI_QUOTES_X"),
            LexicalSettings::new(true, false)
        );
    }

    #[test]
    fn postgres_standard_conforming_strings_off_makes_ordinary_strings_take_backslashes() {
        let read = LexicalSettings::from_postgres_standard_conforming_strings;
        assert_eq!(read("on"), Some(LexicalSettings::default_for(SqlGrammar::PostgreSql)));
        assert_eq!(read("OFF"), Some(LexicalSettings::new(true, false)));
        assert_eq!(read("maybe"), None);
    }

    #[test]
    fn all_lists_each_combination_once() {
        let all = LexicalSettings::ALL;
        for (index, settings) in all.iter().enumerate() {
            assert!(!all[index + 1..].contains(settings));
        }
    }
}
