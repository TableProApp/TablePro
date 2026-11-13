use super::SensitiveKind;
use crate::secret_scan::line_starts;

// What a single-quoted literal of a shared query looks like. Never an IP address: a query names hosts for its own
// reasons.
const SQL_KINDS: [SensitiveKind; 6] = [
    SensitiveKind::Card,
    SensitiveKind::Iban,
    SensitiveKind::Jwt,
    SensitiveKind::ApiKey,
    SensitiveKind::Email,
    SensitiveKind::Phone,
];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PersonalDataHit {
    pub kind: SensitiveKind,
    // Where the literal starts, from 1; CR, LF and CRLF each end a line.
    pub line: u32,
}

// Each kind once per line, by line. Only single-quoted literals, `''` being a quote inside one; double-quoted text
// is a name, and a literal left open is not read.
pub fn scan_sql_personal_data(sql: &str) -> Vec<PersonalDataHit> {
    let starts = line_starts(sql);
    let line_of = |offset: usize| u32::try_from(starts.partition_point(|start| *start <= offset)).unwrap_or(u32::MAX);
    let mut hits: Vec<PersonalDataHit> = single_quoted_literals(sql)
        .into_iter()
        .filter_map(|(offset, literal)| {
            let kind = SQL_KINDS.into_iter().find(|kind| kind.matches(&literal))?;
            Some(PersonalDataHit {
                kind,
                line: line_of(offset),
            })
        })
        .collect();
    hits.sort_by_key(|hit| (hit.line, hit.kind));
    hits.dedup();
    hits
}

// Each closed literal's byte offset and its text with `''` read as one quote.
fn single_quoted_literals(sql: &str) -> Vec<(usize, String)> {
    let mut literals = Vec::new();
    let mut characters = sql.char_indices().peekable();
    while let Some((offset, character)) = characters.next() {
        match character {
            '"' => {
                for (_, inside) in characters.by_ref() {
                    if inside == '"' {
                        break;
                    }
                }
            }
            '\'' => {
                let mut literal = String::new();
                let mut closed = false;
                while let Some((_, inside)) = characters.next() {
                    if inside != '\'' {
                        literal.push(inside);
                    } else if characters.next_if(|(_, next)| *next == '\'').is_some() {
                        literal.push('\'');
                    } else {
                        closed = true;
                        break;
                    }
                }
                if closed {
                    literals.push((offset, literal));
                }
            }
            _ => {}
        }
    }
    literals
}

#[cfg(test)]
mod tests {
    use super::*;

    fn found(sql: &str) -> Vec<(SensitiveKind, u32)> {
        scan_sql_personal_data(sql)
            .into_iter()
            .map(|hit| (hit.kind, hit.line))
            .collect()
    }

    #[test]
    fn literals_read_with_doubled_quotes_and_names_are_skipped() {
        assert_eq!(
            single_quoted_literals(r#"SELECT 'it''s', "a'b", 'x' FROM t WHERE c = 'open"#),
            [(7, "it's".to_owned()), (23, "x".to_owned())]
        );
    }

    #[test]
    fn a_kind_counts_once_per_line_on_the_literal_s_first_line() {
        let sql =
            "SELECT *\r\nFROM users WHERE email IN ('ann@example.com', 'bob@example.com')\rAND phone = '+1 555 0100'";

        assert_eq!(found(sql), [(SensitiveKind::Email, 2), (SensitiveKind::Phone, 3)]);
    }
}
