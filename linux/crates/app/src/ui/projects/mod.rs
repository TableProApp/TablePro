//! Connection projects: the switcher's menu, the dialog that names one
//! and the one that lists them all.

mod manage_projects_dialog;
mod project_menu;
mod project_name_dialog;

pub(crate) use manage_projects_dialog::ManageProjectsDialog;
pub(crate) use project_menu::{
    MANAGE_PROJECTS, NEW_PROJECT, ProjectMenu, SWITCH_PROJECT, all_connections, project_from_target, project_target,
    switcher_menu,
};
pub(crate) use project_name_dialog::ask_new_project;
