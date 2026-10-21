use relm4::gtk;
use relm4::gtk::prelude::*;

pub(in crate::ui::editor) fn build(pages: &gtk::Notebook) -> gtk::Box {
    pages.set_show_tabs(false);
    pages.set_show_border(false);
    let controls = gtk::Box::new(gtk::Orientation::Horizontal, 12);
    controls.set_halign(gtk::Align::Center);
    let previous = gtk::Button::with_label(&crate::tr!("Previous page"));
    let range = gtk::Label::new(None);
    let next = gtk::Button::with_label(&crate::tr!("Next page"));
    previous.connect_clicked({
        let pages = pages.downgrade();
        move |_| {
            if let Some(pages) = pages.upgrade() {
                pages.prev_page();
            }
        }
    });
    next.connect_clicked({
        let pages = pages.downgrade();
        move |_| {
            if let Some(pages) = pages.upgrade() {
                pages.next_page();
            }
        }
    });
    update(pages, &previous, &range, &next);
    pages.connect_page_notify({
        let (previous, range, next) = (previous.clone(), range.clone(), next.clone());
        move |pages| update(pages, &previous, &range, &next)
    });
    controls.append(&previous);
    controls.append(&range);
    controls.append(&next);
    controls
}

fn update(pages: &gtk::Notebook, previous: &gtk::Button, range: &gtk::Label, next: &gtk::Button) {
    let current = pages.current_page();
    previous.set_sensitive(current.is_some_and(|index| index > 0));
    next.set_sensitive(current.is_some_and(|index| index.saturating_add(1) < pages.n_pages()));
    let text = current
        .and_then(|index| pages.nth_page(Some(index)))
        .and_then(|page| pages.tab_label_text(&page));
    range.set_text(text.as_deref().unwrap_or_default());
}

#[cfg(test)]
mod tests;
