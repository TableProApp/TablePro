use tablepro_core::{QueryResult, Value};

pub const DEFAULT_SENSITIVE_PATTERNS: &[&str] = &[
    "*pan*",
    "*card*",
    "*cvv*",
    "*cvc*",
    "*ssn*",
    "*iban*",
    "*secret*",
    "*token*",
    "*password*",
    "*passwd*",
    "*api_key*",
    "*apikey*",
    "*private_key*",
];

const REDACTED: &str = "***REDACTED***";

pub fn column_is_sensitive(column_name: &str, patterns: &[String]) -> bool {
    let name = column_name.to_lowercase();
    patterns.iter().any(|pat| {
        let p = pat.to_lowercase();
        glob::Pattern::new(&p).map(|g| g.matches(&name)).unwrap_or(false)
    })
}

/// Mask sensitive columns in a result set. Non-null values become the
/// redaction sentinel; Null stays Null.
///
/// `sensitive_positions`, when present, marks output columns known to derive
/// from a sensitive source column via the parsed statement's projection (see
/// `classify::sensitive_projection`) — it is ORed with the name-based match
/// so an alias or expression that hides the source column name still gets
/// masked. `patterns` is the caller's fully effective pattern list; this
/// function performs no defaulting of its own.
pub fn apply_masking(
    mut result: QueryResult,
    patterns: &[String],
    sensitive_positions: Option<&[bool]>,
) -> QueryResult {
    let sensitive: Vec<bool> = result
        .columns
        .iter()
        .enumerate()
        .map(|(i, c)| {
            column_is_sensitive(&c.name, patterns)
                || sensitive_positions.and_then(|s| s.get(i)).copied().unwrap_or(false)
        })
        .collect();
    if !sensitive.iter().any(|s| *s) {
        return result;
    }
    for row in &mut result.rows {
        for (i, cell) in row.iter_mut().enumerate() {
            if sensitive.get(i).copied().unwrap_or(false) && !matches!(cell, Value::Null) {
                *cell = Value::Text(REDACTED.into());
            }
        }
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    use tablepro_core::ColumnInfo;

    #[test]
    fn matches_pan_column() {
        let patterns: Vec<String> = DEFAULT_SENSITIVE_PATTERNS.iter().map(|s| (*s).into()).collect();
        assert!(column_is_sensitive("card_pan", &patterns));
        assert!(column_is_sensitive("CVV", &patterns));
        assert!(!column_is_sensitive("amount", &patterns));
    }

    #[test]
    fn redacts_cells() {
        let patterns = vec!["*pan*".into()];
        let result = QueryResult {
            columns: vec![
                ColumnInfo {
                    name: "id".into(),
                    data_type: "int".into(),
                    nullable: false,
                    primary_key: true,
                    is_auto_increment: false,
                    default_value: None,
                    is_generated: false,
                    comment: None,
                    collation: None,
                    enum_type: None,
                    domain_type: None,
                },
                ColumnInfo {
                    name: "pan".into(),
                    data_type: "text".into(),
                    nullable: true,
                    primary_key: false,
                    is_auto_increment: false,
                    default_value: None,
                    is_generated: false,
                    comment: None,
                    collation: None,
                    enum_type: None,
                    domain_type: None,
                },
            ],
            rows: vec![vec![Value::Int(1), Value::Text("4111111111111111".into())]],
            truncated: false,
        };
        let masked = apply_masking(result, &patterns, None);
        assert_eq!(masked.rows[0][0], Value::Int(1));
        assert_eq!(masked.rows[0][1], Value::Text(REDACTED.into()));
    }

    #[test]
    fn an_empty_pattern_list_with_no_known_positions_redacts_nothing() {
        let result = QueryResult {
            columns: vec![ColumnInfo {
                name: "password".into(),
                data_type: "text".into(),
                nullable: true,
                primary_key: false,
                is_auto_increment: false,
                default_value: None,
                is_generated: false,
                comment: None,
                collation: None,
                enum_type: None,
                domain_type: None,
            }],
            rows: vec![vec![Value::Text("secret".into())]],
            truncated: false,
        };
        let masked = apply_masking(result, &[], None);
        assert_eq!(masked.rows[0][0], Value::Text("secret".into()));
    }

    #[test]
    fn a_known_sensitive_position_is_redacted_even_when_its_name_does_not_match() {
        let result = QueryResult {
            columns: vec![ColumnInfo {
                name: "p".into(),
                data_type: "text".into(),
                nullable: true,
                primary_key: false,
                is_auto_increment: false,
                default_value: None,
                is_generated: false,
                comment: None,
                collation: None,
                enum_type: None,
                domain_type: None,
            }],
            rows: vec![vec![Value::Text("4111111111111111".into())]],
            truncated: false,
        };
        let masked = apply_masking(result, &[], Some(&[true]));
        assert_eq!(masked.rows[0][0], Value::Text(REDACTED.into()));
    }
}
