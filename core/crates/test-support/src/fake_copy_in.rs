use tablepro_core::UserSql;

/// One `COPY ... FROM STDIN` a `FakeEditorSession` was given.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FakeCopyIn {
    pub statement: UserSql,
    /// Every piece of the rows joined, as far as they came.
    pub data: Vec<u8>,
    pub pieces: usize,
    /// The source said the rows ended, rather than closing or the copy
    /// being cancelled.
    pub ended: bool,
}
