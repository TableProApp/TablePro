use super::{DropGeneration, RunGeneration, export_name_for_query, read_sql_text, show_cancel_button};
use std::io::Write;

#[test]
fn stale_run_generations_cannot_finish_newer_runs() {
    let mut generations = RunGeneration::default();
    let first = generations.start_new();
    let second = generations.start_new();

    let first_terminal = generations.finish(first).unwrap();
    assert!(!first_terminal.replace_ui);
    assert!(!first_terminal.became_idle);
    assert!(generations.accepts(second));
    let second_terminal = generations.finish(second).unwrap();
    assert!(second_terminal.replace_ui);
    assert!(second_terminal.became_idle);
}

#[test]
fn newer_run_can_finish_ui_without_reporting_idle_before_superseded_run() {
    let mut generations = RunGeneration::default();
    let first = generations.start_new();
    let second = generations.start_new();

    let second_terminal = generations.finish(second).unwrap();
    assert!(second_terminal.replace_ui);
    assert!(!second_terminal.became_idle);
    let first_terminal = generations.finish(first).unwrap();
    assert!(!first_terminal.replace_ui);
    assert!(first_terminal.became_idle);
}

#[test]
fn only_a_started_run_can_replace_the_visible_results() {
    let mut generations = RunGeneration::default();
    let running = generations.start_new();
    assert!(generations.accepts(running));
    assert!(generations.finish(running).unwrap().replace_ui);
    assert!(generations.finish(running).is_none());
}

#[test]
fn stop_is_visible_only_for_running_server_cancellable_queries() {
    assert!(show_cancel_button(true, true));
    assert!(!show_cancel_button(true, false));
    assert!(!show_cancel_button(false, true));
}

#[test]
fn export_name_is_stable_and_safe_for_files() {
    assert_eq!(
        export_name_for_query("SELECT * FROM sales.order_items"),
        "select-from-sales-order-item"
    );
    assert_eq!(export_name_for_query("  \n\t"), "query-results");
}

#[test]
fn dropped_sql_completion_requires_latest_drop_and_unchanged_editor() {
    let generations = DropGeneration::default();
    let first = generations.begin();
    let second = generations.begin();
    assert!(!generations.accepts(first));
    assert!(generations.accepts(second));

    generations.changed();
    assert!(!generations.accepts(second));
}

#[test]
fn dropped_sql_reader_enforces_the_exact_byte_limit() {
    let path = std::env::temp_dir().join(format!("tablepro-drop-{}.sql", uuid::Uuid::new_v4()));
    let mut file = std::fs::File::create(&path).unwrap();
    file.write_all(b"SELECT 1;").unwrap();
    drop(file);

    assert_eq!(read_sql_text(&path, 9).unwrap(), "SELECT 1;");
    assert!(read_sql_text(&path, 8).is_err());
    std::fs::remove_file(path).unwrap();
}
