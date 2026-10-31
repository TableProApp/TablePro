use gtk4::prelude::*;
use gtk4::{gio, glib};

/// The items one level of a menu shows at once. GtkPopoverMenu runs the
/// sections together and slides a submenu in as a page of its own, headed
/// by its item, whose label keeps the access key.
#[derive(Debug, Default)]
pub(crate) struct MenuPage {
    pub labels: Vec<String>,
}

/// Every page of `menu`, its top level first.
pub(crate) fn menu_pages(menu: &impl IsA<gio::MenuModel>) -> Vec<MenuPage> {
    let mut pages = vec![MenuPage::default()];
    collect(menu.as_ref(), 0, &mut pages);
    pages
}

fn collect(menu: &gio::MenuModel, page: usize, pages: &mut Vec<MenuPage>) {
    for position in 0..menu.n_items() {
        // A section's label is a heading, which GTK shows without a key.
        if let Some(section) = menu.item_link(position, gio::MENU_LINK_SECTION) {
            collect(&section, page, pages);
            continue;
        }
        let label = menu
            .item_attribute_value(position, gio::MENU_ATTRIBUTE_LABEL, Some(glib::VariantTy::STRING))
            .and_then(|label| label.get::<String>());
        if let Some(label) = &label {
            pages[page].labels.push(label.clone());
        }
        if let Some(submenu) = menu.item_link(position, gio::MENU_LINK_SUBMENU) {
            pages.push(MenuPage {
                labels: label.into_iter().collect(),
            });
            let index = pages.len() - 1;
            collect(&submenu, index, pages);
        }
    }
}

/// The characters `label` marks as access keys. A doubled underscore is
/// a literal one.
pub(crate) fn access_keys(label: &str) -> Vec<char> {
    let mut keys = Vec::new();
    let mut chars = label.chars();
    while let Some(c) = chars.next() {
        if c == '_' {
            match chars.next() {
                Some('_') | None => {}
                Some(key) => keys.push(key),
            }
        }
    }
    keys
}

/// Each item that has no access key, or more than one, or the key of
/// another item on its page, as the GNOME HIG asks of every menu.
pub(crate) fn access_key_problems(pages: &[MenuPage]) -> Vec<String> {
    let mut problems = Vec::new();
    for page in pages {
        let mut taken: Vec<(String, &str)> = Vec::new();
        for label in &page.labels {
            let keys = access_keys(label);
            let [key] = keys.as_slice() else {
                problems.push(format!("{label:?} has {} access keys", keys.len()));
                continue;
            };
            let key: String = key.to_lowercase().collect();
            if let Some((_, other)) = taken.iter().find(|(used, _)| *used == key) {
                problems.push(format!("{label:?} has the access key of {other:?}"));
            }
            taken.push((key, label));
        }
    }
    problems
}

pub(crate) fn assert_access_keys(menu: &impl IsA<gio::MenuModel>) {
    let problems = access_key_problems(&menu_pages(menu));
    assert!(problems.is_empty(), "{problems:#?}");
}

#[cfg(test)]
mod tests {
    use super::*;

    fn menu(labels: &[&str]) -> gio::Menu {
        let menu = gio::Menu::new();
        for label in labels {
            menu.append(Some(*label), Some("app.any"));
        }
        menu
    }

    #[test]
    fn a_single_underscore_marks_the_key_and_a_doubled_one_is_text() {
        assert_eq!(access_keys("Sort _Descending"), ['D']);
        assert_eq!(access_keys("in__stock"), Vec::<char>::new());
        assert_eq!(access_keys("_a__b"), ['a']);
        assert_eq!(access_keys("Copy"), Vec::<char>::new());
        assert_eq!(access_keys("_One _Two"), ['O', 'T']);
    }

    #[test]
    fn sections_share_a_page_and_a_submenu_is_its_own() {
        let whole = menu(&["_Copy"]);
        whole.append_section(Some("Heading"), &menu(&["C_lose"]));
        whole.append_submenu(Some("Colu_mn"), &menu(&["_Copy Name"]));

        let pages = menu_pages(&whole);

        let labels: Vec<Vec<&str>> = pages
            .iter()
            .map(|page| page.labels.iter().map(String::as_str).collect())
            .collect();
        assert_eq!(
            labels,
            [vec!["_Copy", "C_lose", "Colu_mn"], vec!["Colu_mn", "_Copy Name"]]
        );
        assert_eq!(access_key_problems(&pages), Vec::<String>::new());
    }

    #[test]
    fn a_missing_a_doubled_and_a_shared_key_are_each_reported() {
        let whole = menu(&["_Copy", "Paste", "_Cut", "_One _Two"]);
        whole.append_submenu(Some("_More"), &menu(&["_Mode"]));

        let problems = access_key_problems(&menu_pages(&whole));

        assert_eq!(
            problems,
            [
                "\"Paste\" has 0 access keys",
                "\"_Cut\" has the access key of \"_Copy\"",
                "\"_One _Two\" has 2 access keys",
                "\"_Mode\" has the access key of \"_More\"",
            ]
        );
    }
}
