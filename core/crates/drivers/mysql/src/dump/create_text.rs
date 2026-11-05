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
        return cut(create, &[definer.range.start..end]);
    }
    create.to_owned()
}

/// `create` with `` `database`. `` gone from before the names of the
/// dump's own objects, so the file loads into a database of any name.
/// MySQL qualifies a stored function a view calls, and every name of a
/// view that reads another database too; MariaDB qualifies the sequence
/// a column's default takes from. `names` is in lower case. A column
/// qualified by a table that shares the database's name keeps it.
pub(crate) fn without_database(create: &str, database: &str, names: &HashSet<String>) -> String {
    let tokens = significant(create);
    // A text that also uses the database's name as an alias can mean that
    // alias by `name.`, and nothing tells the two apart, so it is kept.
    let aliased = tokens.windows(2).any(|pair| {
        text(create, &pair[0]).eq_ignore_ascii_case("AS") && name_of(create, &pair[1]).as_deref() == Some(database)
    });
    if aliased {
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
        let names_ours = name_of(create, name).is_some_and(|name| names.contains(&name.to_lowercase()));
        if !follows_dot
            && name_of(create, qualifier).as_deref() == Some(database)
            && text(create, dot) == "."
            && names_ours
        {
            cuts.push(qualifier.range.start..dot.range.end);
        }
    }
    cut(create, &cuts)
}

/// [`without_database`] for a routine or trigger, whose body the server
/// keeps as written. There an alias, label or variable can take the
/// database's name without `AS`, and a table in another database can
/// too, so a body that names it other than as `name.` keeps every
/// qualifier.
pub(crate) fn program_without_database(create: &str, database: &str, names: &HashSet<String>) -> String {
    let tokens = significant(create);
    let alone = (0..tokens.len()).any(|at| {
        let named = name_of(create, &tokens[at]).is_some_and(|name| name.eq_ignore_ascii_case(database));
        let qualifies = tokens.get(at + 1).is_some_and(|token| text(create, token) == ".");
        named && !qualifies
    });
    if alone {
        return create.to_owned();
    }
    without_database(create, database, names)
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

/// The name a token spells, quoted or not.
fn name_of(sql: &str, token: &ScriptToken) -> Option<String> {
    match token.kind {
        ScriptTokenKind::Word => Some(text(sql, token).to_owned()),
        ScriptTokenKind::QuotedIdentifier => {
            let inner = text(sql, token).strip_prefix('`')?.strip_suffix('`')?;
            Some(inner.replace("``", "`"))
        }
        _ => None,
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
                &ours
            ),
            "CREATE VIEW `v` AS select `label_of`(`p`.`id`) AS `l` from `parent` `p`"
        );
        assert_eq!(
            without_database(
                "CREATE TABLE `invoice` (\n  `no` bigint(20) NOT NULL DEFAULT nextval(`app`.`invoice_no`)\n)",
                "app",
                &ours
            ),
            "CREATE TABLE `invoice` (\n  `no` bigint(20) NOT NULL DEFAULT nextval(`invoice_no`)\n)"
        );
    }

    #[test]
    fn other_databases_columns_and_literals_keep_their_qualifier() {
        let ours = names(&["app", "parent"]);
        let create = "CREATE VIEW `v` AS select `app`.`id` AS `id`, '`app`.`parent`' AS `s` \
                      from (`app` join `other`.`parent`) where `x`.`app`.`parent` = 1";

        assert_eq!(without_database(create, "app", &ours), create);
    }

    #[test]
    fn a_routine_body_loses_the_qualifier_as_written() {
        let ours = names(&["orders", "label_of"]);
        let create = "CREATE PROCEDURE `p`()\nBEGIN\n  SELECT shop.label_of(id) FROM shop.orders o;\n  \
                      SELECT * FROM `shop`.`orders` JOIN other.orders USING (id);\nEND";

        assert_eq!(
            program_without_database(create, "shop", &ours),
            "CREATE PROCEDURE `p`()\nBEGIN\n  SELECT label_of(id) FROM orders o;\n  \
             SELECT * FROM `orders` JOIN other.orders USING (id);\nEND"
        );
    }

    #[test]
    fn a_body_that_names_the_database_alone_keeps_it() {
        let ours = names(&["orders"]);
        let create = "CREATE TRIGGER `t` AFTER INSERT ON `orders` FOR EACH ROW \
                      UPDATE shop.orders SET total = 0 WHERE shop.id IN (SELECT id FROM orders shop)";

        assert_eq!(program_without_database(create, "shop", &ours), create);
    }
}
