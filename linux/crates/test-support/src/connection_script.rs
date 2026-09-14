use std::collections::VecDeque;

use tablepro_core::{ColumnInfo, DriverError, QueryResult, TableInfo};

use crate::CloseBehaviour;

#[derive(Debug, Default)]
pub struct ConnectionScript {
    pub(crate) list_tables: VecDeque<Result<Vec<TableInfo>, DriverError>>,
    pub(crate) fetch_columns: VecDeque<Result<Vec<ColumnInfo>, DriverError>>,
    pub(crate) query: VecDeque<Result<QueryResult, DriverError>>,
    pub(crate) execute_in_transaction: VecDeque<Result<Vec<u64>, DriverError>>,
    pub(crate) ping: VecDeque<Result<(), DriverError>>,
    pub(crate) close: CloseBehaviour,
}

impl ConnectionScript {
    pub fn with_list_tables(mut self, result: Result<Vec<TableInfo>, DriverError>) -> Self {
        self.list_tables.push_back(result);
        self
    }

    pub fn with_fetch_columns(mut self, result: Result<Vec<ColumnInfo>, DriverError>) -> Self {
        self.fetch_columns.push_back(result);
        self
    }

    pub fn with_query(mut self, result: Result<QueryResult, DriverError>) -> Self {
        self.query.push_back(result);
        self
    }

    pub fn with_execute_in_transaction(mut self, result: Result<Vec<u64>, DriverError>) -> Self {
        self.execute_in_transaction.push_back(result);
        self
    }

    pub fn with_ping(mut self, result: Result<(), DriverError>) -> Self {
        self.ping.push_back(result);
        self
    }

    pub fn with_close(mut self, behaviour: CloseBehaviour) -> Self {
        self.close = behaviour;
        self
    }
}
