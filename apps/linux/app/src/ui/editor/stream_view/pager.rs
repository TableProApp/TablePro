use relm4::gtk;
use relm4::gtk::prelude::*;

pub(in crate::ui::editor) fn build(pages: &gtk::Stack) -> gtk::Box {
    let controls = gtk::Box::new(gtk::Orientation::Horizontal, 12);
    controls.set_halign(gtk::Align::Center);
    let previous = gtk::Button::with_label(&crate::tr!("Previous page"));
    let range = gtk::Label::new(None);
    let next = gtk::Button::with_label(&crate::tr!("Next page"));
    previous.connect_clicked({
        let pages = pages.downgrade();
        move |_| {
            if let Some(pages) = pages.upgrade()
                && let Some(child) = pages.visible_child().and_then(|child| child.prev_sibling())
            {
                pages.set_visible_child(&child);
            }
        }
    });
    next.connect_clicked({
        let pages = pages.downgrade();
        move |_| {
            if let Some(pages) = pages.upgrade()
                && let Some(child) = pages.visible_child().and_then(|child| child.next_sibling())
            {
                pages.set_visible_child(&child);
            }
        }
    });
    update(pages, &previous, &range, &next);
    pages.connect_visible_child_notify({
        let (previous, range, next) = (previous.clone(), range.clone(), next.clone());
        move |pages| update(pages, &previous, &range, &next)
    });
    controls.append(&previous);
    controls.append(&range);
    controls.append(&next);
    controls
}

fn update(pages: &gtk::Stack, previous: &gtk::Button, range: &gtk::Label, next: &gtk::Button) {
    let current = pages.visible_child();
    previous.set_sensitive(current.as_ref().and_then(|child| child.prev_sibling()).is_some());
    next.set_sensitive(current.as_ref().and_then(|child| child.next_sibling()).is_some());
    let text = current.map(|child| pages.page(&child)).and_then(|page| page.title());
    range.set_text(text.as_deref().unwrap_or_default());
}

#[cfg(test)]
mod tests;
