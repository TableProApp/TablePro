use std::cell::RefCell;
use std::rc::Rc;

use gtk4 as gtk;
use gtk4::prelude::*;
use libadwaita as adw;
use libadwaita::prelude::*;
use secrecy::SecretString;
use tablepro_account::{ShareExpiry, ShareLimits};

use super::ShareDialog;
use super::preview::preview_table;
use super::sheet_view::{self, ExpiryChoice};
use crate::i18n::gettext;
use crate::services::share_subject::{ShareForm, ShareSubject};
use crate::ui::icons;

pub(super) const PRICING: &str = "https://tablepro.app/?ref=app-share#pricing";

pub(super) struct FormFields {
    pub(super) page: adw::PreferencesPage,
    title: adw::EntryRow,
    note: adw::EntryRow,
    expiry: adw::ToggleGroup,
    default_expiry: ShareExpiry,
    hide_sql: Option<adw::SwitchRow>,
    password: Option<adw::PasswordEntryRow>,
    allow_download: Option<adw::SwitchRow>,
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
        }
    }
}

pub(super) fn build_form(dialog: &ShareDialog, subject: &ShareSubject, limits: &ShareLimits) -> FormFields {
    let page = adw::PreferencesPage::new();
    let title = adw::EntryRow::builder()
        .title(gettext("Title"))
        .text(&subject.title)
        .build();
    let note = adw::EntryRow::builder().title(gettext("Note")).build();
    let about = adw::PreferencesGroup::new();
    about.add(&title);
    about.add(&note);
    page.add(&about);

    let options = adw::PreferencesGroup::new();
    let (expiry_row, expiry) = expiry_row(dialog, limits);
    options.add(&expiry_row);
    let hide_sql = subject.rows.is_some().then(|| {
        let row = adw::SwitchRow::builder().title(gettext("Hide SQL")).build();
        options.add(&row);
        row
    });
    let password = match limits.password {
        true => {
            let row = adw::PasswordEntryRow::builder().title(gettext("Password")).build();
            options.add(&row);
            Some(row)
        }
        false => {
            options.add(&pro_only_row(dialog, &gettext("Password"), None));
            None
        }
    };
    let allow_download = match limits.disable_download {
        true => {
            let row = adw::SwitchRow::builder()
                .title(gettext("Allow viewers to download"))
                .active(true)
                .build();
            options.add(&row);
            Some(row)
        }
        false => {
            let title = gettext("Allow viewers to download");
            let switch = gtk::Switch::builder()
                .active(true)
                .sensitive(false)
                .valign(gtk::Align::Center)
                .build();
            switch.update_property(&[gtk::accessible::Property::Label(&title)]);
            options.add(&pro_only_row(dialog, &title, Some(&switch)));
            None
        }
    };
    page.add(&options);

    if let Some(rows) = &subject.rows {
        let preview = adw::PreferencesGroup::builder()
            .title(gettext("Rows that will be shared"))
            .build();
        if let Some(note) = sheet_view::cap_note(rows.total(), limits.max_rows) {
            preview.set_description(Some(&note));
        }
        preview.add(&preview_table(&rows.columns, &rows.rows));
        page.add(&preview);
    }
    add_warnings(&page, subject, hide_sql.as_ref());
    FormFields {
        page,
        title,
        note,
        expiry,
        default_expiry: sheet_view::default_expiry(limits),
        hide_sql,
        password,
        allow_download,
    }
}

fn expiry_row(dialog: &ShareDialog, limits: &ShareLimits) -> (adw::ActionRow, adw::ToggleGroup) {
    let row = adw::ActionRow::builder().title(gettext("Expires")).build();
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
    group.set_active_name(Some(sheet_view::default_expiry(limits).code()));
    group.update_property(&[gtk::accessible::Property::Label(&gettext("Expires"))]);
    row.add_suffix(&group);
    if choices.iter().any(|choice| !choice.allowed) {
        row.add_suffix(&pro_tag(dialog));
    }
    (row, group)
}

// Free shows Pro's options with the control off and a tag that opens the plans, never a modal.
fn pro_only_row(dialog: &ShareDialog, title: &str, control: Option<&gtk::Switch>) -> adw::ActionRow {
    let row = adw::ActionRow::builder().title(title).build();
    if let Some(control) = control {
        row.add_suffix(control);
    }
    row.add_suffix(&pro_tag(dialog));
    row
}

fn pro_tag(dialog: &ShareDialog) -> gtk::Button {
    let tag = gtk::Button::builder()
        .label(gettext("Pro"))
        .valign(gtk::Align::Center)
        .tooltip_text(gettext("Show the Pro plan in your browser"))
        .css_classes(["flat", "accent", "caption-heading"])
        .build();
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
