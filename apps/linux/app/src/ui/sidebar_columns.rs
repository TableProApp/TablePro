use std::sync::Arc;

use relm4::factory::FactorySender;
use relm4::gtk;
use relm4::gtk::prelude::*;
use tablepro_core::{ColumnInfo, TableInfo};
use tokio::sync::{OwnedSemaphorePermit, Semaphore};
use tokio_util::sync::CancellationToken;

use super::sidebar_row::{SidebarRow, SidebarRowMsg};
use crate::services::catalog::CatalogOrigin;
use crate::services::database_service::DatabaseService;

const TABLE_FIELDS: usize = 256;
const VISIBLE_FIELDS: usize = 2048;

#[derive(Clone)]
pub struct ColumnSource {
    origin: CatalogOrigin,
    database: Arc<DatabaseService>,
    timeout_secs: u32,
    loading: Arc<Semaphore>,
    visible: Arc<Semaphore>,
}

impl std::fmt::Debug for ColumnSource {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("ColumnSource")
    }
}

impl ColumnSource {
    pub(crate) fn capture(id: Option<uuid::Uuid>, database: Arc<DatabaseService>, timeout_secs: u32) -> Option<Self> {
        Some(Self {
            origin: CatalogOrigin::capture(id, &database)?,
            database,
            timeout_secs,
            loading: Arc::new(Semaphore::new(4)),
            visible: Arc::new(Semaphore::new(VISIBLE_FIELDS)),
        })
    }

    async fn fetch(&self, info: TableInfo, serial: u64, cancel: CancellationToken) -> ColumnReply {
        let result = self.load(&info, cancel).await;
        ColumnReply { serial, result }
    }

    async fn load(&self, info: &TableInfo, cancel: CancellationToken) -> Result<LoadedColumns, String> {
        let _loading = self
            .loading
            .clone()
            .try_acquire_owned()
            .map_err(|_| crate::tr!("Other fields are loading. Collapse and expand to retry."))?;
        let connection = self
            .origin
            .connection(&self.database)
            .ok_or_else(|| crate::tr!("The connection changed. Reopen the tables sidebar."))?;
        let control = crate::services::operation_control::bounded_with(self.timeout_secs, cancel);
        let columns = connection
            .fetch_columns_controlled(info.schema.as_deref(), &info.name, &control)
            .await
            .map_err(|error| crate::services::error_text::driver_message(&error))?;
        tablepro_core::check_pre_dispatch(&control)
            .map_err(|error| crate::services::error_text::driver_message(&error))?;
        LoadedColumns::retain(columns, &self.visible)
    }
}

pub struct ColumnReply {
    serial: u64,
    result: Result<LoadedColumns, String>,
}

impl std::fmt::Debug for ColumnReply {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("ColumnReply")
            .field("serial", &self.serial)
            .field("succeeded", &self.result.is_ok())
            .finish()
    }
}

struct LoadedColumns {
    columns: Vec<FieldPreview>,
    truncated: bool,
    retained: OwnedSemaphorePermit,
}

struct FieldPreview {
    name: String,
    data_type: String,
    primary_key: bool,
}

impl FieldPreview {
    fn of(column: ColumnInfo) -> Self {
        Self {
            name: bounded(&column.name, 512),
            data_type: bounded(&column.data_type, 512),
            primary_key: column.primary_key,
        }
    }
}

impl LoadedColumns {
    fn retain(columns: Vec<ColumnInfo>, visible: &Arc<Semaphore>) -> Result<Self, String> {
        let truncated = columns.len() > TABLE_FIELDS;
        let columns: Vec<FieldPreview> = columns.into_iter().take(TABLE_FIELDS).map(FieldPreview::of).collect();
        let retained = visible
            .clone()
            .try_acquire_many_owned(columns.len() as u32)
            .map_err(|_| crate::tr!("Close another expanded table to show more fields."))?;
        Ok(Self {
            columns,
            truncated,
            retained,
        })
    }
}

pub(super) struct SidebarColumns {
    source: Option<ColumnSource>,
    toggle: gtk::ToggleButton,
    reveal: gtk::Revealer,
    content: gtk::Box,
    structure: gtk::Button,
    cancel: CancellationToken,
    serial: u64,
    retained: Option<OwnedSemaphorePermit>,
}

impl std::fmt::Debug for SidebarColumns {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("SidebarColumns")
    }
}

impl SidebarColumns {
    pub(super) fn new(source: Option<ColumnSource>) -> Self {
        let content = gtk::Box::builder()
            .orientation(gtk::Orientation::Vertical)
            .spacing(4)
            .margin_start(26)
            .margin_bottom(8)
            .build();
        Self {
            source,
            structure: gtk::Button::builder()
                .label(crate::tr!("Structure…"))
                .action_name("sidebar-row.edit-structure")
                .css_classes(["flat"])
                .build(),
            toggle: gtk::ToggleButton::builder()
                .icon_name("pan-end-symbolic")
                .tooltip_text(crate::tr!("Show columns"))
                .css_classes(["flat"])
                .build(),
            reveal: gtk::Revealer::builder().child(&content).build(),
            content,
            cancel: CancellationToken::new(),
            serial: 0,
            retained: None,
        }
    }

    pub(super) fn install(&self, row: &gtk::ListBoxRow, sender: &FactorySender<SidebarRow>) {
        let Some(header) = row.child().and_downcast::<gtk::Box>() else {
            return;
        };
        row.set_child(gtk::Widget::NONE);
        let body = gtk::Box::new(gtk::Orientation::Vertical, 0);
        header.prepend(&self.toggle);
        body.append(&header);
        body.append(&self.reveal);
        row.set_child(Some(&body));
        let sender = sender.clone();
        self.toggle
            .connect_toggled(move |button| sender.input(SidebarRowMsg::ToggleColumns(button.is_active())));
    }

    pub(super) fn toggle(&mut self, active: bool, info: &TableInfo, sender: FactorySender<SidebarRow>) {
        self.cancel.cancel();
        self.cancel = CancellationToken::new();
        self.serial = self.serial.wrapping_add(1);
        self.retained = None;
        clear(&self.content);
        self.reveal.set_reveal_child(active);
        self.toggle.set_icon_name(if active {
            "pan-down-symbolic"
        } else {
            "pan-end-symbolic"
        });
        self.toggle.set_tooltip_text(Some(&if active {
            crate::tr!("Hide columns")
        } else {
            crate::tr!("Show columns")
        }));
        if !active {
            return;
        }
        let Some(source) = self.source.clone() else {
            return self.message(&crate::tr!("Connect to load the fields of this table."));
        };
        self.message(&crate::tr!("Loading fields…"));
        let (info, serial, cancel) = (info.clone(), self.serial, self.cancel.clone());
        sender.command(move |_, shutdown| {
            shutdown
                .register(async move { source.fetch(info, serial, cancel).await })
                .drop_on_shutdown()
        });
    }

    pub(super) fn apply(&mut self, reply: ColumnReply) {
        if !self.accepts(reply.serial) {
            return;
        }
        clear(&self.content);
        if self
            .source
            .as_ref()
            .is_none_or(|source| source.origin.connection(&source.database).is_none())
        {
            return self.message(&crate::tr!("The connection changed. Reopen the tables sidebar."));
        }
        let loaded = match reply.result {
            Ok(loaded) => loaded,
            Err(message) => return self.message(&message),
        };
        self.retained = Some(loaded.retained);
        if loaded.columns.is_empty() {
            self.message(&crate::tr!("No fields were returned."));
        }
        for column in &loaded.columns {
            self.content.append(&field_row(column));
        }
        if loaded.truncated {
            self.message(&crate::tr!("Showing the first 256 fields. Open Structure for more."));
        }
        self.content.append(&self.structure);
    }

    fn accepts(&self, serial: u64) -> bool {
        serial == self.serial && self.toggle.is_active()
    }

    pub(super) fn close(&self) {
        self.cancel.cancel();
    }

    fn message(&self, text: &str) {
        let label = gtk::Label::builder()
            .label(bounded(text, 512))
            .wrap(true)
            .xalign(0.0)
            .css_classes(["dim-label", "caption"])
            .build();
        self.content.append(&label);
    }
}

fn bounded(text: &str, limit: usize) -> String {
    let mut result: String = text.chars().take(limit).collect();
    if text.chars().nth(limit).is_some() {
        result.push('…');
    }
    result
}

fn field_row(column: &FieldPreview) -> gtk::Box {
    let row = gtk::Box::new(gtk::Orientation::Horizontal, 6);
    if column.primary_key {
        row.append(&gtk::Image::from_icon_name("dialog-password-symbolic"));
    }
    let name = gtk::Label::builder()
        .label(bounded(&column.name, 256))
        .xalign(0.0)
        .hexpand(true)
        .ellipsize(gtk::pango::EllipsizeMode::End)
        .build();
    let data_type = gtk::Label::builder()
        .label(bounded(&column.data_type, 256))
        .max_width_chars(18)
        .xalign(1.0)
        .ellipsize(gtk::pango::EllipsizeMode::End)
        .css_classes(["dim-label", "caption"])
        .build();
    row.set_tooltip_text(Some(&format!(
        "{}: {}",
        bounded(&column.name, 512),
        bounded(&column.data_type, 512)
    )));
    row.append(&name);
    row.append(&data_type);
    row
}

fn clear(content: &gtk::Box) {
    while let Some(child) = content.first_child() {
        content.remove(&child);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn column() -> ColumnInfo {
        ColumnInfo {
            name: "東京 / : %".into(),
            data_type: "public.MixedCaseType".into(),
            nullable: true,
            primary_key: true,
            is_auto_increment: false,
            is_generated: false,
            default_value: None,
            comment: None,
            collation: None,
            enum_type: None,
            domain_type: None,
        }
    }

    #[test]
    fn expanded_tables_share_a_released_field_budget_and_report_truncation() {
        let visible = Arc::new(Semaphore::new(VISIBLE_FIELDS));
        let mut retained = Vec::new();
        for _ in 0..8 {
            let loaded = LoadedColumns::retain(vec![column(); 300], &visible).unwrap();
            assert_eq!(loaded.columns.len(), 256);
            assert!(loaded.truncated);
            retained.push(loaded);
        }
        assert!(LoadedColumns::retain(vec![column()], &visible).is_err());
        retained.pop();
        assert!(LoadedColumns::retain(vec![column(); 256], &visible).is_ok());
        drop(retained);
        assert_eq!(visible.available_permits(), VISIBLE_FIELDS);
    }

    #[test]
    #[ignore = "requires an isolated GTK display"]
    fn a_stale_column_reply_cannot_replace_newer_fields_or_retain_its_budget() {
        gtk::init().unwrap();
        let mut columns = SidebarColumns::new(None);
        columns.serial = 2;
        columns.toggle.set_active(true);
        columns.message("newer request");
        let budget = Arc::new(Semaphore::new(VISIBLE_FIELDS));
        let loaded = LoadedColumns::retain(vec![column()], &budget).unwrap();
        assert_eq!(budget.available_permits(), VISIBLE_FIELDS - 1);
        columns.apply(ColumnReply {
            serial: 1,
            result: Ok(loaded),
        });
        assert_eq!(budget.available_permits(), VISIBLE_FIELDS);
        assert_eq!(
            columns
                .content
                .first_child()
                .and_downcast::<gtk::Label>()
                .unwrap()
                .label(),
            "newer request"
        );
        let field = field_row(&FieldPreview::of(column()));
        assert!(field.tooltip_text().unwrap().contains("public.MixedCaseType"));
        columns.close();
        assert!(columns.cancel.is_cancelled());
    }
}

#[cfg(test)]
mod structure_action_tests {
    use super::*;

    #[test]
    #[ignore = "requires an isolated GTK display"]
    fn the_structure_shortcut_activates_the_owning_row_action() {
        gtk::init().unwrap();
        let columns = SidebarColumns::new(None);
        let root = gtk::Box::new(gtk::Orientation::Vertical, 0);
        let actions = gtk::gio::SimpleActionGroup::new();
        let action = gtk::gio::SimpleAction::new("edit-structure", None);
        let calls = std::rc::Rc::new(std::cell::Cell::new(0));
        let observed = calls.clone();
        action.connect_activate(move |_, _| observed.set(observed.get() + 1));
        actions.add_action(&action);
        root.insert_action_group("sidebar-row", Some(&actions));
        root.append(&columns.structure);
        columns.structure.emit_clicked();
        assert_eq!(calls.get(), 1);
    }
}
