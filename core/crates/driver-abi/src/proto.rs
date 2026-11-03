// The messages of tablepro.driver.v1, written as prost derives so no protoc runs in the build. Field tags are
// the ABI: a tag is never reused or renumbered, and a new kind or field takes the next free tag.

#[derive(Clone, PartialEq, prost::Message)]
pub struct Request {
    #[prost(oneof = "request::Kind", tags = "1, 2, 3, 4, 5, 6, 7")]
    pub kind: Option<request::Kind>,
}

pub mod request {
    #[derive(Clone, PartialEq, prost::Oneof)]
    pub enum Kind {
        #[prost(message, tag = "1")]
        Describe(super::Describe),
        #[prost(message, tag = "2")]
        OpenFile(super::OpenFile),
        #[prost(message, tag = "3")]
        Probe(super::Probe),
        #[prost(message, tag = "4")]
        ListSchemas(super::ListSchemas),
        #[prost(message, tag = "5")]
        ListObjects(super::ListObjects),
        #[prost(message, tag = "6")]
        Read(super::Read),
        #[prost(message, tag = "7")]
        Close(super::Close),
    }
}

impl Request {
    pub fn of(kind: request::Kind) -> Self {
        Self { kind: Some(kind) }
    }
}

#[derive(Clone, PartialEq, prost::Message)]
pub struct Describe {}

#[derive(Clone, PartialEq, prost::Message)]
pub struct OpenFile {
    #[prost(string, tag = "1")]
    pub path: String,
    #[prost(bool, tag = "2")]
    pub create: bool,
    #[prost(bool, tag = "3")]
    pub read_only: bool,
    // Reported to a server beside the application's name, as the app's own connections report it.
    #[prost(string, tag = "4")]
    pub client_version: String,
}

#[derive(Clone, PartialEq, prost::Message)]
pub struct Probe {
    #[prost(uint64, tag = "1")]
    pub connection: u64,
}

#[derive(Clone, PartialEq, prost::Message)]
pub struct ListSchemas {
    #[prost(uint64, tag = "1")]
    pub connection: u64,
}

#[derive(Clone, PartialEq, prost::Message)]
pub struct ListObjects {
    #[prost(uint64, tag = "1")]
    pub connection: u64,
    // None lists the default schema.
    #[prost(string, optional, tag = "2")]
    pub schema: Option<String>,
}

// One statement's first result set, as one Arrow batch.
#[derive(Clone, PartialEq, prost::Message)]
pub struct Read {
    #[prost(uint64, tag = "1")]
    pub connection: u64,
    #[prost(string, tag = "2")]
    pub sql: String,
    // 0 keeps every row.
    #[prost(uint64, tag = "3")]
    pub row_limit: u64,
    // 0 runs without a deadline.
    #[prost(uint64, tag = "4")]
    pub timeout_ms: u64,
}

#[derive(Clone, PartialEq, prost::Message)]
pub struct Close {
    #[prost(uint64, tag = "1")]
    pub connection: u64,
}

#[derive(Clone, PartialEq, prost::Message)]
pub struct Response {
    #[prost(oneof = "response::Kind", tags = "1, 2, 3, 4, 5, 6, 7, 15")]
    pub kind: Option<response::Kind>,
}

pub mod response {
    #[derive(Clone, PartialEq, prost::Oneof)]
    pub enum Kind {
        #[prost(message, tag = "1")]
        Description(super::Description),
        #[prost(message, tag = "2")]
        Opened(super::Opened),
        #[prost(message, tag = "3")]
        Probed(super::Probed),
        #[prost(message, tag = "4")]
        Schemas(super::Schemas),
        #[prost(message, tag = "5")]
        Objects(super::Objects),
        #[prost(message, tag = "6")]
        ReadDone(super::ReadDone),
        #[prost(message, tag = "7")]
        Closed(super::Closed),
        #[prost(message, tag = "15")]
        Error(super::Error),
    }
}

impl Response {
    pub fn of(kind: response::Kind) -> Self {
        Self { kind: Some(kind) }
    }

    pub fn error(code: &str, message: impl Into<String>) -> Self {
        Self::of(response::Kind::Error(Error {
            codes: vec![code.to_owned()],
            message: message.into(),
        }))
    }
}

// The version is the descriptor's, which a host reads before calling the driver ABI.
#[derive(Clone, PartialEq, prost::Message)]
pub struct Description {
    #[prost(string, tag = "1")]
    pub id: String,
    #[prost(string, tag = "2")]
    pub display_name: String,
    #[prost(enumeration = "DataModel", tag = "3")]
    pub data_model: i32,
    #[prost(enumeration = "Category", tag = "4")]
    pub category: i32,
    #[prost(oneof = "description::Endpoint", tags = "5, 6")]
    pub endpoint: Option<description::Endpoint>,
}

pub mod description {
    #[derive(Clone, PartialEq, prost::Oneof)]
    pub enum Endpoint {
        #[prost(message, tag = "5")]
        Network(super::NetworkEndpoint),
        #[prost(message, tag = "6")]
        File(super::FileEndpoint),
    }
}

#[derive(Clone, PartialEq, prost::Message)]
pub struct NetworkEndpoint {
    #[prost(uint32, tag = "1")]
    pub default_port: u32,
}

#[derive(Clone, PartialEq, prost::Message)]
pub struct FileEndpoint {
    // The one a new file gets comes first.
    #[prost(string, repeated, tag = "1")]
    pub suffixes: Vec<String>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, prost::Enumeration)]
#[repr(i32)]
pub enum DataModel {
    Unspecified = 0,
    Relational = 1,
    KeyValue = 2,
    Document = 3,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, prost::Enumeration)]
#[repr(i32)]
pub enum Category {
    Unspecified = 0,
    Relational = 1,
    Document = 2,
    KeyValue = 3,
    Analytical = 4,
    WideColumn = 5,
}

#[derive(Clone, PartialEq, prost::Message)]
pub struct Opened {
    #[prost(uint64, tag = "1")]
    pub connection: u64,
    #[prost(string, tag = "2")]
    pub server_version: String,
}

#[derive(Clone, PartialEq, prost::Message)]
pub struct Probed {}

#[derive(Clone, PartialEq, prost::Message)]
pub struct Schemas {
    #[prost(message, repeated, tag = "1")]
    pub schemas: Vec<Schema>,
}

#[derive(Clone, PartialEq, prost::Message)]
pub struct Schema {
    #[prost(string, tag = "1")]
    pub name: String,
    #[prost(bool, tag = "2")]
    pub is_default: bool,
    #[prost(bool, tag = "3")]
    pub is_system: bool,
}

#[derive(Clone, PartialEq, prost::Message)]
pub struct Objects {
    #[prost(message, repeated, tag = "1")]
    pub objects: Vec<Object>,
}

#[derive(Clone, PartialEq, prost::Message)]
pub struct Object {
    #[prost(string, optional, tag = "1")]
    pub schema: Option<String>,
    #[prost(string, tag = "2")]
    pub name: String,
    #[prost(enumeration = "ObjectKind", tag = "3")]
    pub kind: i32,
    #[prost(string, optional, tag = "4")]
    pub parent_table: Option<String>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, prost::Enumeration)]
#[repr(i32)]
pub enum ObjectKind {
    Unspecified = 0,
    Table = 1,
    PartitionedTable = 2,
    View = 3,
    MaterializedView = 4,
    ForeignTable = 5,
    Sequence = 6,
    Function = 7,
    Procedure = 8,
    Trigger = 9,
    Dictionary = 10,
    Key = 11,
}

#[derive(Clone, PartialEq, prost::Message)]
pub struct ReadDone {
    #[prost(uint64, tag = "1")]
    pub rows: u64,
    #[prost(bool, tag = "2")]
    pub truncated: bool,
}

#[derive(Clone, PartialEq, prost::Message)]
pub struct Closed {}

// codes run from the outermost error in, as the core's error codes do; message is English for the log only.
#[derive(Clone, PartialEq, prost::Message)]
pub struct Error {
    #[prost(string, repeated, tag = "1")]
    pub codes: Vec<String>,
    #[prost(string, tag = "2")]
    pub message: String,
}
