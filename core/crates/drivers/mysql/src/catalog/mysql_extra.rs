//! The EXTRA column of `information_schema.COLUMNS`, which packs several
//! unrelated attributes into one string. MySQL separates them with
//! spaces and MariaDB with `, `, as in `VIRTUAL GENERATED, INVISIBLE`.

/// How a generated column keeps its value. MariaDB spells STORED as
/// PERSISTENT too.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum ExtraGenerated {
    Virtual,
    Stored,
    Persistent,
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub(crate) struct MySqlExtra {
    pub auto_increment: bool,
    /// MySQL 8.0.13 and later mark an expression default this way, which
    /// is the only thing telling `CURRENT_TIMESTAMP` the function from
    /// the text.
    pub default_generated: bool,
    /// The expression of `ON UPDATE`, in the server's own spelling.
    pub on_update: Option<String>,
    pub generated: Option<ExtraGenerated>,
    pub invisible: bool,
    /// Words this build does not model, such as MariaDB's `WITHOUT
    /// SYSTEM VERSIONING`, kept so the structure tab can say they exist.
    pub unmodeled: Vec<String>,
}

impl MySqlExtra {
    pub(crate) fn parse(extra: &str) -> Self {
        let words: Vec<&str> = extra
            .split(|character: char| character.is_whitespace() || character == ',')
            .filter(|word| !word.is_empty())
            .collect();
        let lower: Vec<String> = words.iter().map(|word| word.to_ascii_lowercase()).collect();
        let mut parsed = Self::default();
        let mut leftover: Vec<&str> = Vec::new();
        let mut index = 0;
        while index < words.len() {
            let next = lower.get(index + 1).map(String::as_str);
            match (lower[index].as_str(), next) {
                ("auto_increment", _) => parsed.auto_increment = true,
                ("default_generated", _) => parsed.default_generated = true,
                ("invisible", _) => parsed.invisible = true,
                ("virtual" | "stored" | "persistent", Some("generated")) => {
                    parsed.generated = Some(match lower[index].as_str() {
                        "virtual" => ExtraGenerated::Virtual,
                        "stored" => ExtraGenerated::Stored,
                        _ => ExtraGenerated::Persistent,
                    });
                    index += 1;
                }
                ("on", Some("update")) => match words.get(index + 2) {
                    Some(expression) => {
                        parsed.on_update = Some((*expression).to_owned());
                        index += 2;
                    }
                    None => leftover.extend(&words[index..]),
                },
                _ => leftover.push(words[index]),
            }
            index += 1;
        }
        if !leftover.is_empty() {
            parsed.unmodeled.push(leftover.join(" "));
        }
        parsed
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mysql_extra_parses_all_known_tokens_and_reports_unknown() {
        assert!(MySqlExtra::parse("auto_increment").auto_increment);

        let stamped = MySqlExtra::parse("DEFAULT_GENERATED on update CURRENT_TIMESTAMP(3)");
        assert!(stamped.default_generated);
        assert_eq!(stamped.on_update.as_deref(), Some("CURRENT_TIMESTAMP(3)"));
        assert!(stamped.unmodeled.is_empty());

        assert_eq!(
            MySqlExtra::parse("VIRTUAL GENERATED").generated,
            Some(ExtraGenerated::Virtual)
        );
        assert_eq!(
            MySqlExtra::parse("STORED GENERATED INVISIBLE"),
            MySqlExtra {
                generated: Some(ExtraGenerated::Stored),
                invisible: true,
                ..MySqlExtra::default()
            }
        );
        assert_eq!(
            MySqlExtra::parse("PERSISTENT GENERATED").generated,
            Some(ExtraGenerated::Persistent)
        );
        assert_eq!(
            MySqlExtra::parse("on update current_timestamp()").on_update.as_deref(),
            Some("current_timestamp()")
        );

        assert_eq!(
            MySqlExtra::parse("on update current_timestamp(3), INVISIBLE"),
            MySqlExtra {
                on_update: Some("current_timestamp(3)".to_owned()),
                invisible: true,
                ..MySqlExtra::default()
            }
        );
        assert_eq!(
            MySqlExtra::parse("VIRTUAL GENERATED, INVISIBLE"),
            MySqlExtra {
                generated: Some(ExtraGenerated::Virtual),
                invisible: true,
                ..MySqlExtra::default()
            }
        );
        assert_eq!(
            MySqlExtra::parse("auto_increment, INVISIBLE"),
            MySqlExtra {
                auto_increment: true,
                invisible: true,
                ..MySqlExtra::default()
            }
        );

        let versioned = MySqlExtra::parse("WITHOUT SYSTEM VERSIONING");
        assert_eq!(versioned.unmodeled, ["WITHOUT SYSTEM VERSIONING"]);
        assert_eq!(MySqlExtra::parse(""), MySqlExtra::default());
    }
}
