use std::cell::RefCell;
use std::rc::Rc;
use std::sync::Arc;
use std::time::Duration;

use gtk4::subclass::prelude::ObjectSubclassIsExt;
use libadwaita::prelude::{
    ActionRowExt, AdwDialogExt, AdwWindowExt, AlertDialogExt, ComboRowExt, ExpanderRowExt, PreferencesRowExt,
};
use tablepro_core::column::{ColumnDefault, ColumnType};
use tablepro_core::ddl::{
    CharacterSet, CollationName, ColumnAttributes, ColumnDefinition, ColumnKeyRoles, DraftColumn, DraftTableOptions,
    IdentityStyle, InboundForeignKey, PrimaryKeyConstraint, TableDefinition, TableDraft, TableOptions, TableSource,
    UnmodeledAttribute,
};
use tablepro_core::dialect::SqlDialect;
use tablepro_core::meta::{ObjectInfo, ObjectKind, TableRef};
use tablepro_core::{ColumnInfo, DriverError, LossPhase, ServerInfo};
use tablepro_session::fakes::FakeEstablish;
use tablepro_test_support::{CallCounters, ConnectionScript, FakeReply};

use super::*;
use crate::test_support::{
    FakeSession, OwnedWindow, descendants, drain_main_context, first_descendant_of_type, wait_until,
};

const WAIT: Duration = Duration::from_secs(10);

struct Harness {
    tab: Option<StructureTab>,
    fake: FakeSession,
    runtime: Option<crate::runtime::AppRuntime>,
}

impl Harness {
    fn open(
        mode: StructureMode,
        script: ConnectionScript,
        reconnects: impl IntoIterator<Item = FakeEstablish>,
    ) -> Self {
        adw::init().expect("libadwaita initialises under the test backend");
        crate::register_test_resources();
        let runtime = crate::test_support::test_runtime();
        let fake = FakeSession::start(script, reconnects, runtime.tasks());
        let tab = StructureTab::new(StructureTabInit {
            tracker: StructureTrackerHandle::default(),
            schema: None,
            table: "users".to_owned(),
            mode,
            session: fake.session.clone(),
            tasks: runtime.tasks(),
            first_load: crate::ui::tab_load::FirstLoad::Now,
        });
        Self {
            tab: Some(tab),
            fake,
            runtime: Some(runtime),
        }
    }

    fn tab(&self) -> &StructureTab {
        self.tab.as_ref().expect("the tab is open")
    }

    fn page(&self) -> Option<String> {
        self.tab()
            .imp()
            .inner_stack
            .visible_child_name()
            .map(|name| name.to_string())
    }

    fn draft(&self) -> TableDraft {
        draft(self.tab())
    }

    fn column_names(&self) -> Vec<String> {
        self.draft().columns.into_iter().map(|column| column.name).collect()
    }

    fn comments(&self) -> Vec<Option<String>> {
        self.draft().columns.into_iter().map(|column| column.comment).collect()
    }

    fn column(&self, position: u32) -> DraftColumnObject {
        column_object(self.tab(), position)
    }

    fn tracker(&self) -> StructureTrackerHandle {
        self.tab()
            .imp()
            .model
            .borrow()
            .as_ref()
            .map(|model| model.tracker.clone())
            .expect("the tab has a model")
    }

    /// The structure on screen with the server's character sets read, so
    /// a row held across an edit is not built again under it.
    fn wait_for_structure(&self) {
        wait_until(WAIT, || self.page().as_deref() == Some("editor")).expect("the structure");
        wait_until(WAIT, || {
            self.tab()
                .imp()
                .model
                .borrow()
                .as_ref()
                .is_some_and(|model| !model.sequencer.is_pending(StructureRequestKind::CharacterSets))
        })
        .expect("the character sets were read");
        drain_main_context();
    }
}

impl Drop for Harness {
    fn drop(&mut self) {
        self.tab.take();
        drain_main_context();
        if let Some(runtime) = self.runtime.take() {
            runtime.shutdown();
        }
    }
}

fn draft(tab: &StructureTab) -> TableDraft {
    tab.imp()
        .model
        .borrow()
        .as_ref()
        .map(StructureModel::draft)
        .expect("the tab has a model")
}

fn column_object(tab: &StructureTab, position: u32) -> DraftColumnObject {
    tab.imp()
        .model
        .borrow()
        .as_ref()
        .and_then(|model| model.columns.item(position))
        .and_downcast()
        .expect("a column at that position")
}

fn postgres() -> Arc<dyn SqlDialect> {
    Arc::new(tablepro_driver_postgres::PgDialect::new(&ServerInfo::new(
        "PostgreSQL",
        "18.0",
        18,
        0,
        0,
    )))
}

/// A script whose connection speaks PostgreSQL, so the tab has a DDL
/// dialect to plan with.
fn postgres_script() -> ConnectionScript {
    ConnectionScript {
        dialect: postgres(),
        ..ConnectionScript::default()
    }
}

fn definition(column: &str) -> TableDefinition {
    TableDefinition {
        table: TableRef::unqualified("users"),
        columns: vec![ColumnDefinition::new(
            ColumnInfo {
                name: column.to_owned(),
                column_type: ColumnType::untyped_text("text"),
                nullable: true,
                primary_key: false,
                is_auto_increment: false,
                is_generated: false,
                partition_scoped: false,
                default: ColumnDefault::None,
                comment: None,
            },
            ColumnAttributes::default(),
        )],
        primary_key: None,
        indexes: Vec::new(),
        foreign_keys: Vec::new(),
        inbound_foreign_keys: Vec::new(),
        source: None,
        options: None,
    }
}

fn scheme_id(buffer: &sourceview5::Buffer) -> Option<String> {
    buffer.style_scheme().map(|scheme| scheme.id().to_string())
}

fn sql_buffer(tab: &StructureTab) -> sourceview5::Buffer {
    tab.imp()
        .sql_view
        .buffer()
        .downcast::<sourceview5::Buffer>()
        .expect("a sourceview buffer")
}

#[gtk4::test]
fn style_handler_disconnected_on_shutdown() {
    let style = adw::StyleManager::default();
    style.set_color_scheme(adw::ColorScheme::ForceLight);
    let mut harness = Harness::open(StructureMode::New, ConnectionScript::default(), []);
    let buffer = sql_buffer(harness.tab());
    let light = scheme_id(&buffer);

    harness.tab.take();
    drain_main_context();
    style.set_color_scheme(adw::ColorScheme::ForceDark);
    let after = scheme_id(&buffer);
    style.set_color_scheme(adw::ColorScheme::Default);

    assert_eq!(after, light, "a closed structure tab still follows the theme");
}

#[gtk4::test]
fn structure_tab_freed_after_drop() {
    let mut harness = Harness::open(StructureMode::New, ConnectionScript::default(), []);
    harness.tab().send(ColumnsInput::AddColumn);
    drain_main_context();
    let row = first_descendant_of_type::<adw::ExpanderRow>(harness.tab())
        .expect("the added column's row")
        .downgrade();
    let widgets: Vec<glib::WeakRef<gtk::Widget>> = {
        let imp = harness.tab().imp();
        [
            imp.inner_stack.upcast_ref::<gtk::Widget>(),
            imp.indexes_box.upcast_ref(),
            imp.fks_box.upcast_ref(),
            harness.tab().upcast_ref(),
        ]
        .into_iter()
        .map(ObjectExt::downgrade)
        .collect()
    };

    harness.tab.take();
    drain_main_context();

    assert!(row.upgrade().is_none(), "a column row outlived its tab");
    let alive = widgets.iter().filter(|widget| widget.upgrade().is_some()).count();
    assert_eq!(alive, 0, "parts of the structure tab outlived it");
}

#[gtk4::test]
fn a_draft_takes_its_dialect_from_the_session() {
    let harness = Harness::open(StructureMode::New, postgres_script(), []);
    harness.tab().send(ColumnsInput::AddColumn);
    drain_main_context();

    let buffer = sql_buffer(harness.tab());
    let preview = buffer.text(&buffer.start_iter(), &buffer.end_iter(), false);
    assert!(preview.starts_with("CREATE TABLE"), "{preview}");
}

#[gtk4::test]
fn failed_structure_load_refetches_after_link_replace() {
    let mut first = ConnectionScript::default();
    first
        .fetch_table_definition
        .always(FakeReply::err(DriverError::ConnectionLost {
            during: LossPhase::Statement,
        }));
    let mut second = ConnectionScript::default();
    second.fetch_table_definition.always(FakeReply::ok(definition("email")));
    let harness = Harness::open(StructureMode::Edit, first, [FakeEstablish::Connect(second)]);

    wait_until(WAIT, || harness.page().as_deref() == Some("editor")).expect("the structure after the reconnect");

    assert_eq!(harness.fake.session.link_generation().get(), 1);
    assert_eq!(
        CallCounters::get(&harness.fake.replacement().counters().fetch_table_definition),
        1
    );
    assert_eq!(harness.column_names(), ["email"]);
}

#[gtk4::test]
fn a_loaded_structure_is_not_read_again_on_link_replace() {
    let mut first = ConnectionScript::default();
    first.fetch_table_definition.always(FakeReply::ok(definition("id")));
    let harness = Harness::open(
        StructureMode::Edit,
        first,
        [FakeEstablish::Connect(ConnectionScript::default())],
    );
    wait_until(WAIT, || harness.page().as_deref() == Some("editor")).expect("the structure");

    harness.fake.connection.mark_lost();
    wait_until(WAIT, || harness.fake.session.link_generation().get() == 1).expect("the reconnect");
    std::thread::sleep(Duration::from_millis(200));
    drain_main_context();

    assert_eq!(
        CallCounters::get(&harness.fake.replacement().counters().fetch_table_definition),
        0
    );
    assert_eq!(harness.column_names(), ["id"]);
}

#[gtk4::test]
fn a_schema_change_leaves_a_tab_with_edits_alone() {
    let mut script = ConnectionScript::default();
    script.fetch_table_definition.always(FakeReply::ok(definition("id")));
    let harness = Harness::open(StructureMode::Edit, script, []);
    wait_until(WAIT, || harness.page().as_deref() == Some("editor")).expect("the structure");
    let counters = harness.fake.connection.counters();

    harness.tab().send(ColumnsInput::AddColumn);
    harness.tab().send(LoadInput::SchemaChanged);
    drain_main_context();
    std::thread::sleep(Duration::from_millis(100));
    drain_main_context();

    assert_eq!(CallCounters::get(&counters.fetch_table_definition), 1);
    assert_eq!(harness.column_names(), ["id", "column_1"]);
}

#[gtk4::test]
fn drop_asks_the_window_with_the_table_it_shows() {
    let mut script = ConnectionScript::default();
    script.fetch_table_definition.always(FakeReply::ok(definition("id")));
    let harness = Harness::open(StructureMode::Edit, script, []);
    wait_until(WAIT, || harness.page().as_deref() == Some("editor")).expect("the structure");
    let asked = std::rc::Rc::new(std::cell::RefCell::new(Vec::new()));
    let sink = asked.clone();
    harness
        .tab()
        .connect_drop_table_requested(move |_, schema, table| sink.borrow_mut().push((schema, table)));

    harness.tab().imp().drop_button.emit_clicked();

    assert_eq!(*asked.borrow(), [(None, "users".to_owned())]);
}

/// The driver refuses the DROP on a read-only connection, so the tab
/// does not offer it, as the sidebar's table menu does not.
#[gtk4::test]
fn a_read_only_connection_offers_no_drop() {
    let mut script = ConnectionScript {
        read_only: true,
        ..ConnectionScript::default()
    };
    script.fetch_table_definition.always(FakeReply::ok(definition("id")));
    let harness = Harness::open(StructureMode::Edit, script, []);
    assert!(harness.fake.session.read_only());
    wait_until(WAIT, || harness.page().as_deref() == Some("editor")).expect("the structure");
    let asked = std::rc::Rc::new(std::cell::Cell::new(0));
    let sink = asked.clone();
    harness
        .tab()
        .connect_drop_table_requested(move |_, _, _| sink.set(sink.get() + 1));

    assert!(!harness.tab().imp().drop_button.is_visible());
    harness.tab().send(TableInput::DropTableRequested);
    assert_eq!(asked.get(), 0, "the tab asked to drop the table");
}

fn toasts(tab: &StructureTab) -> std::rc::Rc<std::cell::RefCell<Vec<String>>> {
    let toasts = std::rc::Rc::new(std::cell::RefCell::new(Vec::new()));
    let sink = toasts.clone();
    tab.connect_toast(move |_, text| sink.borrow_mut().push(text));
    toasts
}

#[gtk4::test]
fn copy_sql_puts_the_statement_on_the_clipboard_and_says_so() {
    let harness = Harness::open(StructureMode::New, ConnectionScript::default(), []);
    let toasts = toasts(harness.tab());
    sql_buffer(harness.tab()).set_text("CREATE TABLE users (id int);");

    harness.tab().imp().copy_sql_button.emit_clicked();

    let text = harness
        .tab()
        .clipboard()
        .content()
        .and_then(|content| content.value(String::static_type()).ok())
        .and_then(|value| value.get::<String>().ok());
    assert_eq!(text.as_deref(), Some("CREATE TABLE users (id int);"));
    assert_eq!(*toasts.borrow(), ["Copied to clipboard"]);
}

/// The table reads once, then every read after it fails.
fn readable_once() -> ConnectionScript {
    let mut script = ConnectionScript::default();
    script
        .fetch_table_definition
        .once(FakeReply::ok(definition("id")))
        .always(FakeReply::err(DriverError::server("denied")));
    script
}

fn banner(harness: &Harness) -> adw::Banner {
    harness.tab().imp().stale_banner.get()
}

fn banner_tooltip(harness: &Harness) -> String {
    banner(harness)
        .tooltip_text()
        .map(|text| text.to_string())
        .unwrap_or_default()
}

#[gtk4::test]
fn structure_refresh_failure_keeps_editor_and_shows_banner() {
    let harness = Harness::open(StructureMode::Edit, readable_once(), []);
    wait_until(WAIT, || harness.page().as_deref() == Some("editor")).expect("the structure");
    let toasts = toasts(harness.tab());

    harness.tab().send(LoadInput::SchemaChanged);
    wait_until(WAIT, || banner(&harness).is_revealed()).expect("the failed read was not shown");

    assert_eq!(harness.page().as_deref(), Some("editor"));
    assert_eq!(harness.column_names(), ["id"]);
    assert!(
        banner_tooltip(&harness).contains("denied"),
        "{}",
        banner_tooltip(&harness)
    );
    assert!(toasts.borrow().is_empty(), "{:?}", toasts.borrow());
    assert!(!harness.tab().is_loading());
    assert!(harness.tab().imp().columns_box.is_sensitive());
}

/// The definition on screen is from before the save, so the draft holds
/// still until a read lands: unlocked, its diff would offer the saved
/// changes again.
#[gtk4::test]
fn a_failed_read_after_a_save_keeps_the_saved_draft_locked() {
    let harness = Harness::open(StructureMode::Edit, readable_once(), []);
    wait_until(WAIT, || harness.page().as_deref() == Some("editor")).expect("the structure");

    harness.tab().send(SaveInput::SaveCompleted { new_table_name: None });
    wait_until(WAIT, || banner(&harness).is_revealed()).expect("the failed read was not shown");

    assert_eq!(harness.page().as_deref(), Some("editor"));
    assert!(!harness.tab().imp().columns_box.is_sensitive());
    assert!(
        !harness.tracker().has_pending(),
        "the saved changes came back as pending"
    );
}

/// The save landed, so waiting for it is no help: the edit waits for a
/// read of the table that only Retry starts.
#[gtk4::test]
fn an_edit_after_a_failed_read_after_a_save_says_to_retry() {
    let harness = Harness::open(StructureMode::Edit, readable_once(), []);
    wait_until(WAIT, || harness.page().as_deref() == Some("editor")).expect("the structure");
    harness.tab().send(SaveInput::SaveCompleted { new_table_name: None });
    wait_until(WAIT, || banner(&harness).is_revealed()).expect("the failed read was not shown");
    let toasts = toasts(harness.tab());

    harness.tab().send(ColumnsInput::AddColumn);

    assert_eq!(
        *toasts.borrow(),
        ["The table couldn't be read after the save. Retry, then make the change again."]
    );
    assert_eq!(harness.column_names(), ["id"]);
}

#[gtk4::test]
fn structure_first_load_failure_shows_error_page() {
    let mut script = ConnectionScript::default();
    script
        .fetch_table_definition
        .always(FakeReply::err(DriverError::server("no <such> table")));
    let harness = Harness::open(StructureMode::Edit, script, []);

    wait_until(WAIT, || harness.page().as_deref() == Some("error")).expect("the error page");

    let imp = harness.tab().imp();
    let description = imp
        .error_status
        .description()
        .map(|text| text.to_string())
        .unwrap_or_default();
    assert!(description.contains("no &lt;such&gt; table"), "{description}");
    assert!(imp.retry_button.is_visible());
    assert!(!banner(&harness).is_revealed());
    assert!(!harness.tab().is_loading());
}

#[gtk4::test]
fn index_fetch_failure_keeps_loaded_indexes() {
    let indexed = TableDefinition {
        indexes: vec![tablepro_core::IndexInfo {
            name: "users_id_idx".to_owned(),
            keys: vec![tablepro_core::meta::IndexKey::Column {
                name: "id".to_owned(),
                descending: false,
            }],
            unique: true,
            primary: false,
            predicate: None,
            definition: None,
        }],
        ..definition("id")
    };
    let mut script = ConnectionScript::default();
    script
        .fetch_table_definition
        .once(FakeReply::ok(indexed))
        .always(FakeReply::err(DriverError::server("indexes unreadable")));
    let harness = Harness::open(StructureMode::Edit, script, []);
    wait_until(WAIT, || harness.page().as_deref() == Some("editor")).expect("the structure");

    harness.tab().send(LoadInput::SchemaChanged);
    wait_until(WAIT, || banner(&harness).is_revealed()).expect("the failed read was not shown");

    let indexes: Vec<String> = harness.draft().indexes.into_iter().map(|index| index.name).collect();
    assert_eq!(indexes, ["users_id_idx"]);
    assert_eq!(harness.page().as_deref(), Some("editor"));
}

#[gtk4::test]
fn structure_retry_after_failure_hides_banner() {
    let mut script = ConnectionScript::default();
    script
        .fetch_table_definition
        .once(FakeReply::ok(definition("id")))
        .once(FakeReply::err(DriverError::server("denied")))
        .always(FakeReply::ok(definition("email")));
    let harness = Harness::open(StructureMode::Edit, script, []);
    wait_until(WAIT, || harness.page().as_deref() == Some("editor")).expect("the structure");
    harness.tab().send(LoadInput::SchemaChanged);
    wait_until(WAIT, || banner(&harness).is_revealed()).expect("the stale banner");

    banner(&harness).emit_by_name::<()>("button-clicked", &[]);

    wait_until(WAIT, || harness.column_names() == ["email"]).expect("Retry read the table again");
    assert!(
        !banner(&harness).is_revealed(),
        "the banner outlived the read that landed"
    );
    assert_eq!(
        CallCounters::get(&harness.fake.connection.counters().fetch_table_definition),
        3
    );
}

#[gtk4::test]
fn schema_save_shows_new_column_list() {
    let mut script = ConnectionScript::default();
    script
        .fetch_table_definition
        .once(FakeReply::ok(TableDefinition {
            columns: vec![integer_column("id", true), integer_column("name", false)],
            ..definition("id")
        }))
        .always(FakeReply::ok(TableDefinition {
            columns: vec![
                integer_column("id", true),
                integer_column("name", false),
                integer_column("email", false),
            ],
            ..definition("id")
        }));
    let harness = Harness::open(StructureMode::Edit, script, []);
    wait_until(WAIT, || harness.page().as_deref() == Some("editor")).expect("the structure");
    let loading = Rc::new(RefCell::new(Vec::new()));
    let sink = loading.clone();
    harness
        .tab()
        .connect_loading_changed(move |_, busy| sink.borrow_mut().push(busy));

    harness.tab().send(SaveInput::SaveCompleted { new_table_name: None });

    assert_eq!(
        harness.page().as_deref(),
        Some("editor"),
        "the read after the save blanked the tab"
    );
    wait_until(WAIT, || column_rows(harness.tab()).len() == 3).expect("the columns the save left");
    assert_eq!(harness.column_names(), ["id", "name", "email"]);
    assert_eq!(
        CallCounters::get(&harness.fake.connection.counters().fetch_table_definition),
        2
    );
    assert_eq!(*loading.borrow(), [true, false]);
}

/// The control named `name` in the row the Columns list shows at
/// `position`.
fn column_widget(tab: &StructureTab, position: i32, name: &str) -> gtk::Widget {
    let row = tab
        .imp()
        .columns_list
        .row_at_index(position)
        .unwrap_or_else(|| panic!("no column row at {position}"));
    descendants(&row)
        .into_iter()
        .find(|widget| widget.widget_name() == name)
        .unwrap_or_else(|| panic!("no widget named {name} in row {position}"))
}

fn integer_column(name: &str, primary_key: bool) -> ColumnDefinition {
    let column_type = postgres().parse_type("integer").expect("a PostgreSQL type");
    ColumnDefinition::new(
        ColumnInfo {
            name: name.to_owned(),
            column_type,
            nullable: !primary_key,
            primary_key,
            is_auto_increment: false,
            is_generated: false,
            partition_scoped: false,
            default: ColumnDefault::None,
            comment: None,
        },
        ColumnAttributes::default(),
    )
}

#[gtk4::test]
fn clickhouse_key_column_rename_is_insensitive_with_reason() {
    let clickhouse: Arc<dyn SqlDialect> = Arc::new(tablepro_driver_clickhouse::ClickHouseDialect::new(
        &ServerInfo::new("ClickHouse", "25.8", 25, 8, 0),
    ));
    let mut key = definition("id");
    key.columns[0].info.column_type = clickhouse.parse_type("UInt64").expect("a ClickHouse type");
    key.columns[0].attributes.key_roles = ColumnKeyRoles {
        sorting_key: true,
        partition_key: false,
    };
    let mut label = definition("label").columns.remove(0);
    label.info.column_type = clickhouse.parse_type("String").expect("a ClickHouse type");
    key.columns.push(label);
    let mut script = ConnectionScript {
        dialect: clickhouse,
        ..ConnectionScript::default()
    };
    script.fetch_table_definition.always(FakeReply::ok(key));
    let harness = Harness::open(StructureMode::Edit, script, []);
    wait_until(WAIT, || harness.page().as_deref() == Some("editor")).expect("the structure");
    drain_main_context();

    let key_name = column_widget(harness.tab(), 0, "col-name");
    let plain_name = column_widget(harness.tab(), 1, "col-name");

    assert!(!key_name.is_sensitive(), "a sorting key column could be renamed");
    assert!(
        key_name
            .tooltip_text()
            .is_some_and(|tip| tip.contains("sorting or partition key")),
        "{:?}",
        key_name.tooltip_text()
    );
    assert!(plain_name.is_sensitive());
    assert!(!column_widget(harness.tab(), 0, "col-remove").is_sensitive());
}

#[gtk4::test]
fn referenced_primary_key_switch_is_insensitive_with_foreign_key_names() {
    let users = TableDefinition {
        table: TableRef::unqualified("users"),
        columns: vec![integer_column("id", true), integer_column("score", false)],
        primary_key: Some(PrimaryKeyConstraint {
            name: Some("users_pkey".to_owned()),
            columns: vec!["id".to_owned()],
        }),
        indexes: Vec::new(),
        foreign_keys: Vec::new(),
        inbound_foreign_keys: vec![InboundForeignKey {
            child_compares_alike: true,
            name: "orders_user_fk".to_owned(),
            table: TableRef::unqualified("orders"),
            columns: vec!["user_id".to_owned()],
            referenced_columns: vec!["id".to_owned()],
        }],
        source: None,
        options: None,
    };
    let mut script = postgres_script();
    script.fetch_table_definition.always(FakeReply::ok(users));
    let harness = Harness::open(StructureMode::Edit, script, []);
    wait_until(WAIT, || harness.page().as_deref() == Some("editor")).expect("the structure");
    drain_main_context();

    for position in [0, 1] {
        let switch = column_widget(harness.tab(), position, "col-pk");
        assert!(!switch.is_sensitive(), "column {position} could move a referenced key");
        assert!(
            switch.tooltip_text().is_some_and(|tip| tip.contains("orders_user_fk")),
            "column {position}: {:?}",
            switch.tooltip_text()
        );
    }
    assert!(!column_widget(harness.tab(), 0, "col-remove").is_sensitive());
    assert!(column_widget(harness.tab(), 1, "col-remove").is_sensitive());
}

#[gtk4::test]
fn a_computed_column_takes_no_comment_where_the_comment_restates_it() {
    let mysql: Arc<dyn SqlDialect> = Arc::new(tablepro_driver_mysql::MySqlDialect::new(
        tablepro_driver_mysql::MySqlFlavour::MySql,
        &ServerInfo::new("MySQL", "8.4.3", 8, 4, 3),
    ));
    let mut table = definition("total");
    table.columns[0].info.column_type = mysql.parse_type("int").expect("a MySQL type");
    table.columns[0].info.is_generated = true;
    let mut plain = definition("base").columns.remove(0);
    plain.info.column_type = mysql.parse_type("int").expect("a MySQL type");
    table.columns.push(plain);
    let mut script = ConnectionScript {
        dialect: mysql,
        ..ConnectionScript::default()
    };
    script.fetch_table_definition.always(FakeReply::ok(table));
    let harness = Harness::open(StructureMode::Edit, script, []);
    harness.wait_for_structure();

    let computed = column_widget(harness.tab(), 0, "col-comment");

    assert!(!computed.is_sensitive(), "a generated column's comment could be set");
    assert!(
        computed
            .tooltip_text()
            .is_some_and(|tip| tip.contains("computes this column")),
        "{:?}",
        computed.tooltip_text()
    );
    assert!(column_widget(harness.tab(), 1, "col-comment").is_sensitive());
}

#[gtk4::test]
fn an_edit_previews_the_plan_and_saves_through_the_tracker() {
    let mut script = postgres_script();
    script.fetch_table_definition.always(FakeReply::ok(TableDefinition {
        columns: vec![integer_column("id", true)],
        ..definition("id")
    }));
    let tracker = StructureTrackerHandle::default();
    adw::init().expect("libadwaita initialises under the test backend");
    crate::register_test_resources();
    let runtime = crate::test_support::test_runtime();
    let fake = FakeSession::start(script, [], runtime.tasks());
    let tab = StructureTab::new(StructureTabInit {
        tracker: tracker.clone(),
        schema: None,
        table: "users".to_owned(),
        mode: StructureMode::Edit,
        session: fake.session.clone(),
        tasks: runtime.tasks(),
        first_load: crate::ui::tab_load::FirstLoad::Now,
    });
    wait_until(WAIT, || {
        tab.imp().inner_stack.visible_child_name().as_deref() == Some("editor")
    })
    .expect("the structure");
    let saves = std::rc::Rc::new(std::cell::Cell::new(0));
    let counter = saves.clone();
    tab.connect_save_requested(move |_| counter.set(counter.get() + 1));

    tab.send(ColumnsInput::ColumnEdited {
        column: column_object(&tab, 0),
        field: ColumnField::Default("42".to_owned()),
    });
    let buffer = sql_buffer(&tab);
    let preview = buffer.text(&buffer.start_iter(), &buffer.end_iter(), false).to_string();
    tab.imp().save_button.emit_clicked();

    assert_eq!(preview, "ALTER TABLE \"users\" ALTER COLUMN \"id\" SET DEFAULT 42;");
    assert_eq!(saves.get(), 1);
    let pending = tracker.begin_save().expect("a save").expect("the change is pending");
    assert_eq!(pending.changes.altered_columns.len(), 1);
    tracker.settle_save(&crate::workspace::SaveOutcome::RolledBack(
        crate::workspace::RollbackCause::NotApplied,
    ));

    tab.send(ColumnsInput::ColumnEdited {
        column: column_object(&tab, 0),
        field: ColumnField::Default("1 +".to_owned()),
    });
    assert!(
        !tab.imp().save_button.is_sensitive(),
        "a default that does not parse can be saved"
    );
    // What a close prompt's Save reads.
    assert_eq!(
        tracker.begin_save(),
        Err(crate::workspace::SaveRejection::Blocked(
            crate::services::pending_structure::SaveBlocker::UnparsedDefault("id".to_owned())
        ))
    );
    drop(tab);
    drain_main_context();
    runtime.shutdown();
}

#[gtk4::test]
fn stop_saving_shows_only_while_a_save_runs() {
    let mut script = postgres_script();
    script.fetch_table_definition.always(FakeReply::ok(definition("id")));
    let harness = Harness::open(StructureMode::Edit, script, []);
    wait_until(WAIT, || harness.page().as_deref() == Some("editor")).expect("the structure");
    let stops = std::rc::Rc::new(std::cell::Cell::new(0));
    let stop_sink = stops.clone();
    harness
        .tab()
        .connect_stop_save_requested(move |_| stop_sink.set(stop_sink.get() + 1));
    harness.tab().send(ColumnsInput::ColumnEdited {
        column: harness.column(0),
        field: ColumnField::Comment(Some("key".to_owned())),
    });
    let imp = harness.tab().imp();
    let (stop, save) = (imp.stop_button.get(), imp.save_button.get());
    assert!(!stop.is_visible());
    assert!(save.is_sensitive());

    harness.tab().send(SaveInput::SaveStarted);
    assert!(stop.is_visible() && imp.saving_spinner.is_visible());
    assert!(
        !imp.columns_box.is_sensitive(),
        "the columns stayed editable during the save"
    );
    let toasts = toasts(harness.tab());
    harness.tab().send(ColumnsInput::ColumnEdited {
        column: harness.column(0),
        field: ColumnField::Comment(Some("the key".to_owned())),
    });
    assert_eq!(
        harness.comments(),
        [Some("key".to_owned())],
        "an edit got into a saving draft"
    );
    assert_eq!(toasts.borrow().len(), 1, "a refused edit said nothing");
    assert!(!save.is_sensitive(), "an edit during the save turned Save back on");
    stop.emit_clicked();
    assert_eq!(stops.get(), 1);

    harness.tab().send(SaveInput::SaveFailed("rolled back".to_owned()));
    assert!(!stop.is_visible() && !imp.saving_spinner.is_visible());
    assert!(save.is_sensitive() && imp.columns_box.is_sensitive());
}

/// The read after a commit replaces the draft, so the draft takes no
/// edit from the moment the save takes it until that read lands: one
/// made in between would be lost, and a close waiting on the save would
/// find nothing to ask about.
#[gtk4::test]
fn an_edit_waits_for_the_read_after_a_committed_save() {
    let mut script = postgres_script();
    script.fetch_table_definition.always(FakeReply::ok(TableDefinition {
        columns: vec![integer_column("id", true)],
        ..definition("id")
    }));
    let harness = Harness::open(StructureMode::Edit, script, []);
    wait_until(WAIT, || harness.page().as_deref() == Some("editor")).expect("the structure");
    let counters = harness.fake.connection.counters();
    let tracker = harness.tracker();
    let imp = harness.tab().imp();
    harness.tab().send(ColumnsInput::ColumnEdited {
        column: harness.column(0),
        field: ColumnField::Comment(Some("key".to_owned())),
    });

    let _saving = tracker.begin_save().expect("a save").expect("the change is pending");
    harness.tab().send(ColumnsInput::ColumnEdited {
        column: harness.column(0),
        field: ColumnField::Comment(Some("before the tab heard".to_owned())),
    });
    harness.tab().send(SaveInput::SaveStarted);
    tracker.settle_save(&crate::workspace::SaveOutcome::Committed { rows: None });
    harness.tab().send(ColumnsInput::AddColumn);
    harness.tab().send(SaveInput::SaveCompleted { new_table_name: None });
    harness.tab().send(ColumnsInput::AddColumn);

    assert_eq!(harness.comments(), [Some("key".to_owned())]);
    assert_eq!(harness.column_names(), ["id"]);
    assert!(!imp.columns_box.is_sensitive());
    wait_until(WAIT, || {
        CallCounters::get(&counters.fetch_table_definition) == 2 && imp.columns_box.is_sensitive()
    })
    .expect("the read after the save");
    harness.tab().send(ColumnsInput::AddColumn);
    assert_eq!(harness.column_names(), ["id", "column_1"]);
}

/// `id` keyed by `users_pkey`, and a nullable `score`.
fn keyed_users() -> TableDefinition {
    TableDefinition {
        columns: vec![integer_column("id", true), integer_column("score", false)],
        primary_key: Some(PrimaryKeyConstraint {
            name: Some("users_pkey".to_owned()),
            columns: vec!["id".to_owned()],
        }),
        ..definition("id")
    }
}

fn preview(tab: &StructureTab) -> String {
    let buffer = sql_buffer(tab);
    buffer.text(&buffer.start_iter(), &buffer.end_iter(), false).to_string()
}

/// The preview is text a reader can move through, so it takes a name.
#[gtk4::test]
fn the_sql_preview_is_named() {
    let mut script = postgres_script();
    script.fetch_table_definition.always(FakeReply::ok(keyed_users()));
    let harness = Harness::open(StructureMode::Edit, script, []);

    assert_eq!(
        crate::test_support::assert_labelled(&harness.tab().imp().sql_view.get()),
        Ok(())
    );
}

#[gtk4::test]
fn renaming_existing_column_enables_save_and_previews_rename() {
    let mut script = postgres_script();
    script.fetch_table_definition.always(FakeReply::ok(keyed_users()));
    let harness = Harness::open(StructureMode::Edit, script, []);
    wait_until(WAIT, || harness.page().as_deref() == Some("editor")).expect("the structure");
    drain_main_context();
    let imp = harness.tab().imp();
    assert!(!imp.save_button.is_sensitive());

    let name = column_widget(harness.tab(), 1, "col-name")
        .downcast::<adw::EntryRow>()
        .expect("the Name entry");
    assert!(name.is_sensitive(), "an existing column's name could not be edited");
    name.set_text("points");
    drain_main_context();

    assert_eq!(harness.column_names(), ["id", "points"]);
    assert!(imp.save_button.is_sensitive(), "a rename left Save off");
    assert_eq!(imp.pending_label.label(), "1 unsaved change");
    assert_eq!(
        crate::ui::a11y::announced_in(&imp.pending_label.get()),
        [(
            "1 unsaved change".to_owned(),
            gtk4::AccessibleAnnouncementPriority::Medium
        )]
    );
    assert_eq!(
        preview(harness.tab()),
        "ALTER TABLE \"users\" RENAME COLUMN \"score\" TO \"points\";"
    );
}

fn switch_row(tab: &StructureTab, position: i32, name: &str) -> adw::SwitchRow {
    column_widget(tab, position, name)
        .downcast::<adw::SwitchRow>()
        .expect("a switch row")
}

impl Harness {
    fn draft_column(&self, index: usize) -> DraftColumn {
        self.draft().columns[index].clone()
    }
}

fn open_edit(dialect: Arc<dyn SqlDialect>, table: TableDefinition) -> Harness {
    let mut script = ConnectionScript {
        dialect,
        ..ConnectionScript::default()
    };
    script.fetch_table_definition.always(FakeReply::ok(table));
    let harness = Harness::open(StructureMode::Edit, script, []);
    harness.wait_for_structure();
    harness
}

#[gtk4::test]
fn the_primary_key_holds_a_column_not_null_until_it_leaves() {
    let harness = open_edit(postgres(), keyed_users());
    let tab = harness.tab();
    let (key, nullable) = (switch_row(tab, 1, "col-pk"), switch_row(tab, 1, "col-nullable"));
    assert!(
        !switch_row(tab, 0, "col-nullable").is_sensitive(),
        "a key column could take NULL"
    );
    assert!(nullable.is_sensitive() && nullable.is_active());

    key.set_active(true);
    drain_main_context();

    assert!(!nullable.is_active() && !nullable.is_sensitive());
    assert!(nullable.tooltip_text().is_some_and(|tip| tip.contains("NULL")));
    assert!(harness.draft_column(1).primary_key && !harness.draft_column(1).nullable);
    assert_eq!(
        preview(tab),
        "ALTER TABLE \"users\" DROP CONSTRAINT \"users_pkey\", ALTER COLUMN \"score\" SET NOT NULL, ADD PRIMARY KEY \
         (\"id\", \"score\");"
    );

    key.set_active(false);
    drain_main_context();

    assert!(nullable.is_sensitive() && nullable.is_active());
    assert!(nullable.tooltip_text().is_none());
    assert!(!harness.draft_column(1).primary_key && harness.draft_column(1).nullable);
    assert_eq!(preview(tab), "-- No pending changes.");
}

/// The Nullable switch shows what the draft holds, so a column whose
/// nullability cannot be restated stays nullable in the key, and the
/// preview says what holds the save.
#[gtk4::test]
fn a_held_nullable_column_joins_the_key_as_it_is() {
    let mut table = keyed_users();
    table.columns[1].attributes.unmodeled = vec![UnmodeledAttribute::new("STORAGE EXTERNAL")];
    let harness = open_edit(postgres(), table);
    let tab = harness.tab();
    let nullable = switch_row(tab, 1, "col-nullable");
    assert!(!nullable.is_sensitive());

    switch_row(tab, 1, "col-pk").set_active(true);
    drain_main_context();

    assert!(nullable.is_active());
    assert!(
        nullable
            .tooltip_text()
            .is_some_and(|tip| tip.contains("STORAGE EXTERNAL"))
    );
    assert!(harness.draft_column(1).primary_key && harness.draft_column(1).nullable);
    assert_eq!(preview(tab), "-- Primary key columns must be NOT NULL: score");
}

#[gtk4::test]
fn a_postgres_identity_keeps_numbering_outside_the_key() {
    let mut table = keyed_users();
    table.columns[0].info.is_auto_increment = true;
    table.columns[0].attributes.identity = IdentityStyle::GeneratedAlways;
    let harness = open_edit(postgres(), table);
    let tab = harness.tab();
    let auto = switch_row(tab, 0, "col-auto");
    assert!(
        switch_row(tab, 1, "col-auto").is_sensitive(),
        "a column outside the key could not number itself"
    );

    switch_row(tab, 0, "col-pk").set_active(false);
    drain_main_context();

    assert!(auto.is_active() && auto.is_sensitive());
    assert!(harness.draft_column(0).auto_increment && !harness.draft_column(0).primary_key);
    assert_eq!(preview(tab), "ALTER TABLE \"users\" DROP CONSTRAINT \"users_pkey\";");
}

#[gtk4::test]
fn a_mysql_column_stops_numbering_as_it_leaves_the_key() {
    let mysql: Arc<dyn SqlDialect> = Arc::new(tablepro_driver_mysql::MySqlDialect::new(
        tablepro_driver_mysql::MySqlFlavour::MySql,
        &ServerInfo::new("MySQL", "8.4.3", 8, 4, 3),
    ));
    let mut table = keyed_users();
    for column in &mut table.columns {
        column.info.column_type = mysql.parse_type("int").expect("a MySQL type");
    }
    table.columns[0].info.is_auto_increment = true;
    let harness = open_edit(mysql, table);
    let tab = harness.tab();
    let auto = switch_row(tab, 0, "col-auto");
    assert!(auto.is_active());
    assert!(!switch_row(tab, 1, "col-auto").is_sensitive());

    switch_row(tab, 0, "col-pk").set_active(false);
    drain_main_context();

    assert!(!auto.is_active() && !auto.is_sensitive());
    assert!(!harness.draft_column(0).auto_increment);
}

/// Edit the table, let `change` say it changed meanwhile, then Discard,
/// and count the reads of the table.
fn reads_after_discard(change: Option<StructureTabInput>) -> usize {
    let mut script = postgres_script();
    script.fetch_table_definition.always(FakeReply::ok(definition("id")));
    let harness = Harness::open(StructureMode::Edit, script, []);
    wait_until(WAIT, || harness.page().as_deref() == Some("editor")).expect("the structure");
    let counters = harness.fake.connection.counters();
    harness.tab().send(ColumnsInput::AddColumn);
    let read_again = change.is_some();
    if let Some(change) = change {
        harness.tab().send(change);
    }

    harness.tab().send(SaveInput::Discard);

    if read_again {
        wait_until(WAIT, || CallCounters::get(&counters.fetch_table_definition) == 2)
            .expect("Discard restored the definition read before the change");
        wait_until(WAIT, || harness.page().as_deref() == Some("editor")).expect("the structure read again");
    }
    drain_main_context();
    assert_eq!(harness.column_names(), ["id"]);
    CallCounters::get(&counters.fetch_table_definition)
}

#[gtk4::test]
fn a_plain_discard_restores_the_definition_it_read() {
    assert_eq!(reads_after_discard(None), 1);
}

#[gtk4::test]
fn a_discard_after_a_change_elsewhere_reads_the_table_again() {
    assert_eq!(reads_after_discard(Some(LoadInput::SchemaChanged.into())), 2);
}

#[gtk4::test]
fn a_discard_after_a_save_found_the_table_changed_reads_it_again() {
    assert_eq!(reads_after_discard(Some(SaveInput::TableChangedBeforeSave.into())), 2);
}

#[gtk4::test]
fn a_discard_whose_read_fails_leaves_the_discarded_column_out() {
    let mut script = postgres_script();
    script
        .fetch_table_definition
        .once(FakeReply::ok(definition("id")))
        .always(FakeReply::err(DriverError::server("denied")));
    let harness = Harness::open(StructureMode::Edit, script, []);
    wait_until(WAIT, || harness.page().as_deref() == Some("editor")).expect("the structure");
    harness.tab().send(ColumnsInput::AddColumn);
    harness.tab().send(SaveInput::TableChangedBeforeSave);

    harness.tab().send(SaveInput::Discard);

    wait_until(WAIT, || banner(&harness).is_revealed()).expect("the failed read was not shown");
    assert_eq!(harness.column_names(), ["id"]);
}

/// The titles of the add buttons the tab shows under `container`.
fn add_buttons(container: &gtk::Box) -> Vec<String> {
    descendants(container)
        .into_iter()
        .filter_map(|widget| widget.downcast::<adw::ButtonRow>().ok())
        .filter(|row| row.is_visible() && row.parent().is_some_and(|list| list.is_visible()))
        .map(|row| adw::prelude::PreferencesRowExt::title(&row).to_string())
        .collect()
}

/// A SQLite `users (body)` table stored as `create_statement`.
fn sqlite_users(create_statement: &str) -> Vec<String> {
    let sqlite: Arc<dyn SqlDialect> = Arc::new(tablepro_driver_sqlite::SqliteDialect::new(
        tablepro_driver_sqlite::SqliteVersion::new(3, 45, 0),
    ));
    let mut table = definition("body");
    table.source = Some(TableSource {
        create_statement: create_statement.to_owned(),
        dependents: Vec::new(),
    });
    let harness = open_edit(sqlite, table);
    add_buttons(&harness.tab().imp().fks_box)
}

#[gtk4::test]
fn an_unreadable_sqlite_table_offers_no_foreign_key() {
    assert!(sqlite_users("CREATE VIRTUAL TABLE users USING fts5(body)").is_empty());
}

#[gtk4::test]
fn a_readable_sqlite_table_offers_a_foreign_key() {
    assert_eq!(sqlite_users("CREATE TABLE users (body text)"), ["Add Foreign Key…"]);
}

fn column_row(tab: &StructureTab, position: i32) -> adw::ExpanderRow {
    tab.imp()
        .columns_list
        .row_at_index(position)
        .and_downcast()
        .unwrap_or_else(|| panic!("no column row at {position}"))
}

fn column_rows(tab: &StructureTab) -> Vec<gtk::ListBoxRow> {
    let list = &tab.imp().columns_list;
    (0..).map_while(|position| list.row_at_index(position)).collect()
}

fn entry(tab: &StructureTab, position: i32, name: &str) -> adw::EntryRow {
    column_widget(tab, position, name)
        .downcast::<adw::EntryRow>()
        .expect("an entry row")
}

fn columns_store(tab: &StructureTab) -> gio::ListStore {
    tab.imp()
        .model
        .borrow()
        .as_ref()
        .map(|model| model.columns.clone())
        .expect("the tab has a model")
}

/// Rows built after an edit used to hold back every signal until the
/// next idle, so a name typed before then was lost.
#[gtk4::test]
fn table_name_edit_is_not_dropped() {
    let harness = Harness::open(StructureMode::New, postgres_script(), []);
    let tab = harness.tab();
    tab.send(ColumnsInput::AddColumn);

    tab.imp().name_entry.set_text("people");

    assert_eq!(harness.draft().table.name, "people");
    drain_main_context();
    assert_eq!(harness.draft().table.name, "people");
    assert!(preview(tab).contains("\"people\""), "{}", preview(tab));
}

#[gtk4::test]
fn expanded_row_stays_expanded_after_editing_another_column() {
    let harness = open_edit(postgres(), keyed_users());
    let tab = harness.tab();
    let first = column_row(tab, 0);
    first.set_expanded(true);

    tab.send(ColumnsInput::AddColumn);
    entry(tab, 2, "col-name").set_text("points");
    entry(tab, 1, "col-type").set_text("bigint");
    drain_main_context();

    assert_eq!(column_row(tab, 0), first, "the expanded row was built again");
    assert!(first.is_expanded());
    assert_eq!(harness.column_names(), ["id", "score", "points"]);
}

#[gtk4::test]
fn remove_by_identity_after_reorder_removes_right_column() {
    let harness = open_edit(postgres(), keyed_users());
    let tab = harness.tab();
    tab.send(ColumnsInput::AddColumn);
    let store = columns_store(tab);
    let added = store.item(2).expect("the added column");
    store.remove(2);
    store.insert(0, &added);
    drain_main_context();
    assert_eq!(harness.column_names(), ["column_1", "id", "score"]);

    column_widget(tab, 2, "col-remove")
        .downcast::<gtk::Button>()
        .expect("the remove button")
        .emit_clicked();

    assert_eq!(harness.column_names(), ["column_1", "id"]);
    assert_eq!(column_rows(tab).len(), 2);
}

#[gtk4::test]
fn add_column_changes_one_item() {
    let harness = open_edit(postgres(), keyed_users());
    let tab = harness.tab();
    let rows = column_rows(tab);
    let changes = Rc::new(RefCell::new(Vec::new()));
    let sink = changes.clone();
    columns_store(tab).connect_items_changed(move |_, position, removed, added| {
        sink.borrow_mut().push((position, removed, added));
    });

    tab.send(ColumnsInput::AddColumn);

    assert_eq!(*changes.borrow(), [(2, 0, 1)]);
    let after = column_rows(tab);
    assert_eq!(after.len(), 3);
    assert_eq!(after[..2], rows[..], "the rows already there were built again");
    assert_eq!(column_row(tab, 2).title(), "column_1");
}

/// Building the restored rows sets every control, which is no edit, and
/// the rows take the user's next edit at once.
#[gtk4::test]
fn discard_restores_without_phantom_ops() {
    let harness = open_edit(postgres(), keyed_users());
    let window = in_window(&harness);
    let tab = harness.tab();
    let imp = tab.imp();
    let dirty = Rc::new(RefCell::new(Vec::new()));
    let sink = dirty.clone();
    tab.connect_dirty_changed(move |_, value| sink.borrow_mut().push(value));
    entry(tab, 1, "col-name").set_text("points");
    entry(tab, 0, "col-comment").set_text("key");
    tab.send(ColumnsInput::AddColumn);
    assert_eq!(imp.pending_label.label(), "3 unsaved changes");

    imp.discard_button.emit_clicked();
    answer_discard(&window, "discard");

    assert_eq!(harness.column_names(), ["id", "score"]);
    assert_eq!(harness.comments(), [None, None]);
    assert!(!imp.save_button.is_sensitive() && !imp.pending_label.is_visible());
    assert_eq!(preview(tab), "-- No pending changes.");
    assert_eq!(*dirty.borrow(), [true, false]);
    assert_eq!(harness.tracker().begin_save(), Ok(None));

    entry(tab, 1, "col-name").set_text("points");

    assert_eq!(harness.column_names(), ["id", "points"]);
    assert_eq!(imp.pending_label.label(), "1 unsaved change");
}

/// Discard drops the undo history with the changes, so it asks first,
/// as F5 does on a browse tab.
#[gtk4::test]
fn a_discard_not_confirmed_keeps_every_change() {
    let harness = open_edit(postgres(), keyed_users());
    let window = in_window(&harness);
    let imp = harness.tab().imp();
    entry(harness.tab(), 1, "col-name").set_text("points");

    imp.discard_button.emit_clicked();
    answer_discard(&window, "cancel");

    assert_eq!(harness.column_names(), ["id", "points"]);
    assert_eq!(imp.pending_label.label(), "1 unsaved change");
}

/// Answer the alert Discard opens.
fn answer_discard(window: &adw::Window, response: &str) {
    let alert = shown_form(window)
        .downcast::<adw::AlertDialog>()
        .expect("Discard asks before it drops the changes");
    assert_eq!(alert.close_response(), "cancel");
    alert.emit_by_name::<()>("response", &[&response]);
    alert.force_close();
    drain_main_context();
}

#[gtk4::test]
fn subtitle_updates_on_type_edit() {
    let harness = open_edit(postgres(), keyed_users());
    let tab = harness.tab();
    let row = column_row(tab, 1);
    let before = row.subtitle();

    entry(tab, 1, "col-type").set_text("bigint");

    assert_eq!(row.subtitle(), "bigint · nullable", "was {before}");
    assert!(harness.column(1).summary().starts_with("bigint"));
}

/// The header shows a name as typed, never as Pango markup.
#[gtk4::test]
fn a_column_name_with_markup_characters_shows_as_typed() {
    let harness = open_edit(postgres(), keyed_users());
    let tab = harness.tab();

    entry(tab, 1, "col-name").set_text("<b>a & b</b>");

    let shown: Vec<String> = descendants(&column_row(tab, 1))
        .into_iter()
        .filter_map(|widget| widget.downcast::<gtk::Label>().ok())
        .filter(|label| label.is_visible() && label.text() == "<b>a & b</b>")
        .map(|label| label.text().to_string())
        .collect();
    assert_eq!(shown.len(), 1, "the name was not shown as typed");
}

#[gtk4::test]
fn a_default_the_parser_refuses_is_marked_until_it_parses() {
    let harness = open_edit(postgres(), keyed_users());
    let tab = harness.tab();
    let default = entry(tab, 1, "col-default");

    default.set_text("1 +");

    assert!(default.has_css_class("error"));
    assert!(default.tooltip_text().is_some());
    assert!(!tab.imp().save_button.is_sensitive());
    assert_eq!(
        harness
            .column(1)
            .unparsed_default()
            .map(|unparsed| unparsed.text)
            .as_deref(),
        Some("1 +")
    );

    default.set_text("42");

    assert!(!default.has_css_class("error"));
    assert!(default.tooltip_text().is_none());
    assert!(tab.imp().save_button.is_sensitive());
}

/// The tab in a window of its own, which the add rows open their forms
/// on.
fn in_window(harness: &Harness) -> OwnedWindow<adw::Window> {
    let window = super::form_dialog::tests::window();
    window.set_content(Some(harness.tab()));
    window
}

fn shown_form(window: &adw::Window) -> adw::Dialog {
    let mut shown = None;
    wait_until(WAIT, || {
        shown = window.visible_dialog();
        shown.is_some()
    })
    .expect("the form");
    shown.expect("the form")
}

fn rows_titled<T: IsA<adw::PreferencesRow> + IsA<gtk::Widget>>(form: &adw::Dialog, title: &str) -> Option<T> {
    descendants(form)
        .into_iter()
        .filter_map(|widget| widget.downcast::<T>().ok())
        .find(|row| row.title() == title)
}

/// The tab keeps nothing of a form it opens, so a form that does not
/// keep its own state stops answering here.
#[gtk4::test]
fn add_index_from_the_tab_adds_the_index() {
    let harness = open_edit(postgres(), keyed_users());
    let window = in_window(&harness);

    harness.tab().imp().add_index_row.emit_by_name::<()>("activated", &[]);
    let form = shown_form(&window);
    let name: adw::EntryRow = rows_titled(&form, "Name").expect("the Name row");
    wait_until(WAIT, || name.is_mapped()).expect("the form on screen");
    name.set_text("by_score");
    assert!(
        form.activate_action("index.add-key", Some(&"score".to_variant()))
            .is_ok()
    );
    super::form_dialog::tests::press_enter(&name);

    wait_until(WAIT, || harness.draft().indexes.len() == 1).expect("the index to be added");
    let index = harness.draft().indexes[0].clone();
    assert_eq!(index.name, "by_score");
    assert_eq!(
        index
            .keys
            .iter()
            .map(|key| key.column_name().unwrap_or_default().to_owned())
            .collect::<Vec<_>>(),
        ["score"]
    );
    assert!(harness.tab().imp().save_button.is_sensitive());
    window.destroy();
}

#[gtk4::test]
fn add_foreign_key_from_the_tab_adds_the_key() {
    let mut script = postgres_script();
    script.fetch_table_definition.always(FakeReply::ok(keyed_users()));
    script.list_objects.always(FakeReply::ok(vec![ObjectInfo {
        schema: Some("public".to_owned()),
        name: "accounts".to_owned(),
        kind: ObjectKind::Table,
    }]));
    script
        .fetch_columns
        .always(FakeReply::ok(vec![integer_column("id", true).info]));
    let harness = Harness::open(StructureMode::Edit, script, []);
    wait_until(WAIT, || harness.page().as_deref() == Some("editor")).expect("the structure");
    drain_main_context();
    let window = in_window(&harness);

    harness.tab().imp().add_fk_row.emit_by_name::<()>("activated", &[]);
    let form = shown_form(&window);
    let name: adw::EntryRow = rows_titled(&form, "Name").expect("the Name row");
    wait_until(WAIT, || name.is_mapped()).expect("the form on screen");
    name.set_text("fk_account");
    let table: adw::ComboRow = rows_titled(&form, "Referenced table").expect("the table row");
    wait_until(WAIT, || table.is_sensitive()).expect("the tables to be read");
    table.set_selected(1);
    let id: adw::ActionRow = rows_titled(&form, "id").expect("the id check row");
    id.activatable_widget()
        .and_downcast::<gtk::CheckButton>()
        .expect("the id check")
        .set_active(true);
    wait_until(WAIT, || {
        rows_titled::<adw::ComboRow>(&form, "id references").is_some_and(|pair| pair.is_sensitive())
    })
    .expect("the columns of accounts to be read");
    super::form_dialog::tests::press_enter(&name);

    wait_until(WAIT, || harness.draft().foreign_keys.len() == 1).expect("the key to be added");
    let key = harness.draft().foreign_keys[0].clone();
    assert_eq!((key.name.as_str(), key.ref_table.as_str()), ("fk_account", "accounts"));
    assert_eq!(
        (key.columns, key.ref_columns),
        (vec!["id".to_owned()], vec!["id".to_owned()])
    );
    window.destroy();
}

/// Ctrl+S saves as the Save button does, and only while the button could.
#[gtk4::test]
fn ctrl_s_saves_while_save_is_on() {
    use crate::application::ShortcutOwner;
    use crate::test_support::shortcut_keys::{keystroke, owner_controller, shortcuts, trigger_keys};
    let mut script = postgres_script();
    script.fetch_table_definition.always(FakeReply::ok(TableDefinition {
        columns: vec![integer_column("id", true)],
        ..definition("id")
    }));
    adw::init().expect("libadwaita initialises under the test backend");
    crate::register_test_resources();
    let runtime = crate::test_support::test_runtime();
    let fake = FakeSession::start(script, [], runtime.tasks());
    let tab = StructureTab::new(StructureTabInit {
        tracker: StructureTrackerHandle::default(),
        schema: None,
        table: "users".to_owned(),
        mode: StructureMode::Edit,
        session: fake.session.clone(),
        tasks: runtime.tasks(),
        first_load: crate::ui::tab_load::FirstLoad::Now,
    });
    wait_until(WAIT, || {
        tab.imp().inner_stack.visible_child_name().as_deref() == Some("editor")
    })
    .expect("the structure");
    let saves = std::rc::Rc::new(std::cell::Cell::new(0));
    let counter = saves.clone();
    tab.connect_save_requested(move |_| counter.set(counter.get() + 1));
    let ctrl_s = shortcuts(&owner_controller(&tab, ShortcutOwner::StructureTab).expect("the tab's keys"))
        .into_iter()
        .find(|shortcut| {
            shortcut
                .trigger()
                .is_some_and(|trigger| trigger_keys(&trigger).contains(&keystroke("<Primary>s")))
        })
        .and_then(|shortcut| shortcut.action())
        .expect("Ctrl+S is bound");
    let press = || ctrl_s.activate(gtk::ShortcutActionFlags::empty(), &tab, None);

    assert!(!press(), "Ctrl+S was taken with nothing to save");
    tab.send(ColumnsInput::ColumnEdited {
        column: column_object(&tab, 0),
        field: ColumnField::Default("42".to_owned()),
    });
    assert!(press());

    assert_eq!(saves.get(), 1);
    drop(tab);
    drain_main_context();
    runtime.shutdown();
}

#[gtk4::test]
fn icon_buttons_are_labelled_without_accelerator_hints() {
    let table = TableDefinition {
        table: TableRef::unqualified("users"),
        columns: vec![integer_column("id", true), integer_column("team_id", false)],
        primary_key: Some(PrimaryKeyConstraint {
            name: Some("users_pkey".to_owned()),
            columns: vec!["id".to_owned()],
        }),
        indexes: vec![tablepro_core::IndexInfo {
            name: "users_team_idx".to_owned(),
            keys: vec![tablepro_core::meta::IndexKey::Column {
                name: "team_id".to_owned(),
                descending: false,
            }],
            unique: false,
            primary: false,
            predicate: None,
            definition: Some("CREATE INDEX users_team_idx ON public.users USING btree (team_id)".to_owned()),
        }],
        foreign_keys: vec![tablepro_core::ForeignKeyInfo {
            name: "users_team_fk".to_owned(),
            columns: vec!["team_id".to_owned()],
            ref_schema: None,
            ref_table: "teams".to_owned(),
            ref_columns: vec!["id".to_owned()],
            on_delete: None,
            on_update: None,
        }],
        inbound_foreign_keys: Vec::new(),
        source: None,
        options: None,
    };
    let mut script = postgres_script();
    script.fetch_table_definition.always(FakeReply::ok(table));
    let harness = Harness::open(StructureMode::Edit, script, []);
    wait_until(WAIT, || harness.page().as_deref() == Some("editor")).expect("the structure");
    drain_main_context();
    let tab = harness.tab();
    for row in descendants(tab)
        .into_iter()
        .filter_map(|widget| widget.downcast::<adw::ExpanderRow>().ok())
    {
        row.set_expanded(true);
    }
    let removes = descendants(tab)
        .into_iter()
        .filter(|widget| ["col-remove", "index-remove", "fk-remove"].contains(&widget.widget_name().as_str()))
        .count();
    let suggestions = descendants(tab)
        .into_iter()
        .filter(|widget| widget.is::<gtk::MenuButton>())
        .count();

    assert_eq!(removes, 4, "a column, index or foreign key row is missing");
    assert!(suggestions > 0, "no column offers its suggested types");
    assert_eq!(crate::test_support::unlabelled_icon_buttons(tab), Vec::<String>::new());
    assert_eq!(crate::test_support::tooltips_with_keys(tab), Vec::<String>::new());
}

fn mysql() -> Arc<dyn SqlDialect> {
    Arc::new(tablepro_driver_mysql::MySqlDialect::new(
        tablepro_driver_mysql::MySqlFlavour::MySql,
        &ServerInfo::new("MySQL", "8.4.3", 8, 4, 3),
    ))
}

/// `id int` keyed and numbered, next 7, and `title varchar(40)` in
/// utf8mb4, as MySQL reads them.
fn mysql_users() -> TableDefinition {
    let dialect = mysql();
    let mut id = integer_column("id", true);
    id.info.column_type = dialect.parse_type("int").expect("a MySQL type");
    id.info.is_auto_increment = true;
    let mut title = definition("title").columns.remove(0);
    title.info.column_type = dialect.parse_type("varchar(40)").expect("a MySQL type");
    title.attributes.character_set = Some("utf8mb4".to_owned());
    title.attributes.collation = Some(CollationName::new(None, "utf8mb4_0900_ai_ci"));
    TableDefinition {
        columns: vec![id, title],
        primary_key: Some(PrimaryKeyConstraint {
            name: Some("PRIMARY".to_owned()),
            columns: vec!["id".to_owned()],
        }),
        options: Some(TableOptions {
            character_set: Some("utf8mb4".to_owned()),
            collation: Some("utf8mb4_0900_ai_ci".to_owned()),
            next_auto_increment: Some(7),
        }),
        ..definition("id")
    }
}

fn character_set(name: &str, default_collation: &str, collations: &[&str]) -> CharacterSet {
    CharacterSet {
        name: name.to_owned(),
        default_collation: default_collation.to_owned(),
        collations: collations.iter().map(|collation| (*collation).to_owned()).collect(),
    }
}

fn character_sets() -> Vec<CharacterSet> {
    vec![
        character_set("latin1", "latin1_swedish_ci", &["latin1_bin", "latin1_swedish_ci"]),
        character_set("utf8mb4", "utf8mb4_0900_ai_ci", &["utf8mb4_0900_ai_ci", "utf8mb4_bin"]),
    ]
}

fn open_mysql(table: TableDefinition, sets: FakeReply<Vec<CharacterSet>>) -> Harness {
    let mut script = ConnectionScript {
        dialect: mysql(),
        ..ConnectionScript::default()
    };
    script.fetch_table_definition.always(FakeReply::ok(table));
    script.fetch_character_sets.always(sets);
    let harness = Harness::open(StructureMode::Edit, script, []);
    harness.wait_for_structure();
    harness
}

fn choices(row: &adw::ComboRow) -> Vec<String> {
    let names = row.model().and_downcast::<gtk::StringList>().expect("a list of names");
    (0..names.n_items())
        .filter_map(|position| names.string(position))
        .map(|name| name.to_string())
        .collect()
}

fn picked(row: &adw::ComboRow) -> Option<String> {
    row.selected_item()
        .and_downcast::<gtk::StringObject>()
        .map(|item| item.string().to_string())
}

fn combo(tab: &StructureTab, position: i32, name: &str) -> adw::ComboRow {
    column_widget(tab, position, name)
        .downcast::<adw::ComboRow>()
        .expect("a combo row")
}

fn table_options(harness: &Harness) -> DraftTableOptions {
    harness.draft().options.expect("the table's options")
}

#[gtk4::test]
fn mysql_offers_the_table_options_and_text_column_character_sets() {
    let harness = open_mysql(mysql_users(), FakeReply::ok(character_sets()));
    let (tab, imp) = (harness.tab(), harness.tab().imp());

    assert!(imp.options_page.is_visible());
    assert_eq!(choices(&imp.character_set_row), ["latin1", "utf8mb4"]);
    assert_eq!(picked(&imp.character_set_row).as_deref(), Some("utf8mb4"));
    assert_eq!(
        choices(&imp.collation_row),
        ["utf8mb4_0900_ai_ci (default)", "utf8mb4_bin"]
    );
    assert!(!imp.convert_row.is_active());
    assert!(imp.auto_increment_group.is_visible());
    assert_eq!(imp.auto_increment_row.text(), "7");
    assert!(
        !combo(tab, 0, "col-charset").is_visible(),
        "an int column offers a character set"
    );
    let title = combo(tab, 1, "col-charset");
    assert!(title.is_visible() && title.is_sensitive());
    assert_eq!(choices(&title), ["latin1", "utf8mb4"]);
    assert_eq!(
        picked(&combo(tab, 1, "col-collation")).as_deref(),
        Some("utf8mb4_0900_ai_ci (default)")
    );
    assert_eq!(preview(tab), "-- No pending changes.");
}

#[gtk4::test]
fn postgres_offers_no_table_options_and_reads_no_character_sets() {
    let harness = open_edit(postgres(), keyed_users());

    assert!(!harness.tab().imp().options_page.is_visible());
    assert!(
        descendants(harness.tab())
            .iter()
            .all(|widget| widget.widget_name() != "col-charset"),
        "a PostgreSQL column offers a character set"
    );
    assert_eq!(
        CallCounters::get(&harness.fake.connection.counters().fetch_character_sets),
        0
    );
}

#[gtk4::test]
fn a_table_character_set_takes_its_default_collation_into_the_preview() {
    let harness = open_mysql(mysql_users(), FakeReply::ok(character_sets()));
    let (tab, imp) = (harness.tab(), harness.tab().imp());

    imp.character_set_row.set_selected(0);
    drain_main_context();

    let options = table_options(&harness);
    assert_eq!(options.character_set.as_deref(), Some("latin1"));
    assert_eq!(options.collation.as_deref(), Some("latin1_swedish_ci"));
    assert_eq!(
        choices(&imp.collation_row),
        ["latin1_bin", "latin1_swedish_ci (default)"]
    );
    assert_eq!(
        picked(&imp.collation_row).as_deref(),
        Some("latin1_swedish_ci (default)")
    );
    assert!(preview(tab).contains("latin1_swedish_ci"), "{}", preview(tab));
    assert!(imp.save_button.is_sensitive());

    imp.collation_row.set_selected(0);
    imp.convert_row.set_active(true);

    let options = table_options(&harness);
    assert_eq!(options.collation.as_deref(), Some("latin1_bin"));
    assert!(options.converts_columns);
    assert!(preview(tab).contains("CONVERT TO CHARACTER SET"), "{}", preview(tab));
}

#[gtk4::test]
fn a_convert_beside_a_column_change_says_why_before_save() {
    let harness = open_mysql(mysql_users(), FakeReply::ok(character_sets()));
    let (tab, imp) = (harness.tab(), harness.tab().imp());

    imp.convert_row.set_active(true);
    tab.send(ColumnsInput::ColumnEdited {
        column: harness.column(1),
        field: ColumnField::Comment(Some("a title".to_owned())),
    });
    drain_main_context();

    assert_eq!(
        preview(tab),
        "-- Column title can't be changed this way. Save column and primary key changes before converting existing \
         columns."
    );
}

#[gtk4::test]
fn discard_restores_the_table_options() {
    let harness = open_mysql(mysql_users(), FakeReply::ok(character_sets()));
    let window = in_window(&harness);
    let imp = harness.tab().imp();
    imp.character_set_row.set_selected(0);
    imp.convert_row.set_active(true);
    imp.auto_increment_row.set_text("100");
    assert_eq!(table_options(&harness).next_auto_increment, Some(100));

    imp.discard_button.emit_clicked();
    answer_discard(&window, "discard");

    assert_eq!(
        table_options(&harness),
        DraftTableOptions {
            character_set: Some("utf8mb4".to_owned()),
            collation: Some("utf8mb4_0900_ai_ci".to_owned()),
            converts_columns: false,
            next_auto_increment: Some(7),
        }
    );
    assert_eq!(picked(&imp.character_set_row).as_deref(), Some("utf8mb4"));
    assert_eq!(
        picked(&imp.collation_row).as_deref(),
        Some("utf8mb4_0900_ai_ci (default)")
    );
    assert!(!imp.convert_row.is_active());
    assert_eq!(imp.auto_increment_row.text(), "7");
    assert_eq!(preview(harness.tab()), "-- No pending changes.");
}

/// The draft holds still while a save has it, so an option edit that
/// arrives then is refused and the controls show the draft again.
#[gtk4::test]
fn table_option_edits_wait_for_the_save() {
    let harness = open_mysql(mysql_users(), FakeReply::ok(character_sets()));
    let imp = harness.tab().imp();
    imp.character_set_row.set_selected(0);
    harness.tab().send(SaveInput::SaveStarted);
    assert!(
        !imp.options_box.is_sensitive(),
        "the options stayed editable during the save"
    );
    let toasts = toasts(harness.tab());

    harness.tab().send(TableInput::CollationPicked("latin1_bin".to_owned()));
    harness.tab().send(TableInput::ConvertColumnsToggled(true));
    harness.tab().send(TableInput::NextAutoIncrementEdited("50".to_owned()));

    let options = table_options(&harness);
    assert_eq!(options.collation.as_deref(), Some("latin1_swedish_ci"));
    assert!(!options.converts_columns);
    assert_eq!(options.next_auto_increment, Some(7));
    assert_eq!(
        picked(&imp.collation_row).as_deref(),
        Some("latin1_swedish_ci (default)")
    );
    assert_eq!(imp.auto_increment_row.text(), "7");
    assert_eq!(toasts.borrow().len(), 3, "a refused edit said nothing");

    harness.tab().send(SaveInput::SaveFailed("rolled back".to_owned()));
    assert!(imp.options_box.is_sensitive());
}

#[gtk4::test]
fn a_column_collation_list_follows_its_character_set() {
    let harness = open_mysql(mysql_users(), FakeReply::ok(character_sets()));
    let tab = harness.tab();
    let (character_set, collation) = (combo(tab, 1, "col-charset"), combo(tab, 1, "col-collation"));

    character_set.set_selected(0);

    assert_eq!(choices(&collation), ["latin1_bin", "latin1_swedish_ci (default)"]);
    assert_eq!(picked(&collation).as_deref(), Some("latin1_swedish_ci (default)"));
    let column = harness.draft_column(1);
    assert_eq!(
        (column.character_set.as_deref(), column.collation.as_deref()),
        (Some("latin1"), Some("latin1_swedish_ci"))
    );

    collation.set_selected(0);

    assert_eq!(harness.draft_column(1).collation.as_deref(), Some("latin1_bin"));
    assert!(preview(tab).contains("latin1_bin"), "{}", preview(tab));
}

/// A column the user adds follows the table's character set until one
/// is picked, and the rows show only while its type holds text.
#[gtk4::test]
fn a_new_column_takes_the_table_default_while_its_type_holds_text() {
    let harness = open_mysql(mysql_users(), FakeReply::ok(character_sets()));
    let tab = harness.tab();
    tab.send(ColumnsInput::AddColumn);
    entry(tab, 2, "col-type").set_text("varchar(20)");
    let (character_set, collation) = (combo(tab, 2, "col-charset"), combo(tab, 2, "col-collation"));

    assert!(character_set.is_visible());
    assert_eq!(choices(&character_set), ["Table default", "latin1", "utf8mb4"]);
    assert_eq!(picked(&character_set).as_deref(), Some("Table default"));
    assert_eq!(choices(&collation), ["Table default"]);

    entry(tab, 2, "col-type").set_text("int");

    assert!(!character_set.is_visible() && !collation.is_visible());
}

#[gtk4::test]
fn the_next_auto_increment_takes_only_what_the_column_numbers() {
    let mut table = mysql_users();
    table.columns[0].info.column_type = mysql().parse_type("tinyint").expect("a MySQL type");
    let harness = open_mysql(table, FakeReply::ok(character_sets()));
    let (tab, imp) = (harness.tab(), harness.tab().imp());
    let field = imp.auto_increment_row.get();

    for refused in ["300", "0", "seven"] {
        field.set_text(refused);

        assert!(field.has_css_class("error"), "{refused}");
        assert_eq!(
            field.tooltip_text().as_deref(),
            Some("Enter a whole number from 1 to 127.")
        );
        assert!(!imp.save_button.is_sensitive(), "{refused} could be saved");
        assert_eq!(preview(tab), "-- Fix the highlighted fields to see the SQL.");
        assert_eq!(table_options(&harness).next_auto_increment, Some(7));
    }

    field.set_text("100");

    assert!(!field.has_css_class("error"));
    assert!(imp.save_button.is_sensitive());
    assert!(preview(tab).contains("AUTO_INCREMENT"), "{}", preview(tab));

    switch_row(tab, 0, "col-auto").set_active(false);
    drain_main_context();

    assert!(!imp.auto_increment_group.is_visible());
    assert_eq!(table_options(&harness).next_auto_increment, Some(7));
    assert_eq!(field.text(), "7");
}

#[gtk4::test]
fn a_failed_character_set_read_leaves_the_tab_editable() {
    let harness = open_mysql(
        mysql_users(),
        FakeReply::err(DriverError::server("information_schema denied")),
    );
    let (tab, imp) = (harness.tab(), harness.tab().imp());

    assert!(imp.options_page.is_visible());
    assert_eq!(choices(&imp.character_set_row), ["utf8mb4"]);
    for row in [imp.character_set_row.get(), combo(tab, 1, "col-charset")] {
        assert!(!row.is_sensitive());
        assert!(
            row.tooltip_text()
                .is_some_and(|tip| tip.contains("character sets couldn't be read")),
            "{:?}",
            row.tooltip_text()
        );
    }
    assert!(!banner(&harness).is_revealed());

    entry(tab, 1, "col-comment").set_text("headline");
    imp.auto_increment_row.set_text("100");

    assert!(imp.save_button.is_sensitive());
    assert_eq!(imp.pending_label.label(), "2 unsaved changes");
}

fn email_index(name: &str, definition: Option<&str>) -> tablepro_core::IndexInfo {
    tablepro_core::IndexInfo {
        name: name.to_owned(),
        keys: vec![tablepro_core::meta::IndexKey::Column {
            name: "email".to_owned(),
            descending: false,
        }],
        unique: true,
        primary: false,
        predicate: None,
        definition: definition.map(str::to_owned),
    }
}

/// An index the table has offers its statement to copy or open; one
/// only drafted in the tab has none to offer.
#[gtk4::test]
fn a_saved_index_shows_and_copies_its_create_statement() {
    let statement = "CREATE UNIQUE INDEX users_email ON public.users USING btree (email)";
    let mut table = definition("email");
    table.indexes = vec![email_index("users_email", Some(statement))];
    let mut script = postgres_script();
    script.fetch_table_definition.always(FakeReply::ok(table));
    let harness = Harness::open(StructureMode::Edit, script, []);
    wait_until(WAIT, || harness.page().as_deref() == Some("editor")).expect("the structure");
    let toasts = toasts(harness.tab());
    let opened = std::rc::Rc::new(std::cell::RefCell::new(Vec::new()));
    let sink = opened.clone();
    harness
        .tab()
        .connect_open_in_editor(move |_, sql| sink.borrow_mut().push(sql));
    harness
        .tab()
        .send(IndexesInput::AddIndex(email_index("users_email_draft", None)));
    drain_main_context();

    let menus: Vec<gtk::Widget> = descendants(harness.tab())
        .into_iter()
        .filter(|widget| widget.widget_name() == "index-statement")
        .collect();
    assert_eq!(menus.len(), 1, "only the saved index offers a statement");
    menus[0]
        .activate_action("index.copy-create", None)
        .expect("the copy action");
    menus[0]
        .activate_action("index.show-create", None)
        .expect("the show action");
    drain_main_context();

    let copied = harness
        .tab()
        .clipboard()
        .content()
        .and_then(|content| content.value(String::static_type()).ok())
        .and_then(|value| value.get::<String>().ok());
    let expected = format!("{statement};");
    assert_eq!(copied.as_deref(), Some(expected.as_str()));
    assert_eq!(*toasts.borrow(), ["Copied to clipboard"]);
    assert_eq!(*opened.borrow(), [expected]);
}
