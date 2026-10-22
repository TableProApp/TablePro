use std::cell::{Cell, RefCell};
use std::rc::Rc;

use relm4::gtk::prelude::*;
use relm4::{ComponentSender, gtk};

use super::{DropGeneration, SqlEditor, SqlEditorOutput, folding::FoldController};

pub(super) fn install(
    view: &sourceview5::View,
    generation: Rc<DropGeneration>,
    folding: Rc<RefCell<FoldController>>,
    sender: ComponentSender<SqlEditor>,
    refresh: Rc<dyn Fn()>,
) {
    let depth = Rc::new(Cell::new(0u32));
    let pending = Rc::new(Cell::new(false));
    let publish = Rc::new(move |buffer: &gtk::TextBuffer| {
        if let Some(buffer) = buffer.downcast_ref::<sourceview5::Buffer>() {
            folding.borrow_mut().clear(buffer);
        }
        let (start, end) = buffer.bounds();
        let text = buffer.text(&start, &end, true).to_string();
        let _ = sender.output(SqlEditorOutput::QueryChanged(text));
        refresh();
    });
    let buffer = view.buffer();
    let begin_depth = depth.clone();
    buffer.connect_begin_user_action(move |_| begin_depth.set(begin_depth.get().saturating_add(1)));
    let end_depth = depth.clone();
    let end_pending = pending.clone();
    let end_publish = publish.clone();
    buffer.connect_end_user_action(move |buffer| {
        end_depth.set(end_depth.get().saturating_sub(1));
        if end_depth.get() == 0 && end_pending.replace(false) {
            end_publish(buffer);
        }
    });
    buffer.connect_changed(move |buffer| {
        generation.changed();
        if depth.get() > 0 {
            pending.set(true);
            return;
        }
        publish(buffer);
    });
}
