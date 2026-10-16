use sqlparser::dialect::Dialect;
use sqlparser::tokenizer::{Token, Tokenizer, Whitespace};

pub(crate) fn refusal(sql: &str, driver_id: &str, dialect: &dyn Dialect) -> Option<&'static str> {
    match driver_id {
        "redis" if is_redis_database_switch(sql, dialect) => {
            Some("Redis SELECT switches the connection's database and is not a read")
        }
        "mysql" if contains_mysql_executable_comment(sql, dialect) => {
            Some("MySQL executable comments are not safely classified")
        }
        _ => None,
    }
}

fn contains_mysql_executable_comment(sql: &str, dialect: &dyn Dialect) -> bool {
    let Ok(tokens) = Tokenizer::new(dialect, sql).tokenize() else {
        return false;
    };

    tokens.iter().any(|token| {
        matches!(token, Token::Whitespace(Whitespace::MultiLineComment(comment))
            if comment.starts_with('!') || comment.starts_with("M!"))
    })
}

fn is_redis_database_switch(sql: &str, dialect: &dyn Dialect) -> bool {
    let Ok(tokens) = Tokenizer::new(dialect, sql).tokenize() else {
        return false;
    };
    let words: Vec<&Token> = tokens
        .iter()
        .filter(|token| !matches!(token, Token::Whitespace(_) | Token::SemiColon))
        .collect();
    matches!(
        words.as_slice(),
        [Token::Word(select), _] if select.quote_style.is_none() && select.value.eq_ignore_ascii_case("SELECT")
    )
}
