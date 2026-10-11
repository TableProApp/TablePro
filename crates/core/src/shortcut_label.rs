#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BrowseShortcut {
    pub accelerator: &'static str,
    pub visible_key: &'static str,
    pub item_accelerator: &'static str,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BrowseDrawnShortcuts {
    pub previous_cell: BrowseShortcut,
    pub next_cell: BrowseShortcut,
    pub toggle_boolean: BrowseShortcut,
    pub extend_selection: BrowseShortcut,
    pub toggle_selection: BrowseShortcut,
}

impl BrowseDrawnShortcuts {
    pub fn entries(self) -> [BrowseShortcut; 5] {
        [
            self.previous_cell,
            self.next_cell,
            self.toggle_boolean,
            self.extend_selection,
            self.toggle_selection,
        ]
    }
}

pub fn browse_drawn_shortcuts() -> BrowseDrawnShortcuts {
    BrowseDrawnShortcuts {
        previous_cell: named("Left"),
        next_cell: named("Right"),
        toggle_boolean: named("space"),
        extend_selection: named("Shift-click"),
        toggle_selection: named("Ctrl-click"),
    }
}

pub fn browse_item_accelerator(accelerator: &str) -> Option<&'static str> {
    presented(accelerator).map(|shortcut| shortcut.item_accelerator)
}

pub fn browse_visible_key(accelerator: &str) -> Option<&'static str> {
    presented(accelerator).map(|shortcut| shortcut.visible_key)
}

fn named(key: &'static str) -> BrowseShortcut {
    BrowseShortcut {
        accelerator: key,
        visible_key: key,
        item_accelerator: "",
    }
}

fn presented(accelerator: &str) -> Option<BrowseShortcut> {
    browse_drawn_shortcuts()
        .entries()
        .into_iter()
        .find(|shortcut| shortcut.accelerator == accelerator)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn browse_shortcuts_name_the_keys_the_grid_uses() {
        let drawn = browse_drawn_shortcuts();
        let shortcuts = drawn.entries();
        assert_eq!(
            shortcuts.map(|shortcut| shortcut.accelerator),
            ["Left", "Right", "space", "Shift-click", "Ctrl-click"]
        );
        for shortcut in shortcuts {
            assert_eq!(shortcut.visible_key, shortcut.accelerator);
            assert_eq!(shortcut.item_accelerator, "");
            assert_eq!(browse_visible_key(shortcut.accelerator), Some(shortcut.visible_key));
            assert_eq!(
                browse_item_accelerator(shortcut.accelerator),
                Some(shortcut.item_accelerator)
            );
            assert!(!shortcut.accelerator.contains("KP_"));
            assert!(!shortcut.accelerator.contains("Shift_L"));
            assert!(!shortcut.accelerator.contains("Control_L"));
            assert!(!shortcut.accelerator.contains("Pointer_Button"));
        }
        assert_eq!(browse_item_accelerator("F2"), None);
        assert_eq!(browse_visible_key("Return"), None);
    }
}
