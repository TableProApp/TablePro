use std::collections::HashMap;

/// The text GtkSourceView inserts for `template`, with each stop's text
/// swapped for what `fill` gives for its default, or kept when it gives
/// nothing.
///
/// It reads only what the built-in snippets use: `${N:text}`, `$N` for
/// the text of a stop already met, and `$0`. Anything else is `None`, so
/// a built-in that grows other syntax fails the tests that expand it.
pub fn expand_snippet(template: &str, mut fill: impl FnMut(&str) -> Option<String>) -> Option<String> {
    let mut text = String::new();
    let mut stops: HashMap<u32, String> = HashMap::new();
    let mut rest = template;
    while let Some(dollar) = rest.find('$') {
        text.push_str(rest.get(..dollar)?);
        let after = rest.get(dollar + 1..)?;
        if let Some(inner) = after.strip_prefix('{') {
            let close = inner.find('}')?;
            let (number, default) = inner.get(..close)?.split_once(':')?;
            let number: u32 = number.parse().ok()?;
            if number == 0 || default.contains(['$', '{']) {
                return None;
            }
            let filled = fill(default).unwrap_or_else(|| default.to_owned());
            text.push_str(&filled);
            stops.insert(number, filled);
            rest = inner.get(close + 1..)?;
        } else {
            let digits = after.chars().take_while(char::is_ascii_digit).count();
            let number: u32 = after.get(..digits)?.parse().ok()?;
            if number != 0 {
                text.push_str(stops.get(&number)?);
            }
            rest = after.get(digits..)?;
        }
    }
    text.push_str(rest);
    Some(text)
}

#[cfg(test)]
mod tests {
    use tablepro_core::sql_syntax::{SqlGrammar, builtin_snippets};

    use super::*;

    #[test]
    fn stops_keep_their_defaults_unless_filled() {
        let template = "INSERT INTO ${1:table_name} (${2:columns})\nVALUES (${3:values});$0";

        assert_eq!(
            expand_snippet(template, |_| None).as_deref(),
            Some("INSERT INTO table_name (columns)\nVALUES (values);")
        );
        assert_eq!(
            expand_snippet(template, |default| (default == "table_name")
                .then(|| "users".to_owned()))
            .as_deref(),
            Some("INSERT INTO users (columns)\nVALUES (values);")
        );
    }

    #[test]
    fn a_mirror_repeats_the_stop_it_names() {
        let template = "FROM ${2:t} AS ${3:a} JOIN u AS ${5:b} ON $5.id = $3.id$0";

        assert_eq!(
            expand_snippet(template, |default| (default == "a").then(|| "x".to_owned())).as_deref(),
            Some("FROM t AS x JOIN u AS b ON b.id = x.id")
        );
    }

    #[test]
    fn syntax_the_built_ins_do_not_use_is_refused() {
        for template in [
            "$name",
            "${1:a${2:b}}",
            "${0:end}",
            "$7 before its stop",
            "cost $",
            "${1}",
        ] {
            assert_eq!(expand_snippet(template, |_| None), None, "{template}");
        }
    }

    #[test]
    fn every_built_in_expands() {
        for grammar in SqlGrammar::SQL {
            for snippet in builtin_snippets(grammar) {
                assert!(
                    expand_snippet(snippet.text, |_| None).is_some(),
                    "{grammar:?} {}: {}",
                    snippet.trigger,
                    snippet.text
                );
            }
        }
    }
}
