//! The question Safe Mode asks before a write: the SQL in full, the
//! connection it runs on, and Cancel as the answer Enter gives.

use gtk4 as gtk;
use gtk4::glib;
use libadwaita as adw;
use libadwaita::prelude::*;
use tablepro_core::Value;
use tablepro_core::statement::Statement;

const CANCEL: &str = "cancel";
const PROCEED: &str = "proceed";

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct WriteConfirmation {
    pub heading: String,
    pub body: String,
    pub sql: String,
    /// The button that goes ahead, with its mnemonic.
    pub proceed: String,
    /// Drops, empties or rewrites a whole table, so the button is red.
    pub destructive: bool,
}

impl WriteConfirmation {
    /// Editor statements that need an answer before the run starts.
    pub(crate) fn statements(connection: &str, statements: &[String], destructive: bool) -> Self {
        let count = u32::try_from(statements.len()).unwrap_or(u32::MAX);
        let args = [("connection", connection), ("n", &statements.len().to_string())];
        let body = match destructive {
            true => crate::i18n::ngettext_f(
                "It drops or empties a table, or changes every row of one, on “{connection}”.",
                "Some of them drop or empty a table, or change every row of one, on “{connection}”.",
                count,
                &args,
            ),
            false => crate::i18n::ngettext_f(
                "It changes the database on “{connection}”, which asks before every write.",
                "They change the database on “{connection}”, which asks before every write.",
                count,
                &args,
            ),
        };
        Self {
            heading: crate::i18n::ngettext_f("Run This Statement?", "Run These {n} Statements?", count, &args),
            body,
            sql: statements.join("\n\n"),
            proceed: crate::i18n::gettext("_Run"),
            destructive,
        }
    }

    /// A statement an MCP client sent, asked about whatever the Safe Mode
    /// level: a client asking is not the user asking.
    pub(crate) fn external(connection: &str, sql: &str, destructive: bool) -> Self {
        let args = [("connection", connection)];
        let body = match destructive {
            true => crate::i18n::gettext_f(
                "An MCP client asks to drop or empty a table, or change every row of one, on “{connection}”.",
                &args,
            ),
            false => crate::i18n::gettext_f("An MCP client asks to change the database on “{connection}”.", &args),
        };
        Self {
            heading: crate::i18n::gettext("Run Statement from MCP Client?"),
            body,
            sql: with_hidden_characters_shown(sql),
            proceed: crate::i18n::gettext("_Run"),
            destructive,
        }
    }

    /// A grid save on a connection that asks before every write. The
    /// values go to the server as parameters, so each statement is
    /// followed by the values it binds.
    pub(crate) fn row_save(connection: &str, table: &str, statements: &[Statement]) -> Self {
        let sql = statements
            .iter()
            .map(|statement| {
                let mut text = terminated(&[statement.sql().to_owned()]);
                if !statement.params().is_empty() {
                    let values: Vec<String> = statement
                        .params()
                        .iter()
                        .map(|param| shown_value(param.value()))
                        .collect();
                    text.push_str("\n-- ");
                    text.push_str(&crate::i18n::gettext_f(
                        "Values: {values}",
                        &[("values", &values.join(", "))],
                    ));
                }
                text
            })
            .collect::<Vec<_>>()
            .join("\n");
        Self {
            heading: crate::i18n::gettext_f("Save Changes to “{table}”?", &[("table", table)]),
            body: asks_before_writes(connection),
            sql,
            proceed: crate::i18n::gettext("_Save"),
            destructive: false,
        }
    }

    /// A CSV import on a connection that asks before every write. A file
    /// can plan thousands of statements, so the first stands for them.
    pub(crate) fn import(connection: &str, table: &str, rows: usize, statements: &[String]) -> Self {
        let rows_text = rows.to_string();
        let count = statements.len();
        let mut body = asks_before_writes(connection);
        if count > 1 {
            body.push(' ');
            body.push_str(&crate::i18n::ngettext_f(
                "The import runs {n} statement; the first is shown.",
                "The import runs {n} statements; the first is shown.",
                u32::try_from(count).unwrap_or(u32::MAX),
                &[("n", &count.to_string())],
            ));
        }
        Self {
            heading: crate::i18n::ngettext_f(
                "Import {n} Row into “{table}”?",
                "Import {n} Rows into “{table}”?",
                u32::try_from(rows).unwrap_or(u32::MAX),
                &[("n", &rows_text), ("table", table)],
            ),
            body,
            sql: terminated(statements.get(..1).unwrap_or_default()),
            proceed: crate::i18n::gettext("_Import"),
            destructive: false,
        }
    }
}

/// A client's statement as the user should read it. A character that
/// draws nothing, or reorders the text around it, shows as its code
/// point, so the dialog cannot be made to read unlike what runs.
fn with_hidden_characters_shown(sql: &str) -> String {
    let mut shown = String::with_capacity(sql.len());
    for character in sql.chars() {
        match hides(character) {
            true => shown.push_str(&format!("\\u{{{:04X}}}", u32::from(character))),
            false => shown.push(character),
        }
    }
    shown
}

/// Unicode's Default_Ignorable_Code_Point set, which holds the bidi
/// controls, and the control characters other than line breaks and tabs.
fn hides(character: char) -> bool {
    matches!(
        character,
        '\u{00AD}'
            | '\u{034F}'
            | '\u{061C}'
            | '\u{115F}'..='\u{1160}'
            | '\u{17B4}'..='\u{17B5}'
            | '\u{180B}'..='\u{180F}'
            | '\u{200B}'..='\u{200F}'
            | '\u{202A}'..='\u{202E}'
            | '\u{2060}'..='\u{206F}'
            | '\u{3164}'
            | '\u{FE00}'..='\u{FE0F}'
            | '\u{FEFF}'
            | '\u{FFA0}'
            | '\u{FFF0}'..='\u{FFF8}'
            | '\u{1BCA0}'..='\u{1BCA3}'
            | '\u{1D173}'..='\u{1D17A}'
            | '\u{E0000}'..='\u{E0FFF}'
    ) || (character.is_control() && !matches!(character, '\n' | '\r' | '\t'))
}

/// The sentence that names the connection and why it asks.
pub(crate) fn asks_before_writes(connection: &str) -> String {
    crate::i18n::gettext_f(
        "Safe Mode on “{connection}” asks before every change to the database.",
        &[("connection", connection)],
    )
}

/// A bound value as the user would write it, on one line.
fn shown_value(value: &Value) -> String {
    let Some(text) = tablepro_core::export::value_to_text(value) else {
        return "NULL".to_owned();
    };
    let text = text.replace(['\n', '\r'], " ");
    match value {
        Value::Bool(_)
        | Value::Int(_)
        | Value::UInt(_)
        | Value::WideInt(_)
        | Value::Float32(_)
        | Value::Float64(_)
        | Value::Decimal(_) => text,
        _ => format!("'{}'", text.replace('\'', "''")),
    }
}

/// Generated statements carry no terminator, and run together they read
/// as one.
fn terminated(statements: &[String]) -> String {
    statements
        .iter()
        .map(|statement| format!("{};", statement.trim_end().trim_end_matches(';')))
        .collect::<Vec<_>>()
        .join("\n")
}

pub(crate) async fn confirm(parent: &gtk::Widget, confirmation: &WriteConfirmation) -> bool {
    let dialog = build(confirmation);
    crate::workspace::respond(&dialog, parent).await == PROCEED
}

/// As `confirm`, and taken down unanswered once `cancel` fires, for a
/// question whose asker can go away.
pub(crate) async fn confirm_until(
    parent: &gtk::Widget,
    confirmation: &WriteConfirmation,
    cancel: &tokio_util::sync::CancellationToken,
) -> bool {
    let dialog = build(confirmation);
    let shown = dialog.clone();
    let cancelled = cancel.clone();
    let watching = glib::spawn_future_local(async move {
        cancelled.cancelled().await;
        shown.force_close();
    });
    let answer = crate::workspace::respond(&dialog, parent).await;
    watching.abort();
    answer == PROCEED && !cancel.is_cancelled()
}

pub(crate) fn build(confirmation: &WriteConfirmation) -> adw::AlertDialog {
    let dialog = adw::AlertDialog::new(Some(&confirmation.heading), Some(&confirmation.body));
    // A table or connection name is never markup.
    dialog.set_heading_use_markup(false);
    dialog.set_body_use_markup(false);
    dialog.add_response(CANCEL, &crate::i18n::gettext("_Cancel"));
    dialog.add_response(PROCEED, &confirmation.proceed);
    let appearance = match confirmation.destructive {
        true => adw::ResponseAppearance::Destructive,
        false => adw::ResponseAppearance::Suggested,
    };
    dialog.set_response_appearance(PROCEED, appearance);
    dialog.set_default_response(Some(CANCEL));
    dialog.set_close_response(CANCEL);
    dialog.set_prefer_wide_layout(true);
    dialog.set_extra_child(Some(&crate::ui::review_dialog::sql_view(&confirmation.sql, &dialog)));
    dialog
}

#[cfg(test)]
mod tests {
    use tablepro_core::dialect::BindTarget;
    use tablepro_core::statement::StatementBuilder;

    use super::*;

    fn shown_sql(dialog: &adw::AlertDialog) -> String {
        let view = dialog
            .extra_child()
            .and_then(|child| child.downcast::<gtk::ScrolledWindow>().ok())
            .and_then(|scrolled| scrolled.child())
            .and_then(|child| child.downcast::<sourceview5::View>().ok())
            .expect("the SQL view");
        let buffer = view.buffer();
        buffer.text(&buffer.start_iter(), &buffer.end_iter(), false).to_string()
    }

    #[gtk4::test]
    fn the_whole_statement_shows_and_cancel_is_the_default() {
        adw::init().expect("libadwaita initialises under the test backend");
        let update = "UPDATE orders\nSET total = 0\nWHERE id = 1".to_owned();

        let dialog = build(&WriteConfirmation::statements(
            "<b>Prod</b>",
            std::slice::from_ref(&update),
            false,
        ));

        assert_eq!(dialog.heading().as_deref(), Some("Run This Statement?"));
        assert_eq!(
            dialog.body(),
            "It changes the database on “<b>Prod</b>”, which asks before every write."
        );
        assert!(!dialog.is_body_use_markup());
        assert_eq!(shown_sql(&dialog), update);
        assert_eq!(dialog.default_response().as_deref(), Some(CANCEL));
        assert_eq!(dialog.close_response(), CANCEL);
        assert_eq!(dialog.response_appearance(PROCEED), adw::ResponseAppearance::Suggested);
    }

    #[gtk4::test]
    fn a_destructive_statement_turns_the_button_red() {
        adw::init().expect("libadwaita initialises under the test backend");
        let statements = ["DELETE FROM orders".to_owned(), "DROP TABLE lines".to_owned()];

        let dialog = build(&WriteConfirmation::statements("Prod", &statements, true));

        assert_eq!(dialog.heading().as_deref(), Some("Run These 2 Statements?"));
        assert_eq!(shown_sql(&dialog), "DELETE FROM orders\n\nDROP TABLE lines");
        assert_eq!(
            dialog.response_appearance(PROCEED),
            adw::ResponseAppearance::Destructive
        );
    }

    #[gtk4::test]
    fn a_client_statement_names_the_client_and_cancel_is_the_default() {
        adw::init().expect("libadwaita initialises under the test backend");

        let dialog = build(&WriteConfirmation::external("Prod", "DROP TABLE lines", true));

        assert_eq!(dialog.heading().as_deref(), Some("Run Statement from MCP Client?"));
        assert_eq!(
            dialog.body(),
            "An MCP client asks to drop or empty a table, or change every row of one, on “Prod”."
        );
        assert_eq!(shown_sql(&dialog), "DROP TABLE lines");
        assert_eq!(dialog.default_response().as_deref(), Some(CANCEL));
        assert_eq!(
            dialog.response_appearance(PROCEED),
            adw::ResponseAppearance::Destructive
        );
    }

    #[test]
    fn a_client_statement_shows_the_characters_that_hide_or_reorder_text() {
        let sql = "UPDATE t SET a = 1 /*\u{202E} } \u{2066}WHERE id = 7\u{2069} \u{2066}*/\u{200B}\nWHERE b = 'é'\t";

        let shown = WriteConfirmation::external("Prod", sql, false).sql;

        assert_eq!(
            shown,
            "UPDATE t SET a = 1 /*\\u{202E} } \\u{2066}WHERE id = 7\\u{2069} \\u{2066}*/\\u{200B}\nWHERE b = 'é'\t"
        );
    }

    #[gtk4::test]
    fn a_question_whose_client_went_away_closes_unanswered() {
        adw::init().expect("libadwaita initialises under the test backend");
        let window = crate::test_support::OwnedWindow::presented(adw::Window::new());
        let parent: gtk::Widget = (*window).clone().upcast();
        let cancel = tokio_util::sync::CancellationToken::new();
        let answer = std::rc::Rc::new(std::cell::Cell::new(None));
        let (sink, asked) = (answer.clone(), cancel.clone());
        glib::spawn_future_local(async move {
            let confirmation = WriteConfirmation::external("Prod", "UPDATE t SET a = 1 WHERE id = 1", false);
            sink.set(Some(confirm_until(&parent, &confirmation, &asked).await));
        });
        crate::test_support::wait_until(std::time::Duration::from_secs(10), || {
            crate::workspace::visible_alert(&*window).is_some()
        })
        .expect("the question");

        cancel.cancel();

        crate::test_support::wait_until(std::time::Duration::from_secs(10), || answer.get().is_some())
            .expect("an answer");
        assert_eq!(answer.get(), Some(false));
        crate::test_support::wait_until(std::time::Duration::from_secs(10), || {
            crate::workspace::visible_alert(&*window).is_none()
        })
        .expect("the question to close");
    }

    #[test]
    fn an_import_shows_its_first_statement_and_counts_the_rest() {
        let statements = [
            "INSERT INTO t (a) VALUES ($1), ($2)".to_owned(),
            "INSERT INTO t (a) VALUES ($1)".to_owned(),
        ];

        let confirmation = WriteConfirmation::import("Prod", "t", 3, &statements);

        assert_eq!(confirmation.heading, "Import 3 Rows into “t”?");
        assert_eq!(confirmation.sql, "INSERT INTO t (a) VALUES ($1), ($2);");
        assert_eq!(
            confirmation.body,
            "Safe Mode on “Prod” asks before every change to the database. The import runs 2 statements; the first is shown."
        );
    }

    fn bound(sql: &str, value: Option<Value>) -> Statement {
        let mut builder = StatementBuilder::new();
        builder.push_sql(sql);
        if let Some(value) = value {
            builder
                .push_value(&tablepro_test_support::FakeDialect, value, BindTarget::Pattern)
                .expect("a bindable value");
        }
        builder.finish()
    }

    #[test]
    fn a_row_save_shows_each_statement_with_the_values_it_binds() {
        let update = bound("UPDATE orders SET note = ", Some(Value::Text("it's\nhere".to_owned())));
        let delete = bound("DELETE FROM orders WHERE id = 1;", None);

        let confirmation = WriteConfirmation::row_save("Prod", "orders", &[update.clone(), delete]);

        assert_eq!(
            confirmation.sql,
            format!(
                "{};\n-- Values: 'it''s here'\nDELETE FROM orders WHERE id = 1;",
                update.sql()
            )
        );
        assert!(!confirmation.destructive);
    }
}
