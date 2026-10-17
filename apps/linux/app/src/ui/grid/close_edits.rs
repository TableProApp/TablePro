use gtk4::prelude::*;

use super::display::{POPOVER_SLOT, PREEDIT_SLOT};
use crate::ui::cell_editor::CellEditor;

pub(crate) fn finish_active_edits(root: &impl IsA<gtk4::Widget>) -> bool {
    let mut widgets = vec![root.as_ref().clone()];
    let mut editors = Vec::new();
    while let Some(widget) = widgets.pop() {
        if let Some(editor) = widget.downcast_ref::<CellEditor>() {
            if PREEDIT_SLOT.get(editor).unwrap_or(false)
                || POPOVER_SLOT.cloned(editor).is_some_and(|popover| popover.is_visible())
            {
                return false;
            }
            if editor.is_editing() {
                editors.push(editor.clone());
            }
        }
        let mut child = widget.first_child();
        while let Some(current) = child {
            child = current.next_sibling();
            widgets.push(current);
        }
    }
    if let Some(window) = root.as_ref().downcast_ref::<gtk4::Window>() {
        gtk4::prelude::GtkWindowExt::set_focus(window, None::<&gtk4::Widget>);
    }
    for editor in editors {
        if editor.is_editing() {
            editor.stop_editing(true);
        }
    }
    true
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::Cell;
    use std::rc::Rc;

    fn editor_window() -> (gtk4::Window, CellEditor) {
        gtk4::init().unwrap();
        let editor = CellEditor::new();
        editor.set_inline_editable(true);
        editor.set_text("before");
        let window = gtk4::Window::builder().child(&editor).build();
        window.present();
        editor.start_editing();
        editor.entry().set_text("after");
        (window, editor)
    }

    #[test]
    #[ignore = "requires isolated GTK display"]
    fn finishing_an_inline_edit_keeps_its_field_parented_and_commits_once() {
        let (window, editor) = editor_window();
        let finished = Rc::new(Cell::new(0));
        let seen = finished.clone();
        editor.connect_editing_notify(move |editor| {
            if !editor.is_editing() {
                seen.set(seen.get() + 1);
            }
        });
        assert!(finish_active_edits(&window));
        assert!(!editor.is_editing());
        assert_eq!(editor.text().as_str(), "after");
        assert!(editor.entry().parent().is_some());
        assert!(finish_active_edits(&window));
        assert_eq!(finished.get(), 1);
        window.close();
    }

    #[test]
    #[ignore = "requires isolated GTK display"]
    fn an_active_preedit_is_refused_without_hiding_or_replacing_the_edit() {
        let (window, editor) = editor_window();
        PREEDIT_SLOT.set(&editor, true);
        assert!(!finish_active_edits(&window));
        assert!(editor.is_editing());
        assert_eq!(editor.text().as_str(), "after");
        PREEDIT_SLOT.set(&editor, false);
        editor.stop_editing(false);
        window.close();
    }
}
