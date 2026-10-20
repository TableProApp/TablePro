#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use tablepro_app_services::workspace::{
    CloseAfterSave, OpenMode, TabContent, TableOpenPlan, TableOpenRequest, WorkspaceTabs,
};
use uuid::Uuid;

struct Table(&'static str);

impl TabContent for Table {
    fn table_target(&self) -> Option<(Option<&str>, &str)> {
        Some((Some("public"), self.0))
    }
}

fn plan(tabs: &WorkspaceTabs<Table>, name: &str, dirty: bool) -> TableOpenPlan {
    tabs.plan_table_open(
        TableOpenRequest {
            schema: Some("public"),
            table: name,
            selected: None,
            mode: OpenMode::SwitchOrAppend,
            preview_enabled: true,
        },
        |_| dirty,
    )
}

#[test]
fn a_clean_preview_can_be_replaced() {
    let id = Uuid::new_v4();
    let mut tabs = WorkspaceTabs::default();
    tabs.insert_with_preview(id, Table("old"), true);
    assert_eq!(
        plan(&tabs, "new", false),
        TableOpenPlan::Append {
            preview: true,
            replace: Some(id),
            promote: None
        }
    );
}

#[test]
fn a_preview_with_pending_changes_is_promoted() {
    let id = Uuid::new_v4();
    let mut tabs = WorkspaceTabs::default();
    tabs.insert_with_preview(id, Table("old"), true);
    assert_eq!(
        plan(&tabs, "new", true),
        TableOpenPlan::Append {
            preview: true,
            replace: None,
            promote: Some(id)
        }
    );
    assert!(tabs.keep(&id));
    assert!(!tabs.is_preview(&id));
    assert_eq!(
        plan(&tabs, "new", false),
        TableOpenPlan::Append {
            preview: true,
            replace: None,
            promote: None
        }
    );
}

#[test]
fn the_selected_copy_of_a_table_is_reused_before_another_copy() {
    let first = Uuid::new_v4();
    let selected = Uuid::new_v4();
    let mut tabs = WorkspaceTabs::default();
    tabs.insert(first, Table("items"));
    tabs.insert(selected, Table("items"));
    let request = TableOpenRequest {
        schema: Some("public"),
        table: "items",
        selected: Some(selected),
        mode: OpenMode::SwitchOrAppend,
        preview_enabled: true,
    };
    assert_eq!(
        tabs.plan_table_open(request, |_| false),
        TableOpenPlan::Select(selected)
    );
}

#[test]
fn closing_a_tab_drops_its_preview_and_another_window_keeps_its_tabs() {
    let id = Uuid::new_v4();
    let mut first = WorkspaceTabs::default();
    let mut second = WorkspaceTabs::default();
    first.insert_with_preview(id, Table("first"), true);
    second.insert_with_preview(id, Table("second"), true);
    assert_eq!(first.remove(&id).unwrap().0, "first");
    assert!(!first.is_preview(&id));
    assert_eq!(
        plan(&first, "new", false),
        TableOpenPlan::Append {
            preview: true,
            replace: None,
            promote: None
        }
    );
    assert!(second.is_preview(&id));
    assert_eq!(second.get(&id).unwrap().0, "second");
}

#[test]
fn save_then_close_waits_for_every_save_and_cancellation_retires_late_completions() {
    let tab = Uuid::new_v4();
    let other = Uuid::new_v4();
    let mut close = CloseAfterSave::default();
    close.begin(tab, 2);
    close.begin(other, 1);
    assert!(!close.complete(&tab));
    assert!(close.complete(&tab));
    assert!(!close.complete(&tab));
    close.begin(tab, 1);
    close.cancel(&tab);
    assert!(!close.complete(&tab));
    assert!(close.complete(&other));
    assert!(close.is_empty());
}

#[test]
fn a_regular_tab_is_never_replaced_or_promoted() {
    let id = Uuid::new_v4();
    let mut tabs = WorkspaceTabs::default();
    tabs.insert(id, Table("kept"));
    assert_eq!(
        plan(&tabs, "other", false),
        TableOpenPlan::Append {
            preview: true,
            replace: None,
            promote: None
        }
    );
    assert_eq!(
        plan(&tabs, "other", true),
        TableOpenPlan::Append {
            preview: true,
            replace: None,
            promote: None
        }
    );
}

#[test]
fn a_table_opens_in_the_preview_tab_only_when_the_preference_is_on() {
    let id = Uuid::new_v4();
    let mut tabs = WorkspaceTabs::default();
    tabs.insert_with_preview(id, Table("existing"), true);
    for (mode, preview_enabled) in [
        (OpenMode::NewTab, false),
        (OpenMode::NewTab, true),
        (OpenMode::SwitchOrAppend, false),
    ] {
        let result = tabs.plan_table_open(
            TableOpenRequest {
                schema: Some("public"),
                table: "new",
                selected: None,
                mode,
                preview_enabled,
            },
            |_| panic!("a kept tab must not consult a preview's dirty state"),
        );
        assert_eq!(
            result,
            TableOpenPlan::Append {
                preview: false,
                replace: None,
                promote: None
            }
        );
        assert!(tabs.is_preview(&id));
    }
}

#[test]
fn explicit_new_tab_does_not_reuse_an_existing_copy() {
    let id = Uuid::new_v4();
    let mut tabs = WorkspaceTabs::default();
    tabs.insert(id, Table("items"));
    let result = tabs.plan_table_open(
        TableOpenRequest {
            schema: Some("public"),
            table: "items",
            selected: Some(id),
            mode: OpenMode::NewTab,
            preview_enabled: true,
        },
        |_| false,
    );
    assert_eq!(
        result,
        TableOpenPlan::Append {
            preview: false,
            replace: None,
            promote: None
        }
    );
}

#[test]
fn table_matching_keeps_schema_identity_and_ignores_a_missing_selection() {
    let id = Uuid::new_v4();
    let mut tabs = WorkspaceTabs::default();
    tabs.insert(id, Table("items"));
    let selected = Some(Uuid::new_v4());
    assert_eq!(
        tabs.plan_table_open(
            TableOpenRequest {
                schema: Some("public"),
                table: "items",
                selected,
                mode: OpenMode::SwitchOrAppend,
                preview_enabled: true
            },
            |_| false
        ),
        TableOpenPlan::Select(id)
    );
    assert_eq!(
        tabs.plan_table_open(
            TableOpenRequest {
                schema: Some("other"),
                table: "items",
                selected,
                mode: OpenMode::SwitchOrAppend,
                preview_enabled: true
            },
            |_| false
        ),
        TableOpenPlan::Append {
            preview: true,
            replace: None,
            promote: None
        }
    );
}

#[test]
fn a_failed_or_cancelled_save_keeps_other_tabs_waiting_for_their_own_saves() {
    let first = Uuid::new_v4();
    let second = Uuid::new_v4();
    let mut close = CloseAfterSave::default();
    close.begin(first, 2);
    close.begin(second, 1);
    close.cancel(&first);
    assert!(!close.complete(&first));
    assert_eq!(close.remaining(&second), Some(1));
    assert!(!close.is_empty());
    assert!(close.complete(&second));
    assert!(close.is_empty());
}

#[test]
fn new_saves_for_the_same_tab_accumulate_until_every_completion_arrives() {
    let id = Uuid::new_v4();
    let mut close = CloseAfterSave::default();
    close.begin(id, 0);
    assert!(close.is_empty());
    close.begin(id, 1);
    close.begin(id, 2);
    assert!(!close.complete(&id));
    assert!(!close.complete(&id));
    assert!(close.complete(&id));
    assert!(close.is_empty());
}

#[test]
fn replacing_an_entry_does_not_retain_its_old_preview_state() {
    let id = Uuid::new_v4();
    let mut tabs = WorkspaceTabs::default();
    tabs.insert_with_preview(id, Table("preview"), true);
    let previous = tabs.insert(id, Table("kept"));
    assert_eq!(previous.unwrap().0, "preview");
    assert_eq!(tabs.get(&id).unwrap().0, "kept");
    assert!(!tabs.is_preview(&id));
}

struct Editor;

impl TabContent for Editor {
    fn table_target(&self) -> Option<(Option<&str>, &str)> {
        None
    }
}

#[test]
fn an_editor_cannot_be_marked_as_a_replaceable_table_preview() {
    let id = Uuid::new_v4();
    let mut tabs = WorkspaceTabs::default();
    tabs.insert_with_preview(id, Editor, true);
    assert!(!tabs.is_preview(&id));
    let result = tabs.plan_table_open(
        TableOpenRequest {
            schema: None,
            table: "items",
            selected: Some(id),
            mode: OpenMode::SwitchOrAppend,
            preview_enabled: true,
        },
        |_| panic!("an editor cannot be a preview target"),
    );
    assert_eq!(
        result,
        TableOpenPlan::Append {
            preview: true,
            replace: None,
            promote: None
        }
    );
}

#[test]
fn resetting_a_workspace_releases_its_payloads_when_the_old_workspace_is_dropped() {
    struct Payload(std::rc::Rc<std::cell::Cell<u32>>);
    impl Drop for Payload {
        fn drop(&mut self) {
            self.0.set(self.0.get() + 1);
        }
    }
    let dropped = std::rc::Rc::new(std::cell::Cell::new(0));
    let mut tabs = WorkspaceTabs::default();
    tabs.insert(Uuid::new_v4(), Payload(dropped.clone()));
    let closed = std::mem::take(&mut tabs);
    assert!(tabs.is_empty());
    assert_eq!(dropped.get(), 0);
    drop(closed);
    assert_eq!(dropped.get(), 1);
}
