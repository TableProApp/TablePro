/// A suggestion longer than this is cut at a line end.
const MAX_LINES: usize = 12;
const MAX_CHARS: usize = 1_000;

/// The text to insert at the cursor from a suggestion's reply: without
/// a code fence around it, without the current line when the model
/// wrote it again, and with no trailing space. `None` when nothing is
/// left.
pub fn clean_completion(reply: &str, before_cursor: &str) -> Option<String> {
    let unfenced = strip_fence(reply);
    let line = before_cursor.rsplit('\n').next().unwrap_or_default().trim_start();
    let continued = if line.is_empty() {
        unfenced
    } else {
        unfenced.strip_prefix(line).unwrap_or(unfenced)
    };
    let mut kept = String::new();
    for (index, part) in continued.split('\n').enumerate() {
        if index == MAX_LINES || kept.chars().count() + part.chars().count() > MAX_CHARS {
            break;
        }
        if index > 0 {
            kept.push('\n');
        }
        kept.push_str(part);
    }
    let kept = kept.trim_end();
    (!kept.trim().is_empty()).then(|| kept.to_owned())
}

fn strip_fence(reply: &str) -> &str {
    // A leading line break is part of a suggestion that starts a line.
    let Some(rest) = reply.trim_start().strip_prefix("```") else {
        return reply;
    };
    // The opening fence's info string, such as `sql`, ends its line.
    let body = rest.split_once('\n').map_or("", |(_, body)| body);
    let body = body.trim_end();
    body.strip_suffix("```").unwrap_or(body).trim_end_matches(['\n', '\r'])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_plain_continuation_is_kept_as_written() {
        assert_eq!(
            clean_completion(" FROM orders WHERE total > 100;", "SELECT *").as_deref(),
            Some(" FROM orders WHERE total > 100;")
        );
    }

    #[test]
    fn a_code_fence_around_the_suggestion_is_dropped() {
        assert_eq!(
            clean_completion("```sql\nFROM orders\n```", "SELECT * ").as_deref(),
            Some("FROM orders")
        );
    }

    #[test]
    fn the_line_written_again_is_not_inserted_twice() {
        assert_eq!(
            clean_completion("SELECT name FROM users;", "-- users\n  SELECT name").as_deref(),
            Some(" FROM users;")
        );
    }

    #[test]
    fn a_suggestion_that_starts_a_line_keeps_its_line_break() {
        assert_eq!(
            clean_completion("\nWHERE id = 1;\n", "SELECT * FROM t").as_deref(),
            Some("\nWHERE id = 1;")
        );
    }

    #[test]
    fn an_empty_or_blank_reply_suggests_nothing() {
        assert_eq!(clean_completion("", "SELECT"), None);
        assert_eq!(clean_completion("```\n```", "SELECT"), None);
        assert_eq!(clean_completion("  \n ", "SELECT"), None);
    }

    #[test]
    fn a_long_suggestion_stops_at_a_line_end() {
        let reply = (0..40).map(|n| format!("  , c{n}")).collect::<Vec<_>>().join("\n");

        let kept = clean_completion(&reply, "SELECT").unwrap();

        assert_eq!(kept.lines().count(), MAX_LINES);
        assert!(kept.ends_with("c11"));
    }
}
