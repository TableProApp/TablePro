//! Advisory diagnostics only: never normalize or alter executable SQL.
use std::ops::Range;

pub const MAX_WARNINGS: usize = 200;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum WarningKind {
    FullWidth,
    CurlyQuote,
    NonAsciiSpace,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CharacterWarning {
    pub range: Range<usize>,
    pub kind: WarningKind,
    pub character: char,
    pub suggestion: char,
}

pub fn scan(sql: &str, driver_id: &str) -> Vec<CharacterWarning> {
    if !crate::export::supports_sql_literals(driver_id) {
        return Vec::new();
    }
    let mut warnings = Vec::new();
    let mut index = 0;
    while index < sql.len() && warnings.len() < MAX_WARNINGS {
        let rest = &sql[index..];
        if let Some(length) = crate::sql_lex::skip_span(rest, driver_id).filter(|length| *length > 0) {
            index += length;
            continue;
        }
        let Some(character) = rest.chars().next() else { break };
        let range = index..index + character.len_utf8();
        let replacement = match character {
            '\u{ff01}'..='\u{ff5e}' => {
                char::from_u32(character as u32 - 0xfee0).map(|ascii| (WarningKind::FullWidth, ascii))
            }
            '\u{2018}' | '\u{2019}' => Some((WarningKind::CurlyQuote, '\'')),
            '\u{201c}' | '\u{201d}' => Some((WarningKind::CurlyQuote, '"')),
            '\u{00a0}' | '\u{2000}'..='\u{200a}' | '\u{202f}' | '\u{205f}' | '\u{3000}' => {
                Some((WarningKind::NonAsciiSpace, ' '))
            }
            _ => None,
        };
        index = range.end;
        if let Some((kind, suggestion)) = replacement {
            warnings.push(CharacterWarning {
                range,
                kind,
                character,
                suggestion,
            });
        }
    }
    warnings
}

/// GTK offsets count Unicode scalar values, not UTF-8 bytes.
pub fn character_range(sql: &str, range: Range<usize>) -> Option<Range<i32>> {
    let start = i32::try_from(sql.get(..range.start)?.chars().count()).ok()?;
    let length = i32::try_from(sql.get(range)?.chars().count()).ok()?;
    Some(start..start.checked_add(length)?)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn code_only_and_unicode_offsets() {
        let sql = "SELECT '🙂；', \"列；\", $$‘；$$ /* nested /* ； */ ； */ , Ａ；\u{00a0}‘";
        let warnings = scan(sql, "postgres");
        assert_eq!(
            warnings.iter().map(|w| w.character).collect::<String>(),
            "Ａ；\u{00a0}‘"
        );
        for warning in warnings {
            let range = character_range(sql, warning.range.clone()).unwrap();
            assert_eq!(sql.chars().nth(range.start as usize), Some(warning.character));
            assert_eq!(range.end - range.start, 1);
        }
    }

    #[test]
    fn escaped_and_unterminated_spans_are_ignored() {
        for (driver, sql) in [
            ("mysql", "SELECT 'a\\'；'; ；"),
            ("postgres", "SELECT E'a\\'；'; ；"),
            ("mssql", "SELECT [a]]；]; ；"),
        ] {
            assert_eq!(scan(sql, driver).len(), 1);
        }
        assert!(scan("SELECT '；", "postgres").is_empty());
        assert!(scan("SELECT 1 -- ；", "postgres").is_empty());
        assert!(scan("GET ；", "redis").is_empty());
        assert!(scan("{‘x’:1}", "mongodb").is_empty());
        assert_eq!(scan(&"；".repeat(1000), "postgres").len(), MAX_WARNINGS);
        assert!(scan("SELECT 1;", "postgres").is_empty());
    }
}
