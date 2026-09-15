/// How a LIKE predicate should read.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct LikeForm {
    pub negated: bool,
    pub case: LikeCase,
    /// Whether the pattern went through `escape_like_text`, which
    /// decides if the SQL needs an ESCAPE clause.
    pub escaped: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LikeCase {
    /// Whatever the column's collation does, which is the engine's own
    /// answer and the one the user's other tools give.
    EngineDefault,
    Insensitive,
}

impl LikeForm {
    /// A Contains, StartsWith or EndsWith filter: the app built the
    /// pattern, so its wildcards are escaped.
    pub fn contains() -> Self {
        Self {
            negated: false,
            case: LikeCase::EngineDefault,
            escaped: true,
        }
    }

    /// A LIKE the user typed, wildcards and all.
    pub fn raw(negated: bool) -> Self {
        Self {
            negated,
            case: LikeCase::EngineDefault,
            escaped: false,
        }
    }

    pub fn insensitive(negated: bool) -> Self {
        Self {
            negated,
            case: LikeCase::Insensitive,
            escaped: false,
        }
    }
}
