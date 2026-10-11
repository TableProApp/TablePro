use relm4::adw::prelude::*;
use relm4::gtk::gio;
use relm4::{adw, gtk};

use crate::services::preferences::{ColorSchemePref, PreferencesStore};

/// Must match `browse_tab`'s own `PAGE_SIZE_OPTIONS` (duplicated there and
/// in `workspace_state.rs`, the same way those two already duplicate each
/// other): the per-tab paginator only ever offers this fixed set, so a
/// default outside it would silently snap back to 1,000 on restart instead
/// of the value chosen here.
const PAGE_SIZE_OPTIONS: &[u64] = &[100, 500, 1_000, 5_000, 10_000];

fn format_thousands(n: u64) -> String {
    let s = n.to_string();
    let bytes = s.as_bytes();
    let len = bytes.len();
    let mut out = String::with_capacity(len + len / 3);
    for (i, b) in bytes.iter().enumerate() {
        if i > 0 && (len - i).is_multiple_of(3) {
            out.push(',');
        }
        out.push(*b as char);
    }
    out
}

pub fn present(
    parent: &impl IsA<gtk::Widget>,
    history: Option<tablepro_storage::query_history::HistoryStore>,
    database: &crate::services::database_service::DatabaseService,
    preferences: &PreferencesStore,
    mcp_bridge: Option<std::sync::Arc<tablepro_mcp::McpBridge>>,
) {
    let window = adw::PreferencesDialog::builder()
        .title(crate::tr!("Preferences"))
        .build();

    let general = adw::PreferencesPage::builder()
        .title(crate::tr!("General"))
        .icon_name("preferences-system-symbolic")
        .build();

    let browse_group = adw::PreferencesGroup::builder()
        .title(crate::tr!("Data browser"))
        .description(crate::tr!(
            "Tunes the row paginator and destructive-action confirmation."
        ))
        .build();

    let current = preferences.load();

    let page_size_row = adw::ComboRow::new();
    page_size_row.set_title(&crate::tr!("Default page size"));
    page_size_row.set_subtitle(&crate::tr!("Rows fetched per request when browsing a table"));
    let page_size_labels: Vec<String> = PAGE_SIZE_OPTIONS.iter().map(|n| format_thousands(*n)).collect();
    let page_size_strs: Vec<&str> = page_size_labels.iter().map(String::as_str).collect();
    page_size_row.set_model(Some(&gtk::StringList::new(&page_size_strs)));
    let initial_page_size_idx = PAGE_SIZE_OPTIONS
        .iter()
        .position(|n| *n == current.default_page_size)
        .unwrap_or(2) as u32;
    page_size_row.set_selected(initial_page_size_idx);

    let confirm_row = adw::SwitchRow::builder()
        .title(crate::tr!("Confirm before deleting rows"))
        .subtitle(crate::tr!("Show a confirmation dialog before each destructive action"))
        .build();
    confirm_row.set_active(current.confirm_destructive);

    let scheme_row = adw::ComboRow::new();
    scheme_row.set_title(&crate::tr!("Appearance"));
    scheme_row.set_subtitle(&crate::tr!("Follow the system, or always use the light or dark style"));
    scheme_row.set_model(Some(&gtk::StringList::new(&[
        &crate::tr!("System"),
        &crate::tr!("Light"),
        &crate::tr!("Dark"),
    ])));
    scheme_row.set_selected(current.color_scheme.index());
    scheme_row.connect_selected_notify({
        let preferences = preferences.clone();
        move |row| {
            let scheme = ColorSchemePref::from_index(row.selected());
            adw::StyleManager::default().set_color_scheme(scheme.style());
            if let Err(error) = preferences.update(|prefs| prefs.color_scheme = scheme) {
                tracing::warn!(%error, "preferences: color scheme rejected");
            }
        }
    });

    browse_group.add(&scheme_row);
    browse_group.add(&page_size_row);
    browse_group.add(&confirm_row);
    general.add(&browse_group);

    let history_group = adw::PreferencesGroup::builder()
        .title(crate::tr!("Query history"))
        .description(crate::tr!("Persistent record of every SQL query you run."))
        .build();

    let retention_row = adw::SpinRow::with_range(0.0, 365.0, 1.0);
    retention_row.set_title(&crate::tr!("Retention (days)"));
    retention_row.set_subtitle(&crate::tr!("0 keeps history forever; pinned entries are never pruned."));
    retention_row.set_value(current.history_retention_days as f64);
    history_group.add(&retention_row);

    // Trigger button uses `.flat`, NOT `.destructive-action`. GNOME
    // Settings convention: the trigger that opens a destructive
    // confirmation dialog is a regular/flat button — the confirmation
    // dialog itself carries the destructive (red) appearance. Pre-
    // coloring the trigger anticipates an action the user hasn't
    // taken yet.
    //
    // Ellipsis on the label per GTK4 HIG: "Use ellipsis when the
    // action requires more user input or confirmation."
    let clear_button = gtk::Button::builder()
        .label(crate::tr!("Clear\u{2026}"))
        .valign(gtk::Align::Center)
        .build();
    clear_button.add_css_class("flat");
    let clear_row = adw::ActionRow::builder()
        .title(crate::tr!("Clear query history"))
        .subtitle(crate::tr!("Removes every saved query, including pinned ones."))
        .build();
    clear_row.add_suffix(&clear_button);
    let dialog_root = window.clone();
    let history_for_clear = history.clone();
    clear_button.connect_clicked(move |_| {
        let alert = adw::AlertDialog::new(
            Some(&crate::tr!("Clear all query history?")),
            Some(&crate::tr!(
                "This permanently deletes every saved query, including pinned ones."
            )),
        );
        alert.add_response("cancel", &crate::tr!("Cancel"));
        alert.add_response("clear", &crate::tr!("Clear"));
        alert.set_response_appearance("clear", adw::ResponseAppearance::Destructive);
        alert.set_default_response(Some("cancel"));
        alert.set_close_response("cancel");
        let history = history_for_clear.clone();
        alert.connect_response(None, move |dlg, response| {
            dlg.close();
            if response == "clear" {
                let history = history.clone();
                relm4::spawn(async move {
                    if let Some(history) = history
                        && let Err(e) = history.clear_all().await
                    {
                        tracing::warn!(error = %e, "history clear_all failed");
                    }
                });
            }
        });
        alert.present(Some(&dialog_root));
    });
    history_group.add(&clear_row);

    let storage_button = gtk::Button::builder()
        .label(crate::tr!("Show in Files"))
        .valign(gtk::Align::Center)
        .build();
    storage_button.add_css_class("flat");
    let storage_subtitle = history
        .as_ref()
        .map(|store| store.path().display().to_string())
        .unwrap_or_else(|| format!("$XDG_CONFIG_HOME/{}/history.db", crate::config::storage_dir_name()));
    let storage_row = adw::ActionRow::builder()
        .title(crate::tr!("Storage location"))
        .subtitle(&storage_subtitle)
        .build();
    // AdwActionRow ellipsis-truncates long subtitles; the tooltip
    // exposes the full path on hover so the user can verify exactly
    // where their history lives without resorting to the file manager.
    storage_row.set_tooltip_text(Some(&storage_subtitle));
    storage_row.add_suffix(&storage_button);
    let parent_for_launcher = window.clone();
    let history_for_launcher = history;
    storage_button.connect_clicked(move |_| {
        let Some(path) = history_for_launcher.as_ref().map(|store| store.path().to_path_buf()) else {
            return;
        };
        let parent = path.parent().map(|p| p.to_path_buf()).unwrap_or(path);
        let file = gio::File::for_path(&parent);
        let launcher = gtk::FileLauncher::new(Some(&file));
        let parent_window = parent_for_launcher
            .root()
            .and_then(|r| r.downcast::<gtk::Window>().ok());
        launcher.launch(parent_window.as_ref(), gio::Cancellable::NONE, |_| {});
    });
    history_group.add(&storage_row);

    general.add(&history_group);

    let editor = adw::PreferencesPage::builder()
        .title(crate::tr!("Editor"))
        .icon_name("text-editor-symbolic")
        .build();

    let editor_group = adw::PreferencesGroup::builder().title(crate::tr!("SQL editor")).build();

    let font_size_row = adw::SpinRow::with_range(8.0, 32.0, 1.0);
    font_size_row.set_title(&crate::tr!("Editor font size"));
    font_size_row.set_value(current.editor_font_size as f64);
    editor_group.add(&font_size_row);

    let font_family_row = adw::EntryRow::builder()
        .title(crate::tr!("Editor font family"))
        .text(current.editor_font_family.as_str())
        .build();
    editor_group.add(&font_family_row);

    let vim_row = adw::SwitchRow::builder()
        .title(crate::tr!("Vim keys in the SQL editor"))
        .subtitle(crate::tr!("Applies to editors opened after the change."))
        .active(current.editor_vim_mode)
        .build();
    editor_group.add(&vim_row);

    // 0 disables, 1..=3600s allowed range. Subtitle exposes the
    // disable-via-zero contract so power users editing long-running
    // analytical queries can opt out without spelunking the JSON.
    let timeout_row = adw::SpinRow::with_range(0.0, 3600.0, 5.0);
    timeout_row.set_title(&crate::tr!("Query timeout (seconds)"));
    timeout_row.set_subtitle(&crate::tr!(
        "Cancel long-running queries automatically. Set to 0 to disable."
    ));
    timeout_row.set_value(current.query_timeout_secs as f64);
    editor_group.add(&timeout_row);

    editor.add(&editor_group);

    window.add(&general);
    window.add(&editor);
    window.add(&super::mcp_preferences::build_page(database, mcp_bridge));

    // Live save — write on every value change instead of batching to
    // window.connect_closed. GNOME Settings applies its preferences
    // immediately (no Apply button); same model here. The previous
    // close-only save lost edits on a crash between change and close.
    let save_all: std::rc::Rc<dyn Fn()> = {
        let page_size = page_size_row.clone();
        let confirm = confirm_row.clone();
        let font = font_size_row.clone();
        let family = font_family_row.clone();
        let vim = vim_row.clone();
        let retention = retention_row.clone();
        let timeout = timeout_row.clone();
        let preferences = preferences.clone();
        std::rc::Rc::new(move || {
            let default_page_size = PAGE_SIZE_OPTIONS
                .get(page_size.selected() as usize)
                .copied()
                .unwrap_or(1_000);
            if let Err(error) = preferences.update(|prefs| {
                prefs.default_page_size = default_page_size;
                prefs.confirm_destructive = confirm.is_active();
                prefs.editor_font_size = font.value() as u32;
                prefs.editor_font_family = family.text().trim().to_string();
                prefs.editor_vim_mode = vim.is_active();
                prefs.history_retention_days = retention.value() as u32;
                prefs.query_timeout_secs = timeout.value() as u32;
            }) {
                tracing::warn!(%error, "preferences: update rejected");
            }
        })
    };
    page_size_row.connect_selected_notify({
        let s = save_all.clone();
        move |_| s()
    });
    font_size_row.connect_value_notify({
        let s = save_all.clone();
        move |_| s()
    });
    vim_row.connect_active_notify({
        let s = save_all.clone();
        move |_| s()
    });
    font_family_row.connect_changed({
        let s = save_all.clone();
        move |_| s()
    });
    retention_row.connect_value_notify({
        let s = save_all.clone();
        move |_| s()
    });
    timeout_row.connect_value_notify({
        let s = save_all.clone();
        move |_| s()
    });
    confirm_row.connect_active_notify({
        let s = save_all.clone();
        move |_| s()
    });

    window.present(Some(parent));
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn format_thousands_matches_the_browse_tab_paginator() {
        assert_eq!(format_thousands(100), "100");
        assert_eq!(format_thousands(500), "500");
        assert_eq!(format_thousands(1_000), "1,000");
        assert_eq!(format_thousands(5_000), "5,000");
        assert_eq!(format_thousands(10_000), "10,000");
    }

    /// The stored default must always be one of the choices the per-tab
    /// paginator actually offers, so it survives a restart unchanged
    /// instead of silently reverting to 1,000.
    #[test]
    fn every_page_size_option_round_trips_through_its_own_index() {
        for (index, &size) in PAGE_SIZE_OPTIONS.iter().enumerate() {
            let found = PAGE_SIZE_OPTIONS.iter().position(|n| *n == size);
            assert_eq!(found, Some(index));
        }
    }
}
