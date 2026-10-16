use crate::sql_lex::skip_span;

const MAX_BODY_DEPTH: u8 = 4;

const SECRET_OBJECTS: [&str; 11] = [
    "USER",
    "ROLE",
    "LOGIN",
    "SERVER",
    "SUBSCRIPTION",
    "CREDENTIAL",
    "KEY",
    "CERTIFICATE",
    "MAPPING",
    "COLLECTION",
    "CONNECTION",
];

const SECRET_WORDS: [&str; 5] = ["IDENTIFIED", "SECRET", "PASSPHRASE", "REQUIREPASS", "MASTERAUTH"];

const SECRET_PROCEDURES: [&str; 7] = [
    "SP_ADDLOGIN",
    "SP_PASSWORD",
    "SP_ADDLINKEDSRVLOGIN",
    "SP_ADDAPPROLE",
    "SP_SETAPPROLE",
    "SP_APPROLEPASSWORD",
    "SP_CONTROL_DBMASTERKEY_PASSWORD",
];

const NAME_POSITIONS: [&str; 4] = ["TABLE", "INTO", "VIEW", "REFERENCES"];

const BLOCK_OPENERS: [&str; 5] = ["BEGIN", "THEN", "ELSE", "LOOP", "ATOMIC"];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Token<'a> {
    Word(&'a str),
    Text(&'a str),
    Body(&'a str),
    Punct(char),
}

pub fn carries_credentials(sql: &str, driver_id: &str) -> bool {
    match lex(sql, driver_id) {
        Some(tokens) => tokens_carry(&tokens, driver_id, 0),
        None => true,
    }
}

fn body_carries(body: &str, driver_id: &str, depth: u8) -> bool {
    depth < MAX_BODY_DEPTH && lex(body, driver_id).is_some_and(|tokens| tokens_carry(&tokens, driver_id, depth + 1))
}

fn tokens_carry(tokens: &[Token<'_>], driver_id: &str, depth: u8) -> bool {
    tokens
        .split(|token| *token == Token::Punct(';'))
        .any(|statement| statement_carries(statement, driver_id, depth))
}

fn statement_carries(tokens: &[Token<'_>], driver_id: &str, depth: u8) -> bool {
    let opener = |token: &Token<'_>| matches!(token, Token::Word(word) if BLOCK_OPENERS.iter().any(|opener| opener.eq_ignore_ascii_case(word)));
    let start = tokens.iter().take_while(|token| opener(token)).count();
    secret_statement(&tokens[start..], driver_id)
        || tokens.iter().enumerate().any(|(at, token)| match token {
            Token::Text(text) => {
                secret_text(text)
                    || (routine_body_at(tokens, at, driver_id) && body_carries(&unquote(text), driver_id, depth))
            }
            Token::Body(body) => body_carries(body, driver_id, depth),
            Token::Word(word) => carrier_call_at(tokens, at, word, driver_id),
            Token::Punct(_) => false,
        })
}

fn secret_statement(tokens: &[Token<'_>], driver_id: &str) -> bool {
    let words: Vec<String> = tokens
        .iter()
        .filter_map(|token| match token {
            Token::Word(word) => Some(word.to_ascii_uppercase()),
            _ => None,
        })
        .collect();
    let Some(first) = words.first().map(String::as_str) else {
        return false;
    };
    let names_password = words
        .iter()
        .any(|word| word.contains("PASSWORD") || SECRET_WORDS.contains(&word.as_str()));
    match driver_id {
        "redis" => redis_secret(&words),
        "mongodb" => words
            .iter()
            .any(|word| matches!(word.as_str(), "CREATEUSER" | "UPDATEUSER" | "CHANGEUSERPASSWORD")),
        _ => match first {
            "CREATE" | "ALTER" => {
                secret_object_head(tokens)
                    && (names_password || tokens.iter().any(|token| matches!(token, Token::Text(_))))
            }
            "SET" | "CHANGE" | "START" | "GRANT" | "OPEN" => names_password,
            "EXEC" | "EXECUTE" => names_password || words.iter().any(|word| SECRET_PROCEDURES.contains(&word.as_str())),
            _ => false,
        },
    }
}

fn secret_object_head(tokens: &[Token<'_>]) -> bool {
    tokens
        .iter()
        .take_while(|token| **token != Token::Punct('('))
        .filter_map(|token| match token {
            Token::Word(word) => Some(word),
            _ => None,
        })
        .take(6)
        .any(|word| SECRET_OBJECTS.iter().any(|object| object.eq_ignore_ascii_case(word)))
}

fn redis_secret(words: &[String]) -> bool {
    let word = |at: usize| words.get(at).map_or("", String::as_str);
    match word(0) {
        "AUTH" => true,
        "ACL" => word(1) == "SETUSER",
        "CONFIG" => word(1) == "SET" && matches!(word(2), "REQUIREPASS" | "MASTERAUTH" | "MASTERUSER"),
        "MIGRATE" | "HELLO" => words.iter().any(|word| word == "AUTH" || word == "AUTH2"),
        _ => false,
    }
}

fn carrier_call_at(tokens: &[Token<'_>], at: usize, word: &str, driver_id: &str) -> bool {
    if tokens.get(at + 1) != Some(&Token::Punct('(')) || !is_carrier(word, driver_id) {
        return false;
    }
    !names_an_object(tokens, at)
}

fn is_carrier(word: &str, driver_id: &str) -> bool {
    let carriers: &[&str] = match driver_id {
        "postgres" => &[
            "dblink",
            "dblink_connect",
            "dblink_connect_u",
            "dblink_exec",
            "pgp_sym_encrypt",
            "pgp_sym_decrypt",
            "pgp_sym_encrypt_bytea",
            "pgp_sym_decrypt_bytea",
            "encrypt",
            "decrypt",
            "encrypt_iv",
            "decrypt_iv",
            "crypt",
            "hmac",
        ],
        "mysql" => &[
            "password",
            "old_password",
            "aes_encrypt",
            "aes_decrypt",
            "des_encrypt",
            "des_decrypt",
            "encode",
            "decode",
            "encrypt",
        ],
        "mssql" => &[
            "encryptbypassphrase",
            "decryptbypassphrase",
            "openrowset",
            "opendatasource",
            "pwdencrypt",
            "pwdcompare",
        ],
        "clickhouse" => &[
            "s3",
            "s3cluster",
            "url",
            "mysql",
            "postgresql",
            "remote",
            "remotesecure",
            "azureblobstorage",
            "hdfs",
            "odbc",
            "jdbc",
            "mongodb",
            "redis",
            "encrypt",
            "decrypt",
            "trydecrypt",
            "aes_encrypt_mysql",
            "aes_decrypt_mysql",
        ],
        _ => &[],
    };
    carriers.iter().any(|carrier| carrier.eq_ignore_ascii_case(word))
}

fn names_an_object(tokens: &[Token<'_>], at: usize) -> bool {
    let Some(Token::Word(before)) = at.checked_sub(1).and_then(|index| tokens.get(index)) else {
        return false;
    };
    if NAME_POSITIONS.iter().any(|word| before.eq_ignore_ascii_case(word)) {
        return true;
    }
    before.eq_ignore_ascii_case("ON")
        && tokens[..at]
            .iter()
            .any(|token| matches!(token, Token::Word(word) if word.eq_ignore_ascii_case("INDEX")))
}

fn routine_body_at(tokens: &[Token<'_>], at: usize, driver_id: &str) -> bool {
    if driver_id != "postgres" {
        return false;
    }
    let word_before = |back: usize| match at.checked_sub(back).and_then(|index| tokens.get(index)) {
        Some(Token::Word(word)) => word.to_ascii_uppercase(),
        _ => String::new(),
    };
    if matches!(word_before(1).as_str(), "DO" | "EXECUTE") || (word_before(3) == "DO" && word_before(2) == "LANGUAGE") {
        return true;
    }
    word_before(1) == "AS"
        && tokens[..at]
            .iter()
            .any(|token| matches!(token, Token::Word(word) if word.eq_ignore_ascii_case("FUNCTION") || word.eq_ignore_ascii_case("PROCEDURE")))
}

fn secret_text(text: &str) -> bool {
    let lower = text.to_ascii_lowercase();
    if ["password=", "pwd=", "passwd=", "password =", "pwd ="]
        .iter()
        .any(|key| lower.contains(key))
    {
        return true;
    }
    lower.match_indices("://").any(|(offset, _)| {
        let authority = lower[offset + 3..]
            .split(['/', '\'', '"', ' '])
            .next()
            .unwrap_or_default();
        authority
            .split_once('@')
            .is_some_and(|(user_info, _)| user_info.contains(':'))
    })
}

fn unquote(text: &str) -> String {
    let inner = text.strip_prefix(['E', 'e']).unwrap_or(text);
    let inner = inner
        .strip_prefix('\'')
        .and_then(|rest| rest.strip_suffix('\''))
        .unwrap_or(inner);
    inner.replace("''", "'")
}

fn lex<'a>(sql: &'a str, driver_id: &str) -> Option<Vec<Token<'a>>> {
    let mut tokens = Vec::new();
    let mut at = 0;
    while let Some(character) = sql[at..].chars().next() {
        let rest = &sql[at..];
        if character.is_whitespace() {
            at += character.len_utf8();
            continue;
        }
        if let Some(length) = skip_span(rest, driver_id).filter(|length| *length > 0) {
            let span = &rest[..length];
            if let Some(token) = span_token(span, length == rest.len(), driver_id)? {
                tokens.push(token);
            }
            at += length;
            continue;
        }
        if character.is_alphanumeric() || matches!(character, '_' | '@' | '#') {
            let length = rest
                .find(|next: char| !(next.is_alphanumeric() || matches!(next, '_' | '@' | '#' | '$')))
                .unwrap_or(rest.len());
            tokens.push(Token::Word(&rest[..length]));
            at += length;
            continue;
        }
        tokens.push(Token::Punct(character));
        at += character.len_utf8();
    }
    Some(tokens)
}

fn span_token<'a>(span: &'a str, reaches_end: bool, driver_id: &str) -> Option<Option<Token<'a>>> {
    if span.starts_with("--") || (driver_id == "mysql" && span.starts_with('#')) {
        return Some(None);
    }
    if let Some(comment) = span.strip_prefix("/*") {
        let body = comment.strip_suffix("*/")?;
        let executable = driver_id == "mysql" && body.starts_with('!');
        return Some(executable.then_some(Token::Body(
            body.trim_start_matches(|c: char| c == '!' || c.is_ascii_digit()),
        )));
    }
    if let Some(after_dollar) = span.strip_prefix('$') {
        let tag_end = after_dollar.find('$')? + 2;
        let tag = &span[..tag_end];
        let closed = span.len() >= tag.len() * 2 && span.ends_with(tag);
        return closed.then_some(Some(Token::Body(&span[tag.len()..span.len() - tag.len()])));
    }
    let quote = span.trim_start_matches(['E', 'e']).chars().next()?;
    let closing = match quote {
        '[' => ']',
        other => other,
    };
    let closed = span.len() >= 2 && span.ends_with(closing) && !(reaches_end && span.len() == 1);
    if !closed {
        return None;
    }
    Some(match quote {
        '\'' => Some(Token::Text(span)),
        _ => Some(Token::Word(span)),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn statements_that_set_passwords_or_keys_are_withheld() {
        for (driver, sql) in [
            ("postgres", "ALTER ROLE app PASSWORD 'secret'"),
            ("postgres", "CREATE USER u WITH LOGIN PASSWORD 'p'"),
            (
                "postgres",
                "CREATE USER MAPPING FOR u SERVER s OPTIONS (user 'u', password 'p')",
            ),
            (
                "postgres",
                "CREATE SUBSCRIPTION s CONNECTION 'host=h dbname=d' PUBLICATION p",
            ),
            ("postgres", "SELECT dblink_connect('host=h password=p')"),
            (
                "postgres",
                "SELECT a.id FROM a JOIN b ON public.dblink_connect('c') = b.v",
            ),
            ("postgres", "SELECT pgp_sym_encrypt('text', 'key')"),
            ("postgres", "DO $$BEGIN EXECUTE 'ALTER ROLE app PASSWORD ''x'''; END$$"),
            ("postgres", "DO 'BEGIN ALTER ROLE app PASSWORD ''x''; END'"),
            ("postgres", "SELECT 1; ALTER ROLE app PASSWORD 'secret'"),
            ("mysql", "CREATE USER 'u'@'%' IDENTIFIED BY 'p'"),
            ("mysql", "SET PASSWORD FOR 'u'@'%' = 'p'"),
            ("mysql", "CHANGE REPLICATION SOURCE TO SOURCE_PASSWORD = 'p'"),
            ("mysql", "START GROUP_REPLICATION USER = 'u', PASSWORD = 'p'"),
            ("mysql", "SELECT AES_ENCRYPT('text', 'key')"),
            (
                "mysql",
                "CREATE TABLE t (id int) /*!50100 ENGINE=FEDERATED CONNECTION='mysql://u:p@h/d/t' */",
            ),
            ("mssql", "ALTER LOGIN app WITH PASSWORD = 'p'"),
            (
                "mssql",
                "CREATE DATABASE SCOPED CREDENTIAL c WITH IDENTITY = 'u', SECRET = 's'",
            ),
            ("mssql", "EXEC sp_addlinkedsrvlogin 'srv', 'false', NULL, 'u', 'p'"),
            (
                "mssql",
                "SELECT * FROM OPENROWSET('SQLNCLI', 'Server=h;UID=u;PWD=p', 'SELECT 1')",
            ),
            ("clickhouse", "SELECT * FROM s3('https://b/f.csv', 'key', 'secret')"),
            (
                "clickhouse",
                "CREATE TABLE t (id Int32) ENGINE = URL('http://u:p@h/f.csv', CSV)",
            ),
            (
                "clickhouse",
                "INSERT INTO FUNCTION remote('h', db.t, 'u', 'p') VALUES (1)",
            ),
            ("redis", "AUTH secret"),
            ("redis", "CONFIG SET requirepass secret"),
            ("redis", "ACL SETUSER u on >secret"),
            ("mongodb", "db.createUser({user: 'u', pwd: 'p', roles: []})"),
        ] {
            assert!(carries_credentials(sql, driver), "{driver}: {sql}");
        }
    }

    #[test]
    fn plain_statements_are_kept() {
        for (driver, sql) in [
            ("postgres", "SELECT password FROM users WHERE id = 1"),
            ("postgres", "INSERT INTO users (name, password) VALUES ('a', 'b')"),
            ("postgres", "UPDATE accounts SET password_hash = $1 WHERE id = $2"),
            ("postgres", "CREATE ROLE reporting"),
            ("postgres", "SELECT 'it''s fine', $$ dollar text $$"),
            ("postgres", "SELECT 'https://example.com/a:b'"),
            ("mysql", "SELECT start, password FROM sessions"),
            ("mysql", "CREATE TABLE url (id int)"),
            ("mysql", "CREATE TABLE users (id int, password varchar(64) DEFAULT 'x')"),
            ("postgres", "CREATE TABLE user_keys (key text DEFAULT 'k')"),
            ("postgres", "ALTER TABLE users ADD COLUMN password text"),
            ("clickhouse", "CREATE TABLE s3 (id Int32) ENGINE = Memory"),
            ("clickhouse", "SELECT url, domain(url) FROM visits"),
            ("clickhouse", "CREATE INDEX i ON s3 (id) TYPE minmax"),
            ("mssql", "SELECT [password] FROM dbo.users"),
            ("redis", "GET session:1"),
            ("sqlite", "SELECT 1 -- ALTER ROLE app PASSWORD 'x'"),
        ] {
            assert!(!carries_credentials(sql, driver), "{driver}: {sql}");
        }
    }

    #[test]
    fn text_that_does_not_lex_cleanly_is_withheld() {
        for (driver, sql) in [
            ("postgres", "ALTER ROLE app PASSWORD 'unterminated"),
            ("postgres", "SELECT 1 /* open comment"),
            ("postgres", "SELECT $$ open body"),
            ("mssql", "SELECT [open"),
        ] {
            assert!(carries_credentials(sql, driver), "{driver}: {sql}");
        }
    }
}
