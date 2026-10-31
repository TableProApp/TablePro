/// A GtkPopoverMenu reads an underscore in a label as a mnemonic, so a
/// name the user or the database chose keeps its underscores by
/// doubling them.
pub(crate) fn menu_label(text: &str) -> String {
    text.replace('_', "__")
}

#[cfg(test)]
mod tests {
    use gtk4::{self as gtk, gio};

    use super::menu_label;
    use crate::config::RESOURCE_BASE_PATH;
    use crate::test_support::{access_key_problems, menu_pages};

    #[test]
    fn underscores_are_doubled_and_nothing_else_changes() {
        assert_eq!(menu_label("account_id"), "account__id");
        assert_eq!(menu_label("__x"), "____x");
        assert_eq!(menu_label("Sales Q1"), "Sales Q1");
    }

    fn ui_files(folder: &str) -> Vec<String> {
        let names = gio::resources_enumerate_children(folder, gio::ResourceLookupFlags::NONE).expect("the folder");
        names
            .iter()
            .flat_map(|name| match name.strip_suffix('/') {
                Some(inner) => ui_files(&format!("{folder}/{inner}")),
                None if name.ends_with(".ui") => vec![format!("{folder}/{name}")],
                None => Vec::new(),
            })
            .collect()
    }

    // A template's class is not registered here, so only the menus are built.
    fn menus(ui: &str) -> Vec<(&str, &str)> {
        let mut found = Vec::new();
        let mut rest = ui;
        while let Some(start) = rest.find("<menu id=\"") {
            let id_start = start + "<menu id=\"".len();
            let id_end = id_start + rest[id_start..].find('"').expect("a closed id");
            let end = start + rest[start..].find("</menu>").expect("a closed menu") + "</menu>".len();
            found.push((&rest[id_start..id_end], &rest[start..end]));
            rest = &rest[end..];
        }
        found
    }

    #[gtk4::test]
    fn every_menu_a_ui_file_holds_gives_each_item_its_own_access_key() {
        crate::register_test_resources();
        let mut checked = Vec::new();

        for path in ui_files(RESOURCE_BASE_PATH) {
            let data = gio::resources_lookup_data(&path, gio::ResourceLookupFlags::NONE).expect("the file");
            let found = menus(std::str::from_utf8(&data).expect("UTF-8"));
            if found.is_empty() {
                continue;
            }
            let elements: String = found.iter().map(|(_, element)| *element).collect();
            let builder = gtk::Builder::new();
            builder
                .add_from_string(&format!("<interface>{elements}</interface>"))
                .expect("the menus build");
            for (id, _) in found {
                let menu = builder.object::<gio::MenuModel>(id).expect("the menu");
                let problems = access_key_problems(&menu_pages(&menu));
                assert!(problems.is_empty(), "{path} {id}: {problems:#?}");
                checked.push(id.to_owned());
            }
        }

        for id in ["primary_menu", "tab_overview_menu", "editor_menu", "options_menu"] {
            assert!(checked.iter().any(|read| read == id), "{id} was not read: {checked:?}");
        }
    }
}
