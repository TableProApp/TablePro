//! Import SQL File: the file and the options, then its progress with
//! Stop, then what it did. One dialog for the three, so the import is
//! never out of sight while it writes.

use std::cell::RefCell;
use std::rc::Rc;
use std::time::Duration;

use gtk4 as gtk;
use gtk4::glib;
use libadwaita as adw;
use libadwaita::prelude::*;
use tablepro_core::import::{
    SqlImportEnd, SqlImportErrorPolicy, SqlImportOptions, SqlImportProgress, SqlImportReport, TransactionOutcome,
};

use crate::i18n::{gettext, gettext_f, ngettext_f};
use crate::ui::format::{format_thousands, plural_count};

/// Failures listed in the summary; Copy Details carries every one kept.
const LISTED_FAILURES: usize = 100;

pub(crate) struct SqlImportDialogInit {
    pub file_name: String,
    pub file_size: u64,
    pub connection: String,
    /// Whether the engine can run the file as one transaction.
    pub transactional: bool,
    /// The connection's Safe Mode asks before every write, and this
    /// dialog is that question for the whole file.
    pub confirms_writes: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Stage {
    Choosing,
    Running,
    Done,
}

pub(crate) struct SqlImportDialog {
    dialog: adw::Dialog,
    stack: gtk::Stack,
    stop_on_error: adw::SwitchRow,
    one_transaction: Option<adw::SwitchRow>,
    progress: gtk::ProgressBar,
    counts: gtk::Label,
    stop: gtk::Button,
    result: adw::StatusPage,
    failures: gtk::ListBox,
    failures_box: gtk::Box,
    file_size: u64,
    stage: RefCell<Stage>,
    details: RefCell<String>,
}

impl SqlImportDialog {
    /// The dialog on its first page. `on_import` runs once, with the
    /// options, when Import is clicked; `on_stop` when Stop is.
    pub(crate) fn new(
        init: &SqlImportDialogInit,
        on_import: impl Fn(SqlImportOptions) + 'static,
        on_stop: impl Fn() + 'static,
    ) -> Rc<Self> {
        let stack = gtk::Stack::builder()
            .transition_type(gtk::StackTransitionType::Crossfade)
            .vhomogeneous(false)
            .build();

        let page = adw::PreferencesPage::new();
        let target = adw::PreferencesGroup::new();
        let file = adw::ActionRow::builder()
            .title(&init.file_name)
            .subtitle(glib::format_size(init.file_size).as_str())
            .build();
        target.add(&file);
        let mut description = gettext_f(
            "Every statement in the file runs on “{connection}”.",
            &[("connection", &init.connection)],
        );
        if init.confirms_writes {
            description.push(' ');
            description.push_str(&crate::ui::write_confirmation::asks_before_writes(&init.connection));
        }
        target.set_description(Some(&description));
        page.add(&target);

        let options = adw::PreferencesGroup::builder().title(gettext("Options")).build();
        let stop_on_error = adw::SwitchRow::builder()
            .title(gettext("Stop at First Error"))
            .subtitle(gettext("Off runs the rest and lists what failed"))
            .active(true)
            .build();
        options.add(&stop_on_error);
        let one_transaction = init.transactional.then(|| {
            let row = adw::SwitchRow::builder()
                .title(gettext("Run as One Transaction"))
                .subtitle(gettext("A failure or Stop undoes everything the file did"))
                .active(true)
                .build();
            stop_on_error
                .bind_property("active", &row, "sensitive")
                .sync_create()
                .build();
            options.add(&row);
            row
        });
        if !init.transactional {
            options.set_description(Some(&gettext(
                "This database commits each statement as it runs, so a failure keeps what ran before it.",
            )));
        }
        page.add(&options);

        let import = gtk::Button::builder()
            .label(gettext("_Import"))
            .use_underline(true)
            .halign(gtk::Align::End)
            .build();
        import.add_css_class("suggested-action");
        let choosing = gtk::Box::builder().orientation(gtk::Orientation::Vertical).build();
        choosing.append(&page);
        choosing.append(&bar(&import));
        stack.add_named(&choosing, Some("choosing"));

        let progress = gtk::ProgressBar::builder().show_text(false).build();
        let counts = gtk::Label::builder().xalign(0.0).wrap(true).build();
        counts.add_css_class("dim-label");
        let heading = gtk::Label::builder()
            .label(gettext_f("Importing {name}", &[("name", &init.file_name)]))
            .xalign(0.0)
            .ellipsize(gtk::pango::EllipsizeMode::Middle)
            .build();
        heading.add_css_class("heading");
        progress.update_relation(&[gtk::accessible::Relation::LabelledBy(&[heading.upcast_ref()])]);
        let stop = gtk::Button::builder()
            .label(gettext("_Stop"))
            .use_underline(true)
            .build();
        let running = gtk::Box::builder()
            .orientation(gtk::Orientation::Vertical)
            .spacing(12)
            .margin_top(24)
            .margin_bottom(12)
            .margin_start(24)
            .margin_end(24)
            .build();
        running.append(&heading);
        running.append(&progress);
        running.append(&counts);
        let running_page = gtk::Box::builder().orientation(gtk::Orientation::Vertical).build();
        running_page.append(&running);
        running_page.append(&bar(&stop));
        stack.add_named(&running_page, Some("running"));

        let result = adw::StatusPage::builder().build();
        result.add_css_class("compact");
        let failures = gtk::ListBox::builder().selection_mode(gtk::SelectionMode::None).build();
        failures.add_css_class("boxed-list");
        let failures_scroll = gtk::ScrolledWindow::builder()
            .hscrollbar_policy(gtk::PolicyType::Never)
            .propagate_natural_height(true)
            .max_content_height(280)
            .child(&failures)
            .build();
        let copy = gtk::Button::builder()
            .label(gettext("_Copy Details"))
            .use_underline(true)
            .halign(gtk::Align::Start)
            .build();
        let failures_box = gtk::Box::builder()
            .orientation(gtk::Orientation::Vertical)
            .spacing(12)
            .margin_start(12)
            .margin_end(12)
            .visible(false)
            .build();
        failures_box.append(&failures_scroll);
        failures_box.append(&copy);
        let close = gtk::Button::builder()
            .label(gettext("_Close"))
            .use_underline(true)
            .halign(gtk::Align::End)
            .build();
        let done = gtk::Box::builder().orientation(gtk::Orientation::Vertical).build();
        done.append(&result);
        done.append(&failures_box);
        done.append(&bar(&close));
        stack.add_named(&done, Some("done"));

        let toolbar = adw::ToolbarView::new();
        toolbar.add_top_bar(&adw::HeaderBar::new());
        toolbar.set_content(Some(&stack));
        let dialog = adw::Dialog::builder()
            .title(gettext("Import SQL File"))
            .content_width(480)
            .child(&toolbar)
            .build();
        dialog.set_default_widget(Some(&import));

        let this = Rc::new(Self {
            dialog,
            stack,
            stop_on_error,
            one_transaction,
            progress,
            counts,
            stop,
            result,
            failures,
            failures_box,
            file_size: init.file_size,
            stage: RefCell::new(Stage::Choosing),
            details: RefCell::default(),
        });

        let started = Rc::downgrade(&this);
        import.connect_clicked(move |_| {
            let Some(this) = started.upgrade() else {
                return;
            };
            if *this.stage.borrow() != Stage::Choosing {
                return;
            }
            let options = this.options();
            this.show_running();
            on_import(options);
        });
        let stopping = Rc::downgrade(&this);
        this.stop.connect_clicked(move |button| {
            button.set_sensitive(false);
            if let Some(this) = stopping.upgrade() {
                this.counts.set_label(&gettext("Stopping…"));
            }
            on_stop();
        });
        let closing = this.dialog.downgrade();
        close.connect_clicked(move |_| {
            if let Some(dialog) = closing.upgrade() {
                dialog.close();
            }
        });
        let copying = Rc::downgrade(&this);
        copy.connect_clicked(move |button| {
            if let Some(this) = copying.upgrade() {
                let details = this.details.borrow().clone();
                let told = button.clone();
                crate::ui::clipboard::copy_text(button, details, move |message| {
                    told.announce(message, gtk::AccessibleAnnouncementPriority::Medium);
                });
            }
        });
        this
    }

    pub(crate) fn present(&self, parent: &impl IsA<gtk::Widget>) {
        self.dialog.present(Some(parent));
    }

    pub(crate) fn dialog(&self) -> &adw::Dialog {
        &self.dialog
    }

    fn options(&self) -> SqlImportOptions {
        let stop = self.stop_on_error.is_active();
        SqlImportOptions {
            on_error: match stop {
                true => SqlImportErrorPolicy::Stop,
                false => SqlImportErrorPolicy::Continue,
            },
            one_transaction: stop && self.one_transaction.as_ref().is_some_and(adw::SwitchRow::is_active),
        }
    }

    fn show_running(&self) {
        self.stage.replace(Stage::Running);
        // Stop is the way out while the file writes; the window's own
        // close asks about a running import.
        self.dialog.set_can_close(false);
        self.stack.set_visible_child_name("running");
        self.dialog.set_default_widget(Some(&self.stop));
        self.show_progress(SqlImportProgress::default());
    }

    pub(crate) fn show_progress(&self, progress: SqlImportProgress) {
        if *self.stage.borrow() != Stage::Running {
            return;
        }
        match self.file_size {
            0 => self.progress.pulse(),
            size => self
                .progress
                .set_fraction((progress.bytes_read as f64 / size as f64).clamp(0.0, 1.0)),
        }
        if self.stop.is_sensitive() {
            self.counts
                .set_label(&counts_text(progress.statements, progress.failed));
        }
    }

    /// The import could not start, or its task failed.
    pub(crate) fn show_failure(&self, message: &str) {
        self.finish_with("dialog-error-symbolic", &gettext("Import Failed"), message, &[]);
    }

    pub(crate) fn show_report(&self, report: &SqlImportReport) {
        let (icon, title) = match (&report.end, report.failed) {
            (SqlImportEnd::Completed, 0) => ("emblem-ok-symbolic", gettext("Import Finished")),
            (SqlImportEnd::Completed, _) => ("dialog-warning-symbolic", gettext("Import Finished with Errors")),
            (SqlImportEnd::Cancelled, _) => ("process-stop-symbolic", gettext("Import Stopped")),
            _ => ("dialog-error-symbolic", gettext("Import Failed")),
        };
        let lines: Vec<String> = report_lines(report);
        let failures: Vec<(String, String)> = report
            .failures
            .iter()
            .map(|failure| {
                (
                    gettext_f("Line {line}", &[("line", &failure.line.to_string())]),
                    crate::ui::error_text::sql_import_fault_message(&failure.fault),
                )
            })
            .collect();
        self.details.replace(details_text(report));
        self.finish_with(icon, &title, &lines.join("\n"), &failures);
    }

    fn finish_with(&self, icon: &str, title: &str, description: &str, failures: &[(String, String)]) {
        self.stage.replace(Stage::Done);
        self.dialog.set_can_close(true);
        self.result.set_icon_name(Some(icon));
        self.result.set_title(title);
        self.result
            .set_description(Some(&glib::markup_escape_text(description)));
        while let Some(row) = self.failures.first_child() {
            self.failures.remove(&row);
        }
        for (line, message) in failures.iter().take(LISTED_FAILURES) {
            let row = adw::ActionRow::builder()
                .title(line)
                .subtitle(message)
                .subtitle_selectable(true)
                .use_markup(false)
                .build();
            self.failures.append(&row);
        }
        self.failures_box.set_visible(!failures.is_empty());
        self.stack.set_visible_child_name("done");
    }
}

/// A button at the end of the dialog's bottom bar.
fn bar(button: &gtk::Button) -> gtk::Box {
    let bar = gtk::Box::builder()
        .margin_top(6)
        .margin_bottom(12)
        .margin_start(12)
        .margin_end(12)
        .halign(gtk::Align::End)
        .build();
    bar.append(button);
    bar
}

fn counts_text(statements: u64, failed: u64) -> String {
    let ran = ngettext_f(
        "{n} statement run",
        "{n} statements run",
        plural_count(statements),
        &[("n", &format_thousands(statements))],
    );
    match failed {
        0 => ran,
        failed => ngettext_f(
            "{ran}, {n} failed",
            "{ran}, {n} failed",
            plural_count(failed),
            &[("ran", &ran), ("n", &format_thousands(failed))],
        ),
    }
}

/// What the summary says, one sentence a line.
fn report_lines(report: &SqlImportReport) -> Vec<String> {
    let mut lines = vec![gettext_f(
        "{counts} in {time}.",
        &[
            ("counts", &counts_text(report.statements, report.failed)),
            ("time", &elapsed_text(report.elapsed)),
        ],
    )];
    match &report.end {
        SqlImportEnd::File(error) => lines.push(crate::ui::error_text::sql_file_message(error)),
        SqlImportEnd::Session(error) => lines.push(crate::ui::error_text::driver_message(error)),
        SqlImportEnd::Stopped => {
            if let Some(failure) = report.failures.last() {
                lines.push(gettext_f(
                    "It stopped at line {line}: {reason}",
                    &[
                        ("line", &failure.line.to_string()),
                        (
                            "reason",
                            &crate::ui::error_text::sql_import_fault_message(&failure.fault),
                        ),
                    ],
                ));
            }
        }
        SqlImportEnd::Completed | SqlImportEnd::Cancelled => {}
    }
    match &report.transaction {
        TransactionOutcome::Committed => lines.push(gettext("Everything was committed as one transaction.")),
        TransactionOutcome::RolledBack => lines.push(gettext("Nothing was kept: the transaction was rolled back.")),
        TransactionOutcome::OpenRolledBack => {
            lines.push(gettext("The file left a transaction open, and it was rolled back."))
        }
        TransactionOutcome::Unknown(error) => lines.push(gettext_f(
            "Whether the transaction was kept is not known: {reason}",
            &[("reason", &crate::ui::error_text::driver_message(error))],
        )),
        TransactionOutcome::AsWritten => {
            if !matches!(report.end, SqlImportEnd::Completed) && report.statements > 0 {
                lines.push(gettext("The statements that ran before it are kept."));
            }
        }
    }
    if report.skipped > 0 {
        lines.push(ngettext_f(
            "{n} line only a client reads was passed over.",
            "{n} lines only a client reads were passed over.",
            plural_count(report.skipped),
            &[("n", &format_thousands(report.skipped))],
        ));
    }
    lines
}

/// Every failure kept, with the statement, for the clipboard.
fn details_text(report: &SqlImportReport) -> String {
    report
        .failures
        .iter()
        .map(|failure| {
            format!(
                "{}\n{}\n{}\n",
                gettext_f("Line {line}", &[("line", &failure.line.to_string())]),
                crate::ui::error_text::sql_import_fault_message(&failure.fault),
                failure.statement
            )
        })
        .collect::<Vec<_>>()
        .join("\n")
}

fn elapsed_text(elapsed: Duration) -> String {
    let seconds = elapsed.as_secs();
    match seconds {
        0 => gettext("under a second"),
        seconds if seconds < 60 => ngettext_f(
            "{n} second",
            "{n} seconds",
            plural_count(seconds),
            &[("n", &seconds.to_string())],
        ),
        seconds => {
            let minutes = seconds / 60;
            ngettext_f(
                "{n} minute",
                "{n} minutes",
                plural_count(minutes),
                &[("n", &format_thousands(minutes))],
            )
        }
    }
}

#[cfg(test)]
mod tests {
    use tablepro_core::DriverError;
    use tablepro_core::import::{SqlImportFailure, SqlImportFault};

    use super::*;

    fn report(end: SqlImportEnd, transaction: TransactionOutcome) -> SqlImportReport {
        SqlImportReport {
            end,
            statements: 12,
            skipped: 2,
            failures: vec![SqlImportFailure {
                line: 40,
                statement: "INSERT INTO t VALUES (1)".to_owned(),
                fault: SqlImportFault::Statement(DriverError::Cancelled),
            }],
            failed: 1,
            transaction,
            elapsed: Duration::from_secs(3),
        }
    }

    #[test]
    fn a_stop_names_its_line_and_what_became_of_the_transaction() {
        let lines = report_lines(&report(SqlImportEnd::Stopped, TransactionOutcome::RolledBack));

        assert!(lines.iter().any(|line| line.contains("line 40")), "{lines:?}");
        assert!(lines.iter().any(|line| line.contains("rolled back")), "{lines:?}");
        assert!(lines.iter().any(|line| line.contains("2 lines")), "{lines:?}");
    }

    #[test]
    fn a_stop_with_no_transaction_says_what_ran_stays() {
        let lines = report_lines(&report(SqlImportEnd::Stopped, TransactionOutcome::AsWritten));

        assert!(lines.iter().any(|line| line.contains("are kept")), "{lines:?}");
    }

    #[test]
    fn the_details_carry_each_failed_statement() {
        let details = details_text(&report(SqlImportEnd::Stopped, TransactionOutcome::RolledBack));

        assert!(details.contains("Line 40"));
        assert!(details.contains("INSERT INTO t VALUES (1)"));
    }

    #[gtk4::test]
    fn import_hands_over_the_options_and_turns_to_progress_with_close_off() {
        adw::init().expect("libadwaita initialises under the test backend");
        let chosen = Rc::new(RefCell::new(None));
        let kept = chosen.clone();
        let dialog = SqlImportDialog::new(
            &SqlImportDialogInit {
                file_name: "dump.sql".to_owned(),
                file_size: 100,
                connection: "Shop".to_owned(),
                transactional: true,
                confirms_writes: true,
            },
            move |options| {
                kept.replace(Some(options));
            },
            || {},
        );
        dialog.stop_on_error.set_active(false);

        dialog.dialog.default_widget().expect("Import").activate();

        assert_eq!(
            *chosen.borrow(),
            Some(SqlImportOptions {
                on_error: SqlImportErrorPolicy::Continue,
                one_transaction: false,
            })
        );
        assert!(!dialog.dialog.can_close(), "the dialog closed under a running import");
        dialog.show_progress(SqlImportProgress {
            bytes_read: 50,
            statements: 3,
            failed: 1,
        });
        assert!((dialog.progress.fraction() - 0.5).abs() < f64::EPSILON);
        assert_eq!(dialog.counts.label(), "3 statements run, 1 failed");

        dialog.show_report(&report(SqlImportEnd::Completed, TransactionOutcome::AsWritten));
        assert!(dialog.dialog.can_close());
        assert!(dialog.failures_box.is_visible());
    }
}
