use std::collections::HashSet;
use std::time::{Duration, SystemTime};

use relm4::adw::prelude::*;
use relm4::gtk::{gio, glib};
use relm4::prelude::*;
use relm4::{adw, gtk};

use tablepro_storage::query_history::{self, Entry, SearchFilter};

use crate::services::database_service::{self, ConnectionMetadata};

pub struct HistoryDialog {
    root: adw::Dialog,
    search: gtk::SearchEntry,
    pinned_heading: gtk::Label,
    pinned_listbox: gtk::ListBox,
    listbox: gtk::ListBox,
    list_heading: gtk::Label,
    stack: gtk::Stack,
    status_page: adw::StatusPage,

    filter_connection: adw::ComboRow,
    filter_status: adw::ComboRow,
    filter_window: adw::ComboRow,
    /// Pending debounced search timeout. Replaces the previous fire-
    /// on-every-keystroke behaviour: typing or flipping a filter
    /// schedules a Refresh 150 ms later and cancels any earlier
    /// scheduled one, so we send a single SQL search per pause —
    /// matches GNOME Files' search debounce.
    filter_debounce: std::rc::Rc<std::cell::RefCell<Option<gtk::glib::SourceId>>>,

    selection_bar: gtk::Revealer,
    selection_label: gtk::Label,

    connections: Vec<ConnectionMetadata>,
    selected_ids: HashSet<i64>,
    entries: Vec<Entry>,
    row_popovers: Vec<gtk::PopoverMenu>,
    row_checkboxes: Vec<gtk::CheckButton>,
    select_mode: bool,
}

pub struct HistoryDialogInit;

#[derive(Debug)]
pub enum HistoryDialogInput {
    SearchChanged,
    FiltersChanged,
    Refresh,
    Activate(i64),
    ReplaceCurrent(i64),
    TogglePin(i64),
    Delete(i64),
    ToggleSelectMode(bool),
    ToggleSelected(i64, bool),
    DeleteSelected,
    ExportSelectedSql,
    ExportSelectedCsv,
    ClearAllRequested,
    ClearAllConfirmed,
    OpenStorageLocation,
}

#[derive(Debug)]
pub enum HistoryDialogOutput {
    OpenInNewTab(String),
    ReplaceCurrentTabQuery(String),
}

#[derive(Debug)]
pub enum HistoryDialogCmd {
    Loaded(Vec<Entry>),
    Cleared,
    ExportReady(String, String),
    ExportFailed(String),
}

impl Component for HistoryDialog {
    type Init = HistoryDialogInit;
    type Input = HistoryDialogInput;
    type Output = HistoryDialogOutput;
    type CommandOutput = HistoryDialogCmd;
    type Root = adw::Dialog;
    type Widgets = ();

    fn init_root() -> Self::Root {
        adw::Dialog::builder()
            .title(crate::tr!("Query History"))
            .content_width(640)
            .content_height(640)
            .build()
    }

    fn init(_init: Self::Init, root: Self::Root, sender: ComponentSender<Self>) -> ComponentParts<Self> {
        let toolbar = adw::ToolbarView::new();
        let header = adw::HeaderBar::builder().show_end_title_buttons(true).build();
        header.set_title_widget(Some(&adw::WindowTitle::new(&crate::tr!("Query History"), "")));

        let filter_popover = gtk::Popover::new();
        let filter_button = gtk::MenuButton::builder()
            .label(crate::tr!("Filter"))
            .always_show_arrow(true)
            .tooltip_text(crate::tr!("Filter history"))
            .popover(&filter_popover)
            .build();

        let connections = database_service::instance().all_connections();

        let conn_strings: Vec<String> = std::iter::once(crate::tr!("All connections"))
            .chain(connections.iter().map(|m| m.name.clone()))
            .collect();
        let conn_strings_ref: Vec<&str> = conn_strings.iter().map(String::as_str).collect();
        let conn_model = gtk::StringList::new(&conn_strings_ref);
        let filter_connection = adw::ComboRow::builder()
            .title(crate::tr!("Connection"))
            .model(&conn_model)
            .build();

        let status_strings = [
            crate::tr!("Any"),
            crate::tr!("Successful"),
            crate::tr!("Failed"),
            crate::tr!("Cancelled"),
        ];
        let status_strings_ref: Vec<&str> = status_strings.iter().map(String::as_str).collect();
        let status_model = gtk::StringList::new(&status_strings_ref);
        let filter_status = adw::ComboRow::builder()
            .title(crate::tr!("Status"))
            .model(&status_model)
            .build();

        let window_strings = [
            crate::tr!("Any time"),
            crate::tr!("Last 24 hours"),
            crate::tr!("Last 7 days"),
            crate::tr!("Last 30 days"),
        ];
        let window_strings_ref: Vec<&str> = window_strings.iter().map(String::as_str).collect();
        let window_model = gtk::StringList::new(&window_strings_ref);
        let filter_window = adw::ComboRow::builder()
            .title(crate::tr!("Time window"))
            .model(&window_model)
            .build();

        let reset_button = gtk::Button::builder()
            .label(crate::tr!("Reset"))
            .halign(gtk::Align::End)
            .margin_top(6)
            .build();
        reset_button.add_css_class("flat");
        let reset_conn = filter_connection.clone();
        let reset_status = filter_status.clone();
        let reset_window = filter_window.clone();
        reset_button.connect_clicked(move |_| {
            reset_conn.set_selected(0);
            reset_status.set_selected(0);
            reset_window.set_selected(0);
        });

        // Native popover content: a single AdwPreferencesGroup of
        // AdwComboRow filters, with the Reset button below. Replaces
        // the gtk::Grid + paired labels (the GTK3-era pattern) —
        // ComboRows carry their own titles, so the Grid column of
        // labels was redundant.
        let filter_group = adw::PreferencesGroup::new();
        filter_group.add(&filter_connection);
        filter_group.add(&filter_status);
        filter_group.add(&filter_window);

        let popover_box = gtk::Box::builder()
            .orientation(gtk::Orientation::Vertical)
            .spacing(6)
            .margin_top(12)
            .margin_bottom(12)
            .margin_start(12)
            .margin_end(12)
            .build();
        popover_box.append(&filter_group);
        popover_box.append(&reset_button);
        filter_popover.set_child(Some(&popover_box));

        for combo in [&filter_connection, &filter_status, &filter_window] {
            let s = sender.clone();
            combo.connect_selected_notify(move |_| s.input(HistoryDialogInput::FiltersChanged));
        }

        header.pack_start(&filter_button);

        let select_button = gtk::ToggleButton::builder()
            .label(crate::tr!("Select"))
            .tooltip_text(crate::tr!("Toggle multi-select"))
            .build();
        let s_select = sender.clone();
        select_button.connect_toggled(move |btn| {
            s_select.input(HistoryDialogInput::ToggleSelectMode(btn.is_active()));
        });
        header.pack_start(&select_button);

        let menu = gio::Menu::new();
        let storage_section = gio::Menu::new();
        storage_section.append(Some(&crate::tr!("Show storage location")), Some("history.show-storage"));
        menu.append_section(None, &storage_section);
        let danger_section = gio::Menu::new();
        danger_section.append(Some(&crate::tr!("Clear all history…")), Some("history.clear-all"));
        menu.append_section(None, &danger_section);
        let menu_button = gtk::MenuButton::builder()
            .icon_name("view-more-symbolic")
            .menu_model(&menu)
            .tooltip_text(crate::tr!("More actions"))
            .build();
        header.pack_end(&menu_button);

        let action_group = gio::SimpleActionGroup::new();
        let export_sql_sender = sender.clone();
        let export_sql = gio::ActionEntry::builder("export-sql")
            .activate(move |_, _, _| export_sql_sender.input(HistoryDialogInput::ExportSelectedSql))
            .build();
        let export_csv_sender = sender.clone();
        let export_csv = gio::ActionEntry::builder("export-csv")
            .activate(move |_, _, _| export_csv_sender.input(HistoryDialogInput::ExportSelectedCsv))
            .build();
        let delete_sender = sender.clone();
        let delete = gio::ActionEntry::builder("delete-selected")
            .activate(move |_, _, _| delete_sender.input(HistoryDialogInput::DeleteSelected))
            .build();
        let clear_sender = sender.clone();
        let clear_all = gio::ActionEntry::builder("clear-all")
            .activate(move |_, _, _| clear_sender.input(HistoryDialogInput::ClearAllRequested))
            .build();
        let storage_sender = sender.clone();
        let show_storage = gio::ActionEntry::builder("show-storage")
            .activate(move |_, _, _| storage_sender.input(HistoryDialogInput::OpenStorageLocation))
            .build();
        action_group.add_action_entries([export_sql, export_csv, delete, clear_all, show_storage]);

        let search = gtk::SearchEntry::builder()
            .placeholder_text(crate::tr!("Search queries…"))
            .hexpand(true)
            .build();
        let s = sender.clone();
        search.connect_search_changed(move |_| s.input(HistoryDialogInput::SearchChanged));

        let search_bar = gtk::SearchBar::builder()
            .child(&search)
            .show_close_button(true)
            .search_mode_enabled(false)
            .build();
        search_bar.connect_entry(&search);

        let search_toggle = gtk::ToggleButton::builder()
            .icon_name("system-search-symbolic")
            .tooltip_text(crate::tr!("Search"))
            .build();
        let search_bar_for_toggle = search_bar.clone();
        search_toggle.connect_toggled(move |btn| {
            search_bar_for_toggle.set_search_mode(btn.is_active());
        });
        let toggle_for_close = search_toggle.clone();
        search_bar.connect_search_mode_enabled_notify(move |bar| {
            toggle_for_close.set_active(bar.is_search_mode());
        });
        header.pack_end(&search_toggle);

        let inner = gtk::Box::builder().orientation(gtk::Orientation::Vertical).build();
        inner.append(&search_bar);

        let pinned_heading = gtk::Label::builder()
            .label(crate::tr!("Pinned"))
            .xalign(0.0)
            .margin_top(12)
            .margin_start(12)
            .margin_end(12)
            .margin_bottom(4)
            .visible(false)
            .build();
        pinned_heading.add_css_class("heading");
        pinned_heading.add_css_class("dim-label");

        let pinned_listbox = gtk::ListBox::builder()
            .selection_mode(gtk::SelectionMode::None)
            .visible(false)
            .build();
        pinned_listbox.add_css_class("boxed-list");
        pinned_listbox.set_margin_start(12);
        pinned_listbox.set_margin_end(12);

        let list_heading = gtk::Label::builder()
            .label(crate::tr!("All queries"))
            .xalign(0.0)
            .margin_top(12)
            .margin_start(12)
            .margin_end(12)
            .margin_bottom(4)
            .visible(false)
            .build();
        list_heading.add_css_class("heading");
        list_heading.add_css_class("dim-label");

        let listbox = gtk::ListBox::builder().selection_mode(gtk::SelectionMode::None).build();
        listbox.add_css_class("boxed-list");
        listbox.set_margin_start(12);
        listbox.set_margin_end(12);
        listbox.set_margin_bottom(12);

        let list_box = gtk::Box::builder().orientation(gtk::Orientation::Vertical).build();
        list_box.append(&pinned_heading);
        list_box.append(&pinned_listbox);
        list_box.append(&list_heading);
        list_box.append(&listbox);

        let scroll = gtk::ScrolledWindow::builder()
            .child(&list_box)
            .hscrollbar_policy(gtk::PolicyType::Never)
            .vexpand(true)
            .build();

        let status_page = adw::StatusPage::builder()
            .icon_name("document-open-recent-symbolic")
            .title(crate::tr!("No queries yet"))
            .description(crate::tr!("Run a query in the SQL editor and it will appear here."))
            .vexpand(true)
            .build();

        let stack = gtk::Stack::builder()
            .vhomogeneous(false)
            .vexpand(true)
            .margin_top(12)
            .build();
        stack.add_named(&scroll, Some("list"));
        stack.add_named(&status_page, Some("empty"));

        inner.append(&stack);
        search_bar.set_key_capture_widget(Some(&inner));

        let selection_label = gtk::Label::builder().xalign(0.0).hexpand(true).build();
        selection_label.add_css_class("dim-label");

        let export_menu = gio::Menu::new();
        export_menu.append(Some(&crate::tr!("Export as SQL")), Some("history.export-sql"));
        export_menu.append(Some(&crate::tr!("Export as CSV")), Some("history.export-csv"));
        let export_button = gtk::MenuButton::builder()
            .label(crate::tr!("Export"))
            .always_show_arrow(true)
            .menu_model(&export_menu)
            .build();

        let delete_button = gtk::Button::builder().label(crate::tr!("Delete")).build();
        delete_button.add_css_class("destructive-action");
        let s_del_bar = sender.clone();
        delete_button.connect_clicked(move |_| s_del_bar.input(HistoryDialogInput::DeleteSelected));

        let selection_bar_inner = gtk::Box::builder()
            .orientation(gtk::Orientation::Horizontal)
            .spacing(8)
            .margin_top(6)
            .margin_bottom(6)
            .margin_start(12)
            .margin_end(12)
            .build();
        selection_bar_inner.append(&selection_label);
        selection_bar_inner.append(&export_button);
        selection_bar_inner.append(&delete_button);
        let selection_bar = gtk::Revealer::builder()
            .child(&selection_bar_inner)
            .transition_type(gtk::RevealerTransitionType::SlideUp)
            .reveal_child(false)
            .build();
        toolbar.add_bottom_bar(&selection_bar);

        toolbar.add_top_bar(&header);
        toolbar.set_content(Some(&inner));
        root.set_child(Some(&toolbar));
        root.insert_action_group("history", Some(&action_group));

        let model = Self {
            root: root.clone(),
            search,
            pinned_heading,
            pinned_listbox,
            listbox,
            list_heading,
            stack,
            status_page,
            filter_connection,
            filter_status,
            filter_window,
            filter_debounce: std::rc::Rc::new(std::cell::RefCell::new(None)),
            selection_bar,
            selection_label,
            connections,
            selected_ids: HashSet::new(),
            entries: Vec::new(),
            row_popovers: Vec::new(),
            row_checkboxes: Vec::new(),
            select_mode: false,
        };

        sender.input(HistoryDialogInput::Refresh);

        ComponentParts { model, widgets: () }
    }

    fn update(&mut self, msg: Self::Input, sender: ComponentSender<Self>, _root: &Self::Root) {
        match msg {
            HistoryDialogInput::Refresh => self.run_search(sender),
            // SearchChanged + FiltersChanged go through the debounce —
            // every keystroke and every dropdown flip would otherwise
            // fire its own SQL search. After a 150 ms idle window the
            // scheduled timeout re-enters update with Refresh, which
            // does the actual work.
            HistoryDialogInput::SearchChanged | HistoryDialogInput::FiltersChanged => {
                self.schedule_debounced_search(sender);
            }

            HistoryDialogInput::Activate(id) => {
                if let Some(query) = self.query_for_id(id) {
                    let _ = sender.output(HistoryDialogOutput::OpenInNewTab(query));
                    self.root.close();
                }
            }

            HistoryDialogInput::ReplaceCurrent(id) => {
                if let Some(query) = self.query_for_id(id) {
                    let _ = sender.output(HistoryDialogOutput::ReplaceCurrentTabQuery(query));
                    self.root.close();
                }
            }

            HistoryDialogInput::TogglePin(id) => {
                let pinned = !self.is_pinned(id);
                if let Some(entry) = self.entries.iter_mut().find(|e| e.id == id) {
                    entry.pinned = pinned;
                }
                relm4::spawn(async move {
                    if let Err(e) = query_history::set_pinned(id, pinned).await {
                        tracing::warn!(error = %e, "history set_pinned failed");
                    }
                });
                sender.input(HistoryDialogInput::Refresh);
            }

            HistoryDialogInput::Delete(id) => {
                self.selected_ids.remove(&id);
                relm4::spawn(async move {
                    if let Err(e) = query_history::delete(id).await {
                        tracing::warn!(error = %e, "history delete failed");
                    }
                });
                sender.input(HistoryDialogInput::Refresh);
            }

            HistoryDialogInput::ToggleSelected(id, on) => {
                if on {
                    self.selected_ids.insert(id);
                } else {
                    self.selected_ids.remove(&id);
                }
                self.refresh_selection_bar();
            }

            HistoryDialogInput::ToggleSelectMode(on) => {
                self.select_mode = on;
                if !on {
                    self.selected_ids.clear();
                    for cb in &self.row_checkboxes {
                        cb.set_active(false);
                    }
                }
                for cb in &self.row_checkboxes {
                    cb.set_visible(on);
                }
                self.refresh_selection_bar();
            }

            HistoryDialogInput::DeleteSelected => {
                let ids: Vec<i64> = self.selected_ids.drain().collect();
                if ids.is_empty() {
                    return;
                }
                relm4::spawn(async move {
                    if let Err(e) = query_history::delete_many(&ids).await {
                        tracing::warn!(error = %e, "history delete_many failed");
                    }
                });
                sender.input(HistoryDialogInput::Refresh);
            }

            HistoryDialogInput::ExportSelectedSql => self.export_selected("sql", sender),
            HistoryDialogInput::ExportSelectedCsv => self.export_selected("csv", sender),

            HistoryDialogInput::ClearAllRequested => {
                let dialog = adw::AlertDialog::new(
                    Some(&crate::tr!("Clear all query history?")),
                    Some(&crate::tr!(
                        "This permanently deletes every saved query, including pinned ones."
                    )),
                );
                dialog.add_response("cancel", &crate::tr!("Cancel"));
                dialog.add_response("clear", &crate::tr!("Clear"));
                dialog.set_response_appearance("clear", adw::ResponseAppearance::Destructive);
                dialog.set_default_response(Some("cancel"));
                dialog.set_close_response("cancel");
                let s = sender;
                dialog.connect_response(None, move |d, response| {
                    d.close();
                    if response == "clear" {
                        s.input(HistoryDialogInput::ClearAllConfirmed);
                    }
                });
                dialog.present(Some(&self.root));
            }

            HistoryDialogInput::ClearAllConfirmed => {
                let s = sender.clone();
                sender.command(move |out, shutdown| {
                    shutdown
                        .register(async move {
                            let _ = s;
                            if let Err(e) = query_history::clear_all().await {
                                tracing::warn!(error = %e, "history clear_all failed");
                            }
                            out.send(HistoryDialogCmd::Cleared).ok()
                        })
                        .drop_on_shutdown()
                });
            }

            HistoryDialogInput::OpenStorageLocation => {
                if let Some(path) = query_history::db_path() {
                    let parent = path.parent().map(|p| p.to_path_buf()).unwrap_or(path);
                    let file = gio::File::for_path(&parent);
                    let launcher = gtk::FileLauncher::new(Some(&file));
                    launcher.launch(
                        Some(
                            &self
                                .root
                                .root()
                                .and_then(|r| r.downcast::<gtk::Window>().ok())
                                .unwrap_or_default(),
                        ),
                        gio::Cancellable::NONE,
                        |_| {},
                    );
                }
            }
        }
    }

    fn update_cmd(&mut self, msg: Self::CommandOutput, sender: ComponentSender<Self>, _root: &Self::Root) {
        match msg {
            HistoryDialogCmd::Loaded(entries) => self.render_entries(entries, &sender),
            HistoryDialogCmd::Cleared => {
                self.selected_ids.clear();
                sender.input(HistoryDialogInput::Refresh);
            }
            HistoryDialogCmd::ExportReady(content, suggested_name) => self.save_export(content, suggested_name),
            HistoryDialogCmd::ExportFailed(msg) => {
                tracing::warn!(error = %msg, "history export failed");
            }
        }
    }
}

impl HistoryDialog {
    pub fn dialog(&self) -> &adw::Dialog {
        &self.root
    }

    /// Run the search immediately. Triggered by Refresh (initial load
    /// + after any mutation) and by the debounced timeout firing.
    fn run_search(&self, sender: ComponentSender<Self>) {
        let filter = self.build_filter();
        sender.command(move |out, shutdown| {
            shutdown
                .register(async move {
                    match query_history::search(filter).await {
                        Ok(entries) => out.send(HistoryDialogCmd::Loaded(entries)).ok(),
                        Err(e) => {
                            tracing::warn!(error = %e, "history search failed");
                            out.send(HistoryDialogCmd::Loaded(Vec::new())).ok()
                        }
                    }
                })
                .drop_on_shutdown()
        });
    }

    /// Cancel any pending debounce timeout and schedule a new Refresh
    /// 150 ms from now. The 150 ms idle threshold matches GNOME Files'
    /// search-typing debounce — short enough to feel responsive, long
    /// enough that a fast typer never fires more than one query.
    fn schedule_debounced_search(&self, sender: ComponentSender<Self>) {
        if let Some(prev) = self.filter_debounce.borrow_mut().take() {
            prev.remove();
        }
        let s = sender.clone();
        let slot = self.filter_debounce.clone();
        let id = gtk::glib::timeout_add_local_once(std::time::Duration::from_millis(150), move || {
            slot.borrow_mut().take();
            s.input(HistoryDialogInput::Refresh);
        });
        *self.filter_debounce.borrow_mut() = Some(id);
    }

    fn build_filter(&self) -> SearchFilter {
        let needle = {
            let text = self.search.text().to_string();
            let trimmed = text.trim().to_string();
            if trimmed.is_empty() {
                None
            } else {
                Some(fts5_query(&trimmed))
            }
        };
        let connection_id = if self.filter_connection.selected() == 0 {
            None
        } else {
            self.connections
                .get((self.filter_connection.selected() - 1) as usize)
                .map(|m| m.id)
        };
        let (success_only, exclude_cancelled) = match self.filter_status.selected() {
            0 => (None, None),
            1 => (Some(true), Some(true)),
            2 => (Some(false), Some(true)),
            3 => (None, Some(false)),
            _ => (None, None),
        };
        let min_executed_at = match self.filter_window.selected() {
            1 => Some(SystemTime::now() - Duration::from_secs(24 * 3600)),
            2 => Some(SystemTime::now() - Duration::from_secs(7 * 24 * 3600)),
            3 => Some(SystemTime::now() - Duration::from_secs(30 * 24 * 3600)),
            _ => None,
        };
        SearchFilter {
            needle,
            connection_id,
            success_only,
            exclude_cancelled,
            min_executed_at,
            limit: 200,
        }
    }

    fn render_entries(&mut self, entries: Vec<Entry>, sender: &ComponentSender<Self>) {
        // Unparent the previous round's row popovers explicitly so they drop
        // along with their captured sender clones. Without this, set_parent's
        // strong link from popover→row would keep both alive past the
        // listbox.remove() call below.
        for popover in self.row_popovers.drain(..) {
            popover.unparent();
        }
        self.row_checkboxes.clear();
        clear_listbox(&self.pinned_listbox);
        clear_listbox(&self.listbox);

        let valid_ids: HashSet<i64> = entries.iter().map(|e| e.id).collect();
        self.selected_ids.retain(|id| valid_ids.contains(id));
        self.entries = entries.clone();

        if entries.is_empty() {
            self.pinned_heading.set_visible(false);
            self.pinned_listbox.set_visible(false);
            self.list_heading.set_visible(false);
            let has_search = !self.search.text().to_string().trim().is_empty();
            let has_filter = self.filter_connection.selected() != 0
                || self.filter_status.selected() != 0
                || self.filter_window.selected() != 0;
            if has_search || has_filter {
                self.status_page.set_title(&crate::tr!("No matches"));
                self.status_page
                    .set_description(Some(&crate::tr!("Try a different search term or change the filters.")));
                self.status_page.set_icon_name(Some("system-search-symbolic"));
            } else {
                self.status_page.set_title(&crate::tr!("No queries yet"));
                self.status_page.set_description(Some(&crate::tr!(
                    "Run a query in the SQL editor and it will appear here."
                )));
                self.status_page.set_icon_name(Some("document-open-recent-symbolic"));
            }
            self.stack.set_visible_child_name("empty");
            self.refresh_selection_bar();
            return;
        }
        self.stack.set_visible_child_name("list");

        let (pinned, regular): (Vec<_>, Vec<_>) = entries.into_iter().partition(|e| e.pinned);
        let has_pinned = !pinned.is_empty();
        let has_regular = !regular.is_empty();
        self.pinned_heading.set_visible(has_pinned);
        self.pinned_listbox.set_visible(has_pinned);
        self.list_heading.set_visible(has_pinned && has_regular);

        for entry in &pinned {
            let (row, popover, checkbox) = self.build_row(entry, sender.clone());
            self.pinned_listbox.append(&row);
            self.row_popovers.push(popover);
            self.row_checkboxes.push(checkbox);
        }
        for entry in &regular {
            let (row, popover, checkbox) = self.build_row(entry, sender.clone());
            self.listbox.append(&row);
            self.row_popovers.push(popover);
            self.row_checkboxes.push(checkbox);
        }

        self.refresh_selection_bar();
    }

    fn build_row(
        &self,
        entry: &Entry,
        sender: ComponentSender<Self>,
    ) -> (adw::ActionRow, gtk::PopoverMenu, gtk::CheckButton) {
        let title = preview_title(&entry.query);
        let subtitle = format_subtitle(entry);
        let row = adw::ActionRow::builder()
            .title(&title)
            .subtitle(&subtitle)
            .activatable(true)
            .build();
        row.add_css_class("monospace");

        let icon_name = if entry.cancelled {
            "process-stop-symbolic"
        } else if entry.success {
            "emblem-ok-symbolic"
        } else {
            "dialog-error-symbolic"
        };
        let icon = gtk::Image::from_icon_name(icon_name);
        icon.add_css_class("dim-label");
        row.add_prefix(&icon);

        let select_check = gtk::CheckButton::builder()
            .valign(gtk::Align::Center)
            .visible(self.select_mode)
            .build();
        select_check.set_active(self.selected_ids.contains(&entry.id));
        let id_for_check = entry.id;
        let s_check = sender.clone();
        select_check.connect_toggled(move |btn| {
            s_check.input(HistoryDialogInput::ToggleSelected(id_for_check, btn.is_active()));
        });
        row.add_prefix(&select_check);

        let pin_btn = gtk::Button::builder()
            .icon_name("view-pin-symbolic")
            .valign(gtk::Align::Center)
            .tooltip_text(if entry.pinned {
                crate::tr!("Unpin")
            } else {
                crate::tr!("Pin")
            })
            .build();
        pin_btn.add_css_class("flat");
        if entry.pinned {
            pin_btn.add_css_class("accent");
        }
        let id = entry.id;
        let s = sender.clone();
        pin_btn.connect_clicked(move |_| s.input(HistoryDialogInput::TogglePin(id)));
        row.add_suffix(&pin_btn);

        let delete_btn = gtk::Button::builder()
            .icon_name("user-trash-symbolic")
            .valign(gtk::Align::Center)
            .tooltip_text(crate::tr!("Delete"))
            .build();
        delete_btn.add_css_class("flat");
        let s_del = sender.clone();
        delete_btn.connect_clicked(move |_| s_del.input(HistoryDialogInput::Delete(id)));
        row.add_suffix(&delete_btn);

        let s_act = sender.clone();
        row.connect_activated(move |_| s_act.input(HistoryDialogInput::Activate(id)));

        let menu = gio::Menu::new();
        let nav_section = gio::Menu::new();
        nav_section.append(Some(&crate::tr!("Open in new tab")), Some("history-row.open"));
        nav_section.append(Some(&crate::tr!("Replace current tab")), Some("history-row.replace"));
        menu.append_section(None, &nav_section);
        let util_section = gio::Menu::new();
        util_section.append(
            Some(&if entry.pinned {
                crate::tr!("Unpin")
            } else {
                crate::tr!("Pin")
            }),
            Some("history-row.pin"),
        );
        util_section.append(Some(&crate::tr!("Copy SQL")), Some("history-row.copy"));
        menu.append_section(None, &util_section);
        let danger_section = gio::Menu::new();
        danger_section.append(Some(&crate::tr!("Delete")), Some("history-row.delete"));
        menu.append_section(None, &danger_section);

        let popover_menu = gtk::PopoverMenu::from_model(Some(&menu));
        popover_menu.set_has_arrow(true);
        popover_menu.set_parent(&row);

        let row_actions = gio::SimpleActionGroup::new();
        let s_open = sender.clone();
        let act_open = gio::ActionEntry::builder("open")
            .activate(move |_, _, _| s_open.input(HistoryDialogInput::Activate(id)))
            .build();
        let s_replace = sender.clone();
        let act_replace = gio::ActionEntry::builder("replace")
            .activate(move |_, _, _| s_replace.input(HistoryDialogInput::ReplaceCurrent(id)))
            .build();
        let s_pin = sender.clone();
        let act_pin = gio::ActionEntry::builder("pin")
            .activate(move |_, _, _| s_pin.input(HistoryDialogInput::TogglePin(id)))
            .build();
        let query_for_copy = entry.query.clone();
        let row_for_copy = row.clone();
        let act_copy = gio::ActionEntry::builder("copy")
            .activate(move |_, _, _| {
                row_for_copy.clipboard().set_text(&query_for_copy);
            })
            .build();
        let s_del2 = sender.clone();
        let act_del = gio::ActionEntry::builder("delete")
            .activate(move |_, _, _| s_del2.input(HistoryDialogInput::Delete(id)))
            .build();
        row_actions.add_action_entries([act_open, act_replace, act_pin, act_copy, act_del]);
        row.insert_action_group("history-row", Some(&row_actions));

        let gesture = gtk::GestureClick::new();
        gesture.set_button(gtk::gdk::BUTTON_SECONDARY);
        let popover_for_gesture = popover_menu.clone();
        gesture.connect_pressed(move |gesture, _n, x, y| {
            popover_for_gesture.set_pointing_to(Some(&gtk::gdk::Rectangle::new(x as i32, y as i32, 1, 1)));
            popover_for_gesture.popup();
            gesture.set_state(gtk::EventSequenceState::Claimed);
        });
        row.add_controller(gesture);

        let menu_shortcut = gtk::Shortcut::builder()
            .trigger(&gtk::ShortcutTrigger::parse_string("Menu").expect("valid trigger"))
            .action(&gtk::CallbackAction::new({
                let popover = popover_menu.clone();
                move |_, _| {
                    popover.popup();
                    glib::Propagation::Stop
                }
            }))
            .build();
        let controller = gtk::ShortcutController::new();
        controller.set_scope(gtk::ShortcutScope::Local);
        controller.add_shortcut(menu_shortcut);
        row.add_controller(controller);

        (row, popover_menu, select_check)
    }

    fn refresh_selection_bar(&self) {
        let n = self.selected_ids.len();
        if n == 0 {
            self.selection_bar.set_reveal_child(false);
            return;
        }
        self.selection_label
            .set_label(&crate::tr!("{n} selected").replace("{n}", &n.to_string()));
        self.selection_bar.set_reveal_child(true);
    }

    fn export_selected(&self, kind: &'static str, sender: ComponentSender<Self>) {
        let ids: Vec<i64> = self.selected_ids.iter().copied().collect();
        if ids.is_empty() {
            return;
        }
        let suggested = if kind == "sql" {
            "tablepro-history.sql".to_string()
        } else {
            "tablepro-history.csv".to_string()
        };
        sender.command(move |out, shutdown| {
            shutdown
                .register(async move {
                    let result = match kind {
                        "sql" => query_history::export_sql(&ids).await,
                        _ => query_history::export_csv(&ids).await,
                    };
                    let msg = match result {
                        Ok(text) => HistoryDialogCmd::ExportReady(text, suggested),
                        Err(e) => HistoryDialogCmd::ExportFailed(e.to_string()),
                    };
                    out.send(msg).ok()
                })
                .drop_on_shutdown()
        });
    }

    fn save_export(&self, content: String, suggested_name: String) {
        let filter = gtk::FileFilter::new();
        if suggested_name.ends_with(".sql") {
            filter.set_name(Some(&crate::tr!("SQL files")));
            filter.add_mime_type("text/x-sql");
            filter.add_suffix("sql");
        } else {
            filter.set_name(Some(&crate::tr!("CSV files")));
            filter.add_mime_type("text/csv");
            filter.add_suffix("csv");
        }
        let filters = gio::ListStore::new::<gtk::FileFilter>();
        filters.append(&filter);
        let dialog = gtk::FileDialog::builder()
            .title(crate::tr!("Export query history"))
            .modal(true)
            .initial_name(&suggested_name)
            .default_filter(&filter)
            .filters(&filters)
            .build();
        let parent_window = self.root.root().and_then(|r| r.downcast::<gtk::Window>().ok());
        dialog.save(parent_window.as_ref(), gio::Cancellable::NONE, move |outcome| {
            let Ok(file) = outcome else { return };
            let Some(path) = file.path() else { return };
            if let Err(e) = std::fs::write(&path, content.as_bytes()) {
                tracing::warn!(error = %e, path = %path.display(), "history export write failed");
            }
        });
    }

    fn query_for_id(&self, id: i64) -> Option<String> {
        self.entries.iter().find(|e| e.id == id).map(|e| e.query.clone())
    }

    fn is_pinned(&self, id: i64) -> bool {
        self.entries.iter().any(|e| e.id == id && e.pinned)
    }
}

fn fts5_query(input: &str) -> String {
    // Tokenise on whitespace and quote each token. FTS5 then ANDs them by
    // default ("SELECT users" → match rows containing both terms anywhere),
    // matching what users expect from a search box. Quoting protects each
    // token from FTS5's own operator chars (parens, AND, OR, NEAR, *).
    input
        .split_whitespace()
        .map(|tok| {
            let escaped = tok.replace('"', "\"\"");
            format!("\"{escaped}\"")
        })
        .collect::<Vec<_>>()
        .join(" ")
}

fn preview_title(query: &str) -> String {
    let first_line = query
        .lines()
        .find(|l| !l.trim().is_empty() && !l.trim().starts_with("--"))
        .unwrap_or("")
        .trim();
    let collected: String = first_line.chars().take(80).collect();
    if collected.chars().count() < first_line.chars().count() {
        format!("{collected}…")
    } else if collected.is_empty() {
        crate::tr!("Empty query")
    } else {
        collected
    }
}

fn format_subtitle(entry: &Entry) -> String {
    let when = format_relative_time(entry.executed_at);
    let mut parts: Vec<String> = vec![entry.connection_name.clone(), entry.driver_id.clone(), when];
    if let Some(d) = entry.duration_ms {
        parts.push(format!("{d} ms"));
    }
    if entry.cancelled {
        parts.push(crate::tr!("cancelled"));
    } else if let Some(err) = &entry.error {
        let trimmed: String = err.chars().take(48).collect();
        parts.push(if trimmed.chars().count() < err.chars().count() {
            format!("{trimmed}…")
        } else {
            trimmed
        });
    } else if let Some(rows) = entry.rows_affected {
        parts.push(crate::tr!("{n} row(s)").replace("{n}", &rows.to_string()));
    }
    parts.join(" · ")
}

fn format_relative_time(when: SystemTime) -> String {
    let now = SystemTime::now();
    let diff = now.duration_since(when).unwrap_or_default();
    let secs = diff.as_secs();
    if secs < 60 {
        crate::tr!("just now")
    } else if secs < 3600 {
        let n = secs / 60;
        crate::tr!("{n} min ago").replace("{n}", &n.to_string())
    } else if secs < 86_400 {
        let n = secs / 3600;
        crate::tr!("{n} h ago").replace("{n}", &n.to_string())
    } else if secs < 30 * 86_400 {
        let n = secs / 86_400;
        crate::tr!("{n} d ago").replace("{n}", &n.to_string())
    } else {
        let dt = chrono::DateTime::<chrono::Local>::from(when);
        dt.format("%Y-%m-%d").to_string()
    }
}

fn clear_listbox(listbox: &gtk::ListBox) {
    while let Some(child) = listbox.first_child() {
        listbox.remove(&child);
    }
}
