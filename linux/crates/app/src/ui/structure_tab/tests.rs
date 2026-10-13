use std::time::Duration;

use std::sync::Arc;

use gtk4::subclass::prelude::ObjectSubclassIsExt;
use tablepro_core::column::{ColumnDefault, ColumnType};
use tablepro_core::ddl::{
    ColumnAttributes, ColumnDefinition, ColumnKeyRoles, InboundForeignKey, PrimaryKeyConstraint, TableDefinition,
};
use tablepro_core::dialect::SqlDialect;
use tablepro_core::meta::TableRef;
use tablepro_core::{ColumnInfo, DriverError, LossPhase, ServerInfo};
use tablepro_session::fakes::FakeEstablish;
use tablepro_test_support::{CallCounters, ConnectionScript, FakeReply};

use super::*;
use crate::test_support::{FakeSession, descendants, drain_main_context, first_descendant_of_type, wait_until};

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

    fn column_names(&self) -> Vec<String> {
        self.tab()
            .imp()
            .model
            .borrow()
            .as_ref()
            .map(|model| {
                model
                    .draft
                    .borrow()
                    .columns
                    .iter()
                    .map(|column| column.name.clone())
                    .collect()
            })
            .unwrap_or_default()
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

fn postgres() -> Arc<dyn SqlDialect> {
    Arc::new(drivers_postgres::PgDialect::new(&ServerInfo::new(
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
    harness.tab().send(StructureTabInput::AddColumn);
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
    harness.tab().send(StructureTabInput::AddColumn);
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

    harness.tab().send(StructureTabInput::AddColumn);
    harness.tab().send(StructureTabInput::SchemaChanged);
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

fn toasts(tab: &StructureTab) -> std::rc::Rc<std::cell::RefCell<Vec<String>>> {
    let toasts = std::rc::Rc::new(std::cell::RefCell::new(Vec::new()));
    let sink = toasts.clone();
    tab.connect_toast(move |_, text| sink.borrow_mut().push(text));
    toasts
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

#[gtk4::test]
fn a_failed_read_after_a_schema_change_keeps_the_definition() {
    let harness = Harness::open(StructureMode::Edit, readable_once(), []);
    wait_until(WAIT, || harness.page().as_deref() == Some("editor")).expect("the structure");
    let toasts = toasts(harness.tab());

    harness.tab().send(StructureTabInput::SchemaChanged);
    wait_until(WAIT, || !toasts.borrow().is_empty()).expect("the failed read was not reported");

    assert_eq!(harness.page().as_deref(), Some("editor"));
    assert_eq!(harness.column_names(), ["id"]);
    assert!(toasts.borrow()[0].contains("denied"), "{:?}", toasts.borrow());
}

#[gtk4::test]
fn a_failed_read_after_a_save_shows_the_error() {
    let harness = Harness::open(StructureMode::Edit, readable_once(), []);
    wait_until(WAIT, || harness.page().as_deref() == Some("editor")).expect("the structure");

    harness
        .tab()
        .send(StructureTabInput::SaveCompleted { new_table_name: None });

    wait_until(WAIT, || harness.page().as_deref() == Some("error"))
        .expect("a definition from before the save stayed editable");
}

fn named_widget(tab: &StructureTab, name: &str) -> gtk::Widget {
    descendants(tab)
        .into_iter()
        .find(|widget| widget.widget_name() == name)
        .unwrap_or_else(|| panic!("no widget named {name}"))
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
            default: ColumnDefault::None,
            comment: None,
        },
        ColumnAttributes::default(),
    )
}

#[gtk4::test]
fn clickhouse_key_column_rename_is_insensitive_with_reason() {
    let clickhouse: Arc<dyn SqlDialect> = Arc::new(drivers_clickhouse::ClickHouseDialect::new(&ServerInfo::new(
        "ClickHouse",
        "25.8",
        25,
        8,
        0,
    )));
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

    let key_name = named_widget(harness.tab(), "col-name-0");
    let plain_name = named_widget(harness.tab(), "col-name-1");

    assert!(!key_name.is_sensitive(), "a sorting key column could be renamed");
    assert!(
        key_name
            .tooltip_text()
            .is_some_and(|tip| tip.contains("sorting or partition key")),
        "{:?}",
        key_name.tooltip_text()
    );
    assert!(plain_name.is_sensitive());
    assert!(!named_widget(harness.tab(), "col-remove-0").is_sensitive());
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
            name: "orders_user_fk".to_owned(),
            table: TableRef::unqualified("orders"),
            columns: vec!["user_id".to_owned()],
            referenced_columns: vec!["id".to_owned()],
        }],
        source: None,
    };
    let mut script = postgres_script();
    script.fetch_table_definition.always(FakeReply::ok(users));
    let harness = Harness::open(StructureMode::Edit, script, []);
    wait_until(WAIT, || harness.page().as_deref() == Some("editor")).expect("the structure");
    drain_main_context();

    for name in ["col-pk-0", "col-pk-1"] {
        let switch = named_widget(harness.tab(), name);
        assert!(!switch.is_sensitive(), "{name} could move a referenced key");
        assert!(
            switch.tooltip_text().is_some_and(|tip| tip.contains("orders_user_fk")),
            "{name}: {:?}",
            switch.tooltip_text()
        );
    }
    assert!(!named_widget(harness.tab(), "col-remove-0").is_sensitive());
    assert!(named_widget(harness.tab(), "col-remove-1").is_sensitive());
}

#[gtk4::test]
fn a_computed_column_takes_no_comment_where_the_comment_restates_it() {
    let mysql: Arc<dyn SqlDialect> = Arc::new(drivers_mysql::MySqlDialect::new(
        drivers_mysql::MySqlFlavour::MySql,
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
    wait_until(WAIT, || harness.page().as_deref() == Some("editor")).expect("the structure");
    drain_main_context();

    let computed = named_widget(harness.tab(), "col-comment-0");

    assert!(!computed.is_sensitive(), "a generated column's comment could be set");
    assert!(
        computed
            .tooltip_text()
            .is_some_and(|tip| tip.contains("computes this column")),
        "{:?}",
        computed.tooltip_text()
    );
    assert!(named_widget(harness.tab(), "col-comment-1").is_sensitive());
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
    });
    wait_until(WAIT, || {
        tab.imp().inner_stack.visible_child_name().as_deref() == Some("editor")
    })
    .expect("the structure");
    let saves = std::rc::Rc::new(std::cell::Cell::new(0));
    let counter = saves.clone();
    tab.connect_save_requested(move |_| counter.set(counter.get() + 1));

    tab.send(StructureTabInput::ColumnEdited {
        index: 0,
        field: ColumnField::Default("42".to_owned()),
    });
    let buffer = sql_buffer(&tab);
    let preview = buffer.text(&buffer.start_iter(), &buffer.end_iter(), false).to_string();
    tab.imp().save_button.emit_clicked();

    assert_eq!(preview, "ALTER TABLE \"users\" ALTER COLUMN \"id\" SET DEFAULT 42;");
    assert_eq!(saves.get(), 1);
    let pending = tracker.begin_save().expect("the change is pending");
    assert_eq!(pending.changes.altered_columns.len(), 1);

    tab.send(StructureTabInput::ColumnEdited {
        index: 0,
        field: ColumnField::Default("1 +".to_owned()),
    });
    assert!(
        !tab.imp().save_button.is_sensitive(),
        "a default that does not parse can be saved"
    );
    // What a close prompt's Save reads.
    let typed = tracker.begin_save().expect("the change is still pending");
    assert_eq!(
        typed.check(),
        Err(crate::services::pending_structure::SaveBlocker::UnparsedDefault(
            "id".to_owned()
        ))
    );
    drop(tab);
    drain_main_context();
    runtime.shutdown();
}
