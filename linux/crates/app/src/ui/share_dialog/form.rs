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
use tablepro_core::masking::{ShareChoice, SharePlan, ShareSummary};

use super::ShareDialog;
use super::preview::{PREVIEW_ROWS, preview_table};
use super::share_columns::{self, ShareColumn};
use super::sheet_view::{self, ExpiryChoice};
use crate::i18n::{gettext, gettext_f};
use crate::services::share_subject::{ShareForm, ShareSubject, SharedRows};
use crate::ui::icons;
use crate::ui::masking_text::personal_data_kind;

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
    // The Columns list's choice for each shared column.
    columns: Option<Rc<RefCell<Vec<ShareChoice>>>>,
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
                .columns
                .as_ref()
                .map(|columns| columns.borrow().clone())
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
    if let Some(hide_sql) = &hide_sql {
        add_hide_sql_notice(&page, subject, hide_sql);
    }

    let columns = subject
        .rows
        .as_ref()
        .map(|rows| add_columns(dialog, &page, rows, limits, draft));
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
        columns,
    }
}

// The preview shows the rows as the link carries them, and follows every choice in the Columns list below it.
fn add_columns(
    dialog: &ShareDialog,
    page: &adw::PreferencesPage,
    rows: &SharedRows,
    limits: &ShareLimits,
    draft: Option<&ShareForm>,
) -> Rc<RefCell<Vec<ShareChoice>>> {
    let columns = share_columns::share_columns(rows, limits.max_rows, limits.max_columns);
    let choices: Vec<ShareChoice> = match draft {
        Some(draft) if draft.columns.len() == columns.len() => draft.columns.clone(),
        _ => columns.iter().map(ShareColumn::initial).collect(),
    };
    let choices = Rc::new(RefCell::new(choices));
    let preview = Rc::new(Preview::new());
    let summary = share_columns::summary_label();
    let rows = Arc::new(rows.clone());
    let changed: Rc<dyn Fn()> = {
        let (dialog, preview, choices, summary, limits) = (
            dialog.downgrade(),
            preview.clone(),
            choices.clone(),
            summary.downgrade(),
            limits.clone(),
        );
        Rc::new(move || {
            if let Some(dialog) = dialog.upgrade() {
                let watch = Watch {
                    preview: preview.clone(),
                    summary: summary.clone(),
                };
                dialog.summarize(rows.clone(), choices.borrow().clone(), limits.clone(), watch);
            }
        })
    };
    page.add(&preview.group);
    page.add(&share_columns::columns_group(&columns, &choices, &changed, &summary));
    changed();
    choices
}

// What a summary updates once it lands.
struct Watch {
    preview: Rc<Preview>,
    summary: glib::WeakRef<gtk::Label>,
}

// A share as the plan sends it, worked out off the main loop.
struct Sent {
    plan: SharePlan,
    choices: Vec<ShareChoice>,
    summary: ShareSummary,
    columns: Vec<tablepro_core::column::ResultColumn>,
    rows: Vec<crate::services::grid::RowSnapshot>,
    total: u64,
}

impl ShareDialog {
    // The same plan and budget as the snapshot, so the notes and the preview say what Create sends; Create waits.
    fn summarize(&self, rows: Arc<SharedRows>, choices: Vec<ShareChoice>, limits: ShareLimits, watch: Watch) {
        let imp = self.imp();
        let Some(deps) = imp.deps.get() else {
            return;
        };
        let ticket = imp.summaries.get() + 1;
        imp.summaries.set(ticket);
        self.set_sendable(false);
        let (max_rows, max_columns) = (limits.max_rows, limits.max_columns);
        let working = deps.tasks.spawn_blocking_task(move || {
            let plan = rows.plan(&choices, max_columns);
            let summary = rows.summary(&plan, max_rows);
            let (columns, sent) = rows.sent(&plan, summary.rows_sent.min(PREVIEW_ROWS));
            Sent {
                plan,
                choices,
                summary,
                columns,
                rows: sent,
                total: rows.total(),
            }
        });
        let dialog = self.downgrade();
        glib::spawn_future_local(async move {
            let sent = working.await;
            let Some(dialog) = dialog.upgrade() else {
                return;
            };
            if dialog.imp().summaries.get() != ticket {
                return;
            }
            let sent = match sent {
                Ok(sent) => sent,
                Err(failure) => {
                    tracing::warn!(%failure, "the share was not summarized");
                    return;
                }
            };
            watch.preview.show(&sent, &limits);
            if let Some(summary) = watch.summary.upgrade() {
                summary.set_label(&share_columns::summary(&sent.plan, &sent.choices));
            }
            dialog.imp().summarized.set(ticket);
            dialog.set_sendable(sent.summary.too_large.is_none());
        });
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
            match &sent.summary.too_large {
                None => sheet_view::cap_note(sent.total, sent.summary.rows_sent as u64),
                Some(_) => Some(gettext("This result is too large to share.")),
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
        let table = preview_table(&sent.columns, &sent.rows);
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
fn add_targets(
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
    for row in rows.take() {
        group.remove(&row);
    }
    let added: Vec<adw::ActionRow> = warnings
        .iter()
        .map(|warning| {
            let row = adw::ActionRow::builder()
                .title(warning)
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
            group.add(&row);
            row
        })
        .collect();
    group.set_visible(!added.is_empty());
    rows.replace(added);
}
