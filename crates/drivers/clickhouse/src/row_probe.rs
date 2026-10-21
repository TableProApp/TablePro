fn quoted_name_end(rest: &str) -> Option<usize> {
    let mut chars = rest.char_indices().peekable();
    let (_, quote) = chars.next().filter(|(_, c)| matches!(c, '`' | '"'))?;
    while let Some((index, c)) = chars.next() {
        if c != quote {
            continue;
        }
        if chars.next_if(|(_, next)| *next == quote).is_none() {
            return Some(index + 1);
        }
    }
    None
}

fn qualified_name_end(rest: &str) -> Option<usize> {
    let mut end = quoted_name_end(rest)?;
    if rest[end..].starts_with('.') {
        end += 1 + quoted_name_end(&rest[end + 1..])?;
    }
    Some(end)
}

pub(super) struct RowProbe {
    pub sql: String,
    pub placeholders: usize,
}

pub(super) fn single_row_probe(sql: &str) -> Option<RowProbe> {
    let (table, tail) = if let Some(rest) = sql.strip_prefix("ALTER TABLE ") {
        let end = qualified_name_end(rest)?;
        let tail = rest[end..].strip_prefix(" UPDATE ")?;
        (&rest[..end], tail)
    } else {
        let rest = sql.strip_prefix("DELETE FROM ")?;
        let end = qualified_name_end(rest)?;
        (&rest[..end], rest[end..].strip_prefix(' ')?)
    };
    let (_, condition) = tail
        .rsplit_once(" WHERE ")
        .or_else(|| tail.strip_prefix("WHERE ").map(|c| ("", c)))?;
    Some(RowProbe {
        sql: format!("SELECT 1 FROM {table} WHERE {condition} LIMIT 2"),
        placeholders: condition.matches('?').count(),
    })
}
