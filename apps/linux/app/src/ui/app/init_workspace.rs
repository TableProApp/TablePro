use relm4::factory::FactoryVecDeque;
use relm4::gtk::prelude::*;
use relm4::prelude::*;
use relm4::{adw, gtk};

use crate::ui::connection_row::{ConnectionRow, ConnectionRowOutput};

use super::types::StatusKind;
use super::{App, AppMsg, AppWidgets};

/// The saved-connections popover contents and the workspace outer
/// stack. Both are imperative chrome hung off widgets the `view!`
/// macro declares, so they cannot live in the macro itself.
pub(super) struct WorkspaceChromeParts {
    pub(super) connections_factory: FactoryVecDeque<ConnectionRow>,
    pub(super) outer_stack: gtk::Stack,
}

pub(super) fn build_workspace_chrome(widgets: &AppWidgets, sender: &ComponentSender<App>) -> WorkspaceChromeParts {
    let connections_factory: FactoryVecDeque<ConnectionRow> = FactoryVecDeque::builder()
        .launch(
            gtk::ListBox::builder()
                .selection_mode(gtk::SelectionMode::None)
                .css_classes(["boxed-list"])
                .build(),
        )
        .forward(sender.input_sender(), |out| match out {
            ConnectionRowOutput::Open(saved) => AppMsg::OpenSaved(saved),
            ConnectionRowOutput::ToggleFavorite(id) => AppMsg::ToggleConnectionFavorite(id),
            ConnectionRowOutput::Organize(saved) => AppMsg::OrganizeConnection(saved),
            ConnectionRowOutput::Edit(saved) => AppMsg::EditConnection(saved),
            ConnectionRowOutput::Duplicate(id) => AppMsg::DuplicateConnection(id),
            ConnectionRowOutput::Delete(id) => AppMsg::DeleteConnection(id),
        });

    // The SplitButton's tooltip already labels the popover, so we drop
    // the in-popover "Saved Connections" header that previously sat
    // above the list. Explicit width_request prevents AdwSplitButton's
    // narrow dropdown trigger from constraining the popover width
    // (which produced mid-word hyphenation of connection names).
    let popover_content = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(0)
        .margin_top(6)
        .margin_bottom(6)
        .margin_start(6)
        .margin_end(6)
        .width_request(320)
        .build();

    let scroll = gtk::ScrolledWindow::builder()
        .child(connections_factory.widget())
        .min_content_width(320)
        .min_content_height(120)
        .max_content_height(400)
        .propagate_natural_height(true)
        .hscrollbar_policy(gtk::PolicyType::Never)
        .build();
    popover_content.append(&scroll);
    widgets.connections_popover.set_child(Some(&popover_content));

    // Workspace outer stack: swaps between an empty StatusPage
    // ("Select a table") when no tabs are open and the unified
    // AdwTabOverview hosting both Browse and Editor tabs. The
    // tab tree itself is built lazily on connect via
    // `ensure_workspace_root` in app/workspace_tabs.rs.
    let workspace_outer_stack = gtk::Stack::builder()
        .transition_type(gtk::StackTransitionType::Crossfade)
        .build();
    // CTA button parented inside the empty-state status page so
    // the "open editor" affordance is reachable with the mouse —
    // without it the only path was the keyboard shortcut and the
    // tab-bar "+", and the tab bar is hidden in this empty state.
    let workspace_empty_cta = gtk::Button::builder()
        .label(crate::tr!("Open SQL editor"))
        .action_name("win.open-editor")
        .halign(gtk::Align::Center)
        .build();
    workspace_empty_cta.add_css_class("suggested-action");
    workspace_empty_cta.add_css_class("pill");
    let workspace_empty_page = adw::StatusPage::builder()
        .icon_name(StatusKind::Info.icon())
        .title(crate::tr!("Select a table"))
        .description(crate::tr!(
            "Pick a table from the sidebar, or use the button below (Ctrl+T)."
        ))
        .child(&workspace_empty_cta)
        .build();
    workspace_outer_stack.add_named(&workspace_empty_page, Some("empty"));
    workspace_outer_stack.set_visible_child_name("empty");
    WorkspaceChromeParts {
        connections_factory,
        outer_stack: workspace_outer_stack,
    }
}
