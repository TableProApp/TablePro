use std::collections::HashMap;

use crate::sql_syntax::SqlGrammar;

use super::LexicalSettings;

/// How a session setting decides whether a backslash escapes in a string,
/// followed through a script as its statements set it: PostgreSQL's
/// `standard_conforming_strings`, and MySQL's `sql_mode` with or without
/// `NO_BACKSLASH_ESCAPES`, saved in a user variable and set back as
/// mysqldump does.
#[derive(Debug, Default)]
pub(crate) struct LexicalTracker {
    /// The escape setting each user variable holds a saved `sql_mode` of.
    saved: HashMap<String, bool>,
}

impl LexicalTracker {
    /// The settings after `statement` runs, when it changes them.
    pub(crate) fn after(
        &mut self,
        statement: &str,
        grammar: SqlGrammar,
        current: LexicalSettings,
    ) -> Option<LexicalSettings> {
        let assignments = set_assignments(statement)?;
        let mut escapes = current.backslash_escapes;
        for (target, value) in assignments {
            let target = target.to_ascii_lowercase();
            match grammar {
                SqlGrammar::PostgreSql if setting_name(&target) == "standard_conforming_strings" => {
                    match unquoted(&value).to_ascii_lowercase().as_str() {
                        "on" | "true" | "1" => escapes = false,
                        "off" | "false" | "0" => escapes = true,
                        _ => {}
                    }
                }
                SqlGrammar::MySql if setting_name(&target) == "sql_mode" => {
                    if let Some(variable) = value.strip_prefix('@').filter(|value| !value.starts_with('@')) {
                        if let Some(saved) = self.saved.get(&variable.to_ascii_lowercase()) {
                            escapes = *saved;
                        }
                    } else if value.starts_with('\'') || value.starts_with('"') {
                        escapes = !value.to_ascii_uppercase().contains("NO_BACKSLASH_ESCAPES");
                    }
                }
                SqlGrammar::MySql if target.starts_with('@') && !target.starts_with("@@") => {
                    if setting_name(&value.to_ascii_lowercase()) == "sql_mode" && value.starts_with("@@") {
                        self.saved.insert(target.trim_start_matches('@').to_owned(), escapes);
                    }
                }
                _ => {}
            }
        }
        (escapes != current.backslash_escapes).then_some(LexicalSettings {
            backslash_escapes: escapes,
        })
    }
}

/// `sql_mode` from `@@session.sql_mode`, `SESSION sql_mode` and the like.
fn setting_name(target: &str) -> &str {
    let name = target.rsplit(['.', ' ']).next().unwrap_or(target);
    name.trim_start_matches('@')
}

fn unquoted(value: &str) -> &str {
    value.trim_matches(|character| character == '\'' || character == '"')
}

/// The `target = value` pairs of a SET statement, MySQL's executable
/// comment markers taken off. `None` for any other statement.
fn set_assignments(statement: &str) -> Option<Vec<(String, String)>> {
    let code = without_executable_markers(statement);
    let code = code.trim().trim_end_matches(';').trim();
    let rest = code.get(..4).filter(|head| head.eq_ignore_ascii_case("SET "))?;
    let body = code.get(rest.len()..)?;
    let mut pairs = Vec::new();
    for part in split_outside_quotes(body, ',') {
        let (target, value) = match part.split_once(":=").or_else(|| part.split_once('=')) {
            Some(pair) => pair,
            None => match part.to_ascii_lowercase().find(" to ") {
                Some(at) => (&part[..at], &part[at + 4..]),
                None => continue,
            },
        };
        pairs.push((target.trim().to_owned(), value.trim().to_owned()));
    }
    Some(pairs)
}

/// The statement with `/*!` and MariaDB's `/*M!` openers, their version
/// digits and the closing `*/` taken off.
fn without_executable_markers(statement: &str) -> String {
    let mut out = String::with_capacity(statement.len());
    let mut rest = statement;
    while let Some(at) = rest.find("/*") {
        let marker = ["/*!", "/*M!"]
            .into_iter()
            .find(|marker| rest[at..].starts_with(marker));
        let Some(marker) = marker else {
            out.push_str(&rest[..at + 2]);
            rest = &rest[at + 2..];
            continue;
        };
        out.push_str(&rest[..at]);
        let after = &rest[at + marker.len()..];
        let digits = after.len() - after.trim_start_matches(|c: char| c.is_ascii_digit()).len();
        rest = &after[digits..];
    }
    out.push_str(rest);
    out.replace("*/", " ")
}

fn split_outside_quotes(text: &str, separator: char) -> Vec<&str> {
    let mut parts = Vec::new();
    let mut quote = None;
    let mut start = 0;
    let mut escaped = false;
    for (index, character) in text.char_indices() {
        match quote {
            Some(open) => {
                if escaped {
                    escaped = false;
                } else if character == '\\' {
                    escaped = true;
                } else if character == open {
                    quote = None;
                }
            }
            None if character == '\'' || character == '"' || character == '`' => quote = Some(character),
            None if character == separator => {
                parts.push(&text[start..index]);
                start = index + character.len_utf8();
            }
            None => {}
        }
    }
    parts.push(&text[start..]);
    parts
}

#[cfg(test)]
mod tests {
    use super::*;

    const ESCAPES: LexicalSettings = LexicalSettings {
        backslash_escapes: true,
    };
    const NO_ESCAPES: LexicalSettings = LexicalSettings {
        backslash_escapes: false,
    };

    #[test]
    fn mysqldump_saves_sets_and_restores_the_mode() {
        let mut tracker = LexicalTracker::default();
        let my = SqlGrammar::MySql;

        assert_eq!(
            tracker.after("/*!50003 SET @saved_sql_mode = @@sql_mode */", my, ESCAPES),
            None
        );
        let set = tracker.after(
            "/*!50003 SET sql_mode = 'NO_BACKSLASH_ESCAPES,STRICT_TRANS_TABLES' */",
            my,
            ESCAPES,
        );
        assert_eq!(set, Some(NO_ESCAPES));
        assert_eq!(
            tracker.after("/*!50003 SET sql_mode = @saved_sql_mode */", my, NO_ESCAPES),
            Some(ESCAPES)
        );
    }

    #[test]
    fn a_mariadb_executable_comment_sets_the_mode_too() {
        let mut tracker = LexicalTracker::default();

        assert_eq!(
            tracker.after(
                "/*M!100100 SET sql_mode='NO_BACKSLASH_ESCAPES' */",
                SqlGrammar::MySql,
                ESCAPES
            ),
            Some(NO_ESCAPES)
        );
    }

    #[test]
    fn the_dump_header_keeps_escapes_on() {
        let mut tracker = LexicalTracker::default();

        let header = "/*!40101 SET @OLD_SQL_MODE=@@SQL_MODE, SQL_MODE='NO_AUTO_VALUE_ON_ZERO' */";
        assert_eq!(tracker.after(header, SqlGrammar::MySql, ESCAPES), None);
    }

    #[test]
    fn postgresql_follows_standard_conforming_strings() {
        let mut tracker = LexicalTracker::default();
        let pg = SqlGrammar::PostgreSql;

        assert_eq!(
            tracker.after("SET standard_conforming_strings = off", pg, NO_ESCAPES),
            Some(ESCAPES)
        );
        assert_eq!(
            tracker.after("SET SESSION standard_conforming_strings TO on", pg, ESCAPES),
            Some(NO_ESCAPES)
        );
        assert_eq!(tracker.after("SELECT 1", pg, NO_ESCAPES), None);
    }
}
