//! A whole database or schema as one SQL file: what each engine's
//! catalog says, in the order a restore needs it, and every table's rows
//! as INSERTs. The engine's parts are its driver's `read_dump_catalog`
//! and its dialect's `DumpDialect`.

mod dump_catalog;
mod dump_dialect;
mod dump_order;
mod dump_writer;
mod gzip_chunks;
mod insert_batch;

pub use dump_catalog::{
    DumpCatalog, DumpObject, DumpObjectKind, DumpScope, DumpSection, DumpSkip, DumpSkipReason, DumpStatement, DumpTable,
};
pub use dump_dialect::DumpDialect;
pub use dump_writer::{
    DumpError, DumpOutput, DumpOutputClosed, DumpProgress, DumpReport, DumpRequest, OmittedValues, write_dump,
};
pub use gzip_chunks::GzipChunks;
