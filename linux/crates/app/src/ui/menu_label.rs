/// A GtkPopoverMenu reads an underscore in a label as a mnemonic, so a
/// name the user or the database chose keeps its underscores by
/// doubling them.
pub(crate) fn menu_label(text: &str) -> String {
    text.replace('_', "__")
}

#[cfg(test)]
mod tests {
    use super::menu_label;

    #[test]
    fn underscores_are_doubled_and_nothing_else_changes() {
        assert_eq!(menu_label("account_id"), "account__id");
        assert_eq!(menu_label("__x"), "____x");
        assert_eq!(menu_label("Sales Q1"), "Sales Q1");
    }
}
