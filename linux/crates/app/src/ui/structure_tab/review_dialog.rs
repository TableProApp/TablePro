//! The review a structure save asks for before it runs: what it loses,
//! whether it can stop halfway, and the SQL itself.

use std::cell::RefCell;

use gtk4 as gtk;
use gtk4::prelude::*;
use libadwaita as adw;
use libadwaita::prelude::*;
use tablepro_core::WriteAtomicity;
use tablepro_core::ddl::{ChangeReview, DestructiveChange, RecreatedObject, SchemaObjectKind, TableRebuild};

use crate::ui::handler_guard::HandlerGuard;
use crate::workspace::EngineProfile;

const CANCEL: &str = "cancel";
const APPLY: &str = "apply";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum ReviewDecision {
    Apply,
    Cancel,
}

/// Cancel is the default, so Enter never applies a change that loses
/// data.
pub(crate) async fn confirm(
    parent: &gtk::Widget,
    table: &str,
    review: &ChangeReview,
    engine: &EngineProfile,
) -> ReviewDecision {
    let dialog = build(table, review, engine);
    match crate::workspace::respond(&dialog, parent).await.as_str() {
        APPLY => ReviewDecision::Apply,
        _ => ReviewDecision::Cancel,
    }
}

pub(crate) fn build(table: &str, review: &ChangeReview, engine: &EngineProfile) -> adw::AlertDialog {
    let count = review.operations;
    let heading = crate::i18n::ngettext_f(
        "Apply {count} Change to “{table}”?",
        "Apply {count} Changes to “{table}”?",
        u32::try_from(count).unwrap_or(u32::MAX),
        &[("count", &count.to_string()), ("table", table)],
    );
    let dialog = adw::AlertDialog::new(Some(&heading), Some(&body(review, engine)));
    // A table or column name is never markup.
    dialog.set_heading_use_markup(false);
    dialog.set_body_use_markup(false);
    dialog.add_response(CANCEL, &crate::i18n::gettext("_Cancel"));
    dialog.add_response(APPLY, &crate::i18n::gettext("_Apply"));
    let appearance = match review.destructive.is_empty() {
        true => adw::ResponseAppearance::Suggested,
        false => adw::ResponseAppearance::Destructive,
    };
    dialog.set_response_appearance(APPLY, appearance);
    dialog.set_default_response(Some(CANCEL));
    dialog.set_close_response(CANCEL);
    dialog.set_prefer_wide_layout(true);
    dialog.set_extra_child(Some(&sql_view(&review.sql(), &dialog)));
    dialog
}

fn body(review: &ChangeReview, engine: &EngineProfile) -> String {
    let mut lines: Vec<String> = review.destructive.iter().map(destructive_text).collect();
    if engine.ddl_writes == WriteAtomicity::StatementByStatement && review.statements.len() > 1 {
        lines.push(crate::i18n::gettext_f(
            "{engine} applies each statement separately. If one fails, the statements before it stay applied.",
            &[("engine", &engine.name)],
        ));
    }
    lines.join("\n")
}

fn destructive_text(change: &DestructiveChange) -> String {
    match change {
        DestructiveChange::RebuildTable(rebuild) => rebuild_text(rebuild),
        DestructiveChange::DropColumn { column } => {
            crate::i18n::gettext_f("Drops column “{column}” and the data in it.", &[("column", column)])
        }
        DestructiveChange::ChangeColumnType { column, from, to } => crate::i18n::gettext_f(
            "Changes column “{column}” from {from} to {to}. A value the new type can't hold is converted or refused.",
            &[("column", column), ("from", from), ("to", to)],
        ),
        DestructiveChange::DropIndex { index } => crate::i18n::gettext_f("Drops index “{index}”.", &[("index", index)]),
        DestructiveChange::DropForeignKey { key } => {
            crate::i18n::gettext_f("Drops foreign key “{key}”.", &[("key", key)])
        }
    }
}

fn rebuild_text(rebuild: &TableRebuild) -> String {
    let mut sentences = vec![crate::i18n::gettext(
        "Rebuilds the table: copies its rows into a new table and drops the old one.",
    )];
    if !rebuild.recreated.is_empty() {
        let objects: Vec<String> = rebuild.recreated.iter().map(object_text).collect();
        sentences.push(crate::i18n::gettext_f(
            "Drops and creates again: {objects}.",
            &[("objects", &objects.join(", "))],
        ));
    }
    if rebuild.renumbers_rowids {
        sentences.push(crate::i18n::gettext("The rows get new rowids."));
    }
    sentences.join(" ")
}

fn object_text(object: &RecreatedObject) -> String {
    let name = [("name", object.name.as_str())];
    match object.kind {
        SchemaObjectKind::Index => crate::i18n::gettext_f("index “{name}”", &name),
        SchemaObjectKind::Trigger => crate::i18n::gettext_f("trigger “{name}”", &name),
        SchemaObjectKind::View => crate::i18n::gettext_f("view “{name}”", &name),
    }
}

fn sql_view(sql: &str, dialog: &adw::AlertDialog) -> gtk::ScrolledWindow {
    let buffer = match sourceview5::LanguageManager::default().language("sql") {
        Some(language) => sourceview5::Buffer::with_language(&language),
        None => sourceview5::Buffer::new(None),
    };
    buffer.set_text(sql);
    super::apply_sql_scheme(&buffer);
    let style_manager = adw::StyleManager::default();
    let buffer_for_theme = buffer.downgrade();
    let theme_handler = RefCell::new(Some(HandlerGuard::new(
        &style_manager,
        style_manager.connect_dark_notify(move |_| {
            if let Some(buffer) = buffer_for_theme.upgrade() {
                super::apply_sql_scheme(&buffer);
            }
        }),
    )));
    dialog.connect_closed(move |_| {
        theme_handler.borrow_mut().take();
    });

    let view = sourceview5::View::with_buffer(&buffer);
    view.set_editable(false);
    view.set_cursor_visible(false);
    view.set_monospace(true);
    view.set_wrap_mode(gtk::WrapMode::WordChar);
    view.set_top_margin(8);
    view.set_bottom_margin(8);
    view.set_left_margin(8);
    view.set_right_margin(8);
    view.upcast_ref::<gtk::Widget>()
        .update_property(&[gtk::accessible::Property::Label(&crate::i18n::gettext("SQL to run"))]);
    gtk::ScrolledWindow::builder()
        .child(&view)
        .has_frame(true)
        .hscrollbar_policy(gtk::PolicyType::Never)
        .min_content_height(160)
        .max_content_height(320)
        .propagate_natural_height(true)
        .build()
}

#[cfg(test)]
mod tests {
    use tablepro_core::ddl::{DdlPlan, TableChanges};

    use super::*;

    fn engine(ddl_writes: WriteAtomicity) -> EngineProfile {
        EngineProfile {
            name: "MySQL".to_owned(),
            ddl_writes,
        }
    }

    fn review(statements: &[&str], destructive: Vec<DestructiveChange>) -> ChangeReview {
        let plan = DdlPlan::from_sql(statements.iter().map(|statement| (*statement).to_owned()));
        ChangeReview {
            destructive,
            ..ChangeReview::review(&TableChanges::default(), &plan)
        }
    }

    fn sql_child(dialog: &adw::AlertDialog) -> String {
        let view = dialog
            .extra_child()
            .and_then(|child| child.downcast::<gtk::ScrolledWindow>().ok())
            .and_then(|scrolled| scrolled.child())
            .and_then(|child| child.downcast::<sourceview5::View>().ok())
            .expect("the SQL view");
        assert!(!view.is_editable());
        let buffer = view.buffer();
        buffer.text(&buffer.start_iter(), &buffer.end_iter(), false).to_string()
    }

    #[gtk4::test]
    fn table_name_with_markup_chars_renders_literally() {
        adw::init().expect("libadwaita initialises under the test backend");
        let mut reviewed = review(
            &["ALTER TABLE t DROP COLUMN \"<i>\""],
            vec![DestructiveChange::DropColumn {
                column: "<i>".to_owned(),
            }],
        );
        reviewed.operations = 1;

        let dialog = build("<b>a & b</b>", &reviewed, &engine(WriteAtomicity::Transactional));

        assert_eq!(dialog.heading().as_deref(), Some("Apply 1 Change to “<b>a & b</b>”?"));
        assert!(!dialog.is_heading_use_markup());
        assert!(!dialog.is_body_use_markup());
        assert_eq!(dialog.body(), "Drops column “<i>” and the data in it.");
        assert_eq!(sql_child(&dialog), "ALTER TABLE t DROP COLUMN \"<i>\";");
        assert_eq!(dialog.response_appearance(APPLY), adw::ResponseAppearance::Destructive);
        assert_eq!(dialog.default_response().as_deref(), Some(CANCEL));
        assert_eq!(dialog.close_response(), CANCEL);
        assert!(dialog.prefers_wide_layout());
    }

    #[gtk4::test]
    fn a_save_that_can_stop_halfway_says_so_and_suggests_apply() {
        adw::init().expect("libadwaita initialises under the test backend");
        let reviewed = review(&["ALTER TABLE a", "CREATE INDEX b ON a (c)"], Vec::new());

        let separately = build("a", &reviewed, &engine(WriteAtomicity::StatementByStatement));
        let atomic = build("a", &reviewed, &engine(WriteAtomicity::Transactional));

        assert_eq!(
            separately.body(),
            "MySQL applies each statement separately. If one fails, the statements before it stay applied."
        );
        assert_eq!(
            separately.response_appearance(APPLY),
            adw::ResponseAppearance::Suggested
        );
        assert_eq!(atomic.body(), "");
    }

    #[test]
    fn a_rebuild_names_what_it_makes_again() {
        let text = rebuild_text(&TableRebuild {
            recreated: vec![
                RecreatedObject {
                    kind: SchemaObjectKind::Trigger,
                    name: "stamp".to_owned(),
                },
                RecreatedObject {
                    kind: SchemaObjectKind::View,
                    name: "big".to_owned(),
                },
            ],
            renumbers_rowids: true,
        });

        assert_eq!(
            text,
            "Rebuilds the table: copies its rows into a new table and drops the old one. Drops and creates again: \
             trigger “stamp”, view “big”. The rows get new rowids."
        );
    }
}
