#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct UndecodedValue {
    pub type_name: String,
    pub reason: UndecodableReason,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum UndecodableReason {
    UnsupportedType,
    OutOfRange,
    InvalidEncoding,
}
