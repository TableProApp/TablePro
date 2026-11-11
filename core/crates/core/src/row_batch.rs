use crate::byte_limit::row_bytes;
use crate::value::Value;

// Bounded in bytes too, so a batch of wide rows is not held several times over while a sink copies it.
#[derive(Debug, Default)]
pub struct RowBatch {
    rows: Vec<Vec<Value>>,
    bytes: u64,
}

impl RowBatch {
    pub const MAX_ROWS: usize = 256;
    pub const MAX_BYTES: u64 = 4 * 1024 * 1024;

    pub fn new() -> Self {
        Self::default()
    }

    pub fn push(&mut self, row: Vec<Value>) -> bool {
        self.bytes = self.bytes.saturating_add(row_bytes(&row));
        self.rows.push(row);
        self.is_full()
    }

    pub fn is_full(&self) -> bool {
        self.rows.len() >= Self::MAX_ROWS || self.bytes >= Self::MAX_BYTES
    }

    pub fn is_empty(&self) -> bool {
        self.rows.is_empty()
    }

    pub fn len(&self) -> usize {
        self.rows.len()
    }

    pub fn take(&mut self) -> Vec<Vec<Value>> {
        self.bytes = 0;
        std::mem::take(&mut self.rows)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_batch_of_small_rows_is_full_at_256() {
        let mut batch = RowBatch::new();

        let full: Vec<bool> = (0..RowBatch::MAX_ROWS)
            .map(|n| batch.push(vec![Value::Int(n as i64)]))
            .collect();

        assert!(full[..RowBatch::MAX_ROWS - 1].iter().all(|full| !full));
        assert_eq!(full.last(), Some(&true));
        assert_eq!(batch.take().len(), RowBatch::MAX_ROWS);
        assert!(batch.is_empty());
    }

    #[test]
    fn a_batch_of_wide_rows_is_full_at_4_mib() {
        let mut batch = RowBatch::new();
        let wide = || vec![Value::Text("x".repeat(1024 * 1024))];

        assert!(!batch.push(wide()));
        assert!(!batch.push(wide()));
        assert!(!batch.push(wide()));
        assert!(batch.push(wide()));
        assert_eq!(batch.len(), 4);

        batch.take();
        assert!(!batch.push(vec![Value::Null]), "taking the rows starts the count again");
    }
}
