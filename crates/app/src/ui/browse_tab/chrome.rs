use relm4::{ComponentSender, adw, gtk};

use tablepro_core::{ColumnInfo, QueryResult};

use super::*;

impl BrowseTab {
    pub(super) fn build_paginator(sender: ComponentSender<Self>, page_size: u64) -> Paginator {
        // First / Last bracket the Prev / Next pair. Tables of
        // millions of rows make Last especially valuable — without
        // it the user has to spam Next to reach the bottom. Same
        // visual + interaction model as TablePlus / DataGrip /
        // DBeaver. Last stays disabled until the row count loads.
        // Insert row sits at the very start of the paginator's
        // pack_start group — clearly separated from the nav arrows by
        // its position and by the GtkActionBar's start group spacing,
        // so a mis-aim toward Next doesn't land on Insert.
        let insert_button = gtk::Button::builder()
            .icon_name("list-add-symbolic")
            .tooltip_text(crate::tr!("Insert row (Ctrl+N)"))
            .sensitive(false)
            .build();
        insert_button.add_css_class("flat");
        insert_button.update_property(&[gtk::accessible::Property::Label(&crate::tr!("Insert row"))]);
        let sender_for_insert = sender.clone();
        insert_button.connect_clicked(move |_| sender_for_insert.input(BrowseTabInput::InsertRow));

        let first_button = gtk::Button::builder()
            .icon_name("go-first-symbolic")
            .tooltip_text(crate::tr!("First page"))
            .sensitive(false)
            .build();
        let prev_button = gtk::Button::builder()
            .icon_name("go-previous-symbolic")
            .tooltip_text(crate::tr!("Previous page (Page Up)"))
            .sensitive(false)
            .build();
        let next_button = gtk::Button::builder()
            .icon_name("go-next-symbolic")
            .tooltip_text(crate::tr!("Next page (Page Down)"))
            .sensitive(false)
            .build();
        let last_button = gtk::Button::builder()
            .icon_name("go-last-symbolic")
            .tooltip_text(crate::tr!("Last page"))
            .sensitive(false)
            .build();
        let paginator_label = gtk::Label::builder().build();
        paginator_label.add_css_class("dim-label");

        // Selection count badge — sits beside the paginator label.
        // Hidden when 0–1 rows selected; appears when the user
        // shift-clicks a range or ctrl-clicks to multi-select.
        // `accent` class draws the user's eye to it; AccessibleRole
        // Status is the same role we use for the paginator label so
        // a screen reader announces both as live regions.
        let selection_label = gtk::Label::builder().visible(false).build();
        selection_label.add_css_class("accent");
        selection_label.add_css_class("caption-heading");
        selection_label.set_accessible_role(gtk::AccessibleRole::Status);
        selection_label.set_margin_start(12);

        // Use thousands-separated labels (100 / 500 / 1,000 / 5,000 /
        // 10,000) instead of "1 K" abbreviations. With a visible
        // "Rows:" label inline (below) the dropdown's purpose is
        // obvious without needing a tooltip, matching how Evince
        // labels its zoom dropdown.
        let page_size_labels: Vec<String> = PAGE_SIZE_OPTIONS.iter().map(|n| format_thousands(*n)).collect();
        let page_size_strs: Vec<&str> = page_size_labels.iter().map(String::as_str).collect();
        let page_size_combo = gtk::DropDown::from_strings(&page_size_strs);
        let initial_idx = PAGE_SIZE_OPTIONS
            .iter()
            .position(|n| *n == page_size)
            .unwrap_or_else(|| {
                PAGE_SIZE_OPTIONS
                    .iter()
                    .position(|n| *n == DEFAULT_PAGE_SIZE)
                    .unwrap_or(2)
            }) as u32;
        page_size_combo.set_selected(initial_idx);
        let sender_for_size = sender.clone();
        page_size_combo.connect_selected_notify(move |dd| {
            let idx = dd.selected() as usize;
            if let Some(&size) = PAGE_SIZE_OPTIONS.get(idx) {
                sender_for_size.input(BrowseTabInput::PageSizeChanged(size));
            }
        });
        let page_size_label = gtk::Label::builder().label(crate::tr!("Rows:")).build();
        page_size_label.add_css_class("dim-label");

        let sender_for_first = sender.clone();
        first_button.connect_clicked(move |_| sender_for_first.input(BrowseTabInput::FirstPage));
        let sender_for_prev = sender.clone();
        prev_button.connect_clicked(move |_| sender_for_prev.input(BrowseTabInput::PrevPage));
        let sender_for_next = sender.clone();
        next_button.connect_clicked(move |_| sender_for_next.input(BrowseTabInput::NextPage));
        let sender_for_last = sender;
        last_button.connect_clicked(move |_| sender_for_last.input(BrowseTabInput::LastPage));

        // Paginator lives in a native `gtk::ActionBar` to match the
        // mutations bar and the Structure tab's bottom action bar.
        // Prev/Next/label are start-packed; page-size + export are
        // end-packed — which gives the same visual as before but
        // through the toolkit's intended widget so spacing, dim-label
        // background, and high-contrast theming come for free.
        let paginator_bar = gtk::ActionBar::new();

        // Export menu uses win.export-csv / win.export-json (App-level
        // actions); they read the active tab's snapshot so the buttons
        // implicitly target this tab when this tab is active.
        let export_menu = gtk::gio::Menu::new();
        export_menu.append(Some(&crate::tr!("Export current page as CSV…")), Some("win.export-csv"));
        export_menu.append(
            Some(&crate::tr!("Export current page as JSON…")),
            Some("win.export-json"),
        );
        export_menu.append(Some(&crate::tr!("Export all rows as CSV…")), Some("win.export-all-csv"));
        export_menu.append(
            Some(&crate::tr!("Export all rows as JSON…")),
            Some("win.export-all-json"),
        );
        let export_button = gtk::MenuButton::builder()
            .icon_name("document-save-symbolic")
            .tooltip_text(crate::tr!("Export results"))
            .menu_model(&export_menu)
            .build();
        export_button.add_css_class("flat");

        // Filter button — opens the rule editor for server-side WHERE.
        // Action `win.open-filter` is registered in app/mod.rs and
        // reads the active tab's controller, so the button implicitly
        // targets this tab when this tab is active.
        //
        // Text-only label (no icon) because there is no canonical GNOME
        // symbolic icon for "filter rows" in adwaita-icon-theme — the
        // alternatives (system-search-symbolic, edit-find-symbolic)
        // clash with Ctrl+F (now bound here). GNOME HIG accepts text-
        // labeled toolbar buttons; the surrounding paginator strip is
        // already text-heavy (`Rows 1–12 of 12`, `Rows: 100`) so a
        // text label reads as native here. The `filter_badge` label
        // shows the active rule count next to the word when ≥1 rule
        // applies; hidden otherwise.
        let filter_label = gtk::Label::new(Some(&crate::tr!("Filter")));
        let filter_badge = gtk::Label::builder().label("").visible(false).build();
        filter_badge.add_css_class("numeric");
        filter_badge.add_css_class("caption-heading");
        filter_badge.add_css_class("dim-label");
        let filter_box = gtk::Box::builder()
            .orientation(gtk::Orientation::Horizontal)
            .spacing(6)
            .build();
        filter_box.append(&filter_label);
        filter_box.append(&filter_badge);
        let filter_button = gtk::Button::builder()
            .tooltip_text(crate::tr!("Filter rows (Ctrl+F)"))
            .action_name("win.open-filter")
            .child(&filter_box)
            .build();
        filter_button.add_css_class("flat");

        // First / Prev / Next / Last sit in a `linked` group so they
        // read as one navigation control — same pattern GNOME Files
        // uses on its back/forward toolbar buttons.
        let nav_box = gtk::Box::builder().orientation(gtk::Orientation::Horizontal).build();
        nav_box.add_css_class("linked");
        nav_box.append(&first_button);
        nav_box.append(&prev_button);
        nav_box.append(&next_button);
        nav_box.append(&last_button);

        paginator_bar.pack_start(&insert_button);
        paginator_bar.pack_start(&nav_box);
        paginator_bar.pack_start(&paginator_label);
        paginator_bar.pack_start(&selection_label);
        let inspector_button = gtk::ToggleButton::builder()
            .icon_name("sidebar-show-right-symbolic")
            .tooltip_text(crate::tr!("Row inspector"))
            .build();
        inspector_button.add_css_class("flat");
        inspector_button.update_property(&[gtk::accessible::Property::Label(&crate::tr!("Row inspector"))]);
        paginator_bar.pack_end(&inspector_button);
        paginator_bar.pack_end(&export_button);
        paginator_bar.pack_end(&filter_button);
        paginator_bar.pack_end(&page_size_combo);
        paginator_bar.pack_end(&page_size_label);

        Paginator {
            bar: paginator_bar,
            insert_button,
            first_button,
            prev_button,
            next_button,
            last_button,
            filter_button,
            filter_badge,
            paginator_label,
            selection_label,
            inspector_button,
        }
    }

    /// Pending-changes footer: a `gtk::ActionBar` wrapped in a
    /// `GtkRevealer` so the entire bar slides in only when there are
    /// unsaved edits. Mirrors GNOME Text Editor / Builder's behaviour
    /// of revealing a transient action footer rather than reserving a
    /// permanent strip for occasionally-used controls.
    ///
    /// Layout: pending-count label on the left ("3 unsaved changes"),
    /// Discard + Save on the right (Save is `.suggested-action`).
    pub(super) fn build_pending_revealer(sender: ComponentSender<Self>) -> PendingRevealer {
        let pending_label = gtk::Label::new(None);
        pending_label.add_css_class("dim-label");
        pending_label.add_css_class("caption");

        let discard_button = gtk::Button::builder()
            .label(crate::tr!("Discard"))
            .tooltip_text(crate::tr!("Discard all pending edits"))
            .build();
        let sender_for_discard = sender.clone();
        discard_button.connect_clicked(move |_| sender_for_discard.input(BrowseTabInput::DiscardAll));

        let save_button = gtk::Button::builder()
            .label(crate::tr!("Save"))
            .tooltip_text(crate::tr!("Save pending edits (Ctrl+S)"))
            .build();
        save_button.add_css_class("suggested-action");
        let sender_for_save = sender;
        save_button.connect_clicked(move |_| sender_for_save.input(BrowseTabInput::CommitSave));

        let bar = gtk::ActionBar::new();
        bar.pack_start(&pending_label);
        bar.pack_end(&save_button);
        bar.pack_end(&discard_button);

        let revealer = gtk::Revealer::builder()
            .transition_type(gtk::RevealerTransitionType::SlideUp)
            .transition_duration(150)
            .reveal_child(false)
            .child(&bar)
            .build();

        PendingRevealer {
            widget: revealer,
            save_button,
            discard_button,
            pending_label,
        }
    }

    /// Toggle visibility / label of the pending-changeset cluster in
    /// the mutation bar. Hidden when there are no pending edits; shows
    /// "{n} unsaved change(s)" with Save (.suggested-action) + Discard.
    /// The tab-title bullet (App-side) plus this footer cluster cover
    /// the dirty-state communication — no banner.
    pub(super) fn refresh_pending_bar(&self, count: usize) {
        let visible = count > 0;
        if visible {
            let label = if count == 1 {
                crate::tr!("1 unsaved change")
            } else {
                crate::tr!("{n} unsaved changes").replace("{n}", &count.to_string())
            };
            self.pending_label.set_label(&label);
        }
        // Slide the whole footer in/out as one unit instead of
        // toggling each child's visibility. GtkRevealer animates the
        // reveal so the bar doesn't pop into existence; the bar's
        // own children stay always-visible inside it.
        self.pending_revealer.set_reveal_child(visible);
        self.refresh_banner_visibility();
    }

    /// Reveal at most ONE banner at a time. Read-only takes priority
    /// over no-PK because read-only blocks every kind of edit.
    pub(super) fn refresh_banner_visibility(&self) {
        let read_only = self.read_only;
        let no_pk = self.current_columns.iter().any(|c| !c.primary_key)
            && !self.current_columns.is_empty()
            && !self.current_columns.iter().any(|c| c.primary_key);
        self.read_only_banner.set_revealed(read_only);
        self.no_pk_banner.set_revealed(!read_only && no_pk);
    }

    pub(super) fn refresh_crud_buttons(&self) {
        let has_columns = !self.current_columns.is_empty();
        let has_pk = self.has_primary_key();
        if self.read_only {
            // The Insert button lives in the per-table HeaderBar, not
            // in this tab's own widget tree — but the visibility flip
            // still drives the GtkWidget directly, so the header-bar
            // slot just collapses when the connection is read-only.
            self.insert_button.set_visible(false);
            return;
        }
        self.insert_button.set_visible(true);
        // No-PK tables don't get inline editing because RowKey can't be
        // formed without a PK and our materialise path would silently
        // no-op on UPDATE/DELETE. Disable instead of hide so the
        // affordance stays discoverable; tooltip explains the gate.
        self.insert_button.set_sensitive(has_columns && has_pk);
        if has_columns && !has_pk {
            self.insert_button.set_tooltip_text(Some(&crate::tr!(
                "This table has no primary key. Inline editing is disabled."
            )));
        } else {
            self.insert_button
                .set_tooltip_text(Some(&crate::tr!("Insert row (Ctrl+N)")));
        }
        self.refresh_banner_visibility();
    }

    /// Update the Filter button's count badge + tooltip based on the
    /// current FilterSet. Active filters reveal a small numeric badge
    /// next to the funnel icon and a count-aware tooltip; empty hides
    /// the badge and falls back to the generic shortcut hint. Called
    /// from FilterApplied + once on init so a restored filter shows
    /// immediately.
    pub(super) fn apply_filter(&mut self, set: tablepro_core::FilterSet, sender: &ComponentSender<Self>) {
        // No change to the rule list → don't churn the disk
        // or refetch. Re-fetch on identical filter would just
        // duplicate the F5 path, which the user can take
        // explicitly.
        if set == self.current_filter {
            return;
        }
        self.current_filter = set.clone();
        if let (Some(conn_id), Some(store)) = (self.connection_id, &self.persistence.filter_settings)
            && let Err(error) = store.save(conn_id, self.schema.as_deref(), &self.table, set.clone())
        {
            let _ = sender.output(BrowseTabOutput::ShowToast(error));
        }
        // Filtered counts shift; jump back to page 1 so the
        // user isn't stranded on offset N where N might be
        // beyond the new filtered total.
        self.current_offset = 0;
        self.keyset_cursor = None;
        self.refresh_filter_chrome();
        if let Some(strip) = self.filter_strip.as_ref() {
            strip.update_filter(set);
        }
        let _ = sender.output(BrowseTabOutput::FetchPage);
        let _ = sender.output(BrowseTabOutput::FetchRowCount);
        let _ = sender.output(BrowseTabOutput::StateChanged);
    }

    pub(super) fn filter_by_value(&self, column: &str, value: &tablepro_core::Value, sender: &ComponentSender<Self>) {
        match tablepro_core::equality_rule(column, value) {
            Some(rule) => sender.input(BrowseTabInput::FilterApplied(self.current_filter.narrowed_to(rule))),
            None => {
                let _ = sender.output(BrowseTabOutput::ShowToast(crate::tr!(
                    "Values of this type can't be used as a filter"
                )));
            }
        }
    }

    pub(super) fn refresh_filter_chrome(&self) {
        let n = self.current_filter.len();
        if n == 0 {
            self.filter_badge.set_visible(false);
            self.filter_badge.set_label("");
            self.filter_button
                .set_tooltip_text(Some(&crate::tr!("Filter rows (Ctrl+F)")));
        } else {
            self.filter_badge.set_label(&n.to_string());
            self.filter_badge.set_visible(true);
            self.filter_button.set_tooltip_text(Some(
                &crate::tr!("{n} filter rule(s) active — click to edit").replace("{n}", &n.to_string()),
            ));
        }
    }

    pub(super) fn set_paginator_text(&self, text: &str) {
        self.paginator_label.set_label(text);
        self.paginator_label
            .update_property(&[gtk::accessible::Property::Label(text)]);
    }

    pub(super) fn update_paginator_label(&self) {
        let Some(result) = self.current_result.as_ref() else {
            self.set_paginator_text("");
            return;
        };
        let n_rows = result.rows.len();
        if n_rows == 0 {
            // Reachable when the user navigated past the end of a
            // table that shrank in another session, before
            // RowCountLoaded clamps the offset back. Human
            // wording — the previous "No rows at offset N" read as
            // a bug message.
            self.set_paginator_text(&crate::tr!("No rows on this page"));
            return;
        }
        let start = self.current_offset + 1;
        let end = self.current_offset + n_rows as u64;
        // Match the page-size dropdown's thousands grouping.
        // "Rows 10,001 – 10,100 of 5,000,000" is faster to read than
        // "Rows 10001 – 10100 of 5000000" and matches GNOME File's
        // "1,234 items" idiom.
        let start_s = format_thousands(start);
        let end_s = format_thousands(end);
        let label = match self.current_total_rows {
            Some(total) => crate::tr!("Rows {start} – {end} of {total}")
                .replace("{start}", &start_s)
                .replace("{end}", &end_s)
                .replace("{total}", &format_thousands(total)),
            None => crate::tr!("Rows {start} – {end}")
                .replace("{start}", &start_s)
                .replace("{end}", &end_s),
        };
        self.set_paginator_text(&label);
    }

    pub(super) fn replace_status_child(&self, name: &str, child: &impl IsA<gtk::Widget>) {
        if let Some(prev) = self.inner_stack.child_by_name(name) {
            self.inner_stack.remove(&prev);
        }
        self.inner_stack.add_named(child, Some(name));
        self.inner_stack.set_visible_child_name(name);
    }

    pub(super) fn show_loading_inner(&self, title: &str, description: &str) {
        let spinner = gtk::Spinner::builder()
            .spinning(true)
            .width_request(32)
            .height_request(32)
            .halign(gtk::Align::Center)
            .build();
        let page = adw::StatusPage::builder()
            .title(title)
            .description(description)
            .child(&spinner)
            .build();
        self.replace_status_child("loading", &page);
    }

    pub(super) fn show_error_inner(&self, message: &str) {
        // Title pattern matches the structure tab ("Couldn't load
        // structure"). The previous terse "Failed" left the user
        // guessing what failed.
        let page = adw::StatusPage::builder()
            .icon_name("dialog-error-symbolic")
            .title(crate::tr!("Couldn't load rows"))
            .description(message)
            .build();
        self.replace_status_child("error", &page);
    }
}

pub(super) fn extract_keyset_cursor(
    columns: &[ColumnInfo],
    result: &QueryResult,
    projected_columns: Option<&[usize]>,
) -> Option<Vec<tablepro_core::Value>> {
    let last_row = result.rows.last()?;
    let pk_indexes: Vec<usize> = columns
        .iter()
        .enumerate()
        .filter(|(_, c)| c.primary_key)
        .map(|(i, _)| i)
        .collect();
    if pk_indexes.is_empty() {
        return None;
    }
    let mut values = Vec::with_capacity(pk_indexes.len());
    for idx in pk_indexes {
        let result_index = match projected_columns {
            Some(projection) => projection.iter().position(|projected| *projected == idx)?,
            None => idx,
        };
        values.push(last_row.get(result_index)?.clone());
    }
    Some(values)
}

pub(super) fn clear_box(b: &gtk::Box) {
    while let Some(child) = b.first_child() {
        b.remove(&child);
    }
}
pub(super) fn format_thousands(n: u64) -> String {
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

/// Bundle of widgets returned by `build_paginator` so the builder
/// signature stays narrow.
pub(super) struct Paginator {
    pub(super) bar: gtk::ActionBar,
    pub(super) insert_button: gtk::Button,
    pub(super) first_button: gtk::Button,
    pub(super) prev_button: gtk::Button,
    pub(super) next_button: gtk::Button,
    pub(super) last_button: gtk::Button,
    pub(super) filter_button: gtk::Button,
    pub(super) filter_badge: gtk::Label,
    pub(super) paginator_label: gtk::Label,
    pub(super) selection_label: gtk::Label,
    pub(super) inspector_button: gtk::ToggleButton,
}

/// Bundle of widgets returned by `build_pending_revealer`.
pub(super) struct PendingRevealer {
    pub(super) widget: gtk::Revealer,
    pub(super) save_button: gtk::Button,
    pub(super) discard_button: gtk::Button,
    pub(super) pending_label: gtk::Label,
}

pub(super) fn bind_inspector(
    content: &impl IsA<gtk::Widget>,
    button: &gtk::ToggleButton,
) -> crate::ui::row_inspector::RowInspector {
    let inspector = crate::ui::row_inspector::RowInspector::new(content);
    button.connect_toggled({
        let inspector = inspector.clone();
        move |button| inspector.set_visible(button.is_active())
    });
    inspector
}

#[cfg(test)]
mod tests {
    use super::{extract_keyset_cursor, format_thousands};
    use tablepro_core::{ColumnInfo, QueryResult, Value};

    #[test]
    fn projected_keyset_cursor_maps_primary_keys_to_result_positions() {
        let columns = vec![column("name", false), column("id", true), column("flag", false)];
        let result = QueryResult {
            columns: vec![column("id", true), column("name", false)],
            rows: vec![vec![Value::Int(7), Value::Text("Ada".into())]],
            truncated: false,
        };
        assert_eq!(
            extract_keyset_cursor(&columns, &result, Some(&[1, 0])),
            Some(vec![Value::Int(7)])
        );
        assert_eq!(extract_keyset_cursor(&columns, &result, Some(&[0])), None);
    }

    fn column(name: &str, primary_key: bool) -> ColumnInfo {
        ColumnInfo {
            name: name.into(),
            data_type: "text".into(),
            nullable: false,
            primary_key,
            is_auto_increment: false,
            default_value: None,
            is_generated: false,
            comment: None,
            collation: None,
            enum_type: None,
            domain_type: None,
        }
    }

    #[test]
    fn format_thousands_handles_common_page_sizes() {
        assert_eq!(format_thousands(100), "100");
        assert_eq!(format_thousands(500), "500");
        assert_eq!(format_thousands(1_000), "1,000");
        assert_eq!(format_thousands(5_000), "5,000");
        assert_eq!(format_thousands(10_000), "10,000");
        assert_eq!(format_thousands(1_000_000), "1,000,000");
    }

    #[test]
    fn format_thousands_handles_edges() {
        assert_eq!(format_thousands(0), "0");
        assert_eq!(format_thousands(1), "1");
        assert_eq!(format_thousands(999), "999");
    }
}
