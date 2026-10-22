use std::collections::{BTreeSet, HashSet};
use std::ops::RangeInclusive;

use crate::sql_syntax::SqlGrammar;

/// How the lexer reads the MySQL text whose meaning hangs on who reads
/// it: an executable comment (`/*! … */`, `/*!50100 … */`, MariaDB's
/// `/*M!100100 … */`), a `$tag$` quote and a `DELIMITER` line.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum ServerReading {
    /// As the mysql client reads a script to split it: every executable
    /// comment is code, `$` is a name character, and a `DELIMITER` line
    /// is the client's.
    Client,
    /// What one server session runs of the text it is sent: the comments
    /// its version allows, names quoted as its sql_mode says, and no
    /// `DELIMITER` line, which only a client reads.
    Server {
        server: Server,
        version: u32,
        quotes: NameQuotes,
    },
}

impl ServerReading {
    pub(crate) fn reads_directives(self) -> bool {
        self == Self::Client
    }

    pub(crate) fn quotes_dollar_tags(self) -> bool {
        matches!(
            self,
            Self::Server {
                server: Server::MySql81,
                ..
            }
        )
    }

    pub(crate) fn name_quotes(self) -> NameQuotes {
        match self {
            Self::Client => NameQuotes::Default,
            Self::Server { quotes, .. } => quotes,
        }
    }
}

/// What a session's sql_mode makes of `"` and `[`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub(crate) enum NameQuotes {
    /// `"` quotes a string and `[` is punctuation.
    Default,
    /// ANSI_QUOTES: `"` quotes a name, where a backslash escapes nothing.
    Ansi,
    /// MariaDB's MSSQL mode: ANSI_QUOTES, and `[name]` quotes a name.
    Brackets,
}

/// The servers that read the same text differently.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub(crate) enum Server {
    /// Up to 8.0: five version digits, and `$` is a name character.
    MySql80,
    /// 8.1 and later: six version digits when whitespace follows them,
    /// and `$tag$` opens a quote.
    MySql81,
    MariaDb,
    /// A Galera node also runs `/*!99997` comments.
    MariaDbGalera,
}

impl Server {
    const ALL: [Server; 4] = [Self::MySql80, Self::MySql81, Self::MariaDb, Self::MariaDbGalera];

    fn mariadb(self) -> bool {
        matches!(self, Self::MariaDb | Self::MariaDbGalera)
    }
}

/// What one executable comment is under a reading.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub(crate) enum CommentRead {
    /// Code from `content_start` to the `*/` that ends it.
    Runs { content_start: usize },
    /// Skipped to its first `*/`, past one `/* */` of its own.
    Skipped,
}

/// More versions than this in one text are more readings than worth
/// trying, so the text counts as unreadable.
const MAX_VERSIONS: usize = 16;

/// The bytes all readings of one text may lex between them, about a
/// second's work, since Safe Mode reads a statement before it runs.
const MAX_LEXED_BYTES: usize = 32 * 1024 * 1024;

/// MariaDB skips `/*!` comments for these MySQL versions, whose syntax
/// it may lack.
const MARIADB_SKIPS: RangeInclusive<u32> = 50_700..=99_999;

const GALERA_RUNS: u32 = 99_997;

/// `bytes` starts at a `/*`. `None` when the reading takes it for a
/// plain comment.
pub(crate) fn read_at(bytes: &[u8], reading: ServerReading) -> Option<CommentRead> {
    let (mariadb_marker, marker_len) = match bytes.get(2..)? {
        [b'!', ..] => (false, 3),
        [b'M', b'!', ..] => (true, 4),
        _ => return None,
    };
    let after = bytes.get(marker_len..).unwrap_or_default();
    let ServerReading::Server { server, version, .. } = reading else {
        let digits = after.iter().take_while(|b| b.is_ascii_digit()).count();
        return Some(CommentRead::Runs {
            content_start: marker_len + digits,
        });
    };
    // MySQL knows no `/*M!`.
    if mariadb_marker && !server.mariadb() {
        return None;
    }
    let Some((gate, digits)) = version_gate(after, server) else {
        return Some(CommentRead::Runs {
            content_start: marker_len,
        });
    };
    let skipped = gate > version || (server.mariadb() && !mariadb_marker && MARIADB_SKIPS.contains(&gate));
    Some(match skipped {
        // Galera runs a skipped 99997 past five digits only, a sixth
        // left as code.
        true if server == Server::MariaDbGalera && gate == GALERA_RUNS => CommentRead::Runs {
            content_start: marker_len + 5,
        },
        true => CommentRead::Skipped,
        false => CommentRead::Runs {
            content_start: marker_len + digits,
        },
    })
}

/// The version `after`'s leading digits gate the comment on, and how many
/// digits that takes. With fewer than five the comment always runs and
/// the digits are code.
fn version_gate(after: &[u8], server: Server) -> Option<(u32, usize)> {
    let digit = |at: usize| after.get(at).is_some_and(u8::is_ascii_digit);
    if !(0..5).all(digit) {
        return None;
    }
    let six = digit(5)
        && match server {
            Server::MySql80 => false,
            Server::MySql81 => after
                .get(6)
                .is_some_and(|b| matches!(b, b' ' | b'\t' | b'\n' | b'\r' | 0x0b | 0x0c)),
            Server::MariaDb | Server::MariaDbGalera => true,
        };
    let len = if six { 6 } else { 5 };
    let version = after[..len]
        .iter()
        .fold(0u32, |value, digit| value * 10 + u32::from(digit - b'0'));
    Some((version, len))
}

/// Where the `$tag$` opener that starts at `at` ends, when one does: a
/// tag of letters, digits, `_` or multibyte characters, maybe empty.
pub(crate) fn dollar_tag_end(bytes: &[u8], at: usize) -> Option<usize> {
    let tag = bytes
        .get(at + 1..)?
        .iter()
        .take_while(|&&b| b.is_ascii_alphanumeric() || b == b'_' || b >= 0x80)
        .count();
    let end = at + tag + 2;
    (bytes.get(end - 1) == Some(&b'$')).then_some(end)
}

/// The client's reading of `text`, then each distinct one the servers it
/// may meet give it: each kind of server at version 0 and at each version
/// the text's comments name, since only those change which comments run.
/// `None` when there are more than are worth trying.
pub(crate) fn server_readings(text: &str, grammar: SqlGrammar) -> Option<Vec<ServerReading>> {
    let mut readings = vec![ServerReading::Client];
    if grammar != SqlGrammar::MySql {
        return Some(readings);
    }
    let bytes = text.as_bytes();
    // Every marker counts, even one inside a string, since another reading
    // may find it outside one.
    let markers: Vec<usize> = ["/*!", "/*M!"]
        .into_iter()
        .flat_map(|marker| text.match_indices(marker).map(|(at, _)| at))
        .collect();
    let dollars = bytes
        .iter()
        .enumerate()
        .any(|(at, &b)| b == b'$' && dollar_tag_end(bytes, at).is_some());
    let directives = text.lines().any(|line| {
        let line = line.trim_start();
        line.get(..9).is_some_and(|word| word.eq_ignore_ascii_case("delimiter")) || line.starts_with("\\d")
    });
    let mut quotes = vec![NameQuotes::Default];
    // Without a backslash, a `"` name and a `"` string end alike.
    if text.contains('"') && text.contains('\\') {
        quotes.push(NameQuotes::Ansi);
    }
    if text.contains('[') {
        quotes.push(NameQuotes::Brackets);
    }
    if markers.is_empty() && !dollars && !directives && quotes.len() == 1 {
        return Some(readings);
    }
    // A marker's reading turns on its opener, six digits and the byte
    // after them, so markers alike there read alike.
    let shapes: BTreeSet<&[u8]> = markers
        .iter()
        .filter_map(|&at| bytes.get(at..(at + 11).min(bytes.len())))
        .collect();
    let mut versions = BTreeSet::from([0]);
    for shape in &shapes {
        let marker_len = if shape.get(2) == Some(&b'M') { 4 } else { 3 };
        let after = shape.get(marker_len..).unwrap_or_default();
        versions.extend(
            Server::ALL
                .into_iter()
                .filter_map(|server| version_gate(after, server).map(|(version, _)| version)),
        );
        if versions.len() > MAX_VERSIONS {
            return None;
        }
    }
    // Two readings that read every marker, `$tag$` and name quote alike
    // lex the text alike.
    let mut seen = HashSet::new();
    for server in Server::ALL {
        for &version in &versions {
            for &quotes in &quotes {
                if quotes == NameQuotes::Brackets && !server.mariadb() {
                    continue;
                }
                let reading = ServerReading::Server {
                    server,
                    version,
                    quotes,
                };
                let decisions: Vec<Option<CommentRead>> = shapes.iter().map(|shape| read_at(shape, reading)).collect();
                if seen.insert((reading.quotes_dollar_tags() && dollars, quotes, decisions)) {
                    readings.push(reading);
                    // Each reading is lexed with backslash escapes on and off.
                    if readings.len() * 2 * text.len() > MAX_LEXED_BYTES {
                        return None;
                    }
                }
            }
        }
    }
    Some(readings)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn read(comment: &str, server: Server, version: u32) -> Option<CommentRead> {
        read_at(
            comment.as_bytes(),
            ServerReading::Server {
                server,
                version,
                quotes: NameQuotes::Default,
            },
        )
    }

    #[test]
    fn a_version_comment_runs_on_a_server_at_least_that_new() {
        assert_eq!(
            read("/*!80047 x */", Server::MySql80, 80_046),
            Some(CommentRead::Skipped)
        );
        assert_eq!(
            read("/*!80047 x */", Server::MySql81, 80_411),
            Some(CommentRead::Runs { content_start: 8 })
        );
        assert_eq!(
            read("/*!8004 x */", Server::MySql80, 0),
            Some(CommentRead::Runs { content_start: 3 })
        );
        assert_eq!(
            read("/*! x */", Server::MariaDb, 0),
            Some(CommentRead::Runs { content_start: 3 })
        );
    }

    #[test]
    fn each_server_reads_a_sixth_digit_its_own_way() {
        let comment = "/*!101119 x */";
        assert_eq!(
            read(comment, Server::MySql80, 99_999),
            Some(CommentRead::Runs { content_start: 8 })
        );
        assert_eq!(read(comment, Server::MySql81, 99_999), Some(CommentRead::Skipped));
        assert_eq!(
            read("/*!101119,x */", Server::MySql81, 99_999),
            Some(CommentRead::Runs { content_start: 8 })
        );
        assert_eq!(
            read("/*!101119,x */", Server::MariaDb, 101_118),
            Some(CommentRead::Skipped)
        );
    }

    #[test]
    fn mariadb_skips_mysql_57_comments_and_mysql_knows_no_mariadb_ones() {
        assert_eq!(
            read("/*!50700 x */", Server::MariaDb, 101_119),
            Some(CommentRead::Skipped)
        );
        assert_eq!(
            read("/*M!50700 x */", Server::MariaDb, 101_119),
            Some(CommentRead::Runs { content_start: 9 })
        );
        assert_eq!(read("/*M! x */", Server::MySql81, 90_700), None);
        assert_eq!(read("/* x */", Server::MariaDb, 0), None);
    }

    #[test]
    fn a_galera_node_runs_99997_comments_mariadb_skips() {
        for (comment, galera) in [
            ("/*!99997 x */", Some(CommentRead::Runs { content_start: 8 })),
            ("/*!099997 x */", Some(CommentRead::Runs { content_start: 8 })),
            ("/*!999970 x */", Some(CommentRead::Skipped)),
        ] {
            assert_eq!(read(comment, Server::MariaDbGalera, 101_119), galera, "{comment}");
            assert_eq!(
                read(comment, Server::MariaDb, 101_119),
                Some(CommentRead::Skipped),
                "{comment}"
            );
        }
    }

    #[test]
    fn each_distinct_reading_is_tried_once() {
        let text = "/*!40101 a */ /*!101119 b */";
        let readings = server_readings(text, SqlGrammar::MySql).unwrap_or_default();
        let decisions: Vec<Vec<Option<CommentRead>>> = readings
            .iter()
            .map(|&reading| {
                [0, 14]
                    .map(|at| read_at(text.as_bytes().get(at..).unwrap_or_default(), reading))
                    .to_vec()
            })
            .collect();
        let runs = |content_start| Some(CommentRead::Runs { content_start });
        let skipped = Some(CommentRead::Skipped);

        assert_eq!(
            decisions,
            [
                vec![runs(8), runs(9)],
                vec![skipped, skipped],
                vec![skipped, runs(8)],
                vec![runs(8), runs(8)],
                vec![runs(8), skipped],
                vec![runs(8), runs(9)],
            ]
        );
        assert_eq!(
            server_readings("SELECT 1", SqlGrammar::MySql),
            Some(vec![ServerReading::Client])
        );
        // A server reads a DELIMITER line as SQL.
        assert_eq!(
            server_readings("SELECT 1;\n  delimiter //", SqlGrammar::MySql).map(|readings| readings.len()),
            Some(2)
        );
        assert_eq!(
            server_readings("SELECT $$x$$", SqlGrammar::MySql).map(|readings| readings.len()),
            Some(3)
        );
        assert_eq!(
            server_readings("SELECT data->'$.a', $x FROM t", SqlGrammar::MySql),
            Some(vec![ServerReading::Client])
        );
        assert_eq!(
            server_readings("SELECT /*! 1 */", SqlGrammar::PostgreSql),
            Some(vec![ServerReading::Client])
        );
    }

    #[test]
    fn too_many_readings_are_unreadable() {
        let versions: String = (0..20).map(|n| format!("/*!{} x */", 40_000 + n)).collect();
        let long = format!("/*!40000 x */ /*M!40001 y */ '\"\\[' {}", "x".repeat(2 * 1024 * 1024));

        assert_eq!(server_readings(&versions, SqlGrammar::MySql), None);
        assert_eq!(server_readings(&long, SqlGrammar::MySql), None);
        assert!(server_readings(&"x".repeat(64 * 1024 * 1024), SqlGrammar::MySql).is_some());
    }
}
