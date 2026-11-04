//! MySQL's COLUMN_TYPE, read with a scanner rather than a SQL parser:
//! sqlparser has no ZEROFILL, and the catalogue's spelling is regular
//! enough that three steps cover it.

use super::column_type_scan_error::ColumnTypeScanError;

/// What COLUMN_TYPE adds to DATA_TYPE.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct MySqlColumnType {
    /// The text inside the parentheses, as written: a length, a
    /// precision and scale, or the quoted labels of an ENUM or SET.
    pub args: Option<String>,
    /// ZEROFILL implies UNSIGNED, so this is true for both.
    pub unsigned: bool,
    pub zerofill: bool,
}

/// 1. COLUMN_TYPE starts with DATA_TYPE, ignoring case.
/// 2. One optional parenthesised group, read past quoted labels with
///    `''` and backslash escapes so a `)` inside one does not end it.
/// 3. Whitespace-separated modifiers from {unsigned, signed, zerofill}.
pub(crate) fn scan(data_type: &str, column_type: &str) -> Result<MySqlColumnType, ColumnTypeScanError> {
    let text = column_type.trim();
    let prefix = text
        .get(..data_type.len())
        .filter(|prefix| prefix.eq_ignore_ascii_case(data_type))
        .ok_or_else(|| ColumnTypeScanError::MissingDataTypePrefix {
            data_type: data_type.to_owned(),
            column_type: column_type.to_owned(),
        })?;
    let mut rest = &text[prefix.len()..];
    let mut args = None;
    if rest.starts_with('(') {
        let end = closing_parenthesis(rest).ok_or_else(|| ColumnTypeScanError::Unbalanced(column_type.to_owned()))?;
        args = Some(rest[1..end].to_owned());
        rest = &rest[end + 1..];
    } else if rest.chars().next().is_some_and(|next| !next.is_whitespace()) {
        return Err(ColumnTypeScanError::MissingDataTypePrefix {
            data_type: data_type.to_owned(),
            column_type: column_type.to_owned(),
        });
    }
    let mut scanned = MySqlColumnType {
        args,
        unsigned: false,
        zerofill: false,
    };
    for word in rest.split_whitespace() {
        match word.to_ascii_lowercase().as_str() {
            "unsigned" => scanned.unsigned = true,
            "signed" => {}
            "zerofill" => {
                scanned.zerofill = true;
                scanned.unsigned = true;
            }
            _ => return Err(ColumnTypeScanError::UnexpectedModifier(word.to_owned())),
        }
    }
    Ok(scanned)
}

/// The byte index of the `)` that closes the `(` at index 0.
fn closing_parenthesis(text: &str) -> Option<usize> {
    let mut depth = 0usize;
    let mut quote: Option<char> = None;
    let mut characters = text.char_indices().peekable();
    while let Some((index, character)) = characters.next() {
        match quote {
            Some(open) => match character {
                '\\' => {
                    characters.next();
                }
                _ if character == open => {
                    if characters.peek().is_some_and(|(_, next)| *next == open) {
                        characters.next();
                    } else {
                        quote = None;
                    }
                }
                _ => {}
            },
            None => match character {
                '\'' | '"' => quote = Some(character),
                '(' => depth += 1,
                ')' => {
                    depth = depth.checked_sub(1)?;
                    if depth == 0 {
                        return Some(index);
                    }
                }
                _ => {}
            },
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn modifiers_and_arguments() {
        let scanned = scan("int", "int(10) unsigned zerofill").expect("int zerofill");
        assert_eq!(scanned.args.as_deref(), Some("10"));
        assert!(scanned.unsigned && scanned.zerofill);

        let scanned = scan("decimal", "decimal(10,2) unsigned").expect("decimal");
        assert_eq!(scanned.args.as_deref(), Some("10,2"));
        assert!(scanned.unsigned && !scanned.zerofill);

        let scanned = scan("bigint", "BIGINT").expect("upper case");
        assert_eq!(scanned.args, None);

        let scanned = scan("enum", "enum('a)b','it''s','c\\'d')").expect("labels");
        assert_eq!(scanned.args.as_deref(), Some("'a)b','it''s','c\\'d'"));
    }

    #[test]
    fn what_does_not_scan_says_why() {
        assert!(matches!(
            scan("int", "integer"),
            Err(ColumnTypeScanError::MissingDataTypePrefix { .. })
        ));
        assert!(matches!(
            scan("varchar", "varchar(10"),
            Err(ColumnTypeScanError::Unbalanced(_))
        ));
        assert_eq!(
            scan("int", "int(11) auto_increment"),
            Err(ColumnTypeScanError::UnexpectedModifier("auto_increment".to_owned()))
        );
    }
}
