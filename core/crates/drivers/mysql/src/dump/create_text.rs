use std::collections::HashSet;
use std::ops::Range;

use tablepro_core::sql_syntax::SqlGrammar;
use tablepro_core::sql_syntax::script::{LexicalSettings, ScriptPlan, ScriptToken, ScriptTokenKind};

/// The words that end the part of a CREATE where `DEFINER=` can stand.
const OBJECT_WORDS: [&str; 7] = [
    "VIEW",
    "FUNCTION",
    "PROCEDURE",
    "TRIGGER",
    "EVENT",
    "AGGREGATE",
    "PACKAGE",
];

/// `create` without its `DEFINER=user@host`: the account may not exist
/// where the file loads, and without the clause the server makes
/// whoever runs the CREATE the definer.
pub(crate) fn without_definer(create: &str) -> String {
    let tokens = significant(create);
    let head = tokens
        .iter()
        .position(|token| OBJECT_WORDS.iter().any(|word| is_word(create, token, word)))
        .unwrap_or(tokens.len());
    for (at, window) in tokens[..head].windows(3).enumerate() {
        let [definer, equals, _user] = window else {
            continue;
        };
        if !is_word(create, definer, "DEFINER") || text(create, equals) != "=" {
            continue;
        }
        let mut last = at + 2;
        match tokens.get(last + 1).map(|token| text(create, token)) {
            Some("@") => last += 2,
            Some(host) if host.starts_with('@') => last += 1,
            _ => {}
        }
        let end = tokens.get(last + 1).map_or(create.len(), |next| next.range.start);
        return cut(create, std::slice::from_ref(&(definer.range.start..end)));
    }
    create.to_owned()
}

/// `create` with `` `database`. `` gone from before the names of the
/// dump's own objects, so the file loads into a database of any name.
/// MySQL qualifies a stored function a view calls, and every name of a
/// view that reads another database too; MariaDB qualifies the sequence
/// a column's default takes from; a routine or trigger keeps its body as
/// written. `names` is in lower case.
///
/// A text that names the database other than as `name.` keeps every
/// qualifier: there the name can be a table alias, which SHOW CREATE
/// VIEW writes without `AS`, a label, a variable or a table of another
/// database, and `name.` can mean that one.
pub(crate) fn without_database(create: &str, database: &str, names: &HashSet<String>, reading: ModeReading) -> String {
    let tokens = reading.tokens(create);
    let name_of = |token: &ScriptToken| reading.name_of(create, token);
    let alone = (0..tokens.len()).any(|at| {
        let named = name_of(&tokens[at]).is_some_and(|name| name.eq_ignore_ascii_case(database));
        let qualifies = tokens.get(at + 1).is_some_and(|token| text(create, token) == ".");
        named && !qualifies
    });
    if alone {
        return create.to_owned();
    }
    let mut cuts = Vec::new();
    for (at, window) in tokens.windows(3).enumerate() {
        let [qualifier, dot, name] = window else {
            continue;
        };
        let follows_dot = at
            .checked_sub(1)
            .is_some_and(|before| text(create, &tokens[before]) == ".");
        let names_ours = name_of(name).is_some_and(|name| names.contains(&name.to_lowercase()));
        if !follows_dot && name_of(qualifier).as_deref() == Some(database) && text(create, dot) == "." && names_ours {
            cuts.push(qualifier.range.start..dot.range.end);
        }
    }
    cut(create, &cuts)
}

/// A table whose rows are another server's, through FEDERATED or
/// MariaDB's CONNECT: its CREATE would reach that server again on load,
/// password and all, and its rows would be written there. Read from the
/// table options, not from a comment or a default that spells one.
pub(crate) fn remote_table(create: &str) -> bool {
    let tokens = significant(create);
    tokens.windows(3).any(|window| {
        let [option, equals, value] = window else {
            return false;
        };
        if text(create, equals) != "=" {
            return false;
        }
        is_word(create, option, "CONNECTION")
            || (is_word(create, option, "ENGINE")
                && (is_word(create, value, "FEDERATED") || is_word(create, value, "CONNECT")))
    })
}

fn significant(sql: &str) -> Vec<ScriptToken> {
    let plan = ScriptPlan::build(sql, SqlGrammar::MySql, LexicalSettings::default_for(SqlGrammar::MySql));
    plan.tokens(0..sql.len())
        .filter(|token| !token.kind.is_trivia())
        .collect()
}

fn text<'a>(sql: &'a str, token: &ScriptToken) -> &'a str {
    sql.get(token.range.clone()).unwrap_or_default()
}

fn is_word(sql: &str, token: &ScriptToken, word: &str) -> bool {
    token.kind == ScriptTokenKind::Word && text(sql, token).eq_ignore_ascii_case(word)
}

/// How a text reads under the `sql_mode` a routine or trigger was made
/// in: `ANSI_QUOTES` makes `"name"` a name, and `NO_BACKSLASH_ESCAPES`
/// ends a string at a quote after a backslash. SHOW CREATE TABLE and
/// VIEW print under the session's mode, which is the default here.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct ModeReading {
    ansi_quotes: bool,
    backslash_escapes: bool,
}

impl ModeReading {
    pub(crate) fn of(sql_mode: Option<&str>) -> Self {
        let mode = sql_mode.unwrap_or_default().to_ascii_uppercase();
        let has = |flag: &str| mode.split(',').any(|set| set.trim() == flag);
        Self {
            ansi_quotes: has("ANSI_QUOTES"),
            backslash_escapes: !has("NO_BACKSLASH_ESCAPES"),
        }
    }

    fn tokens(self, sql: &str) -> Vec<ScriptToken> {
        let settings = LexicalSettings {
            backslash_escapes: self.backslash_escapes,
        };
        ScriptPlan::build(sql, SqlGrammar::MySql, settings)
            .tokens(0..sql.len())
            .filter(|token| !token.kind.is_trivia())
            .collect()
    }

    /// The name a token spells, quoted or not.
    fn name_of(self, sql: &str, token: &ScriptToken) -> Option<String> {
        let spelled = text(sql, token);
        match token.kind {
            ScriptTokenKind::Word => Some(spelled.to_owned()),
            ScriptTokenKind::QuotedIdentifier => {
                let inner = spelled.strip_prefix('`')?.strip_suffix('`')?;
                Some(inner.replace("``", "`"))
            }
            ScriptTokenKind::StringLiteral if self.ansi_quotes => {
                let inner = spelled.strip_prefix('"')?.strip_suffix('"')?;
                Some(inner.replace("\"\"", "\""))
            }
            _ => None,
        }
    }
}

fn cut(sql: &str, cuts: &[Range<usize>]) -> String {
    let mut kept = String::with_capacity(sql.len());
    let mut from = 0;
    for range in cuts {
        kept.push_str(sql.get(from..range.start).unwrap_or_default());
        from = range.end;
    }
    kept.push_str(sql.get(from..).unwrap_or_default());
    kept
}

#[cfg(test)]
mod tests {
    use super::*;

    fn names(list: &[&str]) -> HashSet<String> {
        list.iter().map(|name| (*name).to_owned()).collect()
    }

    #[test]
    fn the_definer_goes_and_the_security_stays() {
        assert_eq!(
            without_definer(
                "CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`%` SQL SECURITY DEFINER VIEW `v` AS select 1 AS `1`"
            ),
            "CREATE ALGORITHM=UNDEFINED SQL SECURITY DEFINER VIEW `v` AS select 1 AS `1`"
        );
        assert_eq!(
            without_definer("CREATE DEFINER=`app``s`@`localhost` FUNCTION `f`() RETURNS int\nRETURN 1"),
            "CREATE FUNCTION `f`() RETURNS int\nRETURN 1"
        );
        assert_eq!(
            without_definer(
                "CREATE DEFINER=`root`@`%` TRIGGER `t` BEFORE INSERT ON `c` FOR EACH ROW SET NEW.definer = 'x'"
            ),
            "CREATE TRIGGER `t` BEFORE INSERT ON `c` FOR EACH ROW SET NEW.definer = 'x'"
        );
    }

    #[test]
    fn a_role_definer_has_no_host() {
        assert_eq!(
            without_definer("CREATE DEFINER=`reporting` PROCEDURE `p`()\nBEGIN SELECT 1; END"),
            "CREATE PROCEDURE `p`()\nBEGIN SELECT 1; END"
        );
    }

    #[test]
    fn a_definer_in_the_body_is_not_the_clause() {
        let create = "CREATE PROCEDURE `p`()\nBEGIN SET @x = 'DEFINER=`root`@`%`'; END";

        assert_eq!(without_definer(create), create);
    }

    #[test]
    fn the_database_comes_off_names_of_the_dumps_own_objects() {
        let ours = names(&["label_of", "parent", "invoice_no"]);

        assert_eq!(
            without_database(
                "CREATE VIEW `v` AS select `app`.`label_of`(`p`.`id`) AS `l` from `app`.`parent` `p`",
                "app",
                &ours,
                ModeReading::of(None)
            ),
            "CREATE VIEW `v` AS select `label_of`(`p`.`id`) AS `l` from `parent` `p`"
        );
        assert_eq!(
            without_database(
                "CREATE TABLE `invoice` (\n  `no` bigint(20) NOT NULL DEFAULT nextval(`app`.`invoice_no`)\n)",
                "app",
                &ours,
                ModeReading::of(None)
            ),
            "CREATE TABLE `invoice` (\n  `no` bigint(20) NOT NULL DEFAULT nextval(`invoice_no`)\n)"
        );
    }

    #[test]
    fn other_databases_columns_and_literals_keep_their_qualifier() {
        let ours = names(&["parent"]);
        let create = "CREATE VIEW `v` AS select `app`.`id` AS `id`, '`app`.`parent`' AS `s` \
                      from `other`.`parent` where `x`.`app`.`parent` = 1";

        assert_eq!(
            without_database(create, "app", &ours, ModeReading::of(None)),
            "CREATE VIEW `v` AS select `app`.`id` AS `id`, '`app`.`parent`' AS `s` \
             from `other`.`parent` where `x`.`app`.`parent` = 1"
        );
    }

    #[test]
    fn a_view_with_an_alias_named_like_the_database_keeps_its_qualifiers() {
        let ours = names(&["items", "id"]);
        let create = "CREATE VIEW `v` AS select `shop`.`id` AS `id` \
                      from (`shop`.`items` `shop` join `shop`.`id` `j` on(`j`.`id` = `shop`.`id`))";

        assert_eq!(without_database(create, "shop", &ours, ModeReading::of(None)), create);
    }

    #[test]
    fn a_remote_table_is_read_from_its_options() {
        assert!(remote_table(
            "CREATE TABLE `r` (\n  `id` int\n) ENGINE=FEDERATED DEFAULT CHARSET=utf8mb4 \
             CONNECTION='mysql://u:p@h/db/t'"
        ));
        assert!(remote_table(
            "CREATE TABLE `r` (\n  `id` int\n) ENGINE=CONNECT TABLE_TYPE=MYSQL"
        ));
        assert!(!remote_table(
            "CREATE TABLE `l` (\n  `note` varchar(40) DEFAULT 'CONNECTION=x'\n) ENGINE=InnoDB \
             COMMENT='was ENGINE=CONNECT'"
        ));
    }

    #[test]
    fn a_routine_body_loses_the_qualifier_as_written() {
        let ours = names(&["orders", "label_of"]);
        let create = "CREATE PROCEDURE `p`()\nBEGIN\n  SELECT shop.label_of(id) FROM shop.orders o;\n  \
                      SELECT * FROM `shop`.`orders` JOIN other.orders USING (id);\nEND";

        assert_eq!(
            without_database(create, "shop", &ours, ModeReading::of(None)),
            "CREATE PROCEDURE `p`()\nBEGIN\n  SELECT label_of(id) FROM orders o;\n  \
             SELECT * FROM `orders` JOIN other.orders USING (id);\nEND"
        );
    }

    #[test]
    fn a_routine_made_under_ansi_quotes_loses_a_double_quoted_qualifier() {
        let ours = names(&["t"]);
        let create = "CREATE PROCEDURE `p`()\nBEGIN\n  DELETE FROM \"shop\".\"t\" WHERE note = 'a\\';\nEND";
        let reading = ModeReading::of(Some("ANSI_QUOTES,NO_BACKSLASH_ESCAPES"));

        assert_eq!(
            without_database(create, "shop", &ours, reading),
            "CREATE PROCEDURE `p`()\nBEGIN\n  DELETE FROM \"t\" WHERE note = 'a\\';\nEND"
        );
        assert_eq!(without_database(create, "shop", &ours, ModeReading::of(None)), create);
    }

    #[test]
    fn a_body_that_names_the_database_alone_keeps_it() {
        let ours = names(&["orders"]);
        let create = "CREATE TRIGGER `t` AFTER INSERT ON `orders` FOR EACH ROW \
                      UPDATE shop.orders SET total = 0 WHERE shop.id IN (SELECT id FROM orders shop)";

        assert_eq!(without_database(create, "shop", &ours, ModeReading::of(None)), create);
    }
}
