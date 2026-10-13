use tablepro_core::sql_syntax::script::{OpenConstruct, ScriptDiagnostic};

/// The warning for something the script planner found, with `line`
/// counted from 1 in the buffer.
pub fn script_diagnostic_message(diagnostic: &ScriptDiagnostic, line: usize) -> String {
    let line = line.to_string();
    let args = [("line", line.as_str())];
    match diagnostic {
        ScriptDiagnostic::Unterminated { construct, .. } => match construct {
            OpenConstruct::StringLiteral => crate::i18n::gettext_f(
                "The string starting on line {line} is never closed. It is sent as written.",
                &args,
            ),
            OpenConstruct::QuotedIdentifier => crate::i18n::gettext_f(
                "The quoted name starting on line {line} is never closed. It is sent as written.",
                &args,
            ),
            OpenConstruct::BlockComment => crate::i18n::gettext_f(
                "The comment starting on line {line} is never closed. It is sent as written.",
                &args,
            ),
            OpenConstruct::DollarQuoted => crate::i18n::gettext_f(
                "The dollar-quoted string starting on line {line} is never closed. It is sent as written.",
                &args,
            ),
        },
    }
}
