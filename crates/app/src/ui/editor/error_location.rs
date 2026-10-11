pub(super) fn line_and_column(sql: &str, position: usize) -> Option<(usize, usize)> {
    if position == 0 || position > sql.chars().count() + 1 {
        return None;
    }
    let before: Vec<char> = sql.chars().take(position - 1).collect();
    let line = before.iter().filter(|c| **c == '\n').count() + 1;
    let column = before.iter().rev().take_while(|c| **c != '\n').count() + 1;
    Some((line, column))
}

pub(super) fn located_message(message: &str, sql: &str, position: Option<usize>) -> String {
    let Some((line, column)) = position.and_then(|position| line_and_column(sql, position)) else {
        return message.to_string();
    };
    let line = line.to_string();
    let column = column.to_string();
    let place = crate::tr!("Line {line}, column {column} of this statement")
        .replace("{line}", &line)
        .replace("{column}", &column);
    format!("{message}\n{place}")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_position_on_the_first_line_is_its_column() {
        assert_eq!(line_and_column("SELECT * FROM missing", 15), Some((1, 15)));
    }

    #[test]
    fn a_position_after_a_newline_restarts_the_column() {
        assert_eq!(line_and_column("SELECT 1\nFROM nope", 15), Some((2, 6)));
    }

    #[test]
    fn positions_count_characters_not_bytes() {
        assert_eq!(line_and_column("SELECT 'é', bad", 13), Some((1, 13)));
    }

    #[test]
    fn a_position_outside_the_statement_has_no_location() {
        assert_eq!(line_and_column("SELECT 1", 0), None);
        assert_eq!(line_and_column("SELECT 1", 10), None);
    }

    #[test]
    fn the_message_keeps_its_text_and_gains_a_location_line() {
        let located = located_message("syntax error at or near \"x\"", "SELECT x x", Some(10));
        assert_eq!(
            located,
            "syntax error at or near \"x\"\nLine 1, column 10 of this statement"
        );
        assert_eq!(located_message("boom", "SELECT 1", None), "boom");
    }
}
