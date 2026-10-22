use super::*;

#[test]
#[ignore = "requires an isolated GTK display"]
fn a_failed_statement_offers_a_copy_button() {
    use relm4::gtk::prelude::*;
    relm4::adw::init().unwrap();
    let page = super::super::error_page(0, &"syntax error at position 8".into());
    let mut widgets = vec![page.upcast::<relm4::gtk::Widget>()];
    let mut copy = false;
    let mut audit = false;
    let mut description = false;
    while let Some(widget) = widgets.pop() {
        if let Some(button) = widget.downcast_ref::<relm4::gtk::Button>() {
            copy |= button.label().as_deref() == Some("Copy error");
            audit |= button.action_name().as_deref() == Some("win.show-audit");
        }
        if let Some(label) = widget.downcast_ref::<relm4::gtk::Label>() {
            description |= label.text() == "syntax error at position 8";
        }
        let mut child = widget.first_child();
        while let Some(next) = child {
            child = next.next_sibling();
            widgets.push(next);
        }
    }
    assert!(copy);
    assert!(audit);
    assert!(description);
}

pub(super) fn contains_label(widget: &gtk::Widget, text: &str) -> bool {
    if let Some(label) = widget.downcast_ref::<gtk::Label>()
        && label.text() == text
    {
        return true;
    }
    let mut child = widget.first_child();
    while let Some(widget) = child {
        if contains_label(&widget, text) {
            return true;
        }
        child = widget.next_sibling();
    }
    false
}
