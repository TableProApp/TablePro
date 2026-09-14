use gtk4::prelude::*;

pub(crate) fn descendants(root: &impl IsA<gtk4::Widget>) -> Vec<gtk4::Widget> {
    let mut found = Vec::new();
    let mut pending: Vec<gtk4::Widget> = root.as_ref().first_child().into_iter().collect();
    while let Some(widget) = pending.pop() {
        if let Some(sibling) = widget.next_sibling() {
            pending.push(sibling);
        }
        if let Some(child) = widget.first_child() {
            pending.push(child);
        }
        found.push(widget);
    }
    found
}

pub(crate) fn find_by_action_name(root: &impl IsA<gtk4::Widget>, name: &str) -> Option<gtk4::Widget> {
    descendants(root).into_iter().find(|widget| {
        widget
            .dynamic_cast_ref::<gtk4::Actionable>()
            .and_then(ActionableExt::action_name)
            .is_some_and(|action| action == name)
    })
}

pub(crate) fn first_descendant_of_type<T: IsA<gtk4::Widget>>(root: &impl IsA<gtk4::Widget>) -> Option<T> {
    descendants(root)
        .into_iter()
        .find_map(|widget| widget.downcast::<T>().ok())
}
