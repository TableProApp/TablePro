use tablepro_core::sql_syntax::SqlGrammar;
use tablepro_core::sql_syntax::script::{LexicalSettings, ScriptPlan, ScriptTokenKind};
const KEYWORDS: &[&str] = &[
    "all",
    "and",
    "any",
    "array",
    "as",
    "between",
    "by",
    "case",
    "cast",
    "else",
    "except",
    "exists",
    "extract",
    "filter",
    "from",
    "group",
    "having",
    "in",
    "intersect",
    "is",
    "join",
    "lateral",
    "like",
    "ilike",
    "not",
    "on",
    "or",
    "over",
    "overlay",
    "position",
    "row",
    "select",
    "similar",
    "some",
    "substring",
    "then",
    "trim",
    "union",
    "using",
    "values",
    "when",
    "where",
    "with",
    "within",
];
const READ_ONLY_FUNCTIONS: &[&str] = &[
    "abs",
    "age",
    "array_agg",
    "array_length",
    "array_position",
    "array_to_string",
    "avg",
    "bit_length",
    "bool_and",
    "bool_or",
    "btrim",
    "cardinality",
    "ceil",
    "ceiling",
    "char_length",
    "character_length",
    "clock_timestamp",
    "coalesce",
    "concat",
    "concat_ws",
    "count",
    "cume_dist",
    "date_part",
    "date_trunc",
    "dense_rank",
    "div",
    "encode",
    "decode",
    "every",
    "exp",
    "first_value",
    "floor",
    "format",
    "format_type",
    "generate_series",
    "greatest",
    "initcap",
    "json_agg",
    "json_array_length",
    "json_build_array",
    "json_build_object",
    "json_each",
    "json_extract_path",
    "json_extract_path_text",
    "json_object_agg",
    "json_typeof",
    "jsonb_agg",
    "jsonb_array_elements",
    "jsonb_array_elements_text",
    "jsonb_array_length",
    "jsonb_build_array",
    "jsonb_build_object",
    "jsonb_each",
    "jsonb_extract_path",
    "jsonb_extract_path_text",
    "jsonb_object_agg",
    "jsonb_pretty",
    "jsonb_typeof",
    "lag",
    "last_value",
    "lead",
    "least",
    "left",
    "length",
    "ln",
    "log",
    "lower",
    "lpad",
    "ltrim",
    "make_date",
    "make_interval",
    "make_time",
    "make_timestamp",
    "make_timestamptz",
    "max",
    "md5",
    "min",
    "mod",
    "now",
    "nth_value",
    "ntile",
    "nullif",
    "octet_length",
    "percent_rank",
    "percentile_cont",
    "percentile_disc",
    "pg_typeof",
    "power",
    "rank",
    "regexp_match",
    "regexp_matches",
    "regexp_replace",
    "regexp_split_to_array",
    "repeat",
    "replace",
    "reverse",
    "right",
    "round",
    "row_number",
    "row_to_json",
    "rpad",
    "rtrim",
    "sign",
    "split_part",
    "sqrt",
    "starts_with",
    "statement_timestamp",
    "stddev",
    "stddev_pop",
    "stddev_samp",
    "string_agg",
    "string_to_array",
    "strpos",
    "substr",
    "sum",
    "timezone",
    "to_char",
    "to_date",
    "to_json",
    "to_jsonb",
    "to_number",
    "to_timestamp",
    "transaction_timestamp",
    "trunc",
    "unnest",
    "upper",
    "var_pop",
    "var_samp",
    "variance",
];
pub(crate) fn calls_only_read_only_functions(sql: &str) -> bool {
    let plan = ScriptPlan::build(
        sql,
        SqlGrammar::PostgreSql,
        LexicalSettings::default_for(SqlGrammar::PostgreSql),
    );
    let tokens: Vec<_> = plan
        .tokens(0..sql.len())
        .filter(|token| !token.kind.is_trivia())
        .collect();
    tokens.iter().enumerate().all(|(index, token)| {
        if token.kind != ScriptTokenKind::OpenParen || index == 0 {
            return true;
        }
        let callee = &tokens[index - 1];
        match callee.kind {
            ScriptTokenKind::Word => {
                let before = (index >= 2).then(|| sql[tokens[index - 2].range.clone()].to_ascii_lowercase());
                let name = sql[callee.range.clone()].to_ascii_lowercase();
                match before.as_deref() {
                    Some(".") => false,
                    Some("as") => true,
                    _ => KEYWORDS.contains(&name.as_str()) || READ_ONLY_FUNCTIONS.contains(&name.as_str()),
                }
            }
            ScriptTokenKind::QuotedIdentifier => false,
            _ => true,
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn user_functions_and_unknown_calls_are_not_streamed() {
        for sql in [
            "SELECT archive_rows()",
            "SELECT id, public.archive_rows(id) FROM items",
            "SELECT \"Archive\"(id) FROM items",
            "SELECT * FROM refresh_cache()",
            "SELECT count(*) FROM items WHERE note = touch(id)",
            "SELECT nextval('items_id_seq')",
            "SELECT set_config('search_path', 'x', false)",
        ] {
            assert!(!calls_only_read_only_functions(sql), "{sql}");
        }
    }

    #[test]
    fn plain_reads_with_syntax_and_built_ins_stream() {
        for sql in [
            "SELECT * FROM items",
            "SELECT id FROM items WHERE id IN (1, 2) AND EXISTS (SELECT 1 FROM tags)",
            "SELECT count(*), lower(name), COALESCE(note, '') FROM items GROUP BY name",
            "SELECT CAST(id AS text), row_number() OVER (PARTITION BY kind ORDER BY id) FROM items",
            "WITH recent AS (SELECT * FROM items) SELECT * FROM recent JOIN tags USING (id)",
            "SELECT 'archive_rows()' AS label -- archive_rows()",
            "SELECT * FROM (VALUES (1), (2)) AS t(n)",
        ] {
            assert!(calls_only_read_only_functions(sql), "{sql}");
        }
    }
}
