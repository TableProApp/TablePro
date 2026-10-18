use crate::sql_syntax::script::OpenConstruct;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ScriptDiagnostic {
    Unterminated { construct: OpenConstruct, start: usize },
}
