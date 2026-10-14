use gtk4 as gtk;

use super::ShortcutOwner;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AcceleratorScope {
    /// Installed with `set_accels_for_action`. GtkWindow runs these in a
    /// capture-phase, global controller, so they reach the window before
    /// the focused widget does.
    Application,
    /// Installed by `local_shortcut_controller` on the owner's widget.
    Local {
        owner: ShortcutOwner,
        phase: gtk::PropagationPhase,
    },
    /// Bound by the owner's own controller, which reads its keys from the
    /// table.
    Component(ShortcutOwner),
    /// Bound by a GTK or libadwaita class, or by AdwApplication. Listed
    /// and checked for collisions, never installed.
    Stock,
}
