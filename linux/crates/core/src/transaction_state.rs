/// Where the connection stands with a transaction.
///
/// `Unknown` is its own answer rather than a guess: an engine that
/// cannot be asked leaves a tab's close guard to warn instead of
/// deciding for the user.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum TransactionState {
    Idle,
    InTransaction,
    /// A statement failed inside the transaction, so the rest is
    /// refused until it is rolled back.
    Failed,
    Unknown,
}
