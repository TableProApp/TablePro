use adw::prelude::*;
use relm4::{adw, gtk};
use std::{
    cell::{Cell, RefCell},
    rc::Rc,
};
use tablepro_core::sql_diagnostics::{character_range, scan};

pub(super) struct Diagnostics {
    buffer: gtk::TextBuffer,
    handler: Option<glib::SignalHandlerId>,
    timer: Rc<RefCell<Option<glib::SourceId>>>,
    generation: Rc<Cell<u64>>,
}

impl Diagnostics {
    pub fn install(
        view: &sourceview5::View,
        button: &gtk::MenuButton,
        connection_id: Option<uuid::Uuid>,
        database: std::sync::Arc<crate::services::database_service::DatabaseService>,
    ) -> Self {
        let buffer = view.buffer();
        let timer: Rc<RefCell<Option<glib::SourceId>>> = Rc::default();
        let generation = Rc::new(Cell::new(0u64));
        let queue = {
            let timer = timer.clone();
            let generation = generation.clone();
            let view = view.downgrade();
            let button = button.downgrade();
            move |buffer: &gtk::TextBuffer| {
                let version = generation.get().wrapping_add(1);
                generation.set(version);
                if let Some(button) = button.upgrade() {
                    button.set_visible(false);
                    button.set_popover(None::<&gtk::Popover>);
                }
                if let Some(pending) = timer.borrow_mut().take() {
                    pending.remove();
                }
                let (start, end) = buffer.bounds();
                let sql = buffer.text(&start, &end, false).to_string();
                let Some(metadata) = connection_id.and_then(|id| database.metadata(id)) else {
                    return;
                };
                let driver = metadata.driver_id;
                let view = view.clone();
                let button = button.clone();
                let generation = generation.clone();
                let timer_done = timer.clone();
                *timer.borrow_mut() = Some(glib::timeout_add_local_once(
                    std::time::Duration::from_millis(250),
                    move || {
                        timer_done.borrow_mut().take();
                        let (send, receive) = async_channel::bounded(1);
                        let worker_sql = sql.clone();
                        let worker = std::thread::Builder::new()
                            .name("sql-diagnostics".into())
                            .spawn(move || {
                                let _ = send.send_blocking(scan(&worker_sql, &driver));
                            });
                        if worker.is_err() {
                            return;
                        }
                        glib::spawn_future_local(async move {
                            let Ok(warnings) = receive.recv().await else {
                                return;
                            };
                            if generation.get() != version {
                                return;
                            }
                            let (Some(view), Some(button)) = (view.upgrade(), button.upgrade()) else {
                                return;
                            };
                            if warnings.is_empty() {
                                return;
                            }
                            let list = gtk::Box::builder()
                                .orientation(gtk::Orientation::Vertical)
                                .spacing(4)
                                .build();
                            for warning in &warnings {
                                let Some(range) = character_range(&sql, warning.range.clone()) else {
                                    continue;
                                };
                                let text = crate::tr!("{character} ({code}): consider {suggestion} ({ascii})")
                                    .replace("{character}", &warning.character.to_string())
                                    .replace("{code}", &format!("U+{:04X}", warning.character as u32))
                                    .replace("{suggestion}", &warning.suggestion.to_string())
                                    .replace("{ascii}", &format!("U+{:04X}", warning.suggestion as u32));
                                let item = gtk::Button::with_label(&text);
                                let view = view.downgrade();
                                let generation = generation.clone();
                                let menu = button.downgrade();
                                item.connect_clicked(move |_| {
                                    if generation.get() != version {
                                        return;
                                    }
                                    if let Some(view) = view.upgrade() {
                                        let buffer = view.buffer();
                                        let mut start = buffer.iter_at_offset(range.start);
                                        let end = buffer.iter_at_offset(range.end);
                                        buffer.select_range(&start, &end);
                                        view.scroll_to_iter(&mut start, 0.1, false, 0.0, 0.0);
                                        view.grab_focus();
                                    }
                                    if let Some(menu) = menu.upgrade() {
                                        menu.popdown();
                                    }
                                });
                                list.append(&item);
                            }
                            let scrolled = gtk::ScrolledWindow::builder()
                                .child(&list)
                                .max_content_height(300)
                                .propagate_natural_height(true)
                                .min_content_width(360)
                                .build();
                            let popover = gtk::Popover::builder().child(&scrolled).build();
                            button.set_popover(Some(&popover));
                            button.set_label(
                                &crate::tr!("SQL warnings ({n})").replace("{n}", &warnings.len().to_string()),
                            );
                            button.set_visible(true);
                        });
                    },
                ));
            }
        };
        queue(&buffer);
        let handler = buffer.connect_changed(queue);
        Self {
            buffer,
            handler: Some(handler),
            timer,
            generation,
        }
    }

    pub fn stop(&mut self) {
        self.generation.set(self.generation.get().wrapping_add(1));
        if let Some(timer) = self.timer.borrow_mut().take() {
            timer.remove();
        }
        if let Some(handler) = self.handler.take() {
            self.buffer.disconnect(handler);
        }
    }
}

impl Drop for Diagnostics {
    fn drop(&mut self) {
        self.stop();
    }
}
