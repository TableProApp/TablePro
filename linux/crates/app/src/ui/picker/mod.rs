//! The connection picker's rows, their menu and the actions they reach.

mod connection_menu;
mod connection_row;
mod new_group_dialog;
mod picker_actions;
#[cfg(test)]
mod tests;

pub(crate) use connection_row::connection_row;
pub(crate) use picker_actions::install_picker_actions;
