use relm4::adw::prelude::*;
use relm4::gtk::{gio, glib};
use relm4::{adw, gtk};

use crate::services::preferences::{self, Preferences};

/// Clear keyboard focus whenever the page becomes visible.
///
/// AdwPreferencesDialog auto-grabs focus on the first focusable row
/// of the active page (libadwaita's accessibility default). For our
/// pages that's an `AdwSpinRow` or `AdwSwitchRow` — both noticeable
/// because mouse-scroll over a focused SpinRow changes its value
/// while the user is just reading. Result: opening the dialog or
/// switching to the Editor tab and scrolling the wheel silently
/// edits the font size / timeout etc.
///
/// Solution: schedule an idle hop after the page maps and call
/// `parent_window.set_focus(None)`, which clears any focus libadwaita
/// grabbed during the map. The idle hop matters because libadwaita's
/// grab runs DURING the map; clearing synchronously inside the
/// `map` handler races with it. Tab-key users still reach rows via
/// the natural focus chain — they just start one Tab earlier.
fn clear_focus_on_map(page: &adw::PreferencesPage) {
    page.connect_map(|p| {
        let parent_win = p.root().and_then(|r| r.downcast::<gtk::Window>().ok());
        if let Some(win) = parent_win {
            glib::idle_add_local_once(move || {
                // Disambiguate between RootExt::set_focus and
                // GtkWindowExt::set_focus — both apply to gtk::Window.
                // We want the GtkWindow-level focus reset.
                gtk::prelude::GtkWindowExt::set_focus(&win, gtk::Widget::NONE);
            });
        }
    });
}

pub fn present(parent: &impl IsA<gtk::Widget>) {
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

    let current = preferences::load();

    let page_size_row = adw::SpinRow::with_range(100.0, 100_000.0, 100.0);
    page_size_row.set_title(&crate::tr!("Default page size"));
    page_size_row.set_subtitle(&crate::tr!("Rows fetched per request when browsing a table"));
    page_size_row.set_value(current.default_page_size as f64);

    let confirm_row = adw::SwitchRow::builder()
        .title(crate::tr!("Confirm before deleting rows"))
        .subtitle(crate::tr!("Show a confirmation dialog before each destructive action"))
        .build();
    confirm_row.set_active(current.confirm_destructive);

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
        alert.connect_response(None, move |dlg, response| {
            dlg.close();
            if response == "clear" {
                relm4::spawn(async move {
                    if let Err(e) = tablepro_storage::query_history::clear_all().await {
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
    let storage_subtitle = tablepro_storage::query_history::db_path()
        .map(|p| p.display().to_string())
        .unwrap_or_else(|| "$XDG_CONFIG_HOME/tablepro/history.db".to_string());
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
    storage_button.connect_clicked(move |_| {
        let Some(path) = tablepro_storage::query_history::db_path() else {
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

    clear_focus_on_map(&general);
    clear_focus_on_map(&editor);

    window.add(&general);
    window.add(&editor);

    // Live save — write on every value change instead of batching to
    // window.connect_closed. GNOME Settings applies its preferences
    // immediately (no Apply button); same model here. The previous
    // close-only save lost edits on a crash between change and close.
    let save_all: std::rc::Rc<dyn Fn()> = {
        let page_size = page_size_row.clone();
        let confirm = confirm_row.clone();
        let font = font_size_row.clone();
        let retention = retention_row.clone();
        let timeout = timeout_row.clone();
        std::rc::Rc::new(move || {
            preferences::save(&Preferences {
                default_page_size: page_size.value() as u64,
                confirm_destructive: confirm.is_active(),
                editor_font_size: font.value() as u32,
                history_retention_days: retention.value() as u32,
                query_timeout_secs: timeout.value() as u32,
            });
        })
    };
    page_size_row.connect_value_notify({
        let s = save_all.clone();
        move |_| s()
    });
    font_size_row.connect_value_notify({
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
