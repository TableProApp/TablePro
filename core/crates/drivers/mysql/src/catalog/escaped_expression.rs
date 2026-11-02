/// An expression as MySQL lists it in `information_schema.COLUMNS`,
/// turned back into the SQL SHOW CREATE TABLE prints.
///
/// MySQL 8 escapes a generation expression and an expression default
/// for information_schema, putting a backslash before every quote and
/// backslash and writing NUL and Ctrl-Z as `\0` and `\Z`. Spliced as
/// listed, `DEFAULT (_utf8mb4'x')` would come back as `_utf8mb4\'x\'`,
/// which no statement parses. MariaDB lists the SQL itself.
pub(crate) fn unescape_expression(listed: &str) -> String {
    let mut sql = String::with_capacity(listed.len());
    let mut characters = listed.chars();
    while let Some(character) = characters.next() {
        if character != '\\' {
            sql.push(character);
            continue;
        }
        match characters.next() {
            Some('0') => sql.push('\0'),
            Some('Z') => sql.push('\u{1a}'),
            Some(escaped) => sql.push(escaped),
            None => sql.push('\\'),
        }
    }
    sql
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_listed_expression_reads_back_as_the_sql_show_create_prints() {
        assert_eq!(
            unescape_expression(r#"_utf8mb4\'{"a":"it\\\'s"}\'"#),
            r#"_utf8mb4'{"a":"it\'s"}'"#
        );
        assert_eq!(
            unescape_expression(r"concat(_utf8mb4\'a\',_utf8mb4\'b\\nc\\\\d\')"),
            r"concat(_utf8mb4'a',_utf8mb4'b\nc\\d')"
        );
        assert_eq!(unescape_expression("uuid()"), "uuid()");
        assert_eq!(unescape_expression(r"(`b` * 2)"), "(`b` * 2)");
    }
}
