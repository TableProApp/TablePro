//! What the catalogue says about a database: its schemas, its objects,
//! and how a row in a table can be named again after it was read.

mod index_info;
mod object_info;
mod page;
mod row_identity;
mod schema_info;
mod table_estimate;
mod table_ref;

pub use index_info::{IndexInfo, IndexKey};
pub use object_info::{ObjectInfo, ObjectKind};
pub use page::{PageCost, PagePosition, PageStability};
pub use row_identity::{EngineRowId, EngineRowIdPart, RowIdentity};
pub use schema_info::{ObjectScope, SchemaInfo};
pub use table_estimate::{RowCountEstimate, TableEstimate};
pub use table_ref::TableRef;
