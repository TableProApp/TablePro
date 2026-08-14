//! Transaction support — follows rust-postgres / sqlx patterns.
//!
//! A `Transaction` borrows a `Client` in a database transaction.
//! All operations on the `Transaction` are executed within the transaction.
//! On `Drop`, the transaction is automatically rolled back if not committed.
//!
//! `commit()` and `rollback()` take `self` (ownership), which releases
//! the mutable borrow on `Client` so it can be used again immediately.

use crate::client::Client;
use crate::error::Result;
use crate::row::ResultSet;
use dameng_types::ToDmValue;

pub struct Transaction<'a> {
    client: &'a mut Client,
    finished: bool,
}

impl<'a> Transaction<'a> {
    /// Commit the transaction, consuming `self` and releasing the Client borrow.
    pub fn commit(mut self) -> Result<()> {
        self.finish_inner("COMMIT")
    }

    /// Roll back the transaction, consuming `self` and releasing the Client borrow.
    pub fn rollback(mut self) -> Result<()> {
        self.finish_inner("ROLLBACK")
    }

    /// Execute a DML statement within the transaction. Returns affected rows.
    pub fn execute(&mut self, sql: &str) -> Result<u64> {
        self.client.execute(sql)
    }

    /// Execute DML with dynamic parameters within the transaction.
    pub fn execute_with_params(&mut self, sql: &str, params: &[&dyn ToDmValue]) -> Result<u64> {
        self.client.execute_with_params(sql, params)
    }

    /// Execute a SELECT query within the transaction.
    pub fn query(&mut self, sql: &str) -> Result<ResultSet> {
        self.client.query(sql)
    }

    /// Execute a SELECT query with dynamic parameters within the transaction.
    pub fn query_with_params(&mut self, sql: &str, params: &[&dyn ToDmValue]) -> Result<ResultSet> {
        self.client.query_with_params(sql, params)
    }

    fn finish_inner(&mut self, command: &str) -> Result<()> {
        self.client.execute(command)?;
        self.client.auto_commit = true;
        self.finished = true;
        Ok(())
    }
}

impl<'a> Drop for Transaction<'a> {
    fn drop(&mut self) {
        if !self.finished {
            let _ = self.client.execute("ROLLBACK");
            self.client.auto_commit = true;
        }
    }
}

impl Client {
    /// Begin a new transaction, returning a `Transaction` handle.
    ///
    /// After `commit()` or `rollback()` (which take `self`), the mutable
    /// borrow on `Client` is released and the `Client` can be used again.
    ///
    /// If the `Transaction` is dropped without commit/rollback, a
    /// `ROLLBACK` is sent automatically (best-effort).
    pub fn transaction(&mut self) -> Result<Transaction<'_>> {
        self.begin()?;
        Ok(Transaction {
            client: self,
            finished: false,
        })
    }
}
