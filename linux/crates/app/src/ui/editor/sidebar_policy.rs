/// Whether the results list and its toggle show.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct SidebarState {
    pub toggle_visible: bool,
    pub show_sidebar: bool,
}

/// One result needs no list, so the list and its toggle appear with
/// the second. While the pane is wide the list opens by itself the
/// moment it has something to choose between; while it is collapsed
/// over the result, opening it is left to the user.
pub fn decide(entries: usize, collapsed: bool, previous: SidebarState) -> SidebarState {
    if entries < 2 {
        return SidebarState::default();
    }
    let show_sidebar = if previous.toggle_visible || collapsed {
        previous.show_sidebar
    } else {
        true
    };
    SidebarState {
        toggle_visible: true,
        show_sidebar,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sidebar_policy_single_entry_hides_toggle() {
        for previous in [
            SidebarState::default(),
            SidebarState {
                toggle_visible: true,
                show_sidebar: true,
            },
        ] {
            assert_eq!(decide(1, false, previous), SidebarState::default());
            assert_eq!(decide(0, true, previous), SidebarState::default());
        }
    }

    #[test]
    fn sidebar_policy_two_entries_expanded_shows_list() {
        let shown = decide(2, false, SidebarState::default());
        assert_eq!(
            shown,
            SidebarState {
                toggle_visible: true,
                show_sidebar: true,
            }
        );

        let closed_by_user = SidebarState {
            toggle_visible: true,
            show_sidebar: false,
        };
        assert_eq!(
            decide(3, false, closed_by_user),
            closed_by_user,
            "the list reopened itself"
        );
    }

    #[test]
    fn a_collapsed_pane_leaves_the_list_to_the_user() {
        let state = decide(2, true, SidebarState::default());

        assert!(state.toggle_visible);
        assert!(!state.show_sidebar, "the list covered the result by itself");
    }
}
