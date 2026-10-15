use std::cell::RefCell;
use std::rc::Rc;
use std::sync::Arc;

use gtk4 as gtk;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use gtk4::{gio, glib};
use libadwaita as adw;
use tablepro_session::Session;
use tablepro_session::runtime::Tasks;

use super::columns::build_column_row;
use super::context::StructureContext;
use super::draft_column_object::DraftColumnObject;
use super::fks::build_fk_row;
use super::foreign_key_dialog::{ForeignKeyDialog, ForeignKeyDialogInit, reference_scope};
use super::foreign_key_object::ForeignKeyObject;
use super::index_dialog::IndexDialog;
use super::index_object::IndexObject;
use super::indexes::build_index_row;
use super::structure_tab_widgets::StructureTabWidgets;
use super::{
    ColumnsInput, ForeignKeysInput, IndexesInput, LoadInput, SaveInput, StructureMode, StructureTab, StructureTabInput,
    StructureTabOutput, TableInput, apply_sql_scheme, items,
};
use crate::ui::handler_guard::HandlerGuard;
use crate::ui::tab_load::StaleBanner;

pub(super) struct LayoutInit<'a> {
    pub(super) table: &'a str,
    /// The table's schema, which a foreign key may have to reference
    /// within.
    pub(super) schema: Option<String>,
    pub(super) mode: StructureMode,
    /// The connection refuses writes, so Drop is not offered.
    pub(super) read_only: bool,
    pub(super) session: &'a Arc<Session>,
    pub(super) tasks: &'a Tasks,
}

/// The draft's columns, indexes and foreign keys, which the pages'
/// lists show.
pub(super) struct DraftStores<'a> {
    pub(super) columns: &'a gio::ListStore,
    pub(super) indexes: &'a gio::ListStore,
    pub(super) foreign_keys: &'a gio::ListStore,
}

/// The tab as it opens, each page bound to the draft's stores and each
/// control sending its input. Gives back the widgets the handlers drive.
pub(super) fn build(
    tab: &StructureTab,
    init: LayoutInit<'_>,
    context: &Rc<RefCell<StructureContext>>,
    stores: &DraftStores<'_>,
) -> StructureTabWidgets {
    let imp = tab.imp();
    let (sql_buffer, theme_handler) = sql_preview_page(tab);
    let name_changed = name_row(tab, init.table, init.mode);
    toolbar(tab, init.mode, init.read_only);
    let stale_banner = load_pages(tab, init.mode);
    columns_page(tab, context, stores.columns);
    indexes_page(tab, context, stores);
    foreign_keys_page(tab, context, stores, init.schema, init.session, init.tasks);
    StructureTabWidgets {
        inner_stack: imp.inner_stack.get(),
        error_status: imp.error_status.get(),
        stale_banner,
        name_entry: imp.name_entry.get(),
        name_row: imp.name_row.get(),
        name_changed,
        columns_box: imp.columns_box.get(),
        indexes_box: imp.indexes_box.get(),
        fks_box: imp.fks_box.get(),
        add_column_row: imp.add_column_row.get(),
        add_index_row: imp.add_index_row.get(),
        add_fk_row: imp.add_fk_row.get(),
        sql_buffer,
        pending_label: imp.pending_label.get(),
        save_button: imp.save_button.get(),
        discard_button: imp.discard_button.get(),
        drop_button: imp.drop_button.get(),
        saving_spinner: imp.saving_spinner.get(),
        stop_button: imp.stop_button.get(),
        _theme_handler: theme_handler,
    }
}

/// The preview's buffer, highlighted as SQL in the desktop's light or
/// dark scheme, and the handler that follows the scheme.
fn sql_preview_page(tab: &StructureTab) -> (sourceview5::Buffer, HandlerGuard) {
    let imp = tab.imp();
    let sql_buffer = match sourceview5::LanguageManager::default().language("sql") {
        Some(language) => sourceview5::Buffer::with_language(&language),
        None => sourceview5::Buffer::new(None),
    };
    imp.sql_view.set_buffer(Some(&sql_buffer));
    apply_sql_scheme(&sql_buffer);
    let style_manager = adw::StyleManager::default();
    let buffer_for_theme = sql_buffer.downgrade();
    let theme_handler = HandlerGuard::new(
        &style_manager,
        style_manager.connect_dark_notify(move |_| {
            if let Some(buffer) = buffer_for_theme.upgrade() {
                apply_sql_scheme(&buffer);
            }
        }),
    );
    // Saves the user clicking into the preview, selecting all and
    // copying every time they want the DDL in another tool.
    let buffer_for_copy = sql_buffer.downgrade();
    let tab_for_copy = tab.downgrade();
    imp.copy_sql_button.connect_clicked(move |button| {
        if let Some(buffer) = buffer_for_copy.upgrade() {
            let text = buffer.text(&buffer.start_iter(), &buffer.end_iter(), false);
            crate::ui::clipboard::copy_text(button, text.to_string(), |message| {
                if let Some(tab) = tab_for_copy.upgrade() {
                    tab.emit_output(StructureTabOutput::ShowToast(message.to_owned()));
                }
            });
        }
    });
    (sql_buffer, theme_handler)
}

/// The new table's name, and the entry's handler, which the tab blocks
/// while it writes the name itself.
fn name_row(tab: &StructureTab, table: &str, mode: StructureMode) -> glib::SignalHandlerId {
    let imp = tab.imp();
    imp.name_entry.set_text(table);
    imp.name_row.set_visible(matches!(mode, StructureMode::New));
    let sender = tab.sender();
    imp.name_entry.connect_changed(move |entry| {
        sender.input(TableInput::TableNameEdited(entry.text().to_string()));
    })
}

/// A read-only connection is offered nothing that writes, as the
/// sidebar's table menu offers no Drop Table on one.
fn toolbar(tab: &StructureTab, mode: StructureMode, read_only: bool) {
    let imp = tab.imp();
    imp.drop_button
        .set_visible(matches!(mode, StructureMode::Edit) && !read_only);
    let on_click = |button: &gtk::Button, msg: fn() -> StructureTabInput| {
        let sender = tab.sender();
        button.connect_clicked(move |_| sender.input(msg()));
    };
    on_click(&imp.save_button, || SaveInput::Save.into());
    on_click(&imp.discard_button, || SaveInput::Discard.into());
    on_click(&imp.drop_button, || TableInput::DropTableRequested.into());
    on_click(&imp.stop_button, || SaveInput::StopSaving.into());
}

/// Without a retry a transient network blip on a remote database would
/// force the user to close the tab and open it again.
fn load_pages(tab: &StructureTab, mode: StructureMode) -> StaleBanner {
    let imp = tab.imp();
    imp.inner_stack.set_visible_child_name(match mode {
        StructureMode::New => "editor",
        StructureMode::Edit => "loading",
    });
    let sender = tab.sender();
    imp.retry_button
        .connect_clicked(move |_| sender.input(LoadInput::Retry));
    let sender = tab.sender();
    StaleBanner::new(imp.stale_banner.get(), move || sender.input(LoadInput::Retry))
}

/// Each list builds a row for an item from the item and the context
/// alone, since the stores change while the tab's model is borrowed.
fn columns_page(tab: &StructureTab, context: &Rc<RefCell<StructureContext>>, columns: &gio::ListStore) {
    let imp = tab.imp();
    let (context, sender) = (context.clone(), tab.sender());
    bind_list(&imp.columns_list, columns, move |column: &DraftColumnObject| {
        build_column_row(column, &context.borrow(), &sender)
    });
    let sender = tab.sender();
    imp.add_column_row
        .connect_activated(move |_| sender.input(ColumnsInput::AddColumn));
    hide_with_add_row(&imp.add_column_row, &imp.add_column_list);
}

/// The dialog takes the draft as it is when it opens: its columns, and
/// the names its indexes already take.
fn indexes_page(tab: &StructureTab, context: &Rc<RefCell<StructureContext>>, stores: &DraftStores<'_>) {
    let imp = tab.imp();
    let (context, sender) = (context.clone(), tab.sender());
    bind_list(&imp.indexes_list, stores.indexes, move |index: &IndexObject| {
        let context = context.borrow();
        let removable = context.table_permission(context.capabilities().drop_index);
        build_index_row(index, &removable, &sender)
    });
    let (columns, indexes, sender) = (stores.columns.downgrade(), stores.indexes.downgrade(), tab.sender());
    imp.add_index_row.connect_activated(move |row| {
        let (Some(columns), Some(indexes)) = (columns.upgrade(), indexes.upgrade()) else {
            return;
        };
        let existing = items::<IndexObject>(&indexes)
            .iter()
            .map(|index| index.info().name.clone())
            .collect();
        let sender = sender.clone();
        IndexDialog::new(column_names(&columns), existing, move |index| {
            sender.input(IndexesInput::AddIndex(index));
        })
        .present(row.upcast_ref());
    });
    hide_with_add_row(&imp.add_index_row, &imp.add_index_list);
}

/// The dialog takes the draft as it is when it opens: its columns, and
/// the names its foreign keys already take. `schema` is the table's,
/// which a foreign key may have to reference within.
fn foreign_keys_page(
    tab: &StructureTab,
    context: &Rc<RefCell<StructureContext>>,
    stores: &DraftStores<'_>,
    schema: Option<String>,
    session: &Arc<Session>,
    tasks: &Tasks,
) {
    let imp = tab.imp();
    let (context_for_keys, sender) = (context.clone(), tab.sender());
    bind_list(&imp.fks_list, stores.foreign_keys, move |key: &ForeignKeyObject| {
        let context = context_for_keys.borrow();
        let removable = context.table_permission(context.capabilities().drop_foreign_key);
        let drafted = context
            .original()
            .is_none_or(|definition| !definition.foreign_keys.contains(key.info()));
        build_fk_row(key, &removable, drafted, &sender)
    });
    let (columns, keys, context, sender) = (
        stores.columns.downgrade(),
        stores.foreign_keys.downgrade(),
        context.clone(),
        tab.sender(),
    );
    let (session, tasks) = (session.clone(), tasks.clone());
    imp.add_fk_row.connect_activated(move |row| {
        let engine = context
            .borrow()
            .ddl()
            .map(|ddl| (ddl.referential_actions(), reference_scope(ddl, schema.as_deref())));
        let (Some(columns), Some(keys), Some((actions, scope))) = (columns.upgrade(), keys.upgrade(), engine) else {
            return;
        };
        let init = ForeignKeyDialogInit {
            columns: column_names(&columns),
            existing: items::<ForeignKeyObject>(&keys)
                .iter()
                .map(|key| key.info().name.clone())
                .collect(),
            actions,
            scope,
            session: session.clone(),
            tasks: tasks.clone(),
        };
        let sender = sender.clone();
        ForeignKeyDialog::new(init, move |key| sender.input(ForeignKeysInput::AddForeignKey(key)))
            .present(row.upcast_ref());
    });
    hide_with_add_row(&imp.add_fk_row, &imp.add_fk_list);
}

/// An add row that is hidden would leave its list's frame behind.
fn hide_with_add_row(row: &adw::ButtonRow, list: &gtk::ListBox) {
    row.bind_property("visible", list, "visible").sync_create().build();
}

/// Show `store` in `list`, a row for each item built by `build`. An empty
/// boxed list would still draw its frame, so the list hides while the
/// store is empty.
fn bind_list<T, W>(list: &gtk::ListBox, store: &gio::ListStore, build: impl Fn(&T) -> W + 'static)
where
    T: IsA<glib::Object>,
    W: IsA<gtk::Widget>,
{
    store
        .bind_property("n-items", list, "visible")
        .transform_to(|_, items: u32| Some(items > 0))
        .sync_create()
        .build();
    list.bind_model(Some(store), move |item| match item.downcast_ref::<T>() {
        Some(item) => build(item).upcast(),
        // The store takes only `T`.
        None => gtk::ListBoxRow::new().upcast(),
    });
}

fn column_names(store: &gio::ListStore) -> Vec<String> {
    items::<DraftColumnObject>(store)
        .iter()
        .map(DraftColumnObject::name)
        .collect()
}
