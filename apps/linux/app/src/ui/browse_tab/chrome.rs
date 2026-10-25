use relm4::{ComponentSender, adw, gtk};

use tablepro_core::{ColumnInfo, QueryResult};

use crate::ui::count_format::format_thousands;

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
        for (button, label) in [
            (&first_button, crate::tr!("First page")),
            (&prev_button, crate::tr!("Previous page")),
            (&next_button, crate::tr!("Next page")),
            (&last_button, crate::tr!("Last page")),
        ] {
            button.update_property(&[gtk::accessible::Property::Label(&label)]);
        }
        let paginator_label = gtk::Label::builder().build();
        paginator_label.add_css_class("dim-label");

        // Selection count badge — sits beside the paginator label.
        // Hidden when 0–1 rows selected; appears when the user
        // shift-clicks a range or ctrl-clicks to multi-select.
        // `accent` class draws the user's eye to it; AccessibleRole
        // Status is the same role we use for the paginator label so
        // a screen reader announces both as live regions.
        let selection_count_label = gtk::Label::new(None);
        selection_count_label.add_css_class("accent");
        selection_count_label.add_css_class("caption-heading");
        selection_count_label.set_accessible_role(gtk::AccessibleRole::Status);
        let selection_details_label = gtk::Label::builder().xalign(0.0).wrap(true).selectable(true).build();
        let copy_label = crate::tr!("Copy summary");
        let copy_selection_button = gtk::Button::with_label(&copy_label);
        let selection_details = gtk::Box::builder()
            .orientation(gtk::Orientation::Vertical)
            .spacing(8)
            .margin_top(12)
            .margin_bottom(12)
            .margin_start(12)
            .margin_end(12)
            .build();
        selection_details.append(&selection_details_label);
        selection_details.append(&copy_selection_button);
        let selection_popover = gtk::Popover::new();
        selection_popover.set_child(Some(&selection_details));
        let selection_label = gtk::MenuButton::new();
        selection_label.set_child(Some(&selection_count_label));
        selection_label.set_popover(Some(&selection_popover));
        selection_label.set_visible(false);
        selection_label.set_margin_start(12);
        let summary_for_copy = selection_details_label.clone();
        copy_selection_button.connect_clicked(move |_| {
            if let Some(display) = gtk::gdk::Display::default() {
                display.clipboard().set_text(&summary_for_copy.label());
            }
        });

        // Use thousands-separated labels (100 / 500 / 1,000 / 5,000 /
        // 10,000) instead of "1 K" abbreviations. With a visible
        // "Rows:" label inline (below) the dropdown's purpose is
        // obvious without needing a tooltip, matching how Evince
        // labels its zoom dropdown.
        let page_size_labels: Vec<String> = PAGE_SIZE_OPTIONS
            .iter()
            .map(|n| format_thousands(u128::from(*n)))
            .collect();
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
        page_size_combo.update_relation(&[gtk::accessible::Relation::LabelledBy(&[page_size_label.upcast_ref()])]);

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

        let export_button = gtk::Button::builder()
            .icon_name("document-save-symbolic")
            .tooltip_text(crate::tr!("Export results"))
            .action_name("win.export-csv")
            .build();
        export_button.add_css_class("flat");
        export_button.update_property(&[gtk::accessible::Property::Label(&crate::tr!("Export results"))]);

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
            selection_count_label,
            selection_details_label,
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
        let sender_for_discard_preview = sender.clone();
        discard_button.connect_clicked(move |_| sender_for_discard.input(BrowseTabInput::DiscardAll));

        let save_button = gtk::Button::builder()
            .label(crate::tr!("Save"))
            .tooltip_text(crate::tr!("Save pending edits (Ctrl+S)"))
            .build();
        save_button.add_css_class("suggested-action");
        let sender_for_save = sender;
        save_button.connect_clicked(move |_| sender_for_save.input(BrowseTabInput::CommitSave));

        let preview_button = gtk::Button::builder()
            .label(crate::tr!("Preview SQL"))
            .tooltip_text(crate::tr!("Show the statements Save would run"))
            .build();
        let sender_for_preview = sender_for_discard_preview;
        preview_button.connect_clicked(move |_| sender_for_preview.input(BrowseTabInput::PreviewSql));

        let bar = gtk::ActionBar::new();
        bar.pack_start(&pending_label);
        bar.pack_end(&save_button);
        bar.pack_end(&discard_button);
        bar.pack_end(&preview_button);

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
            let label =
                crate::trn!("{n} unsaved change", "{n} unsaved changes", count).replace("{n}", &count.to_string());
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
        if !self.allows_row_mutations() {
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

    pub(super) fn allows_row_mutations(&self) -> bool {
        !self.read_only
    }

    pub(super) fn allows_keyed_row_mutations(&self) -> bool {
        self.allows_row_mutations() && self.current_columns.iter().any(|column| column.primary_key)
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
        self.reset_keyset_navigation();
        self.refresh_filter_chrome();
        if let Some(strip) = self.filter_strip.as_ref() {
            strip.update_filter(set);
        }
        self.emit_fetch_page_and_count(sender);
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
                &crate::trn!(
                    "{n} filter rule active — click to edit",
                    "{n} filter rules active — click to edit",
                    n
                )
                .replace("{n}", &n.to_string()),
            ));
        }
    }

    pub(super) fn set_paginator_text(&self, text: &str) {
        self.paginator_label.set_label(text);
        self.paginator_label
            .update_property(&[gtk::accessible::Property::Label(text)]);
    }

    pub(super) fn update_next_page_sensitivity(&self) {
        self.next_button.set_sensitive(
            next_page_offset(
                self.current_offset,
                self.page_size,
                self.current_total_rows,
                self.current_result.as_deref(),
            )
            .is_some(),
        );
    }

    pub(super) fn update_paginator_label(&self) {
        let Some(result) = self.current_result.as_ref() else {
            self.set_paginator_text("");
            return;
        };
        self.set_paginator_text(&paginator_summary(result, self.current_offset, self.current_total_rows));
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

    pub(super) fn show_error_inner(&self, message: &str, sender: &ComponentSender<Self>) {
        // Title pattern matches the structure tab ("Couldn't load
        // structure"). The previous terse "Failed" left the user
        // guessing what failed.
        let page = adw::StatusPage::builder()
            .icon_name("dialog-error-symbolic")
            .title(crate::tr!("Couldn't load rows"))
            .description(message)
            .child(&retry_button(sender))
            .build();
        self.replace_status_child("error", &page);
    }
}

fn retry_button(sender: &ComponentSender<BrowseTab>) -> gtk::Button {
    let button = gtk::Button::builder()
        .label(crate::tr!("Retry"))
        .halign(gtk::Align::Center)
        .build();
    button.add_css_class("pill");
    let sender = sender.clone();
    button.connect_clicked(move |_| sender.input(BrowseTabInput::Refresh));
    button
}

fn paginator_summary(result: &QueryResult, offset: u64, total: Option<u64>) -> String {
    let n_rows = result.rows.len();
    if n_rows == 0 {
        return if result.truncated {
            crate::tr!("No rows on this page (result truncated)")
        } else {
            crate::tr!("No rows on this page")
        };
    }
    let template = match (total.is_some(), result.truncated) {
        (true, true) => crate::tr!("Rows {start} – {end} of {total} (result truncated)"),
        (true, false) => crate::tr!("Rows {start} – {end} of {total}"),
        (false, true) => crate::tr!("Rows {start} – {end} (result truncated)"),
        (false, false) => crate::tr!("Rows {start} – {end}"),
    };
    template
        .replace("{start}", &format_thousands(u128::from(offset + 1)))
        .replace("{end}", &format_thousands(u128::from(offset + n_rows as u64)))
        .replace(
            "{total}",
            &total
                .map(|count| format_thousands(u128::from(count)))
                .unwrap_or_default(),
        )
}

pub(super) fn next_page_offset(
    current_offset: u64,
    page_size: u64,
    total_rows: Option<u64>,
    page: Option<&QueryResult>,
) -> Option<u64> {
    let loaded_rows = page.map_or(0, |page| page.rows.len() as u64);
    let truncated = page.is_some_and(|page| page.truncated);
    let shown_rows = if truncated { loaded_rows.max(1) } else { loaded_rows };
    let available = match total_rows {
        Some(total) => current_offset.saturating_add(shown_rows) < total,
        None => truncated || loaded_rows == page_size,
    };
    let step = if truncated { shown_rows } else { page_size };
    available.then(|| current_offset.saturating_add(step))
}

pub(super) fn previous_page_offset(current_offset: u64, page_size: u64) -> Option<u64> {
    (current_offset > 0).then(|| current_offset.saturating_sub(page_size))
}

pub(super) fn extract_keyset_cursor(
    columns: &[ColumnInfo],
    result: &QueryResult,
    projected_columns: Option<&[usize]>,
) -> Option<Vec<tablepro_core::Value>> {
    extract_keyset_boundary(columns, result.rows.last()?, projected_columns)
}

pub(super) fn extract_first_keyset_cursor(
    columns: &[ColumnInfo],
    result: &QueryResult,
    projected_columns: Option<&[usize]>,
) -> Option<Vec<tablepro_core::Value>> {
    extract_keyset_boundary(columns, result.rows.first()?, projected_columns)
}

fn extract_keyset_boundary(
    columns: &[ColumnInfo],
    row: &[tablepro_core::Value],
    projected_columns: Option<&[usize]>,
) -> Option<Vec<tablepro_core::Value>> {
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
        values.push(row.get(result_index)?.clone());
    }
    Some(values)
}

pub(super) fn clear_box(b: &gtk::Box) {
    while let Some(child) = b.first_child() {
        b.remove(&child);
    }
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
    pub(super) selection_label: gtk::MenuButton,
    pub(super) selection_count_label: gtk::Label,
    pub(super) selection_details_label: gtk::Label,
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
    use super::{extract_first_keyset_cursor, extract_keyset_cursor, format_thousands, paginator_summary};
    use tablepro_core::{ColumnInfo, QueryResult, Value};

    #[test]
    fn projected_keyset_cursor_maps_primary_keys_to_result_positions() {
        let columns = vec![column("name", false), column("id", true), column("flag", false)];
        let result = QueryResult {
            columns: vec![column("id", true), column("name", false)],
            rows: vec![
                vec![Value::Int(7), Value::Text("Ada".into())],
                vec![Value::Int(8), Value::Text("Bea".into())],
            ],
            truncated: false,
        };
        assert_eq!(
            extract_keyset_cursor(&columns, &result, Some(&[1, 0])),
            Some(vec![Value::Int(8)])
        );
        assert_eq!(
            extract_first_keyset_cursor(&columns, &result, Some(&[1, 0])),
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

    fn page(rows: usize, truncated: bool) -> QueryResult {
        QueryResult {
            columns: vec![column("payload", false)],
            rows: vec![vec![Value::Text("large".into())]; rows],
            truncated,
        }
    }

    #[test]
    fn truncated_browse_pages_disclose_the_result_limit() {
        assert_eq!(
            paginator_summary(&page(37, true), 1_000, Some(5_000)),
            "Rows 1,001 – 1,037 of 5,000 (result truncated)"
        );
        assert_eq!(
            paginator_summary(&page(37, true), 0, None),
            "Rows 1 – 37 (result truncated)"
        );
    }

    #[test]
    fn a_truncated_browse_page_without_rows_still_discloses_the_result_limit() {
        assert_eq!(
            paginator_summary(&page(0, true), 0, Some(5_000)),
            "No rows on this page (result truncated)"
        );
    }

    #[test]
    fn untruncated_browse_pages_have_no_result_limit_suffix() {
        assert_eq!(
            paginator_summary(&page(100, false), 1_000, Some(5_000)),
            "Rows 1,001 – 1,100 of 5,000"
        );
        assert_eq!(paginator_summary(&page(100, false), 0, None), "Rows 1 – 100");
        assert_eq!(
            paginator_summary(&page(0, false), 0, Some(5_000)),
            "No rows on this page"
        );
    }

    #[test]
    fn format_thousands_handles_edges() {
        assert_eq!(format_thousands(0), "0");
        assert_eq!(format_thousands(1), "1");
        assert_eq!(format_thousands(999), "999");
    }
}
