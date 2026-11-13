use std::cell::RefCell;
use std::rc::Rc;
use std::sync::Arc;

use gtk4 as gtk;
use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use libadwaita as adw;
use libadwaita::prelude::*;
use secrecy::{ExposeSecret as _, SecretString};
use tablepro_account::{ShareExpiry, ShareLimits};
use tablepro_core::export::SnapshotRefusal;
use tablepro_core::masking::{ShareChoice, SharePlan, ShareSummary};

use super::ShareDialog;
use super::masking_text::personal_data_kind;
use super::preview::{PREVIEW_ROWS, preview_table};
use super::share_columns::{self, ShareColumn};
use super::sheet_view::{self, ExpiryChoice};
use crate::i18n::{gettext, gettext_f};
use crate::services::share_subject::{ShareForm, ShareSubject, SharedRows};
use crate::ui::icons;

pub(super) const PRICING: &str = "https://tablepro.app/?ref=app-share#pricing";

pub(super) struct FormFields {
    pub(super) page: adw::PreferencesPage,
    // Each choice of Share As and its button; empty without a team.
    targets: Vec<(Option<String>, gtk::CheckButton)>,
    title: adw::EntryRow,
    note: adw::EntryRow,
    expiry: adw::ToggleGroup,
    default_expiry: ShareExpiry,
    hide_sql: Option<adw::SwitchRow>,
    password: Option<adw::PasswordEntryRow>,
    allow_download: Option<adw::SwitchRow>,
    // What a field holds that the core refuses at create, said under the options.
    problems: adw::PreferencesGroup,
    problem_rows: Rc<RefCell<Vec<adw::ActionRow>>>,
    // The Columns list's choice for each shared column.
    // The Columns list and the preview, which live as long as the form.
    sheet: Option<Rc<Sheet>>,
}

impl FormFields {
    pub(super) fn values(&self) -> ShareForm {
        let expiry = self
            .expiry
            .active_name()
            .and_then(|name| ShareExpiry::from_code(&name))
            .unwrap_or(self.default_expiry);
        ShareForm {
            title: self.title.text().to_string(),
            note: self.note.text().to_string(),
            expiry,
            hide_sql: self.hide_sql.as_ref().is_some_and(adw::SwitchRow::is_active),
            password: SecretString::from(
                self.password
                    .as_ref()
                    .map(|row| row.text().to_string())
                    .unwrap_or_default(),
            ),
            allow_download: self.allow_download.as_ref().is_none_or(adw::SwitchRow::is_active),
            team: self
                .targets
                .iter()
                .find(|(_, button)| button.is_active())
                .and_then(|(team, _)| team.clone()),
            columns: self
                .sheet
                .as_ref()
                .map(|sheet| sheet.choices.borrow().clone())
                .unwrap_or_default(),
        }
    }
}

// What the form keeps across a re-read: the fields as typed and the team chosen.
pub(super) struct Kept<'a> {
    pub(super) draft: Option<&'a ShareForm>,
    pub(super) team: Option<&'a str>,
}

// A draft is the form as the user left it, which a re-read of the limits brings back.
pub(super) fn build_form(
    dialog: &ShareDialog,
    subject: &ShareSubject,
    limits: &ShareLimits,
    kept: Kept<'_>,
) -> FormFields {
    let draft = kept.draft;
    let page = adw::PreferencesPage::new();
    let targets = add_targets(dialog, &page, limits, kept.team);
    let title = adw::EntryRow::builder()
        .title(gettext("Title"))
        .text(draft.map_or(subject.title.as_str(), |draft| draft.title.as_str()))
        .build();
    let note = adw::EntryRow::builder()
        .title(gettext("Note"))
        .text(draft.map_or("", |draft| draft.note.as_str()))
        .build();
    let about = adw::PreferencesGroup::new();
    about.add(&title);
    about.add(&note);
    page.add(&about);

    let options = adw::PreferencesGroup::new();
    if let Some(reason) = &subject.no_sql {
        options.set_description(Some(reason));
    }
    let (expiry_row, expiry) = expiry_row(dialog, limits, draft.map(|draft| draft.expiry));
    options.add(&expiry_row);
    let result = subject.kind() == tablepro_account::ShareKind::Result;
    let hide_sql = (result && subject.has_sql()).then(|| {
        let row = adw::SwitchRow::builder()
            .title(gettext("Hide SQL"))
            .active(draft.is_some_and(|draft| draft.hide_sql))
            .build();
        options.add(&row);
        row
    });
    let password = password_row(dialog, &options, limits, draft);
    let allow_download = download_row(dialog, &options, limits, draft);
    page.add(&options);
    let problems = adw::PreferencesGroup::builder().visible(false).build();
    page.add(&problems);
    if let Some(hide_sql) = &hide_sql {
        add_hide_sql_notice(&page, subject, hide_sql);
    }

    let sheet = subject.rows.as_ref().map(|_| add_columns(dialog, &page, limits, draft));
    add_warnings(&page, subject, hide_sql.as_ref());
    FormFields {
        page,
        targets,
        title,
        note,
        expiry,
        default_expiry: sheet_view::default_expiry(limits),
        hide_sql,
        password,
        allow_download,
        problems,
        problem_rows: Rc::default(),
        sheet,
    }
}

// The preview shows the rows as the link carries them, and follows every choice in the Columns list below it.
// The detectors and the summary run off the main loop; the list and the preview fill in once they land.
fn add_columns(
    dialog: &ShareDialog,
    page: &adw::PreferencesPage,
    limits: &ShareLimits,
    draft: Option<&ShareForm>,
) -> Rc<Sheet> {
    let choices = Rc::new(RefCell::new(
        draft.map(|draft| draft.columns.clone()).unwrap_or_default(),
    ));
    let preview = Preview::new();
    let summary = share_columns::summary_label();
    let group = share_columns::columns_group(&summary);
    page.add(&preview.group);
    page.add(&group);
    let sheet = Rc::new(Sheet {
        limits: limits.clone(),
        preview,
        summary,
        group,
        choices,
        rows: RefCell::new(None),
    });
    dialog.detect(&sheet);
    sheet
}

// The Columns list and the preview of one form.
struct Sheet {
    limits: ShareLimits,
    preview: Preview,
    summary: gtk::Label,
    group: adw::PreferencesGroup,
    choices: Rc<RefCell<Vec<ShareChoice>>>,
    rows: RefCell<Option<Arc<SharedRows>>>,
}

// What the detectors found for a subject's rows under a plan's caps, kept so a form built again reads it.
pub(super) struct Detected {
    subject: Arc<ShareSubject>,
    rows: Arc<SharedRows>,
    caps: (u64, u64),
    columns: Vec<ShareColumn>,
}

// A share as the plan sends it, worked out off the main loop, kept with what it was worked out from.
pub(super) struct Sent {
    rows: Arc<SharedRows>,
    caps: (u64, u64),
    plan: SharePlan,
    choices: Vec<ShareChoice>,
    summary: ShareSummary,
    columns: Vec<tablepro_core::column::ResultColumn>,
    sent: Vec<crate::services::grid::RowSnapshot>,
    total: u64,
}

fn summarize_rows(rows: &Arc<SharedRows>, choices: Vec<ShareChoice>, caps: (u64, u64)) -> Sent {
    let (max_rows, max_columns) = caps;
    let plan = rows.plan(&choices, max_columns);
    let summary = rows.summary(&plan, max_rows);
    let (columns, sent) = rows.sent(&plan, summary.rows_sent.min(PREVIEW_ROWS));
    Sent {
        rows: rows.clone(),
        caps,
        plan,
        choices,
        summary,
        columns,
        sent,
        total: rows.total(),
    }
}

impl ShareDialog {
    // Create stays off while a field holds what the core refuses at create, and the form says why, as macOS does.
    pub(super) fn check_fields(&self) {
        let imp = self.imp();
        let Some(subject) = self.current_subject() else {
            return;
        };
        let problems = {
            let form = imp.form.borrow();
            let Some(fields) = form.as_ref() else {
                return;
            };
            let password = fields.password.as_ref().map(|row| row.text());
            let problems = sheet_view::field_problems(&subject.sql, password.as_deref());
            fill_notices(
                &fields.problems,
                &fields.problem_rows,
                &problems,
                icons::DIALOG_ERROR,
                "error",
            );
            problems
        };
        imp.field_problem.set(!problems.is_empty());
        self.update_create();
    }

    // The subject's detection is reused while the subject and the caps stay; otherwise it runs with the first summary.
    fn detect(&self, sheet: &Rc<Sheet>) {
        let imp = self.imp();
        let (Some(deps), Some(subject)) = (imp.deps.get(), self.current_subject()) else {
            return;
        };
        let caps = (sheet.limits.max_rows, sheet.limits.max_columns);
        let known = imp.detected.borrow().as_ref().and_then(|detected| {
            (Arc::ptr_eq(&detected.subject, &subject) && detected.caps == caps)
                .then(|| (detected.rows.clone(), detected.columns.clone()))
        });
        if let Some((rows, columns)) = known {
            sheet.rows.replace(Some(rows));
            self.show_columns(sheet, &columns);
            self.summarize(sheet);
            return;
        }
        let Some(rows) = subject.rows.clone().map(Arc::new) else {
            return;
        };
        let ticket = self.next_summary();
        let kept = sheet.choices.borrow().clone();
        let working = deps.tasks.spawn_blocking_task(move || {
            let columns = share_columns::share_columns(&rows, caps.0, caps.1);
            let choices: Vec<ShareChoice> = match kept.len() == columns.len() {
                true => kept,
                false => columns.iter().map(ShareColumn::initial).collect(),
            };
            let sent = summarize_rows(&rows, choices, caps);
            (columns, sent)
        });
        let (dialog, sheet) = (self.downgrade(), Rc::downgrade(sheet));
        glib::spawn_future_local(async move {
            let landed = working.await;
            let (Some(dialog), Some(sheet)) = (dialog.upgrade(), sheet.upgrade()) else {
                return;
            };
            if dialog.imp().summaries.get() != ticket {
                return;
            }
            let (columns, sent) = match landed {
                Ok(landed) => landed,
                Err(failure) => {
                    tracing::warn!(%failure, "the shared columns were not read");
                    return;
                }
            };
            dialog.imp().detected.replace(Some(Detected {
                subject,
                rows: sent.rows.clone(),
                caps,
                columns: columns.clone(),
            }));
            sheet.rows.replace(Some(sent.rows.clone()));
            sheet.choices.replace(sent.choices.clone());
            dialog.show_columns(&sheet, &columns);
            dialog.show_sent(&sheet, Rc::new(sent), ticket);
        });
    }

    fn show_columns(&self, sheet: &Rc<Sheet>, columns: &[ShareColumn]) {
        if sheet.choices.borrow().len() != columns.len() {
            sheet
                .choices
                .replace(columns.iter().map(ShareColumn::initial).collect());
        }
        let changed: Rc<dyn Fn()> = {
            let (dialog, sheet) = (self.downgrade(), Rc::downgrade(sheet));
            Rc::new(move || {
                if let (Some(dialog), Some(sheet)) = (dialog.upgrade(), sheet.upgrade()) {
                    dialog.summarize(&sheet);
                }
            })
        };
        share_columns::fill_columns(&sheet.group, columns, &sheet.choices, &changed, &sheet.summary);
    }

    fn next_summary(&self) -> u64 {
        let imp = self.imp();
        let ticket = imp.summaries.get() + 1;
        imp.summaries.set(ticket);
        self.set_sendable(false);
        ticket
    }

    // The same plan and budget as the snapshot, so the notes and the preview say what Create sends; Create waits.
    fn summarize(&self, sheet: &Rc<Sheet>) {
        let imp = self.imp();
        let (Some(deps), Some(rows)) = (imp.deps.get(), sheet.rows.borrow().clone()) else {
            return;
        };
        let choices = sheet.choices.borrow().clone();
        let caps = (sheet.limits.max_rows, sheet.limits.max_columns);
        let ticket = self.next_summary();
        let known = imp
            .sent
            .borrow()
            .clone()
            .filter(|sent| Arc::ptr_eq(&sent.rows, &rows) && sent.caps == caps && sent.choices == choices);
        if let Some(sent) = known {
            self.show_sent(sheet, sent, ticket);
            return;
        }
        let working = deps
            .tasks
            .spawn_blocking_task(move || summarize_rows(&rows, choices, caps));
        let (dialog, sheet) = (self.downgrade(), Rc::downgrade(sheet));
        glib::spawn_future_local(async move {
            let sent = working.await;
            let (Some(dialog), Some(sheet)) = (dialog.upgrade(), sheet.upgrade()) else {
                return;
            };
            match sent {
                Ok(sent) => dialog.show_sent(&sheet, Rc::new(sent), ticket),
                Err(failure) => tracing::warn!(%failure, "the share was not summarized"),
            }
        });
    }

    fn show_sent(&self, sheet: &Sheet, sent: Rc<Sent>, ticket: u64) {
        let imp = self.imp();
        if imp.summaries.get() != ticket {
            return;
        }
        sheet.preview.show(&sent, &sheet.limits);
        sheet
            .summary
            .set_label(&share_columns::summary(&sent.plan, &sent.choices));
        imp.summarized.set(ticket);
        self.set_sendable(sent.summary.refused.is_none());
        imp.sent.replace(Some(sent));
    }
}

// The first rows as sent, with what the plan's caps leave out.
struct Preview {
    group: adw::PreferencesGroup,
    table: RefCell<Option<gtk::Widget>>,
}

impl Preview {
    fn new() -> Self {
        Self {
            group: adw::PreferencesGroup::builder()
                .title(gettext("Rows that will be shared"))
                .build(),
            table: RefCell::new(None),
        }
    }

    fn show(&self, sent: &Sent, limits: &ShareLimits) {
        let notes: Vec<String> = [
            match &sent.summary.refused {
                None => sheet_view::cap_note(sent.total, sent.summary.rows_sent as u64),
                Some(SnapshotRefusal::NoColumns) => Some(sheet_view::no_columns_note()),
                Some(SnapshotRefusal::Cell { .. } | SnapshotRefusal::FirstRow) => {
                    Some(gettext("This result is too large to share."))
                }
            },
            sheet_view::column_note(sent.summary.columns_cut, limits.max_columns),
        ]
        .into_iter()
        .flatten()
        .collect();
        self.group.set_description(
            Some(&notes.join(" "))
                .filter(|notes| !notes.is_empty())
                .map(String::as_str),
        );
        let table = preview_table(&sent.columns, &sent.sent);
        if let Some(old) = self.table.replace(Some(table.clone())) {
            self.group.remove(&old);
        }
        self.group.add(&table);
    }
}

// Personal data in the SQL's literals suggests Hide SQL, which the notice turns on; it goes once Hide SQL is on.
fn add_hide_sql_notice(page: &adw::PreferencesPage, subject: &ShareSubject, hide_sql: &adw::SwitchRow) {
    let hits = subject.personal_data();
    if hits.is_empty() {
        return;
    }
    let kinds: Vec<String> = hits.iter().map(|hit| personal_data_kind(hit.kind)).collect();
    let row = adw::ActionRow::builder()
        .title(gettext_f(
            "This query contains what looks like personal data ({kind}). Turn on Hide SQL to keep the query private.",
            &[("kind", &kinds.join(", "))],
        ))
        .use_markup(false)
        .title_lines(0)
        .build();
    let icon = gtk::Image::builder()
        .icon_name(icons::DIALOG_WARNING)
        .valign(gtk::Align::Center)
        .accessible_role(gtk::AccessibleRole::Presentation)
        .css_classes(["warning"])
        .build();
    row.add_prefix(&icon);
    let button = gtk::Button::builder()
        .label(gettext("Hide SQL"))
        .valign(gtk::Align::Center)
        .build();
    let switch = hide_sql.downgrade();
    button.connect_clicked(move |_| {
        if let Some(switch) = switch.upgrade() {
            switch.set_active(true);
        }
    });
    row.add_suffix(&button);
    let group = adw::PreferencesGroup::new();
    group.add(&row);
    group.set_visible(!hide_sql.is_active());
    let shown = group.downgrade();
    hide_sql.connect_active_notify(move |hide_sql| {
        if let Some(group) = shown.upgrade() {
            group.set_visible(!hide_sql.is_active());
        }
    });
    page.add(&group);
}

// Personal first, then each team the account holds a seat in; a team without public links shows but cannot be picked.
pub(super) fn add_targets(
    dialog: &ShareDialog,
    page: &adw::PreferencesPage,
    limits: &ShareLimits,
    chosen: Option<&str>,
) -> Vec<(Option<String>, gtk::CheckButton)> {
    let targets = sheet_view::share_targets(limits);
    if targets.len() < 2 {
        return Vec::new();
    }
    let group = adw::PreferencesGroup::builder().title(gettext("Share As")).build();
    let chosen = sheet_view::chosen_team(limits, chosen).map(|team| team.id.as_str());
    let mut buttons: Vec<(Option<String>, gtk::CheckButton)> = Vec::new();
    for target in targets {
        let button = gtk::CheckButton::builder()
            .active(target.team.as_deref() == chosen)
            .valign(gtk::Align::Center)
            .build();
        if let Some((_, first)) = buttons.first() {
            button.set_group(Some(first));
        }
        let row = adw::ActionRow::builder()
            .title(&target.name)
            .use_markup(false)
            .activatable_widget(&button)
            .sensitive(target.enabled)
            .build();
        if !target.subtitle.is_empty() {
            row.set_subtitle(&target.subtitle);
        }
        row.add_prefix(&button);
        group.add(&row);
        buttons.push((target.team, button));
    }
    for (team, button) in &buttons {
        let (team, dialog) = (team.clone(), dialog.downgrade());
        button.connect_toggled(move |button| {
            if let (true, Some(dialog)) = (button.is_active(), dialog.upgrade()) {
                dialog.choose_target(team.clone());
            }
        });
    }
    page.add(&group);
    buttons
}

fn password_row(
    dialog: &ShareDialog,
    options: &adw::PreferencesGroup,
    limits: &ShareLimits,
    draft: Option<&ShareForm>,
) -> Option<adw::PasswordEntryRow> {
    let title = gettext("Password");
    if !limits.password {
        options.add(&pro_only_row(dialog, &title, None));
        return None;
    }
    let row = adw::PasswordEntryRow::builder().title(&title).build();
    if let Some(draft) = draft {
        row.set_text(draft.password.expose_secret());
    }
    let weak = dialog.downgrade();
    row.connect_changed(move |_| {
        if let Some(dialog) = weak.upgrade() {
            dialog.check_fields();
        }
    });
    options.add(&row);
    Some(row)
}

fn download_row(
    dialog: &ShareDialog,
    options: &adw::PreferencesGroup,
    limits: &ShareLimits,
    draft: Option<&ShareForm>,
) -> Option<adw::SwitchRow> {
    let title = gettext("Allow viewers to download");
    if !limits.disable_download {
        let switch = gtk::Switch::builder()
            .active(true)
            .sensitive(false)
            .valign(gtk::Align::Center)
            .build();
        switch.update_property(&[gtk::accessible::Property::Label(&title)]);
        options.add(&pro_only_row(dialog, &title, Some(&switch)));
        return None;
    }
    let row = adw::SwitchRow::builder()
        .title(&title)
        .active(draft.is_none_or(|draft| draft.allow_download))
        .build();
    options.add(&row);
    Some(row)
}

fn expiry_row(
    dialog: &ShareDialog,
    limits: &ShareLimits,
    kept: Option<ShareExpiry>,
) -> (adw::ActionRow, adw::ToggleGroup) {
    let title = gettext("Expires");
    let row = adw::ActionRow::builder().title(&title).build();
    let group = adw::ToggleGroup::builder().valign(gtk::Align::Center).build();
    let choices = sheet_view::expiry_choices(limits);
    for ExpiryChoice { expiry, allowed } in &choices {
        let toggle = adw::Toggle::builder()
            .name(expiry.code())
            .label(sheet_view::expiry_label(*expiry))
            .enabled(*allowed)
            .build();
        group.add(toggle);
    }
    let active = kept
        .filter(|kept| limits.expiries.contains(kept))
        .unwrap_or_else(|| sheet_view::default_expiry(limits));
    group.set_active_name(Some(active.code()));
    group.update_property(&[gtk::accessible::Property::Label(&title)]);
    row.add_suffix(&group);
    if let Some(locked) = choices.iter().find(|choice| !choice.allowed) {
        row.add_suffix(&pro_tag(dialog, &sheet_view::expiry_label(locked.expiry)));
    }
    (row, group)
}

// Free shows Pro's options with the control off and a tag that opens the plans, never a modal.
fn pro_only_row(dialog: &ShareDialog, title: &str, control: Option<&gtk::Switch>) -> adw::ActionRow {
    let row = adw::ActionRow::builder().title(title).build();
    if let Some(control) = control {
        row.add_suffix(control);
    }
    row.add_suffix(&pro_tag(dialog, title));
    row
}

// Every tag reads "Pro", so its description names the option it stands for.
fn pro_tag(dialog: &ShareDialog, option: &str) -> gtk::Button {
    let tag = gtk::Button::builder()
        .label(gettext("Pro"))
        .valign(gtk::Align::Center)
        .tooltip_text(gettext("Show the Pro plan in your browser"))
        .css_classes(["flat", "accent", "caption-heading"])
        .build();
    tag.update_property(&[gtk::accessible::Property::Description(&gettext_f(
        "{option} needs TablePro Pro.",
        &[("option", option)],
    ))]);
    let dialog = dialog.downgrade();
    tag.connect_clicked(move |_| {
        if let Some(dialog) = dialog.upgrade() {
            dialog.open_uri(PRICING);
        }
    });
    tag
}

// Inline and never blocking; Hide SQL takes back the SQL's own warnings.
fn add_warnings(page: &adw::PreferencesPage, subject: &ShareSubject, hide_sql: Option<&adw::SwitchRow>) {
    let kinds = subject.secret_kinds();
    let columns = subject.secret_columns();
    if kinds.is_empty() && columns.is_empty() {
        return;
    }
    let group = adw::PreferencesGroup::new();
    let rows: Rc<RefCell<Vec<adw::ActionRow>>> = Rc::default();
    fill_warnings(&group, &rows, sheet_view::secret_warnings(&kinds, &columns, false));
    page.add(&group);
    if let Some(hide_sql) = hide_sql {
        hide_sql.connect_active_notify(move |hide_sql| {
            fill_warnings(
                &group,
                &rows,
                sheet_view::secret_warnings(&kinds, &columns, hide_sql.is_active()),
            );
        });
    }
}

fn fill_warnings(group: &adw::PreferencesGroup, rows: &RefCell<Vec<adw::ActionRow>>, warnings: Vec<String>) {
    fill_notices(group, rows, &warnings, icons::DIALOG_WARNING, "warning");
}

fn fill_notices(
    group: &adw::PreferencesGroup,
    rows: &RefCell<Vec<adw::ActionRow>>,
    notices: &[String],
    icon_name: &str,
    class: &str,
) {
    for row in rows.take() {
        group.remove(&row);
    }
    let added: Vec<adw::ActionRow> = notices
        .iter()
        .map(|notice| {
            let row = adw::ActionRow::builder()
                .title(notice)
                .use_markup(false)
                .title_lines(0)
                .build();
            let icon = gtk::Image::builder()
                .icon_name(icon_name)
                .valign(gtk::Align::Center)
                .accessible_role(gtk::AccessibleRole::Presentation)
                .css_classes([class])
                .build();
            row.add_prefix(&icon);
            group.add(&row);
            row
        })
        .collect();
    group.set_visible(!added.is_empty());
    rows.replace(added);
}
