use super::*;
use gtk::glib;

#[test]
fn an_empty_read_only_grid_menu_does_not_offer_insert_row() {
    assert_eq!(empty_grid_menu(false).n_items(), 1);
}

#[test]
fn an_empty_writable_grid_menu_offers_insert_row() {
    assert_eq!(empty_grid_menu(true).n_items(), 2);
}

#[test]
fn editable_grid_menu_hides_row_mutations_when_the_table_has_no_key() {
    let menu = build_menu(true, false, true, true, false);
    let actions = menu.item_link(3, gio::MENU_LINK_SECTION).expect("actions section");
    assert_eq!(actions.n_items(), 4);
}

#[test]
fn a_local_result_menu_offers_visible_and_all_loaded_row_exports() {
    let export_targets = |local_result| {
        let menu = build_menu(false, false, true, false, local_result);
        let actions = menu
            .item_link(menu.n_items() - 1, gio::MENU_LINK_SECTION)
            .expect("actions section");
        (0..actions.n_items())
            .filter_map(|index| actions.item_attribute_value(index, "action", None))
            .filter_map(|value| value.get::<String>())
            .filter(|action| action.starts_with("cell.export"))
            .collect::<Vec<_>>()
    };
    assert_eq!(export_targets(true), ["cell.export", "cell.export-loaded"]);
    assert_eq!(export_targets(false), ["cell.export"]);
}

#[test]
fn editable_grid_menu_offers_row_mutations_when_the_table_has_a_key() {
    let menu = build_menu(true, true, true, true, false);
    let actions = menu.item_link(3, gio::MENU_LINK_SECTION).expect("actions section");
    assert_eq!(actions.n_items(), 8);
}

#[test]
#[ignore = "requires an isolated GTK display"]
fn copying_a_previewed_cell_copies_the_full_value() {
    gtk::init().unwrap();
    let full = "original".repeat(1_200);
    let columns = vec![ColumnInfo {
        name: "value".into(),
        data_type: "TEXT".into(),
        nullable: true,
        primary_key: false,
        is_auto_increment: false,
        default_value: None,
        is_generated: false,
        comment: None,
        collation: None,
        enum_type: None,
        domain_type: None,
    }];
    let result = std::sync::Arc::new(QueryResult {
        columns: columns.clone(),
        rows: vec![vec![Value::Text(full.clone())]],
        truncated: false,
    });
    let row = crate::ui::row_object::RowObject::from_shared(&result, 0, None).unwrap();
    row.preview_values_from_result();
    let editor = crate::ui::cell_editor::CellEditor::new();
    editor.set_text("preview text");
    IS_NULL_SLOT.set(&editor, false);

    assert_eq!(copy_value_text(editor.upcast_ref(), Some(&row), 0), full);

    let rows = gio::ListStore::new::<crate::ui::row_object::RowObject>();
    rows.append(&row);
    let view = gtk::ColumnView::new(Some(gtk::MultiSelection::new(Some(rows))));
    let snapshot = export_snapshot(&view, &columns, false).unwrap();

    assert_eq!(snapshot.rows, vec![vec![Value::Text(full)]]);
    assert_eq!(snapshot.columns.len(), 1);
}

#[test]
#[ignore = "requires an isolated GTK display"]
fn copy_value_keeps_keyless_previews_pending_edits_and_drafts_whole() {
    gtk::init().unwrap();
    let original = "original".repeat(1_200);
    let keyless = crate::ui::row_object::RowObject::new(vec![Value::Text(original)]);
    keyless.preview_values_from_result();
    let pending = "pending".repeat(1_200);
    let editor = crate::ui::cell_editor::CellEditor::new();
    editor.set_inline_editable(true);
    editor.set_text("pending preview");
    IS_NULL_SLOT.set(&editor, false);
    FULL_EDIT_TEXT_SLOT.set(&editor, pending.clone());
    assert_eq!(
        copy_value_text(editor.upcast_ref(), Some(&keyless), 0),
        pending,
        "a pending edit on a keyless query must copy the current full value"
    );

    let draft_value = "draft".repeat(1_200);
    let draft = crate::ui::row_object::RowObject::new_draft(1, vec![Value::Text(draft_value.clone())]);
    editor.set_text("draft preview");
    IS_NULL_SLOT.set(&editor, false);
    FULL_EDIT_TEXT_SLOT.set(&editor, draft_value.clone());
    assert_eq!(copy_value_text(editor.upcast_ref(), Some(&draft), 0), draft_value);
}

#[test]
#[ignore = "requires an isolated GTK display"]
fn view_value_resolves_pending_text_null_and_draft_values_from_the_cell() {
    gtk::init().unwrap();
    let editor = crate::ui::cell_editor::CellEditor::new();
    let widget = editor.upcast_ref::<gtk::Widget>();
    let pending = "new value".repeat(1_200);
    IS_NULL_SLOT.set(&editor, false);
    FULL_EDIT_TEXT_SLOT.set(&editor, pending.clone());
    assert_eq!(pending_cell_value(widget), Some(Value::Text(pending.clone())));

    IS_NULL_SLOT.set(&editor, true);
    FULL_EDIT_TEXT_SLOT.take(&editor);
    assert_eq!(pending_cell_value(widget), Some(Value::Null));

    IS_NULL_SLOT.set(&editor, false);
    assert_eq!(pending_cell_value(widget), None);

    FULL_EDIT_TEXT_SLOT.set(&editor, pending.clone());
    assert_eq!(pending_cell_value(widget), Some(Value::Text(pending)));
}

#[test]
fn export_rows_refuse_an_incomplete_page() {
    assert!(complete_rows([Some(vec![Value::Int(1)]), None].into_iter()).is_none());
    assert_eq!(
        complete_rows([Some(vec![Value::Int(1)])].into_iter()),
        Some(vec![vec![Value::Int(1)]])
    );
}

#[test]
fn full_value_edit_requires_a_persisted_key_or_a_draft_identity() {
    assert!(!has_persisted_row_key(&[]));
    assert!(!has_persisted_row_key(&[Value::Undecodable("text".into())]));
    assert!(has_persisted_row_key(&[Value::Int(7)]));
}

#[test]
#[ignore = "requires an isolated GTK display"]
fn the_cell_menu_opens_with_the_menu_key_and_shift_f10() {
    relm4::adw::init().unwrap();
    let trigger = crate::ui::shortcut::parse(CELL_MENU_TRIGGER);
    assert!(!trigger.is::<gtk::NeverTrigger>());
    let text = trigger.to_str().to_string();
    assert!(text.contains("Menu"), "{text}");
    assert!(text.contains("<Shift>F10"), "{text}");
    keyboard_reference_state_follows_current_cell();
    keyboard_menus_preserve_editing_and_checkbox_targets();
    pointer_menu_uses_target_and_current_row();
}

fn keyboard_reference_state_follows_current_cell() {
    let (window, label, menus, local) = keyboard_menu_fixture();
    let view = label
        .ancestor(gtk::ColumnView::static_type())
        .and_downcast::<gtk::ColumnView>()
        .unwrap();
    assert!(menu_shortcuts(label.upcast_ref()).is_empty());
    let controllers = label.observe_controllers();
    assert!(!(0..controllers.n_items()).any(|index| {
        controllers
            .item(index)
            .and_downcast::<gtk::GestureClick>()
            .is_some_and(|gesture| gesture.button() == gtk::gdk::BUTTON_SECONDARY)
    }));
    let shortcuts = menu_shortcuts(view.upcast_ref());
    assert_eq!(shortcuts.len(), 1);
    let action = shortcuts[0].action().unwrap();
    let cell = label.parent().unwrap();
    assert!(cell.grab_focus());
    menus.reference_action.set_enabled(false);
    assert!(action.activate(gtk::ShortcutActionFlags::empty(), &view, None));
    assert!(menus.reference_action.is_enabled());
    assert_eq!(
        menus.context.snapshot().unwrap().widget,
        label.clone().upcast::<gtk::Widget>()
    );
    let export = &menus.export_loaded.as_ref().unwrap().0;
    assert!(!export.is_enabled());
    menus.readonly_popover.popdown();
    local.filter_by_value(0, Value::Int(7));
    assert!(cell.grab_focus());
    assert!(action.activate(gtk::ShortcutActionFlags::empty(), &view, None));
    assert!(export.is_enabled());
    local.clear_filter();
    menus.readonly_popover.popdown();
    POSITION_SLOT.set(&label, 1);
    assert!(cell.grab_focus());
    assert!(action.activate(gtk::ShortcutActionFlags::empty(), &view, None));
    assert!(!menus.reference_action.is_enabled());
    assert!(!export.is_enabled());
    menus.readonly_popover.popdown();
    let outside = window.child().unwrap().last_child().unwrap();
    assert!(outside.grab_focus());
    assert!(!action.activate(gtk::ShortcutActionFlags::empty(), &view, None));
    window.close();
}

fn keyboard_menu_fixture() -> (gtk::Window, gtk::Label, GridMenus, LocalResultView) {
    let rows = gio::ListStore::new::<crate::ui::row_object::RowObject>();
    rows.append(&crate::ui::row_object::RowObject::new(vec![Value::Int(7)]));
    rows.append(&crate::ui::row_object::RowObject::new(vec![Value::Null]));
    let view = gtk::ColumnView::new(Some(gtk::MultiSelection::new(Some(rows))));
    let (sender, _receiver) = relm4::channel();
    let local = local_result_for_menu();
    let menus = install_grid_context_menus(
        &view,
        sender,
        &[],
        false,
        "sqlite".into(),
        GridMenuOptions {
            filterable: false,
            row_mutations_allowed: false,
            foreign_key_columns: ["linked".into()].into(),
            local_result_view: Some(local.clone()),
        },
    );
    let cells = Rc::new(std::cell::RefCell::new(Vec::new()));
    let factory = keyboard_menu_factory(&menus, cells.clone());
    view.append_column(&gtk::ColumnViewColumn::new(None, Some(factory)));
    let content = gtk::Box::new(gtk::Orientation::Vertical, 0);
    content.append(&view);
    content.append(&gtk::Button::with_label("Outside grid"));
    let window = gtk::Window::builder()
        .child(&content)
        .default_width(400)
        .default_height(300)
        .build();
    window.present();
    for _ in 0..200 {
        while glib::MainContext::default().iteration(false) {}
        if cells.borrow().iter().any(|cell: &gtk::Label| cell.is_mapped()) {
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(10));
    }
    let label = cells
        .borrow()
        .iter()
        .find(|cell| POSITION_SLOT.get(*cell) == Some(0))
        .unwrap()
        .clone();
    (window, label, menus, local)
}

fn keyboard_menu_factory(
    menus: &GridMenus,
    cells: Rc<std::cell::RefCell<Vec<gtk::Label>>>,
) -> gtk::SignalListItemFactory {
    let factory = gtk::SignalListItemFactory::new();
    let menus = menus.clone();
    factory.connect_setup(move |_, item| {
        let item = item.downcast_ref::<gtk::ListItem>().unwrap();
        super::super::editing::setup_readonly_cell(item, 0, "linked".into(), None, Some(&menus));
        cells
            .borrow_mut()
            .push(item.child().and_downcast::<gtk::Label>().unwrap());
    });
    factory.connect_bind(|_, item| {
        let item = item.downcast_ref::<gtk::ListItem>().unwrap();
        let child = item.child().unwrap();
        POSITION_SLOT.set(&child, item.position());
        super::super::editing::sync_readonly_cell_focus(&child.downcast::<gtk::Label>().unwrap());
    });
    factory
}

fn local_result_for_menu() -> LocalResultView {
    LocalResultView::new(
        std::sync::Arc::new(QueryResult {
            columns: Vec::new(),
            rows: vec![vec![Value::Int(7)]],
            truncated: false,
        }),
        super::super::local_filter::LocalResultSettingsStore::default(),
        super::super::local_filter::ResultViewKey {
            statement_identity: crate::ui::editor::StatementIdentity {
                statement_index: 0,
                digest: [0; 32],
            },
            result_set_index: 0,
        },
    )
}

fn menu_shortcuts(widget: &gtk::Widget) -> Vec<gtk::Shortcut> {
    let controllers = widget.observe_controllers();
    (0..controllers.n_items())
        .filter_map(|index| controllers.item(index)?.downcast::<gtk::ShortcutController>().ok())
        .flat_map(|controller| {
            (0..controller.n_items())
                .filter_map(|index| controller.item(index)?.downcast::<gtk::Shortcut>().ok())
                .collect::<Vec<_>>()
        })
        .filter(|shortcut| {
            shortcut
                .action()
                .is_some_and(|action| action.is::<gtk::CallbackAction>())
                && shortcut.trigger().is_some_and(|trigger| {
                    let text = trigger.to_str();
                    text.contains("Menu") && text.contains("<Shift>F10")
                })
        })
        .collect()
}

fn keyboard_menus_preserve_editing_and_checkbox_targets() {
    let (window, label, menus, _local) = keyboard_menu_fixture();
    let view = label
        .ancestor(gtk::ColumnView::static_type())
        .and_downcast::<gtk::ColumnView>()
        .unwrap();
    let rows = gio::ListStore::new::<crate::ui::row_object::RowObject>();
    rows.append(&crate::ui::row_object::RowObject::new(vec![
        Value::Int(7),
        Value::Text("alpha".into()),
        Value::Bool(false),
    ]));
    view.set_model(Some(&gtk::SingleSelection::new(Some(rows))));
    let editor = crate::ui::cell_editor::CellEditor::new();
    editor.set_text("alpha");
    editor.set_inline_editable(true);
    super::super::display::COLUMN_SLOT.set(&editor, 1);
    let checkbox = gtk::CheckButton::new();
    super::super::display::COLUMN_SLOT.set(&checkbox, 2);
    append_menu_widget(&view, editor.clone().upcast());
    append_menu_widget(&view, checkbox.clone().upcast());
    for _ in 0..200 {
        while glib::MainContext::default().iteration(false) {}
        if editor.is_mapped() && checkbox.is_mapped() {
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(10));
    }
    let action = menu_shortcuts(view.upcast_ref())[0].action().unwrap();
    assert!(menu_shortcuts(editor.upcast_ref()).is_empty());
    assert!(menu_shortcuts(checkbox.upcast_ref()).is_empty());
    let editor_cell = editor.parent().unwrap();
    editor_cell.set_focusable(true);
    assert!(editor_cell.grab_focus());
    assert!(action.activate(gtk::ShortcutActionFlags::empty(), &view, None));
    assert_eq!(
        menus.context.snapshot().unwrap().widget,
        editor.clone().upcast::<gtk::Widget>()
    );
    assert!(menus.edit_action.is_enabled());
    menus.editable_popover.popdown();
    for _ in 0..20 {
        while glib::MainContext::default().iteration(false) {}
        std::thread::sleep(std::time::Duration::from_millis(10));
    }
    editor.start_editing();
    assert!(editor.is_editing());
    for _ in 0..20 {
        while glib::MainContext::default().iteration(false) {}
        std::thread::sleep(std::time::Duration::from_millis(10));
    }
    assert!(editor.is_editing());
    let bounds = editor.compute_bounds(&view).unwrap();
    let picked = view
        .pick(
            f64::from(bounds.x() + bounds.width() / 2.0),
            f64::from(bounds.y() + bounds.height() / 2.0),
            gtk::PickFlags::DEFAULT,
        )
        .unwrap();
    assert!(picked == editor || picked.is_ancestor(&editor));
    assert!(
        pointer_menu::popover_at(
            &view,
            &menus,
            &menus.readonly_popover,
            f64::from(bounds.x() + bounds.width() / 2.0),
            f64::from(bounds.y() + bounds.height() / 2.0),
        )
        .is_none()
    );
    assert!(!action.activate(gtk::ShortcutActionFlags::empty(), &view, None));
    editor.stop_editing(false);
    assert!(checkbox.grab_focus());
    assert!(action.activate(gtk::ShortcutActionFlags::empty(), &view, None));
    assert_eq!(
        menus.context.snapshot().unwrap().widget,
        checkbox.clone().upcast::<gtk::Widget>()
    );
    assert!(!menus.edit_action.is_enabled());
    menus.editable_popover.popdown();
    window.close();
}

fn append_menu_widget(view: &gtk::ColumnView, widget: gtk::Widget) {
    let factory = gtk::SignalListItemFactory::new();
    factory.connect_setup(move |_, item| {
        let item = item.downcast_ref::<gtk::ListItem>().unwrap();
        let idx = super::super::display::COLUMN_SLOT.get(&widget).unwrap();
        POSITION_SLOT.set(&widget, 0);
        set_cell_menu_options(
            &widget,
            CellGestureOptions {
                idx,
                column_name: format!("c{idx}"),
                is_editable: true,
                is_text_editable: widget.is::<crate::ui::cell_editor::CellEditor>(),
                supports_full_value: false,
            },
        );
        item.set_child(Some(&widget));
    });
    view.append_column(&gtk::ColumnViewColumn::new(Some("Fixture"), Some(factory)));
}

fn pointer_menu_uses_target_and_current_row() {
    let (window, label, menus, _) = keyboard_menu_fixture();
    let view = label
        .ancestor(gtk::ColumnView::static_type())
        .and_downcast::<gtk::ColumnView>()
        .unwrap();
    let outside = window.child().unwrap().last_child().unwrap();
    assert!(outside.grab_focus());
    let bounds = label.compute_bounds(&view).unwrap();
    let x = f64::from(bounds.x() + bounds.width() / 2.0);
    let y = f64::from(bounds.y() + bounds.height() / 2.0);
    let empty = gtk::PopoverMenu::from_model(None::<&gio::Menu>);
    let popover = pointer_menu::popover_at(&view, &menus, &empty, x, y).unwrap();
    assert_eq!(popover, menus.readonly_popover);
    assert_eq!(
        menus.context.snapshot().unwrap().widget,
        label.clone().upcast::<gtk::Widget>()
    );
    assert!(menus.reference_action.is_enabled());
    POSITION_SLOT.set(&label, 1);
    assert!(pointer_menu::popover_at(&view, &menus, &empty, x, y).is_some());
    assert!(!menus.reference_action.is_enabled());
    assert!(pointer_menu::popover_at(&view, &menus, &empty, -10.0, -10.0).is_none());
    assert!(label.is_selectable());
    window.close();
}
