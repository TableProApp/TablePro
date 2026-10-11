use mongodb::bson::Document;

use super::codec::serde_json_to_document;
use tablepro_core::MAX_QUERY_ROWS;

pub(super) struct FindQuery {
    pub(super) collection: String,
    pub(super) filter: Document,
    pub(super) skip: u64,
    pub(super) limit: i64,
    pub(super) sort_by_id: bool,
}

pub(super) struct AggregateQuery {
    pub(super) collection: String,
    pub(super) pipeline: Vec<Document>,
}

/// Parse `db.coll.find({...})` / `db["coll"].find({...}).skip(n).limit(m)`.
pub(super) fn parse_find_shell(input: &str) -> Option<FindQuery> {
    let input = input.trim().trim_end_matches(';');
    let (collection, rest) = split_collection_call(input, "find")?;
    let (filter_src, after_filter) = extract_balanced(rest.trim_start(), '(', ')')?;
    let filter = if filter_src.trim().is_empty() {
        Document::new()
    } else {
        serde_json_to_document(filter_src).ok()?
    };
    let mut skip = 0u64;
    let mut limit = MAX_QUERY_ROWS as i64;
    let mut remaining = after_filter;
    while let Some(pos) = remaining.find('.') {
        remaining = &remaining[pos + 1..];
        if let Some(rest) = remaining.strip_prefix("skip") {
            let (n, after) = extract_balanced(rest.trim_start(), '(', ')')?;
            skip = n.trim().parse().ok()?;
            remaining = after;
        } else if let Some(rest) = remaining.strip_prefix("limit") {
            let (n, after) = extract_balanced(rest.trim_start(), '(', ')')?;
            limit = n.trim().parse().ok()?;
            remaining = after;
        } else {
            break;
        }
    }
    if !remaining.trim().is_empty() {
        return None;
    }
    Some(FindQuery {
        collection,
        filter,
        skip,
        limit,
        sort_by_id: false,
    })
}

pub(super) fn parse_aggregate_shell(input: &str) -> Option<AggregateQuery> {
    let input = input.trim().trim_end_matches(';');
    let (collection, rest) = split_collection_call(input, "aggregate")?;
    let (pipeline_src, trailing) = extract_balanced(rest.trim_start(), '(', ')')?;
    if !trailing.trim().is_empty() {
        return None;
    }
    let value: serde_json::Value = serde_json::from_str(pipeline_src).ok()?;
    let arr = value.as_array()?;
    let mut pipeline = Vec::new();
    for item in arr {
        pipeline.push(serde_json_to_document(&item.to_string()).ok()?);
    }
    Some(AggregateQuery { collection, pipeline })
}

pub(super) fn parse_insert_one(input: &str) -> Option<(String, Document)> {
    let (collection, rest) = split_collection_call(input.trim().trim_end_matches(';'), "insertOne")?;
    let (doc_src, trailing) = extract_balanced(rest.trim_start(), '(', ')')?;
    if !trailing.trim().is_empty() {
        return None;
    }
    Some((collection, serde_json_to_document(doc_src).ok()?))
}

pub(super) fn parse_delete_many(input: &str) -> Option<(String, Document)> {
    let (collection, rest) = split_collection_call(input.trim().trim_end_matches(';'), "deleteMany")?;
    let (doc_src, trailing) = extract_balanced(rest.trim_start(), '(', ')')?;
    if !trailing.trim().is_empty() {
        return None;
    }
    Some((collection, serde_json_to_document(doc_src).ok()?))
}

/// The Structure tab's "Drop table" action builds engine-neutral SQL
/// through `tablepro_core::sql_ddl::build_drop_table`, which has no
/// MongoDB-specific case -- it emits `DROP TABLE IF EXISTS "name"`
/// with the same quoting every other driver gets. Recognize that shape
/// here and translate it into a native collection drop instead of
/// failing the drop outright.
pub(super) fn parse_drop_table_sql(input: &str) -> Option<String> {
    let trimmed = input.trim().trim_end_matches(';').trim();
    let rest = trimmed.strip_prefix("DROP TABLE")?.trim_start();
    let rest = rest.strip_prefix("IF EXISTS").unwrap_or(rest).trim_start();
    let Some(quoted) = rest.strip_prefix('"') else {
        return is_simple_ident(rest).then(|| rest.to_owned());
    };
    let mut chars = quoted.chars();
    let mut name = String::new();
    loop {
        match chars.next()? {
            '"' if chars.clone().next() == Some('"') => {
                chars.next();
                name.push('"');
            }
            '"' => break,
            c => name.push(c),
        }
    }
    chars.as_str().trim().is_empty().then_some(name)
}

fn split_collection_call<'a>(input: &'a str, method: &str) -> Option<(String, &'a str)> {
    let rest = input.strip_prefix("db")?;
    let (collection, after) = if let Some(rest) = rest.strip_prefix('.') {
        let end = rest.find('.')?;
        let name = &rest[..end];
        if !is_simple_ident(name) {
            return None;
        }
        (name.to_string(), &rest[end..])
    } else if let Some(rest) = rest.strip_prefix("[\"") {
        let end = rest.find("\"]")?;
        let name = rest[..end].to_string();
        let after = &rest[end + 2..];
        (name, after)
    } else {
        let rest = rest.strip_prefix("['")?;
        let end = rest.find("']")?;
        let name = rest[..end].to_string();
        let after = &rest[end + 2..];
        (name, after)
    };
    let after = after.strip_prefix('.')?;
    let after = after.strip_prefix(method)?;
    Some((collection, after))
}

fn extract_balanced(input: &str, open: char, close: char) -> Option<(&str, &str)> {
    let input = input.trim_start();
    if !input.starts_with(open) {
        return None;
    }
    let mut depth = 0usize;
    let mut in_string = None::<char>;
    let mut escaped = false;
    for (i, c) in input.char_indices() {
        if let Some(q) = in_string {
            if escaped {
                escaped = false;
            } else if c == '\\' {
                escaped = true;
            } else if c == q {
                in_string = None;
            }
            continue;
        }
        match c {
            '"' | '\'' => in_string = Some(c),
            c if c == open => depth += 1,
            c if c == close => {
                depth -= 1;
                if depth == 0 {
                    return Some((&input[1..i], &input[i + 1..]));
                }
            }
            _ => {}
        }
    }
    None
}

fn is_simple_ident(s: &str) -> bool {
    !s.is_empty() && s.chars().all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '$')
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn drop_table_sql_extracts_the_collection_name() {
        assert_eq!(
            parse_drop_table_sql(r#"DROP TABLE IF EXISTS "widgets""#),
            Some("widgets".to_string())
        );
        assert_eq!(
            parse_drop_table_sql(r#"DROP TABLE "widgets""#),
            Some("widgets".to_string())
        );
    }

    #[test]
    fn drop_table_sql_unescapes_a_doubled_quote_in_the_name() {
        assert_eq!(
            parse_drop_table_sql(r#"DROP TABLE IF EXISTS "a""b""#),
            Some(r#"a"b"#.to_string())
        );
    }

    #[test]
    fn drop_table_sql_ignores_an_unrelated_statement() {
        assert_eq!(parse_drop_table_sql("SELECT 1"), None);
        assert_eq!(parse_drop_table_sql("DROP TABLE widgets"), Some("widgets".into()));
        assert_eq!(
            parse_drop_table_sql("DROP TABLE IF EXISTS widgets"),
            Some("widgets".into())
        );
        assert_eq!(parse_drop_table_sql("DROP TABLE widgets extra"), None);
        assert_eq!(parse_drop_table_sql("DROP TABLE wid-gets"), None);
        assert_eq!(parse_drop_table_sql("DROP TABLE "), None);
        assert_eq!(parse_drop_table_sql(r#"db.widgets.deleteMany({})"#), None);
    }

    #[test]
    fn parse_find_shell_basic() {
        let q = parse_find_shell(r#"db.users.find({"age": {"$gt": 18}}).limit(10)"#).unwrap();
        assert_eq!(q.collection, "users");
        assert_eq!(q.limit, 10);
        assert_eq!(q.filter.get_document("age").unwrap().get_i64("$gt").unwrap(), 18);
    }

    #[test]
    fn parse_find_shell_bracket_name() {
        let q = parse_find_shell(r#"db["my-coll"].find({})"#).unwrap();
        assert_eq!(q.collection, "my-coll");
    }

    #[test]
    fn shell_commands_reject_trailing_text_instead_of_executing_a_prefix() {
        assert!(parse_find_shell(r#"db.users.find({}).limit(1) unexpected"#).is_none());
        assert!(parse_find_shell(r#"db.users.find({}).unknown()"#).is_none());
        assert!(parse_aggregate_shell(r#"db.users.aggregate([]) unexpected"#).is_none());
        assert!(parse_insert_one(r#"db.users.insertOne({"name":"Ada"}) unexpected"#).is_none());
        assert!(parse_delete_many(r#"db.users.deleteMany({}) unexpected"#).is_none());
        assert!(parse_drop_table_sql(r#"DROP TABLE "users" unexpected"#).is_none());
    }

    #[test]
    fn parse_aggregate_shell_pipeline() {
        let q = parse_aggregate_shell(r#"db.orders.aggregate([{"$match": {"status": "a"}}])"#).unwrap();
        assert_eq!(q.collection, "orders");
        assert_eq!(q.pipeline.len(), 1);
    }
}
