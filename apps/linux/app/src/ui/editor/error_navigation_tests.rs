use super::*;

#[test]
#[ignore = "requires an isolated GTK display"]
fn a_server_error_navigates_to_its_original_unicode_statement() {
    let fixture = EditorFixture::new();
    let window = gtk::Window::builder()
        .default_width(1000)
        .default_height(700)
        .child(fixture.controller.widget())
        .build();
    window.present();
    spin_until(|| fixture.controller.widget().height() > 0);
    let sql = "SELECT 'é';\nSELECT broken;";
    fixture.controller.model().source_view.buffer().set_text(sql);
    fixture.controller.model().run_button.emit_clicked();
    let first = fixture.next_query();
    first.release.send(success()).unwrap();
    let second = fixture.next_query();
    fixture.finish(
        second,
        Err(DriverError::Query {
            message: "unknown column".into(),
            sqlstate: Some("42703".into()),
            position: Some(8),
        }),
    );
    let navigate = descendants(fixture.controller.widget().upcast_ref())
        .into_iter()
        .filter_map(|widget| widget.downcast::<gtk::Button>().ok())
        .find(|button| button.label().as_deref() == Some("Go to error"))
        .expect("a structured database error needs a source navigation action");
    spin_until(|| navigate.height() > 0);
    let holder = fixture.controller.model().results_holder.clone();
    let bounds = navigate.compute_bounds(&holder).unwrap();
    assert!(bounds.y() >= 0.0 && bounds.y() + bounds.height() <= holder.height() as f32);
    navigate.emit_clicked();
    let buffer = fixture.controller.model().source_view.buffer();
    let expected = "SELECT 'é';\nSELECT ".chars().count() as i32;
    spin_until(|| buffer.iter_at_mark(&buffer.get_insert()).offset() == expected);
    assert_eq!(fixture.calls.load(Ordering::SeqCst), 2);
    window.destroy();
}

fn error() -> Result<QueryResultBatch, DriverError> {
    Err(DriverError::Query {
        message: "unknown column".into(),
        sqlstate: Some("42703".into()),
        position: Some(8),
    })
}

fn navigation(fixture: &EditorFixture) -> gtk::Button {
    descendants(fixture.controller.model().results_holder.upcast_ref())
        .into_iter()
        .filter_map(|widget| widget.downcast::<gtk::Button>().ok())
        .find(|button| button.label().as_deref() == Some("Go to error"))
        .unwrap()
}

fn window(fixture: &EditorFixture) -> gtk::Window {
    let window = gtk::Window::builder()
        .default_width(1000)
        .default_height(700)
        .child(fixture.controller.widget())
        .build();
    window.present();
    spin_until(|| fixture.controller.widget().height() > 0);
    window
}

#[test]
#[ignore = "requires an isolated GTK display"]
fn run_current_locates_the_second_identical_statement_and_restores_the_editor() {
    let fixture = EditorFixture::new();
    let window = window(&fixture);
    let buffer = fixture.controller.model().source_view.buffer();
    let sql = "SELECT broken;\nSELECT broken;";
    buffer.set_text(sql);
    buffer.place_cursor(&buffer.end_iter());
    fixture.controller.sender().send(SqlEditorInput::RunAtCursor).unwrap();
    let query = fixture.next_query();
    assert_eq!(query.sql, "SELECT broken");
    fixture.finish(query, error());
    let button = navigation(&fixture);
    fixture
        .controller
        .model()
        .panel
        .apply(super::super::bottom_panel::PanelAction::Maximize);
    spin_until(|| !fixture.controller.model().source_view.is_mapped());
    button.emit_clicked();
    spin_until(|| buffer.cursor_position() == "SELECT broken;\nSELECT ".chars().count() as i32);
    spin_until(|| fixture.controller.model().source_view.is_mapped());
    assert_eq!(fixture.calls.load(Ordering::SeqCst), 1);
    window.destroy();
}

#[test]
#[ignore = "requires an isolated GTK display"]
fn editing_the_query_disables_an_existing_error_navigation_action() {
    let fixture = EditorFixture::new();
    let window = window(&fixture);
    let buffer = fixture.controller.model().source_view.buffer();
    buffer.set_text("SELECT broken;");
    fixture.controller.model().run_button.emit_clicked();
    fixture.finish(fixture.next_query(), error());
    let button = navigation(&fixture);
    buffer.insert(&mut buffer.end_iter(), "\nSELECT 1;");
    buffer.place_cursor(&buffer.start_iter());
    button.emit_clicked();
    fixture.process_inputs();
    assert_eq!(buffer.cursor_position(), 0);
    assert_eq!(fixture.calls.load(Ordering::SeqCst), 1);
    window.destroy();
}

#[test]
#[ignore = "requires an isolated GTK display"]
fn a_new_run_disables_the_previous_error_navigation_action() {
    let fixture = EditorFixture::new();
    let window = window(&fixture);
    let buffer = fixture.controller.model().source_view.buffer();
    buffer.set_text("SELECT broken;");
    fixture.controller.model().run_button.emit_clicked();
    fixture.finish(fixture.next_query(), error());
    let button = navigation(&fixture);
    buffer.place_cursor(&buffer.start_iter());
    fixture.controller.model().run_button.emit_clicked();
    let pending = fixture.next_query();
    button.emit_clicked();
    fixture.process_inputs();
    assert_eq!(buffer.cursor_position(), 0);
    fixture.finish(pending, success());
    assert_eq!(fixture.calls.load(Ordering::SeqCst), 2);
    window.destroy();
}

#[test]
#[ignore = "requires an isolated GTK display"]
fn closing_the_connection_disables_its_error_navigation_action() {
    let fixture = EditorFixture::new();
    let window = window(&fixture);
    let buffer = fixture.controller.model().source_view.buffer();
    buffer.set_text("SELECT broken;");
    fixture.controller.model().run_button.emit_clicked();
    fixture.finish(fixture.next_query(), error());
    let button = navigation(&fixture);
    buffer.place_cursor(&buffer.start_iter());
    let metadata = fixture.database.metadata(fixture.connection_id).unwrap();
    fixture.database.close(fixture.connection_id);
    button.emit_clicked();
    fixture.process_inputs();
    assert_eq!(buffer.cursor_position(), 0);
    let (requests, _incoming) = mpsc::channel();
    let entered = fixture._runtime.enter();
    assert!(fixture.database.activate(
        fixture.connection_id,
        metadata,
        Box::new(HeldConnection {
            calls: fixture.calls.clone(),
            requests,
            sessions: fixture.sessions.clone(),
        }),
        None,
        false,
        ReconnectParams {
            driver: Arc::new(drivers_sqlite::SqliteDriver),
            opts: ConnectOptions::default(),
            ssh: None,
            environment: tablepro_transport::SshEnvironment::builtin(tablepro_ssh::UnknownHostKey::Refuse),
        },
    ));
    drop(entered);
    button.emit_clicked();
    fixture.process_inputs();
    assert_eq!(buffer.cursor_position(), 0);
    assert_eq!(fixture.calls.load(Ordering::SeqCst), 1);
    window.destroy();
}

#[test]
#[ignore = "requires an isolated GTK display"]
fn error_navigation_does_not_mistake_a_comment_for_the_executed_statement() {
    let fixture = EditorFixture::new();
    let window = window(&fixture);
    let buffer = fixture.controller.model().source_view.buffer();
    let sql = "-- SELECT broken\nSELECT broken;";
    buffer.set_text(sql);
    fixture.controller.model().run_button.emit_clicked();
    let query = fixture.next_query();
    assert_eq!(query.sql, "SELECT broken");
    fixture.finish(query, error());
    navigation(&fixture).emit_clicked();
    fixture.process_inputs();
    assert_eq!(
        buffer.cursor_position(),
        "-- SELECT broken\nSELECT ".chars().count() as i32
    );
    window.destroy();
}

#[test]
#[ignore = "requires an isolated GTK display"]
fn a_selected_query_error_keeps_its_original_unicode_offset() {
    let fixture = EditorFixture::new();
    let window = window(&fixture);
    let buffer = fixture.controller.model().source_view.buffer();
    let prefix = "SELECT 'é';\n";
    let selected = "  SELECT broken;";
    buffer.set_text(&format!("{prefix}{selected}\nSELECT 3;"));
    let start = buffer.iter_at_offset(prefix.chars().count() as i32);
    let end = buffer.iter_at_offset((prefix.chars().count() + selected.chars().count()) as i32);
    buffer.select_range(&start, &end);
    fixture.controller.model().run_button.emit_clicked();
    let pending = fixture.next_query();
    assert_eq!(pending.sql.trim(), "SELECT broken");
    fixture.finish(pending, error());
    navigation(&fixture).emit_clicked();
    let expected = (prefix.chars().count() + 2 + 7) as i32;
    spin_until(|| buffer.cursor_position() == expected);
    assert_eq!(fixture.calls.load(Ordering::SeqCst), 1);
    window.destroy();
}
