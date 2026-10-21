use super::*;

#[test]
#[ignore = "requires an isolated GTK display"]
fn pager_navigates_retained_pages_and_status_without_retaining_its_notebook() {
    gtk::init().unwrap();
    let pages = gtk::Notebook::new();
    for title in ["Rows 6-7", "Rows 8-8", "Status"] {
        pages.append_page(
            &gtk::Box::new(gtk::Orientation::Vertical, 0),
            Some(&gtk::Label::new(Some(title))),
        );
    }
    pages.set_current_page(Some(0));
    let controls = build(&pages);
    let previous = controls.first_child().unwrap().downcast::<gtk::Button>().unwrap();
    let range = previous.next_sibling().unwrap().downcast::<gtk::Label>().unwrap();
    let next = controls.last_child().unwrap().downcast::<gtk::Button>().unwrap();
    assert!(!pages.shows_tabs());
    assert!(!previous.is_sensitive());
    assert!(next.is_sensitive());
    assert_eq!(range.text(), "Rows 6-7");
    next.emit_clicked();
    assert_eq!(pages.current_page(), Some(1));
    assert_eq!(range.text(), "Rows 8-8");
    next.emit_clicked();
    assert_eq!(range.text(), "Status");
    assert!(!next.is_sensitive());
    previous.emit_clicked();
    assert_eq!(range.text(), "Rows 8-8");
    pages.remove_page(Some(0));
    pages.notify("page");
    assert!(!previous.is_sensitive());
    assert_eq!(range.text(), "Rows 8-8");
    let owner = pages.downgrade();
    drop(pages);
    assert!(owner.upgrade().is_none());
}
