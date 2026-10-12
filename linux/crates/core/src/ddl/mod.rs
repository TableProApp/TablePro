//! The model of a table that structure changes are planned against.

mod collation_name;
mod column_attributes;
mod column_definition;
mod column_key_roles;
mod column_visibility;
mod generated_column;
mod identity_style;
mod inbound_foreign_key;
mod primary_key_constraint;
mod referential_action;
mod schema_object_source;
mod table_definition;
mod table_source;
mod unmodeled_attribute;

pub use collation_name::CollationName;
pub use column_attributes::ColumnAttributes;
pub use column_definition::ColumnDefinition;
pub use column_key_roles::ColumnKeyRoles;
pub use column_visibility::ColumnVisibility;
pub use generated_column::{GeneratedColumn, GeneratedStorage};
pub use identity_style::IdentityStyle;
pub use inbound_foreign_key::InboundForeignKey;
pub use primary_key_constraint::PrimaryKeyConstraint;
pub use referential_action::ReferentialAction;
pub use schema_object_source::{SchemaObjectKind, SchemaObjectSource};
pub use table_definition::TableDefinition;
pub use table_source::TableSource;
pub use unmodeled_attribute::UnmodeledAttribute;
