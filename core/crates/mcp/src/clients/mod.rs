// What it takes to set up an MCP client: the catalog both apps ship, the
// entry each client needs, edits to its config file, and whether the
// file already reaches this server. No sentences live here; each app
// words the codes and states itself.

mod catalog;
mod config_edit;
mod json_value;
mod jsonc;
mod merge;
mod paths;
mod status;
mod template;
mod toml_table;

pub use catalog::{
    Applies, CatalogError, CliInstall, CliUpdate, ClientCatalog, ClientDefinition, ClientInfoNames, ClientPlatform,
    ConfigFormat, ConfigLocation, DeeplinkInstall, DetectRule, InstallMethod, PlatformSpec, SCHEMA_VERSION,
    UnsupportedReason,
};
pub use config_edit::{ConfigEditError, members_in_scope, read_member, remove_member, upsert_member};
pub use json_value::JsonValue;
pub use paths::expand_path;
pub use status::{ClientConfigStatus, StaleReason, evaluate_status};
pub use template::{ServerTarget, TemplateError, TemplateRenderer, command_line, snippet};
