use tablepro_core::Value;

#[derive(Debug, Clone)]
pub struct DraftRow {
    pub draft_id: u64,
    pub values: Vec<Value>,
    pub touched: Vec<bool>,
}

impl DraftRow {
    pub fn new(draft_id: u64, values: Vec<Value>) -> Self {
        let touched = vec![false; values.len()];
        Self {
            draft_id,
            values,
            touched,
        }
    }

    pub fn set(&mut self, column: usize, value: Value, touched: bool) {
        if let (Some(slot), Some(flag)) = (self.values.get_mut(column), self.touched.get_mut(column)) {
            *slot = value;
            *flag = touched;
        }
    }
}
