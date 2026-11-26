// CloudKit's side of the records: the schema registry, record names and the projection to wire fields. Swift keeps
// CloudKit's operations; the core decides what each record holds (0054).

pub mod library;
mod project;
mod registry;

pub use project::{
    CloudFields, CloudValue, ProjectionError, SCHEMA_VERSION, WireRecord, from_wire, mac_json_bytes, parse_record_name,
    record_name, to_wire,
};
pub use registry::{
    Carries, CloudField, CloudType, RECORD_TYPES, RETIRED_RECORD_TYPES, RecordType, prefix, record_type_named,
    record_type_of,
};

#[cfg(test)]
mod tests;
